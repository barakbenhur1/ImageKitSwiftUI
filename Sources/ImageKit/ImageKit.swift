//
//  ImageKit.swift
//  Created by Barak Ben Hur on 29/10/2025.
//

import Foundation
import CryptoKit
import ImageIO

#if canImport(UIKit)
import UIKit
@inline(__always) private func _platformScale() -> CGFloat { UIScreen.main.scale }
private extension UIImage {
    var ikCost: Int { Int(size.width * size.height * scale * scale) * 4 }
}
@inline(__always) private func _makeImage(from cg: CGImage, scale: CGFloat) -> UIImage {
    UIImage(cgImage: cg, scale: scale, orientation: .up)
}
#else
#error("ImageKit is iOS-only in this target.")
#endif

// MARK: - Public Facade

public enum ImageKit {
    public static let shared = Pipeline()
}

// MARK: - Errors

public enum ImageKitError: Error, LocalizedError {
    case badStatusCode(Int)
    case cancelled
    case missingData
    case decodingFailed
    case fileIOFailed

    public var errorDescription: String? {
        switch self {
        case .badStatusCode(let c): return "HTTP status code: \(c)"
        case .cancelled:            return "Cancelled"
        case .missingData:          return "No data"
        case .decodingFailed:       return "Failed to decode image"
        case .fileIOFailed:         return "File I/O failed"
        }
    }
}

// MARK: - HTTP Status

public enum HTTPStatus: Int, Sendable, CustomStringConvertible {
    case ok = 200, notModified = 304, notFound = 404
    public var description: String {
        switch self {
        case .ok: return "OK"
        case .notModified: return "Not Modified"
        case .notFound: return "Not Found"
        }
    }
}

public extension HTTPURLResponse {
    var status: HTTPStatus? { HTTPStatus(rawValue: statusCode) }
    var isOK: Bool { statusCode == HTTPStatus.ok.rawValue }
    var isNotModified: Bool { statusCode == HTTPStatus.notModified.rawValue }
    var isNotFound: Bool { statusCode == HTTPStatus.notFound.rawValue }
}

// MARK: - Configuration

public struct ImageKitConfiguration: Sendable {
    public var memoryBytes: Int                 // NSCache budget (bytes)
    public var diskBytes: Int64                 // Disk budget (bytes)
    public var diskPathName: String             // Folder name under Application Support
    public var defaultTTL: TimeInterval         // Default disk TTL if server gives none
    public var sessionConfiguration: URLSessionConfiguration
    public var accepts: String                  // Accept header
    public var memoryTTL: TimeInterval?         // Optional RAM TTL (nil → use effective disk TTL)

    public init(
        memoryBytes: Int         = 128 * 1024 * 1024,
        diskBytes: Int64         = 512 * 1024 * 1024,
        diskPathName: String     = "ImageKitCache",
        defaultTTL: TimeInterval = 4 * 60 * 60,
        sessionConfiguration: URLSessionConfiguration? = nil,
        accepts: String = "image/avif,image/webp,image/*;q=0.8",
        memoryTTL: TimeInterval? = nil
    ) {
        self.memoryBytes          = memoryBytes
        self.diskBytes            = diskBytes
        self.diskPathName         = diskPathName
        self.defaultTTL           = defaultTTL
        self.accepts              = accepts
        self.memoryTTL            = memoryTTL
        self.sessionConfiguration = sessionConfiguration ?? {
            let c = URLSessionConfiguration.default
            c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            c.urlCache = nil
            c.httpMaximumConnectionsPerHost = 6
            c.timeoutIntervalForRequest     = 30
            c.timeoutIntervalForResource    = 120
            return c
        }()
    }
}

// MARK: - URLSession async fallback (iOS 14 and lower)

private extension URLSession {
    func ikData(for request: URLRequest) async throws -> (Data, URLResponse) {
        if #available(iOS 15, tvOS 15, watchOS 8, *) {
            return try await data(for: request, delegate: nil)
        }
        return try await withCheckedThrowingContinuation { cont in
            let task = self.dataTask(with: request) { data, resp, err in
                if let err = err { cont.resume(throwing: err); return }
                guard let data = data, let resp = resp else {
                    cont.resume(throwing: ImageKitError.missingData); return
                }
                cont.resume(returning: (data, resp))
            }
            task.resume()
        }
    }
}

// MARK: - Pipeline

