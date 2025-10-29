//
//  ImageKit.swift
//  Created by Barak Ben Hur on 29/10/2025.
//
//  Cross-platform (iOS + macOS) image loading library with persistent disk cache,
//  downsampling, ETag/Last-Modified validation, and manual cache invalidation.
//  Now with per-entry disk TTL (from Cache-Control) and memory TTL.
//
//  Features
//  - Memory + disk cache (Application Support, excluded from backup) with LRU trimming
//  - ETag / Last-Modified validation (304 support)
//  - Downsampling to target view size for low memory usage
//  - SwiftUI: AsyncImageView(url:placeholder:)
//  - UIKit: AsyncUIImageView
//  - TTL:
//      * Disk item freshness = override `ttl` ?? HTTP Cache-Control:max-age ?? `defaultTTL`
//      * Memory TTL = `memoryTTL` (config) or falls back to effective disk TTL
//  - Manual cache invalidation (global + per-URL)
//

#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
@inline(__always) private func _platformScale() -> CGFloat { UIScreen.main.scale }
private extension UIImage { var ikCost: Int { Int(size.width * size.height * scale * scale) * 4 } }
@inline(__always) private func _makeImage(from cg: CGImage, scale: CGFloat) -> UIImage {
    UIImage(cgImage: cg, scale: scale, orientation: .up)
}

#elseif canImport(AppKit)
import AppKit
public typealias UIImage = NSImage // keep external API type name
private typealias PlatformImage = NSImage
@inline(__always) private func _platformScale() -> CGFloat { NSScreen.main?.backingScaleFactor ?? 2.0 }
private extension NSImage { var ikCost: Int { Int(size.width * size.height) * 4 } }
@inline(__always) private func _makeImage(from cg: CGImage, scale: CGFloat) -> NSImage {
    NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
#endif

import Foundation
import CryptoKit
import ImageIO

// ===============================================================
// MARK: - Public Facade
// ===============================================================

public enum ImageKit {
    public static let shared = Pipeline()
}

// ===============================================================
// MARK: - Errors
// ===============================================================

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

// MARK: - HTTP Status (simple)

public enum HTTPStatus: Int, Sendable, CustomStringConvertible {
    case ok = 200, notModified = 304, notFound = 404
    public var description: String {
        switch self {
        case .ok: return "OK"; case .notModified: return "Not Modified"; case .notFound: return "Not Found"
        }
    }
}

public extension HTTPURLResponse {
    var status: HTTPStatus? { HTTPStatus(rawValue: statusCode) }
    var isOK: Bool { statusCode == HTTPStatus.ok.rawValue }
    var isNotModified: Bool { statusCode == HTTPStatus.notModified.rawValue }
    var isNotFound: Bool { statusCode == HTTPStatus.notFound.rawValue }
}

// ===============================================================
// MARK: - Configuration
// ===============================================================

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
        defaultTTL: TimeInterval = 4 * 60 * 60, // 4h
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

// ===============================================================
// MARK: - URLSession async fallback (macOS < 12 / iOS < 15)
// ===============================================================

private extension URLSession {
    func ikData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(UIKit)
        if #available(iOS 15, tvOS 15, watchOS 8, *) {
            return try await data(for: request, delegate: nil)
        }
        #elseif canImport(AppKit)
        if #available(macOS 12, *) {
            return try await data(for: request, delegate: nil)
        }
        #endif
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

// ===============================================================
// MARK: - Pipeline
// ===============================================================

public final class Pipeline: @unchecked Sendable {
    public let config: ImageKitConfiguration
    private let session: URLSession
    private let memory = MemoryCache()
    private let disk: DiskCache
    private let inflight = Inflight()
    
    public init(config: ImageKitConfiguration = .init()) {
        self.config  = config
        self.session = URLSession(configuration: config.sessionConfiguration)
        self.disk    = DiskCache(pathName: config.diskPathName, sizeLimit: config.diskBytes, defaultTTL: config.defaultTTL)
        memory.setCostLimit(config.memoryBytes)
    }
    deinit { session.invalidateAndCancel() }
    
