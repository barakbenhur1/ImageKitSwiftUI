//
//  ImageKit.swift
//  Created by Barak Ben Hur on 29/10/2025.
//
//  SwiftUI-first image loading library with persistent disk cache,
//  downsampling, and manual cache invalidation. Zero third-party SDKs.
//
//  Features
//  - Memory + disk cache (Application Support, excluded from backup) with LRU trimming
//  - ETag / Last-Modified validation (304 support)
//  - Downsampling to target view size for low memory usage
//  - SwiftUI: AsyncImageView(url:placeholder:)
//  - Manual cache invalidation (global + per-URL)
//

import Foundation
import UIKit
import CryptoKit
import ImageIO

// ===============================================================
// MARK: - Public Facade
// ===============================================================

/// Entry point to the library.
public enum ImageKit {
    /// Shared pipeline (configurable if you add your own initializer).
    public static let shared = Pipeline()
}

// ===============================================================
// MARK: - Errors
// ===============================================================

/// Library error domain.
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
    case ok          = 200
    case notModified = 304
    case notFound    = 404

    public var description: String {
        switch self {
        case .ok:          return "OK"
        case .notModified: return "Not Modified"
        case .notFound:    return "Not Found"
        }
    }
}

public extension HTTPURLResponse {
    /// Map to our simple status set (nil if it's not 200/304/404).
    var status: HTTPStatus? { HTTPStatus(rawValue: statusCode) }

    // Quick predicates, if you prefer them:
    var isOK: Bool { statusCode == HTTPStatus.ok.rawValue }
    var isNotModified: Bool { statusCode == HTTPStatus.notModified.rawValue }
    var isNotFound: Bool { statusCode == HTTPStatus.notFound.rawValue }
}

// ===============================================================
// MARK: - Configuration
// ===============================================================

/// Runtime configuration for the image pipeline.
public struct ImageKitConfiguration: Sendable {
    /// In-memory cache budget in bytes (approximate).
    public var memoryBytes: Int            // e.g., 128 MB
    /// On-disk cache budget in bytes (hard limit; LRU trim).
    public var diskBytes: Int64            // e.g., 512 MB
    /// Folder name inside Application Support.
    public var diskPathName: String        // e.g., "ImageKitCache"
    /// Default freshness horizon. If older and 304 validators are missing, a refresh is attempted.
    public var defaultTTL: TimeInterval    // e.g., 30 days
    /// URLSession configuration (we manage caching ourselves).
    public var sessionConfiguration: URLSessionConfiguration
    /// Accept header to prefer modern formats when available.
    public var accepts: String
    
    public init(
        memoryBytes: Int = 128 * 1024 * 1024,
        diskBytes: Int64 = 512 * 1024 * 1024,
        diskPathName: String = "ImageKitCache",
        defaultTTL: TimeInterval = 30 * 24 * 60 * 60,
        sessionConfiguration: URLSessionConfiguration = {
            let c = URLSessionConfiguration.default
            c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData // we manage caching
            c.urlCache = nil
            c.httpMaximumConnectionsPerHost = 6
            c.timeoutIntervalForRequest = 30
            c.timeoutIntervalForResource = 120
            return c
        }(),
        accepts: String = "image/avif,image/webp,image/*;q=0.8"
    ) {
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.diskPathName = diskPathName
        self.defaultTTL = defaultTTL
        self.sessionConfiguration = sessionConfiguration
        self.accepts = accepts
    }
}

// ===============================================================
// MARK: - Pipeline
// ===============================================================

/// Fetch/decode pipeline with coalescing, memory+disk cache, and validation.
public final class Pipeline: @unchecked Sendable {
    
    // -----------------------------------------------------------
    // MARK: Public State
    // -----------------------------------------------------------
    
    /// Effective configuration currently in use.
    public let config: ImageKitConfiguration
    
    // -----------------------------------------------------------
    // MARK: Private State
    // -----------------------------------------------------------
    
