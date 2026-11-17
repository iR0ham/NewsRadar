import Foundation

/// Collectors for the sources that publish no RSS feed.
///
/// Two shapes are needed:
///   * `AnthropicSource` — server-rendered HTML listing, scraped into entries.
///   * `HuggingFaceSource` — the public models API, one item per notable release.
///
/// Each returns the same `FeedSource.Outcome` shape as the RSS path so the
/// refresh engine does not need to know how a source was read.
enum AltSource {

    // MARK: - Anthropic (HTML listing)

    /// Anthropic publishes no feed. `/news` and `/research` are server-rendered
    /// with one anchored card per article, so the listing itself is the source of
    /// truth: each anchor gives the URL, the date, the section and the headline.
    static func anthropic(_ source: SourceID, now: Date) -> FeedSource.Outcome {
        var status = SourceStatus(source: source, lastAttempt: now)
        let isResearch = source == .anthropicResearch
        do {
            let (body, fromCache) = try HTTP.getWithCache(source.homeURL, maxAge: 2 * 3600)
            let entries = parseAnthropicListing(body, base: source.homeURL, isResearch: isResearch)
            guard !entries.isEmpty else {
                status.message = "Listing page read but no article links were found."
                status.fromCache = fromCache
                return FeedSource.Outcome(items: [], status: status)
            }
            var items = entries.prefix(20).map {
                FeedSource.makeItem($0, source: source, feedImage: nil, now: now)
            }
            // The listing carries no description, so a page fetch supplies the
            // summary and the social image exactly as it does for RSS sources.
            var enriched = 0
            for idx in items.indices where enriched < 10 {
                guard items[idx].imageURL == nil || items[idx].rawSummary.isEmpty else { continue }
                enriched += 1
                FeedSource.enrich(&items[idx], base: items[idx].link)
            }
            status.ok = true
            status.itemCount = items.count
            status.fromCache = fromCache
            status.lastSuccess = now
            status.message = fromCache ? "Served from cache (network request failed)" : ""
            return FeedSource.Outcome(items: items, status: status)
        } catch {
            status.message = HTTP.explain(error)
            return FeedSource.Outcome(items: [], status: status)
        }
    }

    /// Parses one Anthropic listing page.
    ///
    /// The page is a list of `<article>` cards, and the markup inside a card varies
    /// by layout: the featured tile wraps its headline and summary in a link, a
    /// regular tile puts the link inside the heading, and an image-only tile has no
    /// heading at all — its headline is the image's `alt` text. Anchoring on the
    /// card and reading all three shapes is what makes the source work across
    /// layouts; matching one fixed skeleton broke silently when the site changed.
    ///
    /// A card with no date or no headline is skipped: an undated entry would be
    /// filed at "now" and jump to the top of the feed.
    static func parseAnthropicListing(_ html: String, base: URL,
                                      isResearch: Bool) -> [RawFeedEntry] {
        var out: [RawFeedEntry] = []
        var seen = Set<String>()

        // A card boundary is `<article`, which every layout uses. Splitting is
        // cheaper and far less brittle than matching nested tags with a regex.
        let cards = html.components(separatedBy: "<article").dropFirst()
        for card in cards {
            // --- Headline: a heading, or the image's alt text on an image tile.
            let headingBody = RX.first("(?s)<h[23][^>]*>(.*?)</h[23]>", in: card)
            var headline = headingBody.map { HTMLText.plain($0) } ?? ""
            if headline.count <= 4 {
                headline = RX.first("(?s)<img[^>]*alt=\"([^\"]+)\"", in: card)
                    .map { HTMLText.plain($0) } ?? ""
            }
            guard headline.count > 4 else { continue }

            // --- URL: the heading's own anchor, the tile link, or the media link.
            // A topic link ("/news/announcements") is the card's section, not the
            // story, so it is skipped even when it is the first anchor present.
            var href: String?
            if let headingBody {
                href = RX.first("href=\"([^\"]+)\"", in: headingBody)
            }
            if href == nil {
                href = RX.first("(?s)class=\"[^\"]*tileLink[^\"]*\"[^>]*href=\"([^\"]+)\"", in: card)
            }
            if href == nil {
                href = RX.first("(?s)class=\"[^\"]*mediaLink[^\"]*\"[^>]*href=\"([^\"]+)\"", in: card)
            }
            if href == nil {
                // Last resort: the first anchor that is not a topic link.
                for each in RX.all("<a([^>]*)>", in: card) where !each.contains("TopicLink") {
                    if let h = RX.first("href=\"([^\"]+)\"", in: each) { href = h; break }
                }
            }
            // Anthropic links some posts from the site root (/claude-haiku-5-5)
            // rather than under /news/, so the news page accepts both. The research
            // page is stricter: it only accepts /research/ paths, otherwise the two
            // sources would report each other's stories.
            guard let href else { continue }
            let fitsSection = isResearch ? href.contains("/research/") : !href.contains("/research/")
            guard fitsSection,
                  let url = HTMLText.absolute(href, base: base),
                  // A section root is a listing, not a story.
                  url.absoluteString != base.absoluteString,
                  seen.insert(url.absoluteString).inserted else { continue }

            // --- Date: the card's own <time>, which sits outside the link.
            guard let dateText = RX.first("(?s)<time[^>]*>\\s*([^<]+?)\\s*</time>", in: card),
                  let published = ListingDates.listingDate(dateText) else { continue }

            var e = RawFeedEntry()
            e.title = headline
            e.link = url
            e.guid = url.absoluteString
            e.published = published
            // The news cards carry a one-line summary; the research cards do not.
            if let summary = RX.first("(?s)<p[^>]*summary[^>]*>(.*?)</p>", in: card) {
                let text = HTMLText.plain(summary)
                if text.count > 20 { e.summaryHTML = text }
            }
            out.append(e)
        }
        return out
    }