public final class Pipeline: @unchecked Sendable {
    public let config: ImageKitConfiguration
    private let session: URLSession
    private let memory = MemoryCache()
    private let disk: DiskCache
    private let inflight = Inflight()

    public init(config: ImageKitConfiguration = .init()) {
        self.config  = config
        self.session = URLSession(configuration: config.sessionConfiguration)
        self.disk    = DiskCache(pathName: config.diskPathName,
                                 sizeLimit: config.diskBytes,
                                 defaultTTL: config.defaultTTL)
        self.memory.setCostLimit(config.memoryBytes)
    }

    deinit { session.invalidateAndCancel() }

    @discardableResult
    public func uiImage(
        for url: URL,
        targetSize: CGSize? = nil,
        scale: CGFloat? = nil,
        ttl: TimeInterval? = nil
    ) async throws -> UIImage {
        if Task.isCancelled { throw ImageKitError.cancelled }

        let resolvedScale: CGFloat = await {
            if let s = scale { return s }
            return await MainActor.run { _platformScale() }
        }()

        let mKey = MemoryCache.Key(url: url, targetSize: targetSize, scale: resolvedScale)

        // Memory fast path (TTL-aware)
        if let cached = await self.memory.image(for: mKey) { return cached }

        // Coalesced work; capture weak self to avoid long-lived retain cycles
        return try await inflight.run(key: mKey.cacheKey) { [weak self] in
            guard let self else { throw ImageKitError.cancelled }

            // Disk path
            if let candidate = try await disk.read(url: url) {
                let effDiskTTL  = ttl ?? candidate.meta.cacheTTL ?? config.defaultTTL
                let wantsRefresh = !candidate.isFresh(now: Date(), ttl: effDiskTTL)

                if let ui = candidate.decodeDownsampled(to: targetSize, scale: resolvedScale) {
                    let memTTL = config.memoryTTL ?? effDiskTTL
                    await memory.insert(ui, for: mKey, ttl: memTTL)

                    if wantsRefresh {
                        // Background refresh; weak capture to avoid retaining self unnecessarily
                        Task { [weak self] in
                            guard let self else { return }
                            _ = try? await refetch(url: url)
                        }
                    }
                    return ui
                }
            }

            // Network path
            let (data, meta) = try await fetch(url: url)
            try await disk.write(url: url, data: data, meta: meta)

            guard let ui = DiskCache.Decoded.decode(data: data,
                                                    targetSize: targetSize,
                                                    scale: resolvedScale) else {
                throw ImageKitError.decodingFailed
            }
            let effDiskTTL = ttl ?? meta.cacheTTL ?? config.defaultTTL
            let memTTL     = config.memoryTTL ?? effDiskTTL
            await memory.insert(ui, for: mKey, ttl: memTTL)
            return ui
        }
    }

    public func invalidateAll() async {
        await self.memory.removeAll()
        try? await self.disk.removeAll()
    }

    public func invalidate(url: URL) async {
        try? await self.disk.remove(url: url)
        await self.memory.removeAll() // conservative: drop all RAM variants
    }

    public func trimCaches() async { try? await self.disk.enforceLimit() }
    public func clearMemory() async { await self.memory.removeAll() }

    @discardableResult
    private func refetch(url: URL) async throws -> (Data, DiskCache.Meta) {
        try await fetch(url: url)
    }