    private let session: URLSession
    private let memory = MemoryCache()
    private let disk: DiskCache
    private let inflight = Inflight()
    
    // -----------------------------------------------------------
    // MARK: Init / Deinit
    // -----------------------------------------------------------
    
    /// Create a pipeline.
    /// - Parameter config: The configuration to use (see `ImageKitConfiguration`).
    public init(config: ImageKitConfiguration = .init()) {
        self.config  = config
        self.session = URLSession(configuration: config.sessionConfiguration)
        self.disk    = DiskCache(pathName: config.diskPathName, sizeLimit: config.diskBytes, defaultTTL: config.defaultTTL)
        memory.setCostLimit(config.memoryBytes)
    }
    
    deinit { session.invalidateAndCancel() }
    
    // -----------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------
    
    /// Load and decode a `UIImage`. Safe to call off the main actor.
    ///
    /// The method:
    /// 1. Checks the in-memory cache for a downsampled variant.
    /// 2. If missing, attempts to read original bytes from disk, decodes (downsampled to `targetSize`) and returns immediately.
    /// 3. If the disk item is stale per TTL, a network refresh is performed opportunistically.
    /// 4. If not on disk, fetches the bytes from the network (using ETag/Last-Modified when available), writes to disk, decodes and caches in memory.
    ///
    /// - Parameters:
    ///   - url: Remote image URL.
    ///   - targetSize: Desired render size in **points** (e.g., the SwiftUI view size). Decoding is downsampled to this size.
    ///   - scale: Display scale to combine with `targetSize` (defaults to `UIScreen.main.scale`, resolved safely on main actor).
    ///   - ttl: Optional TTL override for this request. If not provided, `config.defaultTTL` is used.
    /// - Returns: A decoded `UIImage`.
    /// - Throws: `ImageKitError` on network/decoding failures.
    @discardableResult
    public func uiImage(
        for url: URL,
        targetSize: CGSize? = nil,
        scale: CGFloat? = nil,
        ttl: TimeInterval? = nil
    ) async throws -> UIImage {
        if Task.isCancelled { throw ImageKitError.cancelled }
        
        // Resolve device scale on the main actor only if needed
        let resolvedScale: CGFloat
        if let s = scale {
            resolvedScale = s
        } else {
            resolvedScale = await MainActor.run { UIScreen.main.scale }
        }
        
        let mKey = MemoryCache.Key(url: url, targetSize: targetSize, scale: resolvedScale)
        if let cached = await self.memory.image(for: mKey) { return cached }
        
        return try await self.inflight.run(key: mKey.cacheKey) {
            // 1) Disk fast path (decode + optional background refresh)
            if let candidate = try await self.disk.read(url: url) {
                let freshEnough = candidate.isFresh(now: Date(), ttl: ttl ?? self.config.defaultTTL)
                let wantsRefresh = !freshEnough
                
                if let ui = candidate.decodeDownsampled(to: targetSize, scale: resolvedScale) {
                    await self.memory.insert(ui, for: mKey)
                    if wantsRefresh { Task { try? await self.refetch(url: url) } }
                    return ui
                }
            }
            
            // 2) Network fetch (with validators when present)
            let (data, meta) = try await self.fetch(url: url)
            try await self.disk.write(url: url, data: data, meta: meta)
            
            guard let ui = DiskCache.Decoded.decode(data: data, targetSize: targetSize, scale: resolvedScale) else {
                throw ImageKitError.decodingFailed
            }
            await self.memory.insert(ui, for: mKey)
            return ui
        }
    }
    
    /// Remove **both** memory and disk caches.
    public func invalidateAll() async {
        await self.memory.removeAll()
        try? await self.disk.removeAll()
    }
    
    /// Remove a **single URL** from disk (best-effort) and drop memory cache.
    /// - Parameter url: The image URL to evict.
    public func invalidate(url: URL) async {
        try? await self.disk.remove(url: url)
        await self.memory.removeAll() // conservative: ensure no stale variant remains
    }
    
