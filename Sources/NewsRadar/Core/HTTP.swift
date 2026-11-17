import Foundation

/// Thin URLSession wrapper: shared user agent, timeouts, one retry, and a
/// small on-disk response cache so a refresh never re-downloads what a recent
/// refresh already fetched.
enum HTTP {

    /// The `Accept` header every request sends: a feed, a document, and
    /// nothing else. Kept in one place so a publisher that refuses a vague
    /// request is answered consistently.
    static let feedAccept = "application/rss+xml, application/atom+xml, "
        + "application/xml;q=0.9, text/xml;q=0.9, text/html;q=0.8, */*;q=0.5"

    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        // A request that says it wants a feed, and a document, and nothing
        // else. Several publishers answer "too many requests" to a bare
        // `Accept: * / *` but serve the feed when the header says what is
        // wanted — VentureBeat is one of them, and the app would otherwise
        // never read a single story from it.
        cfg.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": feedAccept,
            "Accept-Language": "en-US,en;q=0.9"
        ]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    struct Response {
        var data: Data
        var status: Int
        var finalURL: URL
    }

    enum HTTPError: LocalizedError {
        case badStatus(Int)
        case empty
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let c): return "Server returned status \(c)"
            case .empty: return "Empty response"
            case .transport(let m): return m
            }
        }
    }

    /// Turns a failure into the reason, in words a reader can act on.
    ///
    /// "Server returned status 403" is true and useless. What matters is whether
    /// the site refuses automated clients, wants a different path, or is simply
    /// down, because those need different answers.
    static func explain(_ error: Error) -> String {
        if let e = error as? HTTPError {
            switch e {
            case .badStatus(let code):
                switch code {
                case 401: return "The site requires a sign-in or an API key (401)."
                case 403: return "The site refuses automated clients (403). It serves a browser a different page, so this source cannot be read from here."
                case 404: return "The feed path does not exist (404). The publisher probably moved it."
                case 405: return "The site rejected the request method (405)."
                case 410: return "The feed was withdrawn (410); the publisher retired it."
                case 429: return "Rate limited (429). The site is asking clients to slow down."
                case 500...599: return "The publisher's server is failing (\(code)). Nothing to fix here."
                default: return "The site answered \(code) instead of content."
                }
            case .empty:
                return "The server answered but sent no content. This is usually a JavaScript-only page, not a feed."
            case .transport(let m):
                if m.localizedCaseInsensitiveContains("timed out") {
                    return "The request timed out. The source was too slow to answer."
                }
                if m.localizedCaseInsensitiveContains("offline")
                    || m.localizedCaseInsensitiveContains("not connected") {
                    return "No network connection at the time of the check."
                }
                if m.localizedCaseInsensitiveContains("certificate")
                    || m.localizedCaseInsensitiveContains("ssl")
                    || m.localizedCaseInsensitiveContains("secure connection") {
                    return "The site's certificate could not be validated. Nothing was read."
                }
                if m.localizedCaseInsensitiveContains("could not resolve")
                    || m.localizedCaseInsensitiveContains("host") {
                    return "The host name did not resolve. The source may have moved or the network may be filtering it."
                }
                return m
            }
        }
        return error.localizedDescription
    }

    /// Synchronous GET. Safe to call from a background queue; the app only calls
    /// it from the refresh task, never from the main thread.
    static func get(_ url: URL, timeout: TimeInterval = 20, retries: Int = 1,
                    accept: String = feedAccept, bearer: String = "") throws -> Response {
        var lastError: Error = HTTPError.empty
        for attempt in 0...max(0, retries) {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = timeout
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue(accept, forHTTPHeaderField: "Accept")
                if !bearer.isEmpty {
                    req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                }
                let sem = DispatchSemaphore(value: 0)
                var result: Result<Response, Error>?
                let task = session.dataTask(with: req) { data, response, error in
                    defer { sem.signal() }
                    if let error {
                        result = .failure(HTTPError.transport(error.localizedDescription))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        result = .failure(HTTPError.transport("Invalid response"))
                        return
                    }
                    let body = data ?? Data()
                    guard (200..<300).contains(http.statusCode) else {
                        result = .failure(HTTPError.badStatus(http.statusCode))
                        return
                    }
                    guard !body.isEmpty else {
                        result = .failure(HTTPError.empty)
                        return
                    }
                    result = .success(Response(data: body, status: http.statusCode,
                                               finalURL: http.url ?? url))
                }
                task.resume()
                // Poll instead of blocking forever so a wedged socket cannot hang
                // the refresh pipeline.
                let deadline = Date().addingTimeInterval(timeout + 5)
                while sem.wait(timeout: .now() + 0.2) == .timedOut {
                    if Date() > deadline {
                        task.cancel()
                        throw HTTPError.transport("Request timed out")
                    }
                }
                switch result {
                case .success(let r): return r
                case .failure(let e): throw e
                case nil: throw HTTPError.transport("No response received")
                }
            } catch {
                lastError = error
                if attempt < retries { usleep(400_000) }
            }
        }
        throw lastError
    }

    /// The last transport-level failure, for callers that want to explain
    /// themselves ("403: the site refuses automated clients") instead of printing a
    /// bare code. Reset on every `getPlain` call.
    private(set) static var lastError: Error?

    /// Text GET used when a page has to be read where a feed was expected.
    ///
    /// Unlike `getString` this keeps a 200 that carries an HTML page: the caller
    /// needs to see the page to decide whether it advertises a feed, so a "not a
    /// feed" is a result rather than an error.
    static func getPlain(_ url: URL, timeout: TimeInterval = 20) -> String? {
        lastError = nil
        do {
            let r = try get(url, timeout: timeout, retries: 1, accept: feedAccept)
            return String(data: r.data, encoding: .utf8)
                ?? String(data: r.data, encoding: .isoLatin1)
                ?? String(decoding: r.data, as: UTF8.self)
        } catch {
            lastError = error
            return nil
        }
    }

    static func getString(_ url: URL, timeout: TimeInterval = 20,
                          retries: Int = 1) throws -> String {
        let r = try get(url, timeout: timeout, retries: retries)
        return String(data: r.data, encoding: .utf8)
            ?? String(data: r.data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: - Conditional fetch

    /// Remembers the validators a server sent, so the next request can ask
    /// "has this changed?" and skip the body entirely when it has not.
    struct Validators: Codable {
        var etag: String?
        var lastModified: String?
    }

    private static func validatorFile(for url: URL) -> URL {
        cacheDirectory.appendingPathComponent(stableKey(url.absoluteString) + ".validators.json")
    }

    static func storedValidators(for url: URL) -> Validators? {
        guard let data = try? Data(contentsOf: validatorFile(for: url)) else { return nil }
        return try? JSONDecoder().decode(Validators.self, from: data)
    }

    static func storeValidators(_ v: Validators, for url: URL) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        try? data.write(to: validatorFile(for: url))
    }

    /// Result of a conditional GET.
    enum ConditionalResult {
        /// The server confirmed nothing changed since the last stored body.
        case unchanged
        /// A fresh body, with the URL it finally came from.
        case body(String, finalURL: URL)
    }

    /// GET with `If-None-Match` / `If-Modified-Since`. A `304 Not Modified` means
    /// the source has published nothing new, which lets a check for new stories
    /// skip parsing, classification and summarisation for that source entirely.
    /// That is what keeps reopening the app cheap.
    static func getConditional(_ url: URL, timeout: TimeInterval = 20,
                               retries: Int = 1) throws -> ConditionalResult {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(feedAccept, forHTTPHeaderField: "Accept")
        if let v = storedValidators(for: url) {
            if let etag = v.etag, !etag.isEmpty {
                req.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lm = v.lastModified, !lm.isEmpty {
                req.setValue(lm, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        var lastError: Error = HTTPError.empty
        for attempt in 0...max(0, retries) {
            do {
                return try performConditional(req, url: url)
            } catch {
                lastError = error
                if attempt < retries { usleep(300_000) }
            }
        }
        throw lastError
    }

    private static func performConditional(_ req: URLRequest, url: URL) throws -> ConditionalResult {
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<ConditionalResult, Error>?
        let task = session.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                outcome = .failure(HTTPError.transport(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(HTTPError.transport("Invalid response"))
                return
            }
            if http.statusCode == 304 {
                outcome = .success(.unchanged)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                outcome = .failure(HTTPError.badStatus(http.statusCode))
                return
            }
            let body = data ?? Data()
            guard !body.isEmpty else {
                outcome = .failure(HTTPError.empty)
                return
            }
            let text = String(data: body, encoding: .utf8)
                ?? String(data: body, encoding: .isoLatin1) ?? ""
            storeValidators(Validators(etag: http.value(forHTTPHeaderField: "ETag"),
                                       lastModified: http.value(forHTTPHeaderField: "Last-Modified")),
                            for: url)
            writeCache(text, for: url)
            outcome = .success(.body(text, finalURL: http.url ?? url))
        }
        task.resume()
        let deadline = Date().addingTimeInterval(req.timeoutInterval + 5)
        while sem.wait(timeout: .now() + 0.2) == .timedOut {
            if Date() > deadline {
                task.cancel()
                throw HTTPError.transport("Request timed out")
            }
        }
        switch outcome {
        case .success(let r): return r
        case .failure(let e): throw e
        case nil: throw HTTPError.transport("No response received")
        }
    }

    // MARK: - Disk cache for fetched bodies

    /// Drops cache files that no key can ever map to again. Called once per launch;
    /// the old per-process hashing scheme left thousands of them.
    static func purgeOrphanedCacheFiles(maxAge: TimeInterval = 14 * 86400) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for f in files {
            guard f.pathExtension == "body" || f.pathExtension == "json" else { continue }
            if let attrs = try? fm.attributesOfItem(atPath: f.path),
               let modified = attrs[.modificationDate] as? Date, modified < cutoff {
                try? fm.removeItem(at: f)
            }
        }
    }

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("NewsRadar/FetchedCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stable 64-bit FNV-1a hash of the URL.
    ///
    /// `String.hashValue` is randomly seeded per process in Swift, so using it as
    /// a cache key meant every launch wrote a brand-new file and could never read
    /// the previous one: the disk cache silently never hit, and the directory grew
    /// to ten thousand orphans. This hash is identical across launches.
    static func stableKey(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private static func cacheFile(for url: URL) -> URL {
        cacheDirectory.appendingPathComponent(stableKey(url.absoluteString) + ".body")
    }

    static func writeCache(_ body: String, for url: URL) {
        try? body.write(to: cacheFile(for: url), atomically: true, encoding: .utf8)
    }

    static func readCache(for url: URL, maxAge: TimeInterval = 6 * 3600) -> String? {
        let f = cacheFile(for: url)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge,
              let body = try? String(contentsOf: f, encoding: .utf8),
              !body.isEmpty
        else { return nil }
        return body
    }

    /// The cached body with no age limit, used to answer a 304: the server says
    /// the stored copy is still current, so its age is irrelevant.
    static func readCacheIgnoringAge(for url: URL) -> String? {
        guard let body = try? String(contentsOf: cacheFile(for: url), encoding: .utf8),
              !body.isEmpty else { return nil }
        return body
    }

    static func clearFetchedCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// A conditional fetch that also falls back to the cached copy on failure.
    ///
    /// Three outcomes matter to the caller:
    ///  * `.unchanged` — the server confirmed nothing was published since the last
    ///    check, so there is nothing to parse or summarise.
    ///  * a fresh body.
    ///  * a stale cached body, when the network failed but a copy exists.
    enum ConditionalCached {
        case unchanged
        case body(String, finalURL: URL)
        case cached(String, reason: String)
    }

    static func getConditionalCached(_ url: URL, timeout: TimeInterval = 20) -> ConditionalCached? {
        do {
            switch try getConditional(url, timeout: timeout, retries: 0) {
            case .unchanged:
                return .unchanged
            case .body(let text, let finalURL):
                return .body(text, finalURL: finalURL)
            }
        } catch {
            if let cached = readCache(for: url, maxAge: 7 * 24 * 3600) {
                return .cached(cached, reason: error.localizedDescription)
            }
            return nil
        }
    }

    // MARK: - Conditional fetch used by the "cache fallback" path

    /// Fetch with a transparent fallback: on any network error return the last
    /// cached body (flagged to the caller) so the UI can still show content.
    static func getWithCache(_ url: URL, maxAge: TimeInterval = 6 * 3600)
        throws -> (body: String, fromCache: Bool) {
        do {
            let body = try getString(url)
            writeCache(body, for: url)
            return (body, false)
        } catch {
            if let cached = readCache(for: url, maxAge: maxAge) {
                return (cached, true)
            }
            throw error
        }
    }
}