    private func fetch(url: URL) async throws -> (Data, DiskCache.Meta) {
        var request = URLRequest(url: url)
        request.setValue(config.accepts, forHTTPHeaderField: "Accept")

        if let cached = try? await self.disk.read(url: url),
           let v = cached.meta.validators() {
            if let etag = v.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lm   = v.lastModified { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        }

        let (data, response) = try await session.ikData(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImageKitError.missingData }

        switch http.status {
        case .some(.ok):
            let meta = DiskCache.Meta.from(http: http)
            return (data, meta)
        case .some(.notModified):
            if let cached = try await self.disk.read(url: url) {
                try await self.disk.touch(url: url)   // refresh lastAccess
                return (cached.data, cached.meta)
            }
            fallthrough
        case .some(.notFound), .none:
            throw ImageKitError.badStatusCode(http.statusCode)
        }
    }
}

// MARK: - Memory Cache (NSCache) with TTL

final class MemoryCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let url: URL
        let variant: String
        init(url: URL, targetSize: CGSize?, scale: CGFloat) {
            if let s = targetSize {
                self.variant = "\(Int(s.width * scale))x\(Int(s.height * scale))"
            } else {
                self.variant = "orig"
            }
            self.url = url
        }
        var cacheKey: String { url.absoluteString + "|" + variant }
    }

    private final class Box: NSObject {
        let image: UIImage
        let expiresAt: Date
        init(_ i: UIImage, expiresAt: Date) {
            self.image = i
            self.expiresAt = expiresAt
        }
    }

    private let cache = NSCache<NSString, Box>()

    func setCostLimit(_ bytes: Int) { cache.totalCostLimit = bytes }

    func image(for key: Key) async -> UIImage? {
        guard let box = cache.object(forKey: key.cacheKey as NSString) else { return nil }
        if Date() < box.expiresAt { return box.image }
        cache.removeObject(forKey: key.cacheKey as NSString) // expired
        return nil
    }

    func insert(_ image: UIImage, for key: Key, ttl: TimeInterval) async {
        let box = Box(image, expiresAt: Date().addingTimeInterval(ttl))
        cache.setObject(box, forKey: key.cacheKey as NSString, cost: image.ikCost)
    }

    func removeAll() async { cache.removeAllObjects() }
}

// MARK: - Disk Cache (Application Support) with per-entry TTL

actor DiskCache {
    struct Meta: Codable, Sendable {
        var etag: String?
        var lastModified: String?
        var contentType: String?
        var lastAccess: Date
        var size: Int
        var created: Date
        var cacheTTL: TimeInterval?    // from Cache-Control:max-age

        static func from(http: HTTPURLResponse) -> Meta {
            let headers = http.allHeaderFields
            func hdr(_ name: String) -> String? {
                for (k, v) in headers {
                    if String(describing: k).caseInsensitiveCompare(name) == .orderedSame {
                        return String(describing: v)
                    }
                }
                return nil
            }
            var ttlFromCacheControl: TimeInterval? = nil
            if let cc = hdr("Cache-Control")?.lowercased(),
               let r = cc.range(of: "max-age=") {
                let rest = cc[r.upperBound...]
                let digits = rest.prefix { $0.isNumber }
                if let secs = TimeInterval(digits) { ttlFromCacheControl = secs }
            }
            return Meta(
                etag: hdr("Etag"),
                lastModified: hdr("Last-Modified"),
                contentType: hdr("Content-Type"),
                lastAccess: Date(),
                size: Int(http.expectedContentLength > 0 ? http.expectedContentLength : 0),
                created: Date(),
                cacheTTL: ttlFromCacheControl
            )
        }
        func validators() -> (etag: String?, lastModified: String?)? { (etag, lastModified) }
    }

    struct Decoded: Sendable {
        let data: Data
        let meta: Meta

        func decodeDownsampled(to targetSize: CGSize?, scale: CGFloat) -> UIImage? {
            Self.decode(data: data, targetSize: targetSize, scale: scale)
        }

        static func decode(data: Data, targetSize: CGSize?, scale: CGFloat) -> UIImage? {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                return UIImage(data: data)
            }
            var opts: [CFString: Any] = [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let ts = targetSize {
                let maxDim = max(ts.width * scale, ts.height * scale)
                opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
                opts[kCGImageSourceThumbnailMaxPixelSize] = Int(maxDim)
            }
            let cg: CGImage? = (opts[kCGImageSourceCreateThumbnailFromImageAlways] as? Bool == true)
                ? CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                : CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)

            return cg.map { _makeImage(from: $0, scale: scale) } ?? UIImage(data: data)
        }

        /// Freshness check for disk (age since lastAccess).
        func isFresh(now: Date, ttl: TimeInterval) -> Bool {
            now.timeIntervalSince(meta.lastAccess) < ttl
        }
    }

    private let fm = FileManager()
    private let root: URL
    private let sizeLimit: Int64
    private let defaultTTL: TimeInterval

    init(pathName: String, sizeLimit: Int64, defaultTTL: TimeInterval) {
        self.sizeLimit  = sizeLimit
        self.defaultTTL = defaultTTL
        let base = try! fm.url(for: .applicationSupportDirectory,
                               in: .userDomainMask,
                               appropriateFor: nil,
                               create: true)
        self.root = base.appendingPathComponent(pathName, isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        var r = self.root; try? r.setResourceValues(rv)
    }

    func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func dataURL(for key: String) -> URL { root.appendingPathComponent(key + ".img") }
    func metaURL(for key: String) -> URL { root.appendingPathComponent(key + ".json") }

    func write(url: URL, data: Data, meta: Meta) throws {
        let key = key(for: url)
        do {
            try data.write(to: dataURL(for: key), options: .atomic)
            var m = meta; m.lastAccess = Date()
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(m).write(to: metaURL(for: key), options: .atomic)
        } catch { throw ImageKitError.fileIOFailed }
        try enforceLimit()
    }

    func read(url: URL) throws -> Decoded? {
        let key  = key(for: url)
        let dURL = dataURL(for: key)
        let mURL = metaURL(for: key)
        guard let data = try? Data(contentsOf: dURL) else { return nil }
        if let meta = try? JSONDecoder.iso8601.decode(Meta.self, from: Data(contentsOf: mURL)) {
            return Decoded(data: data, meta: meta)
        } else {
            let basic = Meta(etag: nil, lastModified: nil, contentType: nil,
                             lastAccess: Date(), size: data.count, created: Date(),
                             cacheTTL: nil)
            return Decoded(data: data, meta: basic)
        }
    }

    func touch(url: URL) throws {
        let key = key(for: url)
        let mURL = metaURL(for: key)
        guard var meta = try? JSONDecoder.iso8601.decode(Meta.self,
                                                         from: Data(contentsOf: mURL)) else { return }
        meta.lastAccess = Date()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: mURL, options: .atomic)
        try? fm.setAttributes([.modificationDate: Date()],
                              ofItemAtPath: dataURL(for: key).path)
    }

    func remove(url: URL) throws {
        let key = key(for: url)
        try? fm.removeItem(at: dataURL(for: key))
        try? fm.removeItem(at: metaURL(for: key))
    }

    func removeAll() throws {
        try fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        var r = self.root; try? r.setResourceValues(rv)
    }

    func enforceLimit() throws {
        let urls = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "img" }

        var total: Int64 = 0
        var entries: [(url: URL, date: Date, size: Int64)] = []
        for u in urls {
            let res  = try u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = res.contentModificationDate ?? Date.distantPast
            let size = Int64(res.fileSize ?? 0)
            total += size
            entries.append((u, date, size))
        }
        if total <= sizeLimit { return }
        entries.sort { $0.date < $1.date } // LRU-ish via mod date
        for e in entries {
            try? fm.removeItem(at: e.url)
            let mURL = e.url.deletingPathExtension().appendingPathExtension("json")
            try? fm.removeItem(at: mURL)
            total -= e.size
            if total <= sizeLimit { break }
        }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