    /// Prefetch a list of URLs into disk (and memory if decoded as part of the pipeline).
    /// - Parameters:
    ///   - urls: URLs to prefetch.
    ///   - maxConcurrent: Max concurrent downloads.
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
    
    /// Trim caches to their budget (disk LRU). Use in background/memory-warning hooks.
    public func trimCaches() async {
        try? await self.disk.enforceLimit()
        // For memory, NSCache is budgeted by `totalCostLimit`; no explicit trim API beyond removal.
    }
    
    /// Clear in-memory cache only (keeps disk persistent between launches).
    public func clearMemory() async {
        await self.memory.removeAll()
    }
    
    // -----------------------------------------------------------
    // MARK: Internal Helpers
    // -----------------------------------------------------------
    
    /// Force a refetch and rewrite to disk (used after TTL expiry).
    @discardableResult
    private func refetch(url: URL) async throws -> (Data, DiskCache.Meta)   {
        try await fetch(url: url) // write happens in fetch()->disk.write via the UI path
    }
    
    /// Perform a network fetch with conditional validators when available.
    private func fetch(url: URL) async throws -> (Data, DiskCache.Meta) {
        var request = URLRequest(url: url)
        request.setValue(config.accepts, forHTTPHeaderField: "Accept")
        
        if let cached = try? await self.disk.read(url: url),
           let validators = cached.meta.validators() {
            if let etag   = validators.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lm     = validators.lastModified { request.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        }
        
        let (data, response) = try await session.data(for: request, delegate: nil)
        guard let http = response as? HTTPURLResponse else { throw ImageKitError.missingData }
        
        switch http.status {
        case .some(.ok):
            let meta = DiskCache.Meta.from(http: http)
            return (data, meta)
            
        case .some(.notModified):
            if let cached = try await self.disk.read(url: url) {
                try await self.disk.touch(url: url)
                return (cached.data, cached.meta)
            }
            // fall through to treat as error if somehow no local file:
            fallthrough
            
        case .some(.notFound):
            throw ImageKitError.badStatusCode(http.statusCode)
            
        case .none:
            // any other status → treat as error
            throw ImageKitError.badStatusCode(http.statusCode)
        }
    }
}

// ===============================================================
// MARK: - Memory Cache (NSCache)
// ===============================================================

final class MemoryCache: @unchecked Sendable {
    /// Memory key includes the downsample variant (size × scale).
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
        init(_ i: UIImage) { self.image = i }
    }
    
    private let cache = NSCache<NSString, Box>()
    
    func setCostLimit(_ bytes: Int) { cache.totalCostLimit = bytes }
    func image(for key: Key) async -> UIImage? { cache.object(forKey: key.cacheKey as NSString)?.image }
    func insert(_ image: UIImage, for key: Key) async {
        cache.setObject(Box(image), forKey: key.cacheKey as NSString, cost: image.cost)
    }
    func removeAll() async { cache.removeAllObjects() }
}

private extension UIImage {
    /// Rough RGBA byte estimate for NSCache cost.
    var cost: Int { Int(size.width * size.height * scale * scale) * 4 }
}

// ===============================================================
// MARK: - Disk Cache (Application Support)
// ===============================================================

