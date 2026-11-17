import Foundation

/// Reads an article's own text inside the app, so following a story does not mean
/// leaving it.
///
/// There is no readability library in Foundation, and pulling a whole browser in
/// for this would be absurd, so the extraction is a deliberately small heuristic:
/// take the block with the most paragraph text and throw the furniture away. It
/// fails honestly — when it cannot find an article it says so and offers the
/// original page, rather than showing an empty sheet.
enum ArticleReader {

    /// One block of the article body, in the order the page presents it.
    ///
    /// The reader used to hold a flat `[String]` of paragraphs, which dropped every
    /// inline image and every link. A story that explains itself with a diagram, or
    /// that cites its sources inline, came out as anonymous prose with the
    /// evidence missing.
    enum Block {
        case paragraph(String)
        /// An image inside the body, with its caption when the page has one.
        case image(URL, caption: String?)
        /// A paragraph that contains links, kept as attributed text.
        case linked(String, [LinkRun], plain: String)

        struct LinkRun: Hashable {
            var text: String
            var url: URL
        }
    }

    struct Article {
        var title: String
        var byline: String?
        var paragraphs: [String]
        /// The body in page order, including inline images and links.
        var blocks: [Block] = []
        var imageURL: URL?
        var url: URL
        /// How the text was obtained, shown to the reader so the provenance is not
        /// a mystery.
        var source: String
        /// True when the page gave only a teaser, which matters because a feed's
        /// own summary is often longer.
        var possiblyTruncated: Bool

        var isEmpty: Bool { paragraphs.isEmpty }
        var wordCount: Int { paragraphs.reduce(0) { $0 + $1.split(separator: " ").count } }
    }

    enum Failure: LocalizedError {
        case unreachable(String)
        case noText

        var errorDescription: String? {
            switch self {
            case .unreachable(let r): return r
            case .noText:
                return "The page was read, but no article text could be found in it. It is probably drawn by JavaScript, or it is a video page."
            }
        }
    }

    /// Hosts whose pages are applications, not articles. Extracting "the article"
    /// from these produces file listings and navigation dressed up as prose.
    private static let appHosts = ["github.com", "gitlab.com", "news.ycombinator.com",
                                   "reddit.com", "youtube.com", "youtu.be", "x.com",
                                   "twitter.com", "huggingface.co/spaces"]

    static func isAppPage(_ url: URL) -> Bool {
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        let path = url.absoluteString.lowercased()
        if appHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        // Hugging Face model and dataset pages are cards, not articles; its blog is
        // still prose, so only these paths are refused.
        if host == "huggingface.co", !path.contains("/blog/") { return true }
        return false
    }

    /// Whether a page is a listing rather than a story: a feed document, a section
    /// front, or a page whose paragraphs are mostly one-line teasers.
    ///
    /// Reading a listing produces a run of unrelated summaries presented as one
    /// article, which is worse than declining to read it.
    static func listingReason(url: URL, title: String, paragraphs: [String]) -> String? {
        let path = url.path.lowercased()
        if path.hasSuffix("/feed") || path.hasSuffix("/feed/") || path.hasSuffix("/rss")
            || path.contains("/feed.") {
            return "This address is a feed, not an article. Open a story from the list instead."
        }
        if title.lowercased().hasPrefix("category:") || title.lowercased().hasPrefix("tag:") {
            return "This is a section front — a list of stories rather than one story."
        }
        // A real article has at least a couple of multi-sentence paragraphs. A
        // listing is a pile of 1–2 sentence teasers.
        guard paragraphs.count >= 6 else { return nil }
        let long = paragraphs.filter { $0.split(separator: " ").count >= 40 }.count
        if long <= 1 {
            return "This page is a list of story teasers, not a single article. Open one of the stories instead."
        }
        return nil
    }

    /// Fetches and extracts. Blocking: always call off the main thread.
    static func read(url: URL, fallbackTitle: String, feedSummary: String) -> Result<Article, Failure> {
        if isAppPage(url) {
            return .failure(.unreachable(
                "\(url.host ?? "This site") is a web app rather than an article: a repository page, a forum thread or a video. There is no article text to extract, so it opens in your browser instead."))
        }
        guard let html = HTTP.getPlain(url) else {
            let reason = HTTP.lastError.map(HTTP.explain)
                ?? "The page did not answer."
            return .failure(.unreachable(reason))
        }
        if let article = extract(html: html, url: url, fallbackTitle: fallbackTitle) {
            return .success(article)
        }
        // The feed usually carries a summary. Showing that with a clear label is
        // better than an empty sheet, as long as it is not passed off as the article.
        let fallback = HTMLText.plain(feedSummary)
        if fallback.count > 160 {
            return .success(Article(title: fallbackTitle, byline: nil,
                                    paragraphs: fallback
                                        .components(separatedBy: "\n")
                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                        .filter { !$0.isEmpty },
                                    imageURL: nil, url: url,
                                    source: "Summary from the feed — the full page could not be read.",
                                    possiblyTruncated: true))
        }
        return .failure(.noText)
    }