    // Load & decode
    @discardableResult
    public func uiImage(
        for url: URL,
        targetSize: CGSize? = nil,
        scale: CGFloat? = nil,
        ttl: TimeInterval? = nil          // per-call override for disk freshness
    ) async throws -> UIImage {
        if Task.isCancelled { throw ImageKitError.cancelled }
        
        let resolvedScale: CGFloat = await {
            if let s = scale { return s }
            return await MainActor.run { _platformScale() }
        }()
        
        let mKey = MemoryCache.Key(url: url, targetSize: targetSize, scale: resolvedScale)
        
        // Memory fast path (TTL-aware)
        if let cached = await self.memory.image(for: mKey) { return cached }
        
        return try await self.inflight.run(key: mKey.cacheKey) {
            // Disk path
            if let candidate = try await self.disk.read(url: url) {
                // Effective disk TTL: param > Cache-Control:max-age > default
                let effDiskTTL = ttl ?? candidate.meta.cacheTTL ?? self.config.defaultTTL
                let freshEnough = candidate.isFresh(now: Date(), ttl: effDiskTTL)
                let wantsRefresh = !freshEnough
                
                if let ui = candidate.decodeDownsampled(to: targetSize, scale: resolvedScale) {
                    let memTTL = self.config.memoryTTL ?? effDiskTTL
                    await self.memory.insert(ui, for: mKey, ttl: memTTL)
                    
                    if wantsRefresh {
                        // async background refresh; keep served image
                        Task { try? await self.refetch(url: url) }
                    }
                    return ui
                }
            }
            
            // Network path
            let (data, meta) = try await self.fetch(url: url)  // meta may contain cacheTTL
            try await self.disk.write(url: url, data: data, meta: meta)
            
            guard let ui = DiskCache.Decoded.decode(data: data, targetSize: targetSize, scale: resolvedScale) else {
                throw ImageKitError.decodingFailed
            }
            let effDiskTTL = ttl ?? meta.cacheTTL ?? self.config.defaultTTL
            let memTTL = self.config.memoryTTL ?? effDiskTTL
            await self.memory.insert(ui, for: mKey, ttl: memTTL)
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
    
    public func prefetch(urls: [URL], maxConcurrent: Int = 4) async {
        await withTaskGroup(of: Void.self) { group in
            let limiter = AsyncSemaphore(value: maxConcurrent)
            for url in urls {
                group.addTask {
                    await limiter.wait()
                    defer { limiter.signal() }
                    _ = try? await self.uiImage(for: url)
                }
            }
            await group.waitForAll()
        }
    }
    
    public func trimCaches() async { try? await self.disk.enforceLimit() }
    public func clearMemory() async { await self.memory.removeAll() }
    
    @discardableResult
    private func refetch(url: URL) async throws -> (Data, DiskCache.Meta) { try await fetch(url: url) }
    
    private func fetch(url: URL) async throws -> (Data, DiskCache.Meta) {
        var request = URLRequest(url: url)
        request.setValue(config.accepts, forHTTPHeaderField: "Accept")
        
        if let cached = try? await self.disk.read(url: url),
           let v = cached.meta.validators() {
            if let etag = v.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lm = v.lastModified { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        }
        
        let (data, response) = try await session.ikData(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImageKitError.missingData }
        
        switch http.status {
        case .some(.ok):
            let meta = DiskCache.Meta.from(http: http)
            return (data, meta)
        case .some(.notModified):
            if let cached = try await self.disk.read(url: url) {
                try await self.disk.touch(url: url)           // refresh lastAccess
                return (cached.data, cached.meta)
            }
            fallthrough
        case .some(.notFound):
            throw ImageKitError.badStatusCode(http.statusCode)
        case .none:
            throw ImageKitError.badStatusCode(http.statusCode)
        }
    }
}

// ===============================================================
// MARK: - Memory Cache (NSCache) with TTL
// ===============================================================

final class MemoryCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let url: URL
        let variant: String
        init(url: URL, targetSize: CGSize?, scale: CGFloat) {
            if let s = targetSize { self.variant = "\(Int(s.width * scale))x\(Int(s.height * scale))" }
            else { self.variant = "orig" }
            self.url = url
        }
        var cacheKey: String { url.absoluteString + "|" + variant }
    }
    
    private final class Box: NSObject {
        let image: UIImage
        let expiresAt: Date
        init(_ i: UIImage, expiresAt: Date) { self.image = i; self.expiresAt = expiresAt }
    }
    
    private let cache = NSCache<NSString, Box>()
    
    func setCostLimit(_ bytes: Int) { cache.totalCostLimit = bytes }
    
    func image(for key: Key) async -> UIImage? {
        guard let box = cache.object(forKey: key.cacheKey as NSString) else { return nil }
        guard box.expiresAt < Date() else {
            cache.removeObject(forKey: key.cacheKey as NSString) // expired
            return nil
        }
        return box.image
    }
    
    func insert(_ image: UIImage, for key: Key, ttl: TimeInterval) async {
        let box = Box(image, expiresAt: Date().addingTimeInterval(ttl))
        cache.setObject(box, forKey: key.cacheKey as NSString, cost: image.ikCost)
    }
    
    func removeAll() async { cache.removeAllObjects() }
}

// ===============================================================
// MARK: - Disk Cache (Application Support) with per-entry TTL
// ===============================================================

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
            // Parse Cache-Control: max-age=####
            var ttlFromCacheControl: TimeInterval? = nil
            if let cc = hdr("Cache-Control")?.lowercased() {
                if let r = cc.range(of: "max-age=") {
                    let rest = cc[r.upperBound...]
                    let digits = rest.prefix { $0.isNumber }
                    if let secs = TimeInterval(digits) { ttlFromCacheControl = secs }
                }
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
            let cg: CGImage?
            if opts[kCGImageSourceCreateThumbnailFromImageAlways] as? Bool == true {
                cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            } else {
                cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
            }
            #if canImport(UIKit)
            return cg.map { _makeImage(from: $0, scale: scale) } ?? UIImage(data: data)
            #else
            if let cg = cg { return _makeImage(from: cg, scale: scale) }
            return UIImage(data: data)
            #endif
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
        self.sizeLimit = sizeLimit
        self.defaultTTL = defaultTTL
        let base = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
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
        let key = key(for: url)
        let dURL = dataURL(for: key)
        let mURL = metaURL(for: key)
        guard let data = try? Data(contentsOf: dURL) else { return nil }
        if let meta = try? JSONDecoder.iso8601.decode(Meta.self, from: Data(contentsOf: mURL)) {
            return Decoded(data: data, meta: meta)
        } else {
            // tolerate missing meta
            let basic = Meta(etag: nil, lastModified: nil, contentType: nil,
                             lastAccess: Date(), size: data.count, created: Date(),
                             cacheTTL: nil)
            return Decoded(data: data, meta: basic)
        }
    }
    