// MARK: - In-Flight Coalescing

actor Inflight {
    private var tasks: [String: Task<UIImage, Error>] = [:]

    func run(key: String, _ block: @escaping () async throws -> UIImage) async throws -> UIImage {
        if let existing = tasks[key] { return try await existing.value }
        let t = Task { try await block() }
        tasks[key] = t
        defer { tasks.removeValue(forKey: key) }
        return try await t.value
    }
}

// MARK: - SwiftUI View

#if canImport(SwiftUI)
import SwiftUI

public struct AsyncImageView<Placeholder: View>: View {
    public let url: URL?
    public let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var didFail = false

    public init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }

    public var body: some View {
        GeometryReader { geo in
            Group {
                if let img = uiImage {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    if didFail { unavailableView() }
                    else { placeholder() }
                }
            }
            .clipped()
            .task(id: url) {
                guard let url, !isLoading else { return }
                isLoading = true
                defer { isLoading = false }
                do {
                    let img = try await ImageKit.shared.uiImage(
                        for: url,
                        targetSize: geo.size,
                        scale: nil,
                        ttl: nil
                    )
                    withAnimation(.easeIn(duration: 0.15)) {
                        self.uiImage = img
                        self.didFail = false
                    }
                } catch ImageKitError.cancelled {
                    // benign on refresh/scroll reuse
                } catch {
                    withAnimation(.easeIn(duration: 0.15)) { self.didFail = true }
                }
            }
        }
    }

    @ViewBuilder
    private func unavailableView() -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").imageScale(.large)
            Text("Image unavailable").font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Image unavailable")
    }
}
#endif

// MARK: - UIKit Helper View

#if canImport(UIKit)
import UIKit

