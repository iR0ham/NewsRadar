import Foundation

/// Small NSRegularExpression helper used by the HTML scrapers.
enum RX {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let r = cache[pattern] { return r }
        guard let r = try? NSRegularExpression(pattern: pattern,
                                               options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }
        cache[pattern] = r
        return r
    }

    static func all(_ pattern: String, in s: String, group: Int = 1) -> [String] {
        guard let r = regex(pattern) else { return [] }
        let ns = s as NSString
        return r.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > group else { return nil }
            let range = m.range(at: group)
            guard range.location != NSNotFound else { return nil }
            return ns.substring(with: range)
        }
    }

    static func first(_ pattern: String, in s: String, group: Int = 1) -> String? {
        all(pattern, in: s, group: group).first
    }

    /// Blocks matched by a pattern that captures the whole element body.
    static func blocks(_ pattern: String, in s: String) -> [(full: String, body: String)] {
        guard let r = regex(pattern) else { return [] }
        let ns = s as NSString
        return r.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            let full = ns.substring(with: m.range)
            let body = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound
                ? ns.substring(with: m.range(at: 1)) : full
            return (full, body)
        }
    }

    static func stripSVG(_ s: String) -> String {
        s.replacingOccurrences(of: "<svg.*?</svg>", with: "",
                               options: [.regularExpression, .caseInsensitive])
    }

    static func int(_ s: String?) -> Int? {
        guard let s else { return nil }
        let digits = s.replacingOccurrences(of: ",", with: "")
            .filter { $0.isNumber }
        return Int(digits)
    }
}

// MARK: - GitHub REST API

/// Minimal GitHub REST client: repo metadata and one search endpoint.
/// Unauthenticated requests share a 60/hour budget, so enrichment is capped and
/// every failure degrades to the stats scraped from the trending page.
enum GitHubAPI {

    struct APIRepo: Decodable {
        var full_name: String
        var html_url: String
        var description: String?
        var stargazers_count: Int
        var forks_count: Int?
        var language: String?
        var created_at: String?
        var pushed_at: String?
        var topics: [String]?
        var homepage: String?
        var archived: Bool?
        var license: License?

        struct License: Decodable { var spdx_id: String?; var name: String? }
    }

    struct SearchResponse: Decodable {
        var total_count: Int?
        var items: [APIRepo]?
    }

    /// GitHub enforces separate hourly budgets for its core and search endpoints
    /// (60 and 10 per hour unauthenticated). They are tracked separately: running
    /// out of core requests — which the per-repository lookups do quickly — must
    /// not disable search, which is the cheap way to get a whole list at once.
    private(set) static var coreRateLimited = false
    private(set) static var searchRateLimited = false

    /// True when either budget is exhausted, for callers that only want to know
    /// whether GitHub can be reached at all.
    static var rateLimited: Bool { coreRateLimited && searchRateLimited }
    private(set) static var remaining: Int?
    private(set) static var lastError: String?

    static func resetRateLimitFlag() {
        coreRateLimited = false
        searchRateLimited = false
        lastError = nil
    }

    static func repo(_ fullName: String) -> RepoStats? {
        guard !coreRateLimited else { return nil }
        guard let url = URL(string: "https://api.github.com/repos/\(fullName)") else { return nil }
        do {
            let r = try HTTP.get(url, timeout: 15, retries: 0, accept: "application/vnd.github+json")
            let decoded = try JSONDecoder().decode(APIRepo.self, from: r.data)
            return stats(from: decoded)
        } catch let e as HTTP.HTTPError {
            if case .badStatus(let code) = e, code == 403 || code == 429 {
                coreRateLimited = true
                lastError = "GitHub core rate limit reached (no token)"
            } else {
                lastError = e.localizedDescription
            }
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    static func search(query: String, perPage: Int = 15) -> [RepoStats] {
        guard !searchRateLimited else { return [] }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string:
            "https://api.github.com/search/repositories?q=\(q)&sort=stars&order=desc&per_page=\(perPage)")
        else { return [] }
        do {
            let r = try HTTP.get(url, timeout: 18, retries: 0, accept: "application/vnd.github+json")
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: r.data)
            return (decoded.items ?? []).map(stats(from:))
        } catch let e as HTTP.HTTPError {
            if case .badStatus(let code) = e, code == 403 || code == 429 {
                searchRateLimited = true
                lastError = "GitHub search rate limit reached"
            }
            return []
        } catch {
            return []
        }
    }