    // MARK: - Extraction

    static func extract(html: String, url: URL, fallbackTitle: String) -> Article? {
        guard !html.isEmpty else { return nil }
        let og = HTMLText.openGraph(in: html)
        let title = clean(metaTitle(html) ?? fallbackTitle)
        let byline = metaAuthor(html)

        // Strip the parts that are never article text before looking for blocks.
        var body = html
        // `figure` is deliberately NOT stripped: an inline diagram or screenshot is
        // part of the story, and the reader has to be able to show it.
        for tag in ["script", "style", "nav", "header", "footer", "aside", "form",
                    "noscript", "svg", "iframe"] {
            body = removeElement(body, tag)
        }

        // Score candidate containers by the amount of paragraph text inside them.
        // The article body is almost always the densest block of <p> text on the
        // page; the sidebar, comments and related-links lists are not.
        let candidates = blocks(in: body)
        var best: (text: [String], html: String, score: Int)?
        for block in candidates {
            let paragraphs = paragraphTexts(in: block)
            guard !paragraphs.isEmpty else { continue }
            let words = paragraphs.reduce(0) { $0 + $1.split(separator: " ").count }
            // Links are the giveaway for a menu or a list of teasers: a block that
            // is mostly anchor text is navigation, not prose.
            let linkChars = linkTextLength(in: block)
            let totalChars = max(1, HTMLText.plain(block).count)
            let linkDensity = Double(linkChars) / Double(totalChars)
            let score = Int(Double(words) * (1.0 - min(0.9, linkDensity)))
            if score > (best?.score ?? 0) {
                best = (paragraphs, block, score)
            }
        }

        // A page with no <p> structure at all: fall back to the whole body, which
        // is worse but still better than nothing.
        var paragraphs: [String]
        if let best, best.score >= 40 {
            paragraphs = best.text
        } else {
            let loose = HTMLText.plain(body)
            paragraphs = loose.components(separatedBy: "\n")
        }
        paragraphs = paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { p in
                // Drop furniture: cookie notices, "share this", single-word lines.
                p.split(separator: " ").count >= 6
                    && !isFurniture(p)
            }
        // The same block often appears twice (a hero heading and a body heading,
        // or a teaser repeated in the sidebar). Repeating it reads as a stutter.
        var deduped: [String] = []
        for p in paragraphs where deduped.last != p && !deduped.contains(p) {
            deduped.append(p)
        }
        paragraphs = deduped
        guard !paragraphs.isEmpty else { return nil }
        if let reason = listingReason(url: url, title: title, paragraphs: paragraphs) {
            let image = og.image ?? HTMLText.firstImageURL(in: html)
            return Article(title: title, byline: byline, paragraphs: paragraphs,
                           imageURL: image, url: url, source: reason,
                           possiblyTruncated: true)
        }

        // Rebuild the body in page order from the winning container, keeping the
        // inline images and links the flat paragraph list throws away.
        // The score gate applies to choosing the *container*; once one has been
        // chosen its structure is worth keeping even when the text is short.
        // The blocks are then trimmed to the paragraphs that survived the furniture
        // filter: the container also holds "related articles" teasers, and those
        // are text, not part of this story.
        let raw = best.map { bodyBlocks(in: $0.html, base: url) } ?? []
        let accepted = Set(paragraphs.map { normalize($0) })
        let inline = trimToBody(raw, accepted: accepted)

        let image = og.image ?? HTMLText.firstImageURL(in: html)
        let words = paragraphs.reduce(0) { $0 + $1.split(separator: " ").count }
        // 250 words is about one screen. Below that the page almost certainly gave
        // a teaser (a paywall, a newsletter sign-up), and saying "read from the page
        // itself" would be a half-truth.
        let shortened = words < 250
        return Article(title: title, byline: byline, paragraphs: paragraphs,
                       blocks: inline,
                       imageURL: image, url: url,
                       source: shortened
                        ? "Only \(words) words of the page could be read — the rest is probably behind a paywall or drawn by JavaScript."
                        : "Read from the page itself.",
                       possiblyTruncated: shortened)
    }