    // MARK: - Design sites that publish no feed

    /// Collects a publisher that has no RSS feed, by reading the article
    /// links out of its own listing page.
    ///
    /// A third of the design publishers — Adobe, Runway, Luma, Recraft, HeyGen,
    /// School of Motion, Affinity — publish no feed at all, and several refuse
    /// automated clients outright. Their own pages are server-rendered, though,
    /// so the listing is the source of truth. The entries are the anchors that
    /// point at an article, with the date taken from the card or from the
    /// article page's own metadata.
    static func listing(_ source: SourceID, now: Date,
                        pathPrefix: String,
                        titleSelector: ListingTitleSelector = .heading,
                        dateSelector: ListingDateSelector = .card) -> FeedSource.Outcome {
        var status = SourceStatus(source: source, lastAttempt: now)
        do {
            let (body, fromCache) = try HTTP.getWithCache(source.homeURL, maxAge: 2 * 3600)
            let entries = parseListing(body, base: source.homeURL,
                                       pathPrefix: pathPrefix,
                                       titleSelector: titleSelector,
                                       dateSelector: dateSelector)
            guard !entries.isEmpty else {
                status.message = "Listing page read but no article links were found."
                status.fromCache = fromCache
                return FeedSource.Outcome(items: [], status: status)
            }
            var items = entries.prefix(20).map {
                FeedSource.makeItem($0, source: source, feedImage: nil, now: now)
            }
            if dateSelector == .articlePage {
                // The listing prints no date, so the story is filed at the moment
                // the page was read. The article page carries the real date, and
                // it is read for as many stories as the budget allows — without
                // it every story of such a publisher would look brand new.
                var dated = 0
                for idx in items.indices where dated < 12 {
                    dated += 1
                    items[idx].publishedFromListing = true
                    FeedSource.enrich(&items[idx], base: items[idx].link)
                }
            } else {
                var enriched = 0
                for idx in items.indices where enriched < 6 {
                    guard items[idx].imageURL == nil || items[idx].rawSummary.isEmpty else { continue }
                    enriched += 1
                    FeedSource.enrich(&items[idx], base: items[idx].link)
                }
            }
            status.ok = true
            status.itemCount = items.count
            status.fromCache = fromCache
            status.lastSuccess = now
            status.message = fromCache ? "Served from cache (network request failed)" : ""
            return FeedSource.Outcome(items: items, status: status)
        } catch {
            status.message = HTTP.explain(error)
            return FeedSource.Outcome(items: [], status: status)
        }
    }

    /// How the headline of a listed article is found.
    enum ListingTitleSelector {
        /// A heading inside the anchor, or the anchor's own text.
        case heading
        /// The anchor's `title` or `aria-label` attribute, then its text.
        case attribute
    }

