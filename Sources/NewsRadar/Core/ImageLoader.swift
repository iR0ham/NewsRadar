import Foundation
import AppKit

/// Shared image downloader with an in-memory + on-disk cache.
///
/// SwiftUI's `AsyncImage` re-downloads on every scroll and has no disk cache, so
/// the card grids use this instead. Loads are serialised on one queue because
/// cards are cheap and the network budget matters more than latency.
final class ImageLoader {

    static let shared = ImageLoader()

    private let queue = DispatchQueue(label: "newsradar.images", qos: .utility,
                                      attributes: .concurrent)
    /// How many pictures may be downloading at once.
    ///
    /// This used to be a serial queue: one picture at a time for the whole
    /// window. A screen of nine cards therefore queued nine downloads end to end,
    /// each with a fifteen-second timeout and a retry — the ninth card could wait
    /// two minutes and the grid looked broken. Six at a time fills a screen in a
    /// couple of seconds while staying well clear of the connection budget the
    /// feed refresh already uses.
    private static let maxConcurrent = 6
    private let slots: DispatchSemaphore

    /// Concurrency is a fixed pool, not a per-request thread.
    ///
    /// `NEWSRADAR_IMAGE_CONCURRENCY` exists only so the benchmark can measure the
    /// difference between one and six: with one, a screen of nine pictures is
    /// queued end to end and the last card waits minutes.
    private static var configuredConcurrency: Int {
        if let raw = ProcessInfo.processInfo.environment["NEWSRADAR_IMAGE_CONCURRENCY"],
           let n = Int(raw), n > 0 { return n }
        return maxConcurrent
    }
    private let cache = NSCache<NSString, NSImage>()
    /// One entry per URL currently downloading, holding every completion that is
    /// waiting on it. Without this, a second card asking for the same image would
    /// silently never receive a callback and stay blank forever.
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]
    private let lock = NSLock()

    private let diskDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("NewsRadar/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() {
        slots = DispatchSemaphore(value: Self.configuredConcurrency)
        // The cost of a decoded image is pixels × 4 bytes, not the size of the
        // JPEG it came from. Charging `data.count` meant a 6 MB photo of a
        // 4000×3000 cover was charged 6 MB when it occupied 48 MB, so the limit
        // below never triggered and a screenful of cards could hold a gigabyte.
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 160
    }

    /// A card never draws an image wider than about 700 points, and on a Retina
    /// screen that is 1400 pixels. Downsampling to that size on load is the
    /// difference between a 48 MB bitmap and a 3 MB one, and it is invisible at
    /// the size these are actually drawn.
    private static let maxPixelSize = 1400

    /// Decodes at display resolution, and reports what the result really costs.
    ///
    /// A feed hands over whatever the publisher uploaded: a 6.8 MB animated GIF
    /// of a security story, a 4.9 MB press photo. Decoded whole, one card could
    /// take 60 MB and a second of CPU. The thumbnail below asks ImageIO for the
    /// first frame at the size the card draws it, so the cost follows the card
    /// rather than the upload.
    private static func decode(_ data: Data) -> NSImage? {
        // A picture smaller than a postage stamp is not a cover; it is a tracker
        // pixel or an empty sprite that a feed put in an `<img>`.
        guard data.count > 1200 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return NSImage(data: data)
    }

    /// The bytes to keep on disk for a picture.
    ///
    /// The decoded picture is re-encoded as a JPEG at card resolution. The card
    /// draws it at about 700 points, so a Retina screen wants 1400 pixels — the
    /// same size the picture was decoded at. A picture with transparency (a
    /// PNG logo over a card) keeps the PNG form, because a JPEG would put a
    /// black box around it.
    private static func storedRepresentation(of image: NSImage) -> Data? {
        guard let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
            return nil
        }
        let hasAlpha = rep.hasAlpha && !rep.isOpaque
        if hasAlpha {
            return rep.representation(using: .png, properties: [:])
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    /// What an image occupies in memory, used as the cache's cost.
    private static func cost(of image: NSImage) -> Int {
        // Prefer the backing bitmap when there is one; fall back to the size in
        // points, which is close enough to keep the limit meaningful.
        if let rep = image.representations.first {
            let pixels = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
            let pixelsHigh = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height)
            return max(1, pixels * pixelsHigh * 4)
        }
        return max(1, Int(image.size.width * image.size.height) * 4)
    }

    /// True when the last failure was the publisher asking us to slow down.
    private static func isRateLimited(_ error: Error) -> Bool {
        if case HTTP.HTTPError.badStatus(let code) = error { return code == 429 || code == 503 }
        return false
    }

    /// What an image request asks for.
    ///
    /// The feed `Accept` header was being sent for pictures too. Most hosts ignore
    /// it, but a CDN that negotiates on it can answer with a document instead of
    /// the picture, which decodes to nothing and leaves the card blank.
    static let imageAccept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"

    private func diskFile(_ url: URL) -> URL {
        let name = String(format: "%016llx", UInt64(bitPattern: Int64(url.absoluteString.hashValue)))
        return diskDir.appendingPathComponent(name + ".img")
    }

    /// Cached image if present, otherwise nil. Never touches the network.
    ///
    /// Reading and decoding from disk happens on the caller's queue, which is the
    /// main one for every card. A decode is 3–10 ms, and a grid of nine cards
    /// asking for nine of them while scrolling is a visible stutter. So a disk hit
    /// is decoded off the main thread and delivered like a network load would be.
    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// Cached image, or the disk copy decoded off the main thread.
    ///
    /// Returns nil only when there is neither: a card can then draw its
    /// placeholder without the main thread ever waiting on the disk.
    func cachedOrDeferred(_ url: URL, completion: @escaping (NSImage?) -> Void) -> Bool {
        if let img = cache.object(forKey: url.absoluteString as NSString) {
            completion(img)
            return true
        }
        let file = diskFile(url)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        queue.async { [weak self] in
            guard let self else { return }
            let img = (try? Data(contentsOf: file)).flatMap { Self.decode($0) }
            if let img {
                self.cache.setObject(img, forKey: url.absoluteString as NSString,
                                     cost: Self.cost(of: img))
            }
            DispatchQueue.main.async { completion(img) }
        }
        return true
    }

    /// Loads an image, calling back on the main queue. Safe to call repeatedly;
    /// duplicate requests for the same URL are dropped.
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        // Memory, then disk (decoded off the main thread), then the network.
        // Checking the disk here as well as in the card means a picture that is
        // already stored is never re-downloaded because a card happened to be
        // built a moment before the decode finished.
        if cachedOrDeferred(url, completion: { [weak self] img in
            if let img {
                completion(img)
            } else {
                self?.fetch(url, completion: completion)
            }
        }) { return }
        fetch(url, completion: completion)
    }

    private func fetch(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        lock.lock()
        if var waiting = inFlight[url.absoluteString] {
            waiting.append(completion)
            inFlight[url.absoluteString] = waiting
            lock.unlock()
            return
        }
        inFlight[url.absoluteString] = [completion]
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.slots.wait()
            defer { self.slots.signal() }
            // A rate-limited picture is retried once after a pause, not
            // immediately: GitHub's social-card images answer 429 to a burst and
            // serve normally a second later, and without the pause thirteen cards
            // in a grid went permanently blank.
            var data = try? HTTP.get(url, timeout: 10, retries: 0, accept: Self.imageAccept).data
            // Read the error before the next call overwrites it.
            let limited = (HTTP.lastError).map(Self.isRateLimited) ?? false
            if data == nil, limited {
                usleep(900_000)
                data = try? HTTP.get(url, timeout: 10, retries: 0, accept: Self.imageAccept).data
            }
            let img = data.flatMap { Self.decode($0) }
            if let img {
                // The stored copy is the downsampled picture, not the bytes the
                // publisher sent. A 6.8 MB animated GIF of a security story was
                // kept at 6.8 MB on disk and re-read at 6.8 MB on every visit;
                // as a JPEG at card size it is about 90 KB and looks identical
                // at the size a card draws it.
                if let stored = Self.storedRepresentation(of: img) {
                    try? stored.write(to: self.diskFile(url), options: .atomic)
                }
                self.cache.setObject(img, forKey: url.absoluteString as NSString,
                                     cost: Self.cost(of: img))
            }
            self.lock.lock()
            let waiting = self.inFlight.removeValue(forKey: url.absoluteString) ?? []
            self.lock.unlock()
            DispatchQueue.main.async {
                for callback in waiting { callback(img) }
            }
        }
    }

    func clearDiskCache() {
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// The most the picture cache may occupy on disk.
    ///
    /// The cache used to grow without a ceiling: every picture a reader scrolled
    /// past stayed on disk forever, and it had reached 170 MB. The oldest files
    /// go first, because a picture that is still being looked at is the one that
    /// was fetched most recently.
    private static let diskLimit: Int64 = 250 * 1024 * 1024

    /// Trims the picture cache to its ceiling.
    @discardableResult
    func trimDiskCache() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diskDir, includingPropertiesForKeys: [.fileSizeKey,
                                                      .contentModificationDateKey])) ?? []
        var sized: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey,
                                                          .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            total += size
            sized.append((file, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > Self.diskLimit else { return total }
        for entry in sized.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= Self.diskLimit { break }
        }
        return total
    }

    var diskUsage: Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(into: Int64(0)) { acc, u in
            acc += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Placeholder gradient used while an image is missing or still loading, so
    /// a card never shows an empty hole.
    static func placeholderImage(seed: String, size: CGSize = CGSize(width: 480, height: 270),
                                 hue hex: String = "#6B7280") -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let color = NSColor(hex: hex) ?? .systemGray
        let top = color.blended(withFraction: 0.25, of: .white) ?? color
        let bottom = color.blended(withFraction: 0.35, of: .black) ?? color
        if let gradient = NSGradient(starting: top, ending: bottom) {
            gradient.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        }
        image.unlockFocus()
        return image
    }
}

extension NSColor {
    /// `#RRGGBB` / `#RGB` / `#RRGGBBAA` parser for the accent hexes in Models.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 3 || s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        default:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