    /// Walks a container's markup in document order and returns paragraphs, inline
    /// images and linked paragraphs, so the reader can render the article as it was
    /// written rather than as a plain-text transcription of it.
    static func bodyBlocks(in html: String, base: URL) -> [Block] {
        var out: [Block] = []
        // The order matters: find the earliest occurrence of any of the tags we
        // care about, consume it, and repeat.
        let pattern = "(?s)<(p|img|figure|h2|h3|li)\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let ns = html as NSString
        var cursor = 0
        while cursor < ns.length {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            guard let m = regex.firstMatch(in: html, range: searchRange) else { break }
            let tag = ns.substring(with: m.range(at: 1)).lowercased()

            switch tag {
            case "img":
                let tagText = ns.substring(with: m.range)
                if let src = RX.first("src=\"([^\"]+)\"", in: tagText),
                   let url = HTMLText.absolute(src, base: base),
                   !isTrackingPixel(url, in: tagText), isStillImage(url),
                   !isThumbnail(url, in: tagText) {
                    out.append(.image(url, caption: nil))
                }
                cursor = m.range.location + m.range.length

            case "figure":
                // A figure is an image plus, often, the caption that explains it.
                guard let end = html.range(of: "</figure>", options: [.caseInsensitive],
                                           range: Range(NSRange(location: m.range.location,
                                                                length: ns.length - m.range.location),
                                                        in: html)!) else {
                    cursor = m.range.location + m.range.length
                    break
                }
                let inner = String(html[html.index(html.startIndex, offsetBy: m.range.location)..<end.lowerBound])
                if let src = RX.first("src=\"([^\"]+)\"", in: inner),
                   let url = HTMLText.absolute(src, base: base), isStillImage(url),
                   !isThumbnail(url, in: inner) {
                    let caption = RX.first("(?s)<figcaption[^>]*>(.*?)</figcaption>", in: inner)
                        .map { HTMLText.plain($0) }
                        .flatMap { $0.isEmpty ? nil : $0 }
                        ?? RX.first("(?s)alt=\"([^\"]{12,})\"", in: inner)
                    out.append(.image(url, caption: caption))
                }
                cursor = ns.range(of: "</figure>", options: [.caseInsensitive],
                                  range: NSRange(location: m.range.location,
                                                 length: ns.length - m.range.location)).location
                cursor += "</figure>".count

            default:
                // <p>, <h2>, <h3>, <li>: read up to the matching close.
                // Start *after* the opening tag: searching from its own location
                // finds it again, counts it as a nested open, and never balances.
                guard let close = self.closeRange(of: tag,
                                                  from: m.range.location + m.range.length,
                                                  in: html, ns: ns) else {
                    cursor = m.range.location + m.range.length
                    break
                }
                let inner = ns.substring(with: NSRange(location: m.range.location + m.range.length,
                                                       length: close.location - (m.range.location + m.range.length)))
                let plain = HTMLText.plain(inner).trimmingCharacters(in: .whitespacesAndNewlines)
                if plain.split(separator: " ").count >= 6, !isFurniture(plain) {
                    let links = inlineLinks(in: inner, base: base)
                    if links.isEmpty {
                        out.append(.paragraph(plain))
                    } else {
                        out.append(.linked(plain, links, plain: plain))
                    }
                }
                cursor = close.location + close.length
            }
        }
        // The same picture is often marked up twice (a <figure> and a bare <img>);
        // showing it once is the point of keeping it at all.
        var seen = Set<String>()
        out = out.filter { block in
            guard case .image(let url, _) = block else { return true }
            return seen.insert(url.absoluteString).inserted
        }
        // A page whose paragraphs all failed the filter still deserves the text.
        if out.isEmpty {
            for p in paragraphTexts(in: html) where !isFurniture(p) {
                out.append(.paragraph(p))
            }
        }
        return out
    }