    /// Where the date of a listed article comes from.
    enum ListingDateSelector {
        /// A date printed on the listing card, next to the headline.
        case card
        /// No date on the card: the article page carries one, and it is read
        /// from the page's own metadata when the story is enriched.
        case articlePage
    }

    /// Reads article entries out of a listing page.
    ///
    /// The card boundary is not a fixed tag on these sites — some use
    /// `<article>`, some a `<div>` grid, some `<li>`. So the page is read at
    /// its anchors, and each anchor is judged on its own: the headline comes
    /// from the heading inside it, the date from the markup around it.
    static func parseListing(_ html: String, base: URL,
                              pathPrefix: String,
                              titleSelector: ListingTitleSelector = .heading,
                              dateSelector: ListingDateSelector = .card) -> [RawFeedEntry] {
        var out: [RawFeedEntry] = []
        var seen = Set<String>()

        // Group 1 of the pattern is the anchor's inner markup, which carries
        // the headline; the attributes are read from the whole match.
        let anchors = RX.blocks("(?s)<a\\b[^>]*>(.*?)</a>", in: html)
        for anchor in anchors {
            let attrs = anchor.full
            let body = anchor.body
            guard let href = RX.first("href=\"([^\"]+)\"", in: attrs) else { continue }
            // The link may be absolute, root-relative or relative to the
            // listing's own path — Framer writes "./post" under /blog/ and
            // "../updates/post" under /updates/. Foundation resolves all three
            // against the listing's address, which is the only rule that gets
            // them all right.
            guard let resolved = URL(string: href, relativeTo: base)?.absoluteURL
            else { continue }
            let full = resolved.absoluteString
            guard full.contains(pathPrefix) else { continue }
            // The path after the prefix must name a story, not a section.
            let tail = full.components(separatedBy: pathPrefix).last ?? ""
            let slug = tail.components(separatedBy: "/").first ?? ""
            guard slug.count >= 4, !slug.contains("?"), !slug.contains("#") else { continue }
            // The address must name a story and nothing under it. A listing
            // also prints its own navigation, and Framer's writes section
            // pages like "/updates/solutions/ui-ux-design/" — two segments
            // after the prefix. Those were stored as stories with the
            // refresh time as their date, so the tab read as broken.
            let segments = tail.components(separatedBy: "/").filter { !$0.isEmpty }
            guard segments.count == 1 else { continue }
            guard !full.contains("/page/"), !full.contains("/tag/"), !full.contains("/category/") else { continue }
            // The same story is often printed twice — once as a picture with
            // no headline beside it, once with the headline. The copy with
            // no headline is passed over rather than counted, so the copy
            // that carries the headline is the one that is kept.
            if seen.contains(full) { continue }

            var title = ""
            switch titleSelector {
            case .heading:
                let h = RX.first("(?s)<h[1-6][^>]*>(.*?)</h[1-6]>", in: body)
                title = h.map { HTMLText.plain($0) } ?? ""
                if title.count < 8 { title = HTMLText.plain(body) }
            case .attribute:
                let t = RX.first("title=\"([^\"]+)\"", in: attrs)
                    ?? RX.first("aria-label=\"([^\"]+)\"", in: attrs)
                title = t.map { HTMLText.plain($0) } ?? ""
                if title.count < 8 { title = HTMLText.plain(body) }
            }
            title = cleanListingTitle(title)
            guard title.count >= 12 else { continue }
            guard seen.insert(full).inserted else { continue }

            var e = RawFeedEntry()
            e.title = title
            guard let url = URL(string: full) else { continue }
            e.link = url
            e.guid = full

            switch dateSelector {
            case .card:
                // The page may print the link in its short form — Shopify's
                // newsroom writes href="/news/the-story" while the resolved
                // address is the full one — so the date is looked for beside
                // either form.
                if let d = dateNear(html, anchor: full, also: href) { e.published = d }
            case .articlePage:
                e.published = Date()
            }
            out.append(e)
            if out.count >= 40 { break }
        }
        return out
    }