/// Actor-isolated disk cache with LRU trimming and HTTP validators.
actor DiskCache {
    
    // -----------------------------------------------------------
    // MARK: Metadata / Decoded wrappers
    // -----------------------------------------------------------
    
    struct Meta: Codable, Sendable {
        var etag: String?
        var lastModified: String?
        var contentType: String?
        var lastAccess: Date
        var size: Int
        var created: Date
        
        static func from(http: HTTPURLResponse) -> Meta {
            Meta(
                etag: http.value(forHTTPHeaderField: "Etag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                lastAccess: Date(),
                size: Int(http.expectedContentLength > 0 ? http.expectedContentLength : 0),
                created: Date()
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
            return cg.map { UIImage(cgImage: $0, scale: scale, orientation: .up) } ?? UIImage(data: data)
        }
        
        func isFresh(now: Date, ttl: TimeInterval) -> Bool {
            now.timeIntervalSince(meta.lastAccess) < ttl
        }
    }
    
    // -----------------------------------------------------------
    // MARK: Paths & Limits
    // -----------------------------------------------------------
    
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
        
        // Exclude from iCloud backup
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        var r = self.root
        try? r.setResourceValues(rv)
    }
    
    // -----------------------------------------------------------
    // MARK: CRUD
    // -----------------------------------------------------------
    
    func key(for url: URL) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        return hash
    }
    
    func dataURL(for key: String) -> URL { root.appendingPathComponent(key + ".img") }
    func metaURL(for key: String) -> URL { root.appendingPathComponent(key + ".json") }
    
    func write(url: URL, data: Data, meta: Meta) throws {
        let key = key(for: url)
        do {
            try data.write(to: dataURL(for: key), options: .atomic)
            var m = meta
            m.lastAccess = Date()
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(m).write(to: metaURL(for: key), options: .atomic)
        } catch {
            throw ImageKitError.fileIOFailed
        }
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
            // Tolerate missing metadata.
            let basic = Meta(etag: nil, lastModified: nil, contentType: nil,
                             lastAccess: Date(), size: data.count, created: Date())
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
        // Re-apply the "do not back up" flag after recreation.
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        var r = self.root; try? r.setResourceValues(rv)
    }
    
    /// Enforce disk size limit by removing least-recently-used files.
    func enforceLimit() throws {
        var urls = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        )
        urls = urls.filter { $0.pathExtension == "img" }
        
        var total: Int64 = 0
        var entries: [(url: URL, date: Date, size: Int64)] = []
        for u in urls {
            let res  = try u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = res.contentModificationDate ?? Date.distantPast
            let s    = Int64(res.fileSize ?? 0)
            total += s
            entries.append((u, date, s))
        }
        
        if total <= sizeLimit { return }
        entries.sort { $0.date < $1.date } // oldest first
        
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

/// Deduplicates concurrent requests for the same cache key.
actor Inflight {
    private var tasks: [String: Task<UIImage, Error>] = [:]
    
    /// Run (or join) a task for the given key.
    /// - Parameters:
    ///   - key: Unique cache key per (url, variant).
    ///   - block: Async operation to execute if not already running.
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

/// Minimal async semaphore for prefetch concurrency limiting.
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

/// A lightweight SwiftUI view that downloads, caches, and displays an image.
/// Uses `ImageKit.shared` internally.
///
/// ```swift
/// AsyncImageView(
///   url: URL(string: "https://example.com/image.jpg"),
///   placeholder: { ProgressView() }
/// )
/// .frame(width: 220, height: 140)
/// .clipped()
/// ```
///
/// - Parameters:
///   - url: The remote image URL (optional).
///   - placeholder: A view builder used while loading or on failure.
public struct AsyncImageView<Placeholder: View>: View {
    public let url: URL?
    public let placeholder: () -> Placeholder
    
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    
    /// Create an `AsyncImageView`.
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
                    let img = try await ImageKit.shared.uiImage(for: url,
                                                                targetSize: geo.size,
                                                                scale: nil,
                                                                ttl: nil)
                    withAnimation { self.uiImage = img }
                } catch {
                    // Keep showing placeholder on failure.
                }
            }
        }
    }
}
#endif

// ===============================================================
// MARK: - Lifecycle Helpers
// ===============================================================

/// Useful app hooks. Call from App/Scene delegate as desired.
public enum ImageKitLifecycle {
    /// Free *memory* cache quickly when the OS signals pressure.
    public static func applicationDidReceiveMemoryWarning() {
        Task { await ImageKit.shared.clearMemory() }
    }
    
    /// Optionally trim disk LRU on backgrounding (keeps cache persistent).
    public static func applicationDidEnterBackground() {
        Task { await ImageKit.shared.trimCaches() }
    }
}