    /// Keeps only the part of a container that belongs to the story: the run of
    /// blocks from the first accepted paragraph to the last, with any paragraph
    /// that did not survive the furniture filter dropped.
    ///
    /// Without this the reader showed the article followed by a row of unrelated
    /// "related links" — the page's furniture, presented as the author's words.
    static func trimToBody(_ blocks: [Block], accepted: Set<String>) -> [Block] {
        func plain(_ b: Block) -> String? {
            switch b {
            case .paragraph(let t): return normalize(t)
            case .linked(let t, _, _): return normalize(t)
            case .image: return nil
            }
        }
        guard var first = blocks.firstIndex(where: { plain($0).map(accepted.contains) == true }),
              let last = blocks.lastIndex(where: { plain($0).map(accepted.contains) == true }),
              first <= last else { return blocks }
        // A story usually opens with its lead picture, before the first sentence.
        // Walking back over a contiguous run of images keeps that, without pulling in
        // whatever logo sat at the top of the container.
        while first > 0, case .image = blocks[first - 1] { first -= 1 }
        var out: [Block] = []
        for b in blocks[first...last] {
            if let t = plain(b), !accepted.contains(t) { continue }
            out.append(b)
        }
        return out
    }

    /// Comparison form for paragraph matching: whitespace collapsed, quotes and
    /// dashes normalised, lowercased. The plain-text and the HTML paths differ in
    /// exactly those characters.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// The range of `</tag>`, accounting for nested same-name tags.
    private static func closeRange(of tag: String, from start: Int,
                                   in html: String, ns: NSString) -> NSRange? {
        let open = try? NSRegularExpression(pattern: "<\(tag)\\b[^>]*>", options: [.caseInsensitive])
        let close = try? NSRegularExpression(pattern: "</\(tag)\\s*>", options: [.caseInsensitive])
        guard let open, let close else { return nil }
        var depth = 1
        var cursor = start
        while cursor < ns.length {
            let range = NSRange(location: cursor, length: ns.length - cursor)
            let nextOpen = open.firstMatch(in: html, range: range)
            let nextClose = close.firstMatch(in: html, range: range)
            guard let nextClose else { return nil }
            if let nextOpen, nextOpen.range.location < nextClose.range.location {
                depth += 1
                cursor = nextOpen.range.location + nextOpen.range.length
            } else {
                depth -= 1
                if depth == 0 { return nextClose.range }
                cursor = nextClose.range.location + nextClose.range.length
            }
        }
        return nil
    }

    /// Anchors inside a paragraph, with the words they are attached to.
    static func inlineLinks(in inner: String, base: URL) -> [Block.LinkRun] {
        var out: [Block.LinkRun] = []
        guard let regex = try? NSRegularExpression(
            pattern: "(?s)<a\\b[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>",
            options: [.caseInsensitive]) else { return [] }
        let ns = inner as NSString
        for m in regex.matches(in: inner, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 2 else { continue }
            let href = ns.substring(with: m.range(at: 1))
            // Anchor text can wrap across lines in the source; collapse the
            // newlines or the link words come back as "inline\ncitation".
            let text = HTMLText.plain(ns.substring(with: m.range(at: 2)))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Anchor text of one or two words is usually a menu or "here".
            guard text.split(separator: " ").count >= 1, text.count > 2,
                  let url = HTMLText.absolute(href, base: base),
                  !url.absoluteString.hasPrefix("javascript:") else { continue }
            if out.contains(where: { $0.text == text && $0.url == url }) { continue }
            out.append(.init(text: text, url: url))
        }
        return out
    }