    /// Finds a printed date near a given link in a listing page.
    ///
    /// The card is a window of markup around the link: a date is either just
    /// before the headline or just after it.
    ///
    /// The window is searched for the date nearest the link. The first version
    /// took the first date anywhere in the window, which was the date of
    /// whatever the previous card said — so every story on a listing page was
    /// filed under the date of the card above it. On Brand New, whose archive is
    /// grouped by day, that put a post from June under today's date, and the
    /// whole archive looked like it had been published this morning.
    private static func dateNear(_ html: String, anchor: String, also: String? = nil) -> Date? {
        let patterns = [#"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}"#,
                        #"\b\d{1,2}\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{4}"#,
                        #"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+\d{4}"#]
        // A link can appear on the page more than once — Shopify's newsroom
        // shows the same story in a carousel at the top and again in the grid
        // below, and only the grid copy has a date beside it. So every
        // occurrence of the link is looked at, and the nearest date to any of
        // them wins.
        //
        // The page may also print the link in more than one form: the full
        // address, or the short form it was written with. Both are looked
        // for, because a listing that writes "/news/the-story" has no
        // "https://www.shopify.com/news/the-story" in it at all, and the
        // date beside the card would never be found.
        var forms = [anchor]
        if let also, also.count >= 4, also != anchor { forms.append(also) }

        var best: (distance: Int, date: Date)?
        for form in forms {
            var searchStart = html.startIndex
            while let i = html.range(of: form, range: searchStart..<html.endIndex) {
                let start = html.index(i.lowerBound, offsetBy: -1200, limitedBy: html.startIndex) ?? html.startIndex
                let end = html.index(i.upperBound, offsetBy: 1200, limitedBy: html.endIndex) ?? html.endIndex
                let window = String(html[start..<end])
                let (text, origins) = HTMLText.plainWithOrigins(window)
                // Where the link sits inside the plain text, so the nearest
                // date wins. The position is taken from the stripped text
                // through the map back to the original, because a tag cut in
                // half by the cut is not a tag and would otherwise shift every
                // position.
                let rawAnchorOffset = html.distance(from: start, to: i.lowerBound)
                let anchorOffset = origins.firstIndex(where: { $0 >= rawAnchorOffset })
                    ?? origins.count
                for pattern in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern,
                                                               options: [.caseInsensitive]) else { continue }
                    let ns = text as NSString
                    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                        guard let r = Range(match.range, in: text),
                              let d = ListingDates.listingDate(String(text[r])) else { continue }
                        let distance = abs(r.lowerBound.utf16Offset(in: text) - anchorOffset)
                        if best == nil || distance < best!.distance {
                            best = (distance, d)
                        }
                    }
                }
                searchStart = i.upperBound
                if searchStart >= html.endIndex { break }
            }
        }
        return best?.date
    }

    /// Cuts the category and the date out of a headline that was printed with
    /// them glued on.
    static func cleanListingTitle(_ raw: String) -> String {
        var t = raw
        for pattern in [#"(?i)\b(News|Product Updates|Blog|Insights|Resources|Newsroom|Research|Company News|Announcements|Product|Feature|Guide|Tutorial|Update|Company)\b"#,] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // A date glued to the front or the back.
        t = t.replacingOccurrences(of: #"(?i)\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}\b"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Publishers that publish a sitemap but no feed

    /// Collects a publisher that lists its articles in a sitemap.
    ///
    /// Adobe's two sites publish no feed at all, but each publishes a sitemap
    /// with every article and the date it was last changed. The date in the
    /// URL is the publication date, which is better than guessing: a story
    /// from 2024 must not look like it was published today.
    static func sitemap(_ source: SourceID, now: Date,
                        sitemapURL: URL,
                        pathPrefix: String,
                        dateInPath: Bool = true) -> FeedSource.Outcome {
        var status = SourceStatus(source: source, lastAttempt: now)
        do {
            let (body, fromCache) = try HTTP.getWithCache(sitemapURL, maxAge: 6 * 3600)
            let entries = parseSitemap(body, base: source.homeURL,
                                       pathPrefix: pathPrefix, dateInPath: dateInPath)
            guard !entries.isEmpty else {
                status.message = "Sitemap read but it listed no articles."
                status.fromCache = fromCache
                return FeedSource.Outcome(items: [], status: status)
            }
            var items = entries.prefix(20).map {
                FeedSource.makeItem($0, source: source, feedImage: nil, now: now)
            }
            var enriched = 0
            for idx in items.indices where enriched < 6 {
                guard items[idx].imageURL == nil || items[idx].rawSummary.isEmpty else { continue }
                enriched += 1
                FeedSource.enrich(&items[idx], base: items[idx].link)
            }
            status.ok = true
            status.itemCount = items.count
            status.fromCache = fromCache
            status.lastSuccess = now
            status.message = fromCache ? "Served from cache (network request failed)" : ""
            return FeedSource.Outcome(items: items, status: status)
        } catch {
            status.message = HTTP.explain(error)
            return FeedSource.Outcome(items: [], status: status)
        }
    }

    /// Reads stories out of a WordPress JSON endpoint.
    ///
    /// Some publishers run a WordPress whose feed is broken or advertising
    /// something else entirely — Brand New's feed file answers with a server
    /// error, and Web Design Weekly's feed is a year out of date. The same
    /// site still answers the WordPress JSON endpoint, which gives every post
    /// with its real publication date, its headline, its address and its
    /// picture.
    ///
    /// The endpoint answers with PHP warnings in front of the JSON when the
    /// theme has a broken variable, so the document is read from its first
    /// bracket rather than from its first character.
    static func wordPressJSON(_ source: SourceID, now: Date,
                               endpoint: URL) -> FeedSource.Outcome {
        var status = SourceStatus(source: source, lastAttempt: now)
        do {
            let (body, fromCache) = try HTTP.getWithCache(endpoint, maxAge: 2 * 3600)
            guard let start = body.firstIndex(of: "[") else {
                status.message = "The JSON endpoint answered with no list of posts."
                status.fromCache = fromCache
                return FeedSource.Outcome(items: [], status: status)
            }
            let json = String(body[start...])
            let data = json.data(using: .utf8) ?? Data()
            guard let posts = try? JSONDecoder().decode([WPPost].self, from: data),
                  !posts.isEmpty else {
                status.message = "The JSON endpoint answered with no posts."
                status.fromCache = fromCache
                return FeedSource.Outcome(items: [], status: status)
            }
            var out: [RawFeedEntry] = []
            for post in posts {
                guard let link = post.link, let url = URL(string: link) else { continue }
                let title = HTMLText.plain(post.titleRendered ?? "")
                guard title.count >= 8 else { continue }
                var e = RawFeedEntry()
                e.title = title
                e.link = url
                e.guid = link
                // The WordPress endpoint writes its dates without a zone. The
                // "gmt" copy of the date is the same moment in UTC, so it is
                // the one that is read: the publisher's own local time would
                // put the story a day early or late.
                e.published = (post.dateGMT ?? post.date).flatMap { DateParsing.parse($0) }
                e.summaryHTML = post.excerptRendered ?? ""
                // The picture of a WordPress post sits in its own body text, and
                // the body is what the endpoint returns.
                if let body = post.contentRendered, !body.isEmpty {
                    e.contentHTML = body
                    if let image = HTMLText.firstImage(in: body) {
                        e.imageURL = image.url
                        e.imageWidth = image.width
                        e.imageHeight = image.height
                    }
                }
                out.append(e)
            }
            guard !out.isEmpty else {
                status.message = "The JSON endpoint listed no stories."
                status.fromCache = fromCache
                return FeedSource.Outcome(items: [], status: status)
            }
            var items = out.prefix(20).map {
                FeedSource.makeItem($0, source: source, feedImage: nil, now: now)
            }
            var enriched = 0
            for idx in items.indices where enriched < 6 {
                guard items[idx].imageURL == nil || items[idx].rawSummary.isEmpty else { continue }
                enriched += 1
                FeedSource.enrich(&items[idx], base: items[idx].link)
            }
            status.ok = true
            status.itemCount = items.count
            status.fromCache = fromCache
            status.lastSuccess = now
            status.message = fromCache ? "Served from cache (network request failed)" : ""
            return FeedSource.Outcome(items: items, status: status)
        } catch {
            status.message = HTTP.explain(error)
            return FeedSource.Outcome(items: [], status: status)
        }
    }

    /// One post of a WordPress JSON response.
    struct WPPost: Decodable {
        struct Rendered: Decodable {
            var rendered: String
        }
        var date: String?
        var dateGMT: String?
        var link: String?
        var title: Rendered?
        var excerpt: Rendered?
        var content: Rendered?

        enum CodingKeys: String, CodingKey {
            case date, link, title, excerpt, content
            case dateGMT = "date_gmt"
        }

        var titleRendered: String? { title?.rendered }
        var excerptRendered: String? { excerpt?.rendered }
        var contentRendered: String? { content?.rendered }
    }

    /// Reads the article entries out of a sitemap.
    ///
    /// A sitemap entry gives a URL and a last-changed date. The date is only
    /// the publication date when the publisher puts it in the URL — Adobe does,
    /// as /news/2026/10/slug — so that is read first and the last-changed date
    /// is used only when the URL carries none.
    static func parseSitemap(_ xml: String, base: URL, pathPrefix: String,
                             dateInPath: Bool = true) -> [RawFeedEntry] {
        var out: [RawFeedEntry] = []
        var seen = Set<String>()
        let blocks = RX.blocks("(?s)<url>(.*?)</url>", in: xml)
        for block in blocks {
            guard let loc = RX.first("<loc>([^<]+)</loc>", in: block.body) else { continue }
            let url = loc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.hasPrefix("http") else { continue }
            // The path prefix says which part of the site is the article
            // section. A sitemap also lists the home page, the media library
            // and the static pages, and those are not stories.
            if !pathPrefix.isEmpty {
                guard url.contains(pathPrefix) else { continue }
            } else {
                // Without a stated prefix, an article is a URL with a date in
                // its path or a slug of its own — the site root is not.
                let path = url.components(separatedBy: "/").filter { !$0.isEmpty }.dropFirst(1)
                guard path.count >= 2 else { continue }
            }
            guard !url.contains("/page/"), seen.insert(url).inserted else { continue }

            // The slug is the last path segment; the title is read from the
            // page, because a slug is not a headline.
            let slug = url.components(separatedBy: "/").last ?? ""
            guard slug.count >= 8, !slug.contains("?") else { continue }

            var published: Date?
            if dateInPath {
                // The date is three consecutive path segments — a four-digit
                // year, a two-digit month, a two-digit day. The day may be
                // followed by more digits (Adobe writes the time into it), so
                // the segments are scanned rather than counted from the end.
                let parts = url.components(separatedBy: "/")
                for i in 0..<(parts.count - 2) {
                    guard parts[i].count == 4, let y = Int(parts[i]), y > 1990, y < 2100
                    else { continue }
                    guard parts[i + 1].count == 2, let m = Int(parts[i + 1]), (1...12).contains(m)
                    else { continue }
                    let dayText = parts[i + 2].prefix(2)
                    guard dayText.count == 2, let d = Int(dayText), (1...31).contains(d)
                    else { continue }
                    var comps = DateComponents()
                    comps.year = y
                    comps.month = m
                    comps.day = d
                    published = Calendar(identifier: .gregorian).date(from: comps)
                    break
                }
            }
            if published == nil,
               let lastmod = RX.first("<lastmod>([^<]+)</lastmod>", in: block.body) {
                published = DateParsing.parse(lastmod.trimmingCharacters(in: .whitespaces))
            }
            guard let published else { continue }

            var e = RawFeedEntry()
            e.title = titleFromSlug(slug)
            e.link = URL(string: url)
            e.guid = url
            e.published = published
            out.append(e)
        }
        // A sitemap is not in date order — Adobe's blog lists fifteen years of
        // posts — so everything is read, dated, and then the newest are taken.
        return out.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
    }

    /// Turns a URL slug into a readable headline.
    ///
    /// A slug is written for search engines, not readers, so the words are
    /// capitalised and the separators become spaces. The article page carries
    /// the real headline, which the enrichment step prefers.
    static func titleFromSlug(_ slug: String) -> String {
        let stem = slug.components(separatedBy: ".").first ?? slug
        let words = stem.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.joined(separator: " ")
    }

    // MARK: - Hugging Face models

    struct HFModel: Decodable {
        var id: String
        var likes: Int?
        var downloads: Int?
        var trendingScore: Int?
        var pipeline_tag: String?
        var library_name: String?
        var tags: [String]?
        var createdAt: String?
    }

    /// Hugging Face publishes no feed for models, and treating every upload as a
    /// story would flood the radar with hundreds of untitled checkpoints a day.
    /// Instead the trending endpoint is read and only models above a likes floor
    /// become items, so the list means "notable new models" rather than "everything
    /// uploaded".
    static func huggingFaceModels(now: Date) -> FeedSource.Outcome {
        var status = SourceStatus(source: .huggingFaceModels, lastAttempt: now)
        let url = URL(string: "https://huggingface.co/api/models"
            + "?sort=trendingScore&direction=-1&limit=40")!
        do {
            let (body, fromCache) = try HTTP.getWithCache(url, maxAge: 3 * 3600)
            guard let data = body.data(using: .utf8),
                  let models = try? JSONDecoder().decode([HFModel].self, from: data) else {
                status.message = "Models API answered but the JSON could not be read."
                status.fromCache = fromCache
                return FeedSource.Outcome(items: [], status: status)
            }
            // A floor keeps one-off uploads out: a model needs real interest.
            let notable = models.filter { ($0.likes ?? 0) >= 25 || ($0.trendingScore ?? 0) >= 100 }
            var items: [RadarItem] = []
            for m in notable.prefix(12) {
                guard let item = modelItem(m, now: now) else { continue }
                items.append(item)
            }
            guard !items.isEmpty else {
                status.message = "No model cleared the notability threshold this refresh."
                status.fromCache = fromCache
                return FeedSource.Outcome(items: [], status: status)
            }
            status.ok = true
            status.itemCount = items.count
            status.fromCache = fromCache
            status.lastSuccess = now
            status.message = fromCache ? "Served from cache (network request failed)" : ""
            return FeedSource.Outcome(items: items, status: status)
        } catch {
            status.message = HTTP.explain(error)
            return FeedSource.Outcome(items: [], status: status)
        }
    }

    static func modelItem(_ m: HFModel, now: Date) -> RadarItem? {
        guard !m.id.isEmpty else { return nil }
        let published = m.createdAt.flatMap { DateParsing.iso8601($0) } ?? now
        let task = m.pipeline_tag?.replacingOccurrences(of: "-", with: " ")
        var summary = "\(m.id) is a model published on Hugging Face"
        if let task { summary += " for \(task)" }
        if let lib = m.library_name { summary += ", built on \(lib)" }
        var facts: [String] = []
        if let likes = m.likes, likes > 0 { facts.append("\(TextFormat.number(likes)) likes") }
        if let downloads = m.downloads, downloads > 0 {
            facts.append("\(TextFormat.number(downloads)) downloads")
        }
        // Licence and runtime tags are the parts a reader actually cares about.
        let tags = m.tags ?? []
        if let lic = tags.first(where: { $0.hasPrefix("license:") }) {
            facts.append("Licence: " + lic.replacingOccurrences(of: "license:", with: ""))
        }
        if tags.contains("gguf") { facts.append("GGUF quantisations available") }
        if !facts.isEmpty { summary += ". " + facts.joined(separator: " · ") + "." }
        return RadarItem(
            id: "\(SourceID.huggingFaceModels.rawValue)::\(FeedSource.stableID(m.id))",
            source: .huggingFaceModels,
            kind: .product,
            title: m.id,
            link: URL(string: "https://huggingface.co/\(m.id)")!,
            published: published,
            rawSummary: summary,
            imageURL: nil,
            author: m.id.split(separator: "/").first.map(String.init),
            sourceCategories: Array(tags.filter { $0 != "region:us" }.prefix(6))
        )
    }
}

/// Date formats the HTML listings use. `FeedParsing.parse` already covers the RSS
/// forms; these are the human-readable ones printed on listing cards.
enum ListingDates {
    private static let listing: [DateFormatter] = {
        let specs: [(String, Locale)] = [
            ("MMM d, yyyy", Locale(identifier: "en_US_POSIX")),
            ("d MMM yyyy", Locale(identifier: "en_US_POSIX")),
            ("MMMM d, yyyy", Locale(identifier: "en_US_POSIX"))
        ]
        return specs.map { fmt, loc in
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = loc
            f.timeZone = TimeZone(identifier: "UTC")
            return f
        }
    }()

    static func listingDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for f in listing { if let d = f.date(from: t) { return d } }
        return nil
    }
}