    static func stats(from r: APIRepo) -> RepoStats {
        var s = RepoStats(fullName: r.full_name,
                          htmlURL: URL(string: r.html_url) ?? URL(string: "https://github.com")!,
                          stars: r.stargazers_count)
        s.forks = r.forks_count
        s.language = r.language
        if let l = r.license?.spdx_id, l != "NOASSERTION" { s.license = l }
        s.created = r.created_at.flatMap(DateParsing.iso8601)
        s.pushed = r.pushed_at.flatMap(DateParsing.iso8601)
        s.topics = r.topics ?? []
        s.descriptionEN = r.description
        s.homepage = r.homepage.flatMap { URL(string: $0) }
        return s
    }
}

// MARK: - Trending page

/// Scrapes github.com/trending, which is server-rendered HTML.
enum GitHubTrendingScraper {

    struct Scraped {
        var fullName: String
        var description: String?
        var language: String?
        var stars: Int
        var starsToday: Int?
        var url: URL
    }

    static func parse(_ html: String) -> [Scraped] {
        var out: [Scraped] = []
        var seen = Set<String>()
        let articles = RX.blocks("<article class=\"Box-row\">(.*?)</article>", in: html)
        for (_, raw) in articles {
            let body = RX.stripSVG(raw)
            guard let path = RX.first("<h2[^>]*>\\s*.*?href=\"(/[^\"?#]+)\"", in: body, group: 1)
                    ?? RX.first("href=\"(/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\"[^>]*>\\s*<span[^>]*>[^<]*</span>", in: body),
                  path.split(separator: "/").count == 2
            else { continue }
            let fullName = String(path.dropFirst())
            guard !seen.contains(fullName) else { continue }
            seen.insert(fullName)

            let desc = RX.first("<p class=\"col-9[^\"]*\"[^>]*>\\s*(.*?)\\s*</p>", in: body)
                .map { HTMLText.plain($0) }
            let lang = RX.first("itemprop=\"programmingLanguage\">([^<]+)<", in: body)
            let stars = RX.int(RX.first("href=\"/\(fullName)/stargazers\"[^>]*>\\s*(?:<svg.*?</svg>)?\\s*([\\d,]+)", in: body))
            let today = RX.int(RX.first("float-sm-right\"[^>]*>\\s*(?:<svg.*?</svg>)?\\s*([\\d,]+)\\s*stars? today", in: body))

            out.append(Scraped(fullName: fullName,
                               description: desc?.isEmpty == true ? nil : desc,
                               language: lang?.trimmingCharacters(in: .whitespaces),
                               stars: stars ?? 0,
                               starsToday: today,
                               url: URL(string: "https://github.com/\(fullName)")!))
        }
        return out
    }
}

// MARK: - Explore page

/// github.com/explore only server-renders developer cards, so repo rows are read
/// when they exist and otherwise the GitHub search API supplies fresh AI projects.
/// The result records which path was taken so the UI can say so honestly.
enum GitHubExploreScraper {

    struct Result {
        var repos: [RepoStats]
        var viaSearchAPI: Bool
        var note: String
    }

    static func parse(_ html: String) -> [String] {
        var names: [String] = []
        for (_, body) in RX.blocks("<article class=\"Box-row\">(.*?)</article>", in: html) {
            let clean = RX.stripSVG(body)
            if let p = RX.first("href=\"(/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\"", in: clean),
               p.split(separator: "/").count == 2,
               !p.hasPrefix("/topics/"), !p.hasPrefix("/sponsors/"), !p.hasPrefix("/login"),
               !names.contains(String(p.dropFirst())) {
                names.append(String(p.dropFirst()))
            }
        }
        return names
    }

    static func fetch(fallbackLanguageNote: Bool = true, now: Date = Date()) -> Result {
        // 1) Try the page itself, but only while the core budget can enrich the
        //    names it yields. Otherwise go straight to the search API, which
        //    returns full repository records in a single request.
        if !GitHubAPI.coreRateLimited,
           let html = try? HTTP.getWithCache(URL(string: "https://github.com/explore")!).body {
            let names = parse(html).prefix(10)
            var repos: [RepoStats] = []
            for n in names {
                if let r = GitHubAPI.repo(n) { repos.append(r) }
                if repos.count >= 8 { break }
            }
            if !repos.isEmpty {
                return Result(repos: repos, viaSearchAPI: false,
                              note: "Projects were read directly from the Explore page.")
            }
        }
        // 2) Fall back to the search API for what Explore is meant to surface:
        //    recently created, already popular AI repositories.
        let since = ISO8601DateFormatter().string(from: now.addingTimeInterval(-45 * 86400))
            .prefix(10)
        let query = "topic:artificial-intelligence created:>\(since)"
        let found = GitHubAPI.search(query: query, perPage: 12)
        let note = found.isEmpty
            ? "Explore was unreachable and the GitHub search API did not answer either."
            : "The Explore page loads its projects with JavaScript only, so fresh AI projects were read from the GitHub search API instead."
        return Result(repos: found, viaSearchAPI: true, note: note)
    }
}