    /// 1×1 beacons, spacers and ad frames: never article content.
    /// Whether the URL is a picture at all.
    ///
    /// Ars Technica marks its inline video with an <img> whose src is the .mp4;
    /// drawing that in the reader produces an empty frame where a figure should
    /// be, and a video the reader cannot play is worse than the gap left in its
    /// place. Only still formats are kept.
    private static func isStillImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let moving: Set<String> = ["mp4", "webm", "mov", "m3u8", "m4v", "ogv", "gifv"]
        if moving.contains(ext) { return false }
        return !url.absoluteString.lowercased().contains(".mp4?")
    }

    /// A small image that is furniture rather than a figure.
    ///
    /// The Verge puts a 96px author avatar in the body markup; drawn inline it
    /// looked like a picture the story was about. A picture the article is about
    /// is at least a couple of hundred pixels wide, in the tag or in the CDN's
    /// own resize parameter.
    private static func isThumbnail(_ url: URL, in tagText: String) -> Bool {
        for attr in ["width=\"\\s*(\\d+)", "height=\"\\s*(\\d+)"] {
            if let v = RX.first(attr, in: tagText), let n = Int(v), n < 200 { return true }
        }
        // CDNs encode the rendered size: ?w=96, /w_96, &amp;width=96
        for pat in ["[?&;]w[=_](\\d+)", "[?&;]width[=_](\\d+)"] {
            if let v = RX.first(pat, in: url.absoluteString), let n = Int(v), n < 200 { return true }
        }
        return false
    }

    private static func isTrackingPixel(_ url: URL, in tagText: String) -> Bool {
        if let w = RX.first("width=\"\\s*(\\d+)", in: tagText), let n = Int(w), n <= 2 { return true }
        if let h = RX.first("height=\"\\s*(\\d+)", in: tagText), let n = Int(h), n <= 2 { return true }
        let lower = tagText.lowercased()
        if lower.contains("pixel") || lower.contains("1x1") || lower.contains("spacer") { return true }
        // An author headshot belongs to the byline, not to the story. Without this
        // the body ended with a 96px photo of the reporter.
        let path = url.absoluteString.lowercased()
        return path.contains("author_profile") || path.contains("/avatar") || path.contains("headshot")
    }

    /// Sentences that appear on nearly every site and mean nothing to a reader.
    private static let furniture = [
        "cookie", "subscribe to our newsletter", "sign up for", "all rights reserved",
        "share this", "follow us on", "advertisement", "we use cookies",
        "accept all", "privacy policy", "terms of service", "related articles",
        "read more:", "you may also like"
    ]

    private static func isFurniture(_ p: String) -> Bool {
        let lower = p.lowercased()
        // Code that leaked out of an inline script or a code sample is never prose.
        let codeSignals = ["function(", "function (", "prototype.", "=>{", "document.",
                           "window.", "});", "return new ", "var "]
        if codeSignals.contains(where: { lower.contains($0) }) { return true }
        // Prose is mostly letters; a line that is a tenth punctuation is code.
        let punctuation = p.filter { ",.;:{}[]()=<>|&".contains($0) }.count
        if Double(punctuation) / Double(max(1, p.count)) > 0.10 { return true }
        // Only drop short lines: a real paragraph may mention cookies.
        if p.split(separator: " ").count > 40 { return false }
        // "Subscribe to the Creative Blog newsletter for details of…" varies by
        // site, so match the shape rather than one exact sentence.
        if lower.contains("subscribe") && (lower.contains("newsletter") || lower.contains("inbox")) {
            return true
        }
        if lower.hasPrefix("sign up") || lower.contains("sign up for our") { return true }
        return furniture.contains { lower.contains($0) }
    }

    private static func clean(_ s: String) -> String {
        var t = HTMLText.decodeEntities(s)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Publishers append their own name to <title>; the reader shows the article.
        for sep in [" | ", " - ", " — ", " · "] {
            if let r = t.range(of: sep, options: .backwards), t.distance(from: r.lowerBound, to: t.endIndex) < 42 {
                // Only cut when the tail looks like a site name (2–4 words).
                let tail = String(t[r.upperBound...])
                if tail.split(separator: " ").count <= 4 { t = String(t[..<r.lowerBound]) }
            }
        }
        return t
    }

    private static func metaTitle(_ html: String) -> String? {
        if let r = html.range(of: "<title[^>]*>(.*?)</title>",
                              options: [.regularExpression, .caseInsensitive]) {
            let raw = String(html[r])
                .replacingOccurrences(of: "<title[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "</title>", with: "", options: [.caseInsensitive])
            let t = HTMLText.plain(raw)
            if !t.isEmpty { return t }
        }
        // og:title is usually cleaner than <title>.
        if let r = html.range(of: "<meta[^>]*property=[\"']og:title[\"'][^>]*content=[\"']([^\"']+)[\"']",
                              options: [.regularExpression, .caseInsensitive]) {
            let tag = String(html[r])
            if let c = tag.range(of: "content=[\"']([^\"']+)", options: .regularExpression) {
                return String(tag[c]).replacingOccurrences(of: "content=[\"']", with: "")
            }
        }
        return nil
    }

    /// The article's author, from whichever byline convention the page uses.
    /// Internal rather than private so the offline self-test can prove the
    /// pattern substitutes the key: it was written with `\\(key)`, a literal
    /// "(key)" in the regular expression, so every lookup missed.
    static func metaAuthor(_ html: String) -> String? {
        let keys = ["author", "article:author", "og:article:author"]
        for key in keys {
            let patterns = [
                "<meta[^>]*(?:name|property)=[\"']\(key)[\"'][^>]*content=[\"']([^\"']+)[\"']",
                "<meta[^>]*content=[\"']([^\"']+)[\"'][^>]*(?:name|property)=[\"']\(key)[\"']"
            ]
            for p in patterns {
                if let r = html.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                    let tag = String(html[r])
                    if let c = tag.range(of: "content=[\"']([^\"']+)", options: .regularExpression) {
                        let v = String(tag[c])
                            .replacingOccurrences(of: "^content=[\"']", with: "",
                                                  options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !v.isEmpty, v.count < 80 { return HTMLText.decodeEntities(v) }
                    }
                }
            }
        }
        return nil
    }

    private static func removeElement(_ s: String, _ name: String) -> String {
        // (?s) matters: without it `.` stops at the first newline, a multi-line
        // <script> survives, and its JavaScript is then scored as the densest block
        // of prose on the page.
        s.replacingOccurrences(of: "(?s)<\(name)[^>]*>.*?</\(name)>", with: " ",
                               options: [.regularExpression, .caseInsensitive])
    }

    /// Splits the body into `<article>`, `<main>` and `<div>` blocks large enough to
    /// be worth scoring.
    private static func blocks(in body: String) -> [String] {
        var out: [String] = []
        for tag in ["article", "main"] {
            out.append(contentsOf: elements(named: tag, in: body))
        }
        // Divs too, because plenty of sites use no semantic containers at all.
        let divPattern = "<div[^>]*(?:class|id)=[\"'][^\"']*(?:article|content|post|entry|story|body)[^\"']*[\"'][^>]*>"
        for opening in matches(divPattern, in: body) {
            if let inner = innerHTML(from: opening.upperBound, tag: "div", in: body) {
                out.append(inner)
            }
        }
        if out.isEmpty { out.append(body) }
        return out
    }

    /// The inner HTML of every `<tag>…</tag>` element, with nesting respected.
    ///
    /// The first version stopped at the first `</div>`, so on any page with nested
    /// divs (that is every modern page) each "block" was a fragment holding one
    /// paragraph. The densest fragment won, and a 4-paragraph article was reported
    /// as 68 words with one paragraph.
    private static func elements(named tag: String, in body: String) -> [String] {
        var out: [String] = []
        for opening in matches("<\(tag)[^>]*>", in: body) {
            if let inner = innerHTML(from: opening.upperBound, tag: tag, in: body) {
                out.append(inner)
            }
        }
        return out
    }

    /// Walks forward from `start`, counting same-name open and close tags, and
    /// returns the content up to the matching close.
    private static func innerHTML(from start: String.Index, tag: String,
                                  in body: String) -> String? {
        let open = "<\(tag)(?:\\s[^>]*)?>"
        let close = "</\(tag)\\s*>"
        var depth = 1
        var cursor = start
        while cursor < body.endIndex {
            let nextOpen = body.range(of: open, options: [.regularExpression, .caseInsensitive],
                                      range: cursor..<body.endIndex)
            let nextClose = body.range(of: close, options: [.regularExpression, .caseInsensitive],
                                       range: cursor..<body.endIndex)
            guard let closeRange = nextClose else { return nil }
            if let openRange = nextOpen, openRange.lowerBound < closeRange.lowerBound {
                depth += 1
                cursor = openRange.upperBound
            } else {
                depth -= 1
                if depth == 0 {
                    return String(body[start..<closeRange.lowerBound])
                }
                cursor = closeRange.upperBound
            }
        }
        return nil
    }

    private static func matches(_ pattern: String,
                                in body: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else { return [] }
        let ns = body as NSString
        return regex.matches(in: body, range: NSRange(location: 0, length: ns.length)).compactMap {
            Range($0.range, in: body)
        }
    }

    private static func paragraphTexts(in block: String) -> [String] {
        var out: [String] = []
        var range = block.startIndex..<block.endIndex
        while let s = block.range(of: "<p[^>]*>", options: [.regularExpression, .caseInsensitive], range: range) {
            guard let e = block.range(of: "</p>", options: [.caseInsensitive], range: s.upperBound..<block.endIndex)
            else { break }
            let text = HTMLText.plain(String(block[s.upperBound..<e.lowerBound]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.split(separator: " ").count >= 5 { out.append(text) }
            range = e.upperBound..<block.endIndex
        }
        return out
    }

    private static func linkTextLength(in block: String) -> Int {
        var total = 0
        var range = block.startIndex..<block.endIndex
        while let s = block.range(of: "<a[^>]*>", options: [.regularExpression, .caseInsensitive], range: range) {
            guard let e = block.range(of: "</a>", options: [.caseInsensitive], range: s.upperBound..<block.endIndex)
            else { break }
            total += HTMLText.plain(String(block[s.upperBound..<e.lowerBound])).count
            range = e.upperBound..<block.endIndex
        }
        return total
    }
}