    func touch(url: URL) throws {
        let key = key(for: url)
        let mURL = metaURL(for: key)
        guard var meta = try? JSONDecoder.iso8601.decode(Meta.self, from: Data(contentsOf: mURL)) else { return }
        meta.lastAccess = Date()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: mURL, options: .atomic)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dataURL(for: key).path)
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

// ===============================================================
// MARK: - In-Flight Coalescing
// ===============================================================

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

// ===============================================================
// MARK: - Async Semaphore
// ===============================================================

final class AsyncSemaphore: @unchecked Sendable {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(value: Int) { self.value = value }
    func wait() async {
        await withCheckedContinuation { cont in
            if value > 0 { value -= 1; cont.resume() }
            else { waiters.append(cont) }
        }
    }
    func signal() {
        if let c = waiters.first { waiters.removeFirst(); c.resume() } else { value += 1 }
    }
}

// ===============================================================
// MARK: - SwiftUI View
// ===============================================================

#if canImport(SwiftUI)
import SwiftUI

public struct AsyncImageView<Placeholder: View>: View {
    public let url: URL?
    public let placeholder: () -> Placeholder
    
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    
    public init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }
    
    public var body: some View {
        GeometryReader { geo in
            Group {
                if let img = uiImage {
                    #if canImport(UIKit)
                    Image(uiImage: img).resizable().scaledToFit()
                    #else
                    Image(nsImage: img).resizable().scaledToFit()
                    #endif
                } else {
                    placeholder()
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { return }
                if isLoading { return }
                isLoading = true
                defer { isLoading = false }
                do {
                    let img = try await ImageKit.shared.uiImage(
                        for: url,
                        targetSize: geo.size,
                        scale: nil,
                        ttl: nil
                    )
                    withAnimation(.easeIn(duration: 0.15)) { self.uiImage = img }
                } catch ImageKitError.cancelled {
                    // benign on refresh/scroll reuse
                } catch {
                    // keep placeholder
                }
            }
        }
    }
}
#endif

// ===============================================================
// MARK: - UIKit Helper View
// ===============================================================

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
    
    private let imageView = UIImageView()
    private let indicator = UIActivityIndicatorView(style: .medium)
    private var loadTask: Task<Void, Never>?
    private var lastTargetSize: CGSize = .zero
    
    public override init(frame: CGRect) { super.init(frame: frame); commonInit() }
    public required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    deinit { cancel() }
    
    private func commonInit() {
        clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        addSubview(imageView); addSubview(indicator)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    
    public func set(url: URL?, placeholder: UIImage? = nil, ttl: TimeInterval? = nil) {
        self.placeholder = placeholder; self.ttl = ttl; self.url = url
    }
    public func cancel() { loadTask?.cancel(); loadTask = nil }
    
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
           abs(newSize.width - lastTargetSize.width) > 1 || abs(newSize.height - lastTargetSize.height) > 1 {
            load()
        }
    }
    
    private func load() {
        cancel()
        imageView.image = placeholder
        guard let url = url else { return }
        indicator.startAnimating()
        let target = resolvedTargetSize()
        lastTargetSize = target
        
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let img = try await ImageKit.shared.uiImage(
                    for: url, targetSize: target, scale: nil, ttl: ttl
                )
                if Task.isCancelled { return }
                await MainActor.run {
                    self.indicator.stopAnimating()
                    if self.animated {
                        UIView.transition(with: self.imageView, duration: 0.25, options: .transitionCrossDissolve) {
                            self.imageView.image = img
                        }
                    } else {
                        self.imageView.image = img
                    }
                }
            } catch ImageKitError.cancelled {
                await MainActor.run { self.indicator.stopAnimating() }
            } catch {
                await MainActor.run { self.indicator.stopAnimating() }
            }
        }
    }
}
#endif

// ===============================================================
// MARK: - Lifecycle Helpers
// ===============================================================

public enum ImageKitLifecycle {
    public static func applicationDidReceiveMemoryWarning() {
        Task { await ImageKit.shared.clearMemory() }
    }
    public static func applicationDidEnterBackground() {
        Task { await ImageKit.shared.trimCaches() }
    }
}