// MARK: - Source

/// GitHub source: trending repos plus explore.
struct GitHubSource {

    /// How many repos get an extra metadata round-trip per refresh. The
    /// unauthenticated REST budget is 60/hour, so this stays small.
    static let metadataBudget = 18

    struct Outcome {
        var items: [RadarItem]
        var status: SourceStatus
        var snapshots: [StarSnapshot]
    }

    static func fetchTrending(now: Date = Date(),
                              existingSnapshots: [StarSnapshot]) -> Outcome {
        var status = SourceStatus(source: .gitHubTrending, lastAttempt: now)
        do {
            let (html, fromCache) = try HTTP.getWithCache(URL(string: "https://github.com/trending")!,
                                                          maxAge: 3 * 3600)
            let scraped = GitHubTrendingScraper.parse(html)
            var items: [RadarItem] = []
            var snaps: [StarSnapshot] = []
            var used = 0

            for s in scraped {
                var repo = RepoStats(fullName: s.fullName, htmlURL: s.url, stars: s.stars)
                repo.starsToday = s.starsToday
                repo.descriptionEN = s.description
                repo.language = s.language
                if used < metadataBudget, let enriched = GitHubAPI.repo(s.fullName) {
                    used += 1
                    repo = enriched
                    repo.starsToday = s.starsToday
                    // Prefer the live star count but keep the scraped value if the
                    // API returned a stale/zero number.
                    if s.stars > repo.stars { repo.stars = s.stars }
                }
                repo.starGrowth7d = growth(for: s.fullName, now: s.stars, snapshots: existingSnapshots)
                repo.starGrowthNote = repo.starGrowth7d == nil
                    ? "Star growth appears after a few days of local snapshots."
                    : nil
                snaps.append(StarSnapshot(fullName: s.fullName, stars: repo.stars, takenAt: now))
                items.append(makeItem(repo: repo, source: .gitHubTrending, now: now,
                                      fallbackSummary: s.description))
            }
            status.ok = !items.isEmpty
            status.itemCount = items.count
            status.fromCache = fromCache
            status.lastSuccess = now
            status.message = items.isEmpty
                ? "No repositories could be read from the Trending page."
                : (fromCache ? "Served from cache (network request failed)" : "")
            return Outcome(items: items, status: status, snapshots: snaps)
        } catch {
            status.ok = false
            status.message = HTTP.explain(error)
            return Outcome(items: [], status: status, snapshots: [])
        }
    }

    static func fetchExplore(now: Date = Date(),
                             existingSnapshots: [StarSnapshot]) -> Outcome {
        var status = SourceStatus(source: .gitHubExplore, lastAttempt: now)
        let result = GitHubExploreScraper.fetch(now: now)
        var snaps: [StarSnapshot] = []
        var items: [RadarItem] = []
        for var repo in result.repos {
            repo.starGrowth7d = growth(for: repo.fullName, now: repo.stars, snapshots: existingSnapshots)
            repo.starGrowthNote = repo.starGrowth7d == nil
                ? "Star growth appears after a few days of local snapshots."
                : nil
            snaps.append(StarSnapshot(fullName: repo.fullName, stars: repo.stars, takenAt: now))
            items.append(makeItem(repo: repo, source: .gitHubExplore, now: now,
                                  fallbackSummary: repo.descriptionEN))
        }
        status.ok = !items.isEmpty
        status.itemCount = items.count
        status.lastSuccess = items.isEmpty ? nil : now
        status.message = items.isEmpty ? result.note : (result.viaSearchAPI ? result.note : "")
        if !GitHubAPI.coreRateLimited, let r = GitHubAPI.remaining {
            status.message = status.message.isEmpty ? "API budget left: \(r)" : status.message
        }
        return Outcome(items: items, status: status, snapshots: snaps)
    }

    // MARK: - Helpers

    /// Star growth is only meaningful when a snapshot at least a day old exists.
    static func growth(for fullName: String, now: Int, snapshots: [StarSnapshot]) -> Int? {
        let prior = snapshots
            .filter { $0.fullName == fullName }
            .min { $0.takenAt < $1.takenAt }
        guard let prior else { return nil }
        guard Date().timeIntervalSince(prior.takenAt) > 12 * 3600 else { return nil }
        return now - prior.stars
    }

    /// GitHub renders a social preview card for every repository. The service is
    /// public and does not need a token, so a project card gets a real picture
    /// instead of an empty placeholder.
    static func previewImage(_ fullName: String) -> URL? {
        URL(string: "https://opengraph.githubassets.com/1/\(fullName)")
    }

