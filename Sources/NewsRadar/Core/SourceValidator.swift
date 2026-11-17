import Foundation

/// Validates a feed the user pasted, before the app agrees to trust it.
///
/// "Add a source" is easy to get wrong in a way that fails silently: the URL
/// answers 200 with an HTML article list, the feed parser finds no entries, and
/// three days later the user wonders why the source contributes nothing. So the
/// check is done up front, out loud, and the verdict is a sentence the user can
/// act on — not a spinner that ends in silence.
enum SourceValidator {

    enum Verdict {
        case valid(CustomSource)
        /// The URL answered, but it is not a feed. `hint` carries anything that
        /// was found on the page that might be the real feed.
        case notAFeed(reason: String, suggestion: String?)
        /// The URL did not answer at all.
        case unreachable(reason: String)
        /// It is a feed, and it is already configured.
        case duplicate(title: String)

        var wasAdded: Bool { if case .valid = self { return true }; return false }
    }

    /// Fetches the URL, parses it, and decides.
    ///
    /// A page that is not a feed is still inspected for `<link rel="alternate"
    /// type="application/rss+xml">`, because that is where most sites keep the
    /// feed they do not show. When one is found it is fetched and validated too,
    /// so the user pastes a blog address and gets a working source.
    static func validate(urlString: String, title: String?) -> Verdict {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: trimmed), let scheme = url.scheme else {
            return .unreachable(reason: "That is not a web address. It needs to start with https://")
        }
        guard scheme == "https" || scheme == "http" else {
            return .unreachable(reason: "Only http and https addresses can be read.")
        }
        if scheme == "http" { url = URL(string: "https://" + trimmed.dropFirst("http://".count)) ?? url }

        // 1. Try the URL as a feed.
        switch fetchFeed(url) {
        case .feed(let entries, let feedTitle):
            return finish(url: url, feedTitle: feedTitle, entries: entries, title: title)
        case .notFeed(let body):
            // 2. Look for an advertised feed on the page.
            if let alternates = advertisedFeeds(in: body, base: url), !alternates.isEmpty {
                var lastReason = ""
                for candidate in alternates {
                    if case .feed(let entries, let feedTitle) = fetchFeed(candidate) {
                        var note = "The address you gave is a web page; the feed it advertises was used."
                        if candidate != url { note += " Feed: \(candidate.absoluteString)" }
                        return finish(url: candidate, feedTitle: feedTitle, entries: entries,
                                      title: title, prefix: note)
                    }
                    lastReason = candidate.absoluteString
                }
                return .notAFeed(
                    reason: "The page is not a feed, and the feed it links to could not be read.",
                    suggestion: lastReason.isEmpty ? nil : lastReason)
            }
            return .notAFeed(
                reason: "That address answered with a web page, not an RSS or Atom feed, and it does not advertise one.",
                suggestion: nil)
        case .failed(let reason):
            return .unreachable(reason: reason)
        }
    }

    // MARK: - Fetching

    private enum FetchResult {
        case feed(entries: Int, title: String?)
        case notFeed(body: String)
        case failed(String)
    }

    private static func fetchFeed(_ url: URL) -> FetchResult {
        guard let body = HTTP.getPlain(url) else {
            // Reuse the HTTP layer's own explanation rather than inventing one, so
            // a 403 here reads exactly like a 403 anywhere else in the app.
            if let error = lastHTTPError() {
                return .failed(HTTP.explain(error))
            }
            return .failed("The address did not answer. Check the spelling, or whether the site blocks automated clients.")
        }
        let parsed = FeedXMLParser.parseWithTitle(body)
        let usable = parsed.entries.filter { $0.link != nil }
        if !usable.isEmpty {
            // The feed's own title, never the first article's: a source named after
            // a single story is worse than no name at all.
            return .feed(entries: usable.count, title: parsed.title)
        }
        // An empty but well-formed feed is a real feed that happens to have nothing
        // in it right now; an HTML page with no entries is not a feed at all.
        let looksLikeFeed = body.contains("<rss") || body.contains("<feed")
            || body.contains("<rdf:RDF")
        if looksLikeFeed {
            return .feed(entries: 0, title: nil)
        }
        return .notFeed(body: body)
    }

    /// The last HTTP failure, so validation can say why rather than "it failed".
    private static func lastHTTPError() -> Error? {
        HTTP.lastError
    }

    /// `<link rel="alternate" type="application/rss+xml" href="…">`, in page order.
    static func advertisedFeeds(in html: String, base: URL) -> [URL]? {
        guard !html.isEmpty else { return nil }
        var out: [URL] = []
        let pattern = "<link[^>]*>"
        var searchRange = html.startIndex..<html.endIndex
        while let r = html.range(of: pattern, options: [.regularExpression, .caseInsensitive],
                                 range: searchRange) {
            let tag = String(html[r])
            let lower = tag.lowercased()
            if lower.contains("rss+xml") || lower.contains("atom+xml") {
                if let href = attribute("href", in: tag),
                   let url = URL(string: HTMLText.decodeEntities(href), relativeTo: base)?.absoluteURL,
                   !out.contains(url) {
                    out.append(url)
                }
            }
            searchRange = r.upperBound..<html.endIndex
        }
        return out.isEmpty ? nil : out
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let patterns = [
            "\(name)=[\"']([^\"']+)[\"']",
            "\(name)\\s*=\\s*([^\\s>\"']+)"
        ]
        for p in patterns {
            if let r = tag.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let found = String(tag[r])
                if let v = found.range(of: "=[\"']?([^\"'>]+)", options: .regularExpression) {
                    return String(found[v])
                        .replacingOccurrences(of: "=", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
            }
        }
        return nil
    }

    // MARK: - Finishing

    private static func finish(url: URL, feedTitle: String?, entries: Int,
                               title: String?, prefix: String? = nil) -> Verdict {
        let host = url.host ?? url.absoluteString
        let existing = SourceRegistry.shared.all.first {
            $0.feedURL.caseInsensitiveCompare(url.absoluteString) == .orderedSame
        }
        if let existing {
            return .duplicate(title: existing.title)
        }
        // A feed the app already ships with: adding it again would double its
        // stories in every list, so it is a duplicate even though the user "added"
        // it rather than the app.
        if let builtIn = SourceID.builtIns.first(where: {
            guard let f = $0.feedURL else { return false }
            return f.absoluteString.caseInsensitiveCompare(url.absoluteString) == .orderedSame
        }) {
            return .duplicate(title: builtIn.title)
        }
        // A feed with no title and no entries is not useful to add: it would show
        // as an empty source forever. Say so instead of adding a dead row.
        let name = firstNonEmpty(title, feedTitle, host)
        let note = prefix ?? "Read \(entries) item\(entries == 1 ? "" : "s") when it was added."
        return .valid(CustomSource(
            id: UUID().uuidString,
            title: name,
            feedURL: url.absoluteString,
            homeURL: homeURLString(for: url),
            host: host.replacingOccurrences(of: "www.", with: ""),
            addedAt: Date(),
            itemCount: entries,
            note: note))
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for v in values {
            if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "Untitled source"
    }

    /// The site root, which is what a "Source page" button should open.
    private static func homeURLString(for feed: URL) -> String {
        guard let host = feed.host else { return feed.absoluteString }
        return "https://\(host)/"
    }
}