public final class AsyncUIImageView: UIView {
    public var url: URL? { didSet { load() } }
    public var placeholder: UIImage? { didSet { imageView.image = placeholder } }
    public var ttl: TimeInterval?
    public var animated: Bool = true

    public override var contentMode: UIView.ContentMode {
        didSet { imageView.contentMode = contentMode }
    }

    // MARK: - Subviews
    private let imageView  = UIImageView()
    private let indicator  = UIActivityIndicatorView(style: .medium)
    private let unavailableOverlay = UIView()
    private let unavailableIcon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
    private let unavailableLabel: UILabel = {
        let l = UILabel()
        let base = UIFont.preferredFont(forTextStyle: .footnote)
        l.font = UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        l.text = "Image unavailable"
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 1
        return l
    }()
    private var loadTask: Task<Void, Never>?
    private var lastTargetSize: CGSize = .zero

    // MARK: - Init
    public override init(frame: CGRect) { super.init(frame: frame); commonInit() }
    public required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    deinit { cancel() }

    private func commonInit() {
        clipsToBounds = true

        // Image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill

        // Spinner
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true

        // Unavailable overlay (covers entire view)
        unavailableOverlay.translatesAutoresizingMaskIntoConstraints = false
        unavailableOverlay.isUserInteractionEnabled = false
        unavailableOverlay.isAccessibilityElement = true
        unavailableOverlay.accessibilityLabel = "Image unavailable"
        unavailableOverlay.isHidden = true

        // Icon styling
        unavailableIcon.translatesAutoresizingMaskIntoConstraints = false
        unavailableIcon.tintColor = .secondaryLabel
        unavailableIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(scale: .large)
        unavailableIcon.setContentHuggingPriority(.required, for: .vertical)

        // Stack inside overlay
        let stack = UIStackView(arrangedSubviews: [unavailableIcon, unavailableLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8

        addSubview(imageView)
        addSubview(indicator)
        addSubview(unavailableOverlay)
        unavailableOverlay.addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            unavailableOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            unavailableOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            unavailableOverlay.topAnchor.constraint(equalTo: topAnchor),
            unavailableOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.centerXAnchor.constraint(equalTo: unavailableOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: unavailableOverlay.centerYAnchor)
        ])
    }

    // MARK: - API
    public func set(url: URL?, placeholder: UIImage? = nil, ttl: TimeInterval? = nil) {
        self.placeholder = placeholder
        self.ttl = ttl
        self.url = url
    }

    public func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Layout
    private func resolvedTargetSize() -> CGSize {
        layoutIfNeeded()
        var size = bounds.size
        if size == .zero { size = CGSize(width: 200, height: 200) }
        return size
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let newSize = bounds.size
        if url != nil, newSize != .zero,
           abs(newSize.width - lastTargetSize.width) > 1 ||
           abs(newSize.height - lastTargetSize.height) > 1 {
            load()
        }
    }

    // MARK: - Unavailable overlay
    private func showUnavailable(_ show: Bool) {
        if unavailableOverlay.isHidden == !show { return }
        unavailableOverlay.isHidden = !show
    }

    // MARK: - Loading
    private func load() {
        cancel()
        imageView.image = placeholder
        showUnavailable(false)

        guard let url = url else { return }
        indicator.startAnimating()
        let target = resolvedTargetSize()
        lastTargetSize = target

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let img = try await ImageKit.shared.uiImage(
                    for: url, targetSize: target, scale: nil, ttl: self.ttl
                )
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.indicator.stopAnimating()
                    self.showUnavailable(false)
                    if self.animated {
                        UIView.transition(with: self.imageView, duration: 0.25, options: .transitionCrossDissolve) {
                            self.imageView.image = img
                        }
                    } else {
                        self.imageView.image = img
                    }
                }
            } catch ImageKitError.cancelled {
                await MainActor.run { [weak self] in
                    self?.indicator.stopAnimating()
                    // cancelled: keep current content, do not show unavailable
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.indicator.stopAnimating()
                    self.showUnavailable(true) 
                }
            }
        }
    }
}
#endif

// MARK: - Lifecycle

public enum ImageKitLifecycle {
    public static func applicationDidReceiveMemoryWarning() {
        Task { await ImageKit.shared.clearMemory() }
    }
    public static func applicationDidEnterBackground() {
        Task { await ImageKit.shared.trimCaches() }
    }
}