    /// A repository has no "reading mode": its page is files and a rendered README.
    /// The README *is* the original text, so it is read here and shown in full on
    /// the detail sheet. Without it a project card carries one description line and
    /// there is nothing to read except by opening a browser tab.
    ///
    /// The raw host is used rather than the REST API on purpose: the API allows 60
    /// requests an hour per IP and answers 403 once they are gone, which is exactly
    /// what happened here. `raw.githubusercontent.com` serves the same file with no
    /// such limit and no token.
    static func readme(_ fullName: String) -> String? {
        for name in ["README.md", "readme.md", "Readme.md", "README.markdown",
                     "README.rst", "README.txt", "README"] {
            guard let url = URL(string: "https://raw.githubusercontent.com/\(fullName)/HEAD/\(name)"),
                  let response = try? HTTP.get(url), response.status == 200,
                  let text = String(data: response.data, encoding: .utf8),
                  !text.isEmpty else { continue }
            return markdownText(text)
        }
        return nil
    }

    /// README markdown reduced to readable plain text: headings kept as lines, code
    /// fences dropped, images and badges dropped, links reduced to their words.
    static func markdownText(_ md: String, limit: Int = 40_000) -> String {
        var t = md
        // Fenced code loses its meaning without syntax colouring and swamps the text.
        t = t.replacingOccurrences(of: "(?s)```.*?```", with: "",
                                   options: [.regularExpression])
        // Images and badges: ![alt](url)
        t = t.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "",
                                   options: [.regularExpression])
        // A badge wrapped in a link leaves "[ ](url)" behind; remove before
        // unwrapping, or the page shows a row of empty brackets.
        t = t.replacingOccurrences(of: "\\[\\s*\\]\\([^)]*\\)", with: "",
                                   options: [.regularExpression])
        // Links: [words](url) -> words
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1",
                                   options: [.regularExpression])
        // Reference-style links: [words][ref]
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\[[^\\]]*\\]", with: "$1",
                                   options: [.regularExpression])
        // Link reference definitions: [ref]: https://…
        t = t.replacingOccurrences(of: "(?m)^\\s*\\[[^\\]]+\\]:\\s*\\S+.*$", with: "",
                                   options: [.regularExpression])
        // HTML that survives in READMEs.
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression])
        // Headings and rules become paragraph breaks.
        t = t.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "",
                                   options: [.regularExpression])
        t = t.replacingOccurrences(of: "(?m)^\\s{0,3}([-*_])\\1{2,}\\s*$", with: "",
                                   options: [.regularExpression])
        // List bullets: keep the item, drop the marker.
        t = t.replacingOccurrences(of: "(?m)^\\s{0,3}[-*+]\\s+", with: "• ",
                                   options: [.regularExpression])
        t = t.replacingOccurrences(of: "`", with: "")
        // Emphasis markers. A README is read for its information, and "**no
        // affiliated cryptocurrency**" with the asterisks left in reads like code.
        t = t.replacingOccurrences(of: "(?m)^\\s*>\\s?", with: "", options: [.regularExpression])
        t = t.replacingOccurrences(of: "\\*\\*([^*\\n]+)\\*\\*", with: "$1",
                                   options: [.regularExpression])
        t = t.replacingOccurrences(of: "(?m)(^|[\\s(])\\*([^*\\n]+)\\*($|[\\s).,])", with: "$1$2$3",
                                   options: [.regularExpression])
        t = t.replacingOccurrences(of: "(?m)(^|[\\s(])_([^_\\n]+)_($|[\\s).,])", with: "$1$2$3",
                                   options: [.regularExpression])
        // Collapse runs of blank lines to one.
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: [.regularExpression])
        t = HTMLText.decodeEntities(t)
        // Drop lines that are now only punctuation or whitespace (an orphaned
        // bullet, a leftover divider), then re-collapse the blank lines they leave.
        t = t.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return true }
                return trimmed.rangeOfCharacter(from: .alphanumerics) != nil
            }
            .joined(separator: "\n")
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: [.regularExpression])
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "\n\n…" : t
    }

    static func makeItem(repo: RepoStats, source: SourceID, now: Date,
                         fallbackSummary: String?) -> RadarItem {
        let summary = repo.descriptionEN ?? fallbackSummary ?? ""
        var item = RadarItem(
            id: "\(source.rawValue)::\(repo.fullName)",
            source: source,
            kind: .repository,
            title: repo.fullName,
            link: repo.htmlURL,
            published: repo.pushed ?? repo.created ?? now,
            rawSummary: summary,
            imageURL: previewImage(repo.fullName),
            author: repo.fullName.split(separator: "/").first.map(String.init),
            sourceCategories: repo.topics
        )
        item.repo = repo
        return item
    }
}
