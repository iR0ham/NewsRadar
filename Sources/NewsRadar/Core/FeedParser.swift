import Foundation

/// One raw entry extracted from an RSS 2.0 or Atom feed, before classification.
struct RawFeedEntry {
    var title: String = ""
    var link: URL?
    var guid: String = ""
    var published: Date?
    var summaryHTML: String = ""
    var contentHTML: String = ""
    var imageURL: URL?
    /// The size the feed declared for the picture, in pixels.
    ///
    /// It is kept because it distinguishes a story photo from a publisher's
    /// mark without guessing from the file name.
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var authors: [String] = []
    var categories: [String] = []

    /// First paragraph of the body as plain text, trimmed to a sentence-ish length.
    func plainSummary(limit: Int = 700) -> String {
        let source = summaryHTML.isEmpty ? contentHTML : summaryHTML
        var text = HTMLText.plain(source)
        if text.count > limit {
            // Cut on a sentence boundary when one is nearby, else on a word.
            let slice = String(text.prefix(limit))
            if let dot = slice.lastIndex(of: "."), slice.distance(from: slice.startIndex, to: dot) > 80 {
                text = String(slice[...dot])
            } else if let space = slice.lastIndex(of: " ") {
                text = String(slice[..<space]) + "…"
            } else {
                text = slice + "…"
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Minimal RSS/Atom reader built on Foundation's SAX parser.
///
/// Only the fields the app renders are pulled out, so it tolerates the very
/// different shapes of the configured sources (RSS 2.0, Atom, media:content,
/// namespaced elements, CDATA summaries).
final class FeedXMLParser: NSObject, XMLParserDelegate {

    private var entries: [RawFeedEntry] = []
    private var current: RawFeedEntry?
    private var path: [String] = []
    private var textBuffer = ""
    private var feedImageURL: URL?
    /// The feed's own <title>, which is the publication's name. It is what a
    /// new source should be called; the first entry's title is an article.
    private var feedTitle: String?

    private static let entryNames: Set<String> = ["item", "entry"]

    /// XMLParser hands back qualified names ("dc:creator") when namespace
    /// processing is off, so every comparison works on the local part only.
    /// Without this, namespaced elements (dc:creator, media:content) are
    /// silently ignored.
    private static func local(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return name.lowercased() }
        return String(name[name.index(after: colon)...]).lowercased()
    }

    static func parse(_ xml: String) -> (entries: [RawFeedEntry], feedImage: URL?) {
        let result = parseOnce(xml)
        if !result.entries.isEmpty { return result }
        // Some feeds use namespace prefixes without declaring them, which is a
        // fatal XML error. Retrying with the prefixes flattened recovers the
        // content instead of losing the whole source.
        let flattened = flattenNamespaces(xml)
        if flattened != xml {
            let retry = parseOnce(flattened)
            if !retry.entries.isEmpty { return retry }
        }
        // A bare `&` in a URL inside the body is enough to make XMLParser abort
        // the whole document, which loses every story in the feed — Motionographer
        // publishes `?w=800&quality=80&ssl=1` unescaped on every image. Escaping
        // the strays is the standard recovery and changes only invalid XML.
        let escaped = escapeStrayAmpersands(xml)
        if escaped != xml {
            let retry = parseOnce(escaped)
            if !retry.entries.isEmpty { return retry }
        }
        return result
    }

    /// Turns an `&` that does not begin a known entity into `&amp;`.
    /// Well-formed escapes (`&amp;`, `&#38;`, `&#x26;`) are left alone, so this is
    /// a no-op on a document that already parses.
    static func escapeStrayAmpersands(_ xml: String) -> String {
        guard xml.contains("&") else { return xml }
        var out = ""
        out.reserveCapacity(xml.count + 64)
        var i = xml.startIndex
        while i < xml.endIndex {
            let c = xml[i]
            guard c == "&" else {
                out.append(c)
                i = xml.index(after: i)
                continue
            }
            // Look ahead for a complete entity reference.
            var j = xml.index(after: i)
            var valid = false
            if j < xml.endIndex, xml[j] == "#" {
                j = xml.index(after: j)
                var digits = 0
                if j < xml.endIndex, xml[j] == "x" || xml[j] == "X" {
                    j = xml.index(after: j)
                    while j < xml.endIndex, xml[j].isHexDigit { j = xml.index(after: j); digits += 1 }
                } else {
                    while j < xml.endIndex, xml[j].isWholeNumber { j = xml.index(after: j); digits += 1 }
                }
                valid = digits > 0 && j < xml.endIndex && xml[j] == ";"
            } else {
                let start = j
                while j < xml.endIndex, xml[j].isLetter || xml[j].isWholeNumber { j = xml.index(after: j) }
                valid = j > start && j < xml.endIndex && xml[j] == ";"
            }
            if valid {
                out.append("&")
                i = xml.index(after: i)
            } else {
                out.append("&amp;")
                i = xml.index(after: i)
            }
        }
        return out
    }

    private static func parseOnce(_ xml: String) -> (entries: [RawFeedEntry], feedImage: URL?) {
        let p = FeedXMLParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.parse()
        return (p.entries, p.feedImageURL)
    }

    /// Parses and also returns the feed's own title, for the add-source check.
    static func parseWithTitle(_ xml: String) -> (entries: [RawFeedEntry], feedImage: URL?, title: String?) {
        let p = FeedXMLParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.parse()
        var title = p.feedTitle
        if title == nil || p.entries.isEmpty {
            let flattened = flattenNamespaces(xml)
            if flattened != xml {
                let p2 = FeedXMLParser()
                let parser2 = XMLParser(data: Data(flattened.utf8))
                parser2.delegate = p2
                parser2.shouldProcessNamespaces = false
                parser2.parse()
                title = p2.feedTitle ?? title
                if p.entries.isEmpty, !p2.entries.isEmpty {
                    return (p2.entries, p2.feedImageURL, title)
                }
            }
        }
        if p.entries.isEmpty {
            // Same stray-`&` recovery as `parse`, so the add-source sheet reports
            // the stories a feed actually has instead of "Read 0 items".
            let escaped = escapeStrayAmpersands(xml)
            if escaped != xml {
                let p3 = FeedXMLParser()
                let parser3 = XMLParser(data: Data(escaped.utf8))
                parser3.delegate = p3
                parser3.shouldProcessNamespaces = false
                parser3.parse()
                title = p3.feedTitle ?? title
                if !p3.entries.isEmpty {
                    return (p3.entries, p3.feedImageURL, title)
                }
            }
        }
        return (p.entries, p.feedImageURL, title)
    }

    /// Rewrites `<dc:creator>` into `<dccreator>` and drops `xmlns:*` declarations
    /// so an undeclared-prefix feed still parses. Element names are compared
    /// colon-free throughout, so both spellings are handled identically.
    static func flattenNamespaces(_ xml: String) -> String {
        guard xml.contains(":") else { return xml }
        var out = xml
        out = out.replacingOccurrences(of: "(</?)[A-Za-z0-9_.\\-]+:", with: "$1",
                                      options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+xmlns(:[A-Za-z0-9_.\\-]+)?=\"[^\"]*\"",
                                      with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+xmlns(:[A-Za-z0-9_.\\-]+)?='[^']*'",
                                      with: "", options: .regularExpression)
        return out
    }

    /// Copy-out mutators: reading and writing `current` in one expression trips
    /// Swift's exclusivity checker, so the optional is unwrapped first.
    private func setImageIfEmpty(_ url: URL?) {
        guard var c = current, c.imageURL == nil, let url else { return }
        c.imageURL = url
        current = c
    }

    private func setLinkIfEmpty(_ url: URL?) {
        guard var c = current, c.link == nil, let url else { return }
        c.link = url
        current = c
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let name = Self.local(elementName)
        path.append(name)
        textBuffer = ""
        if Self.entryNames.contains(name) {
            current = RawFeedEntry()
            return
        }
        guard let _ = current else {
            // Feed-level image (used when an entry has no image of its own).
            if name == "image", let url = attributeDict["url"] ?? attributeDict["href"] {
                feedImageURL = feedImageURL ?? URL(string: url)
            }
            return
        }
        switch name {
        case "link":
            let rel = attributeDict["rel"] ?? "alternate"
            let type = attributeDict["type"] ?? ""
            if let href = attributeDict["href"], (rel == "alternate" || rel.isEmpty),
               !type.contains("json") {
                setLinkIfEmpty(URL(string: href))
            }
        case "content", "thumbnail":
            // media:content / media:thumbnail after local-name stripping.
            if name == "thumbnail" || (attributeDict["medium"] ?? "image") == "image",
               let url = attributeDict["url"] {
                setImageIfEmpty(URL(string: url))
            }
        case "enclosure":
            if let url = attributeDict["url"],
               (attributeDict["type"] ?? "").hasPrefix("image") {
                setImageIfEmpty(URL(string: url))
            }
        case "category":
            if let term = attributeDict["term"] {
                current?.categories.append(term)
                textBuffer = "" // value already captured from the attribute
            }
        case "author":
            break
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { textBuffer += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.local(elementName)
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if !path.isEmpty { path.removeLast() }
            textBuffer = ""
        }

        if current == nil, name == "title", feedTitle == nil, !text.isEmpty {
            // Feed-level title: the publication's name.
            feedTitle = HTMLText.plain(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if Self.entryNames.contains(name) {
            if var e = current {
                e.title = HTMLText.plain(e.title).trimmingCharacters(in: .whitespacesAndNewlines)
                if e.guid.isEmpty { e.guid = e.link?.absoluteString ?? e.title }
                if e.imageURL == nil {
                    if let image = HTMLText.firstImage(in: e.contentHTML)
                        ?? HTMLText.firstImage(in: e.summaryHTML) {
                        e.imageURL = image.url
                        e.imageWidth = image.width
                        e.imageHeight = image.height
                    }
                }
                if e.imageURL == nil { e.imageURL = feedImageURL }
                if !e.title.isEmpty { entries.append(e) }
            }
            current = nil
            return
        }

        if current == nil {
            if (name == "icon" || name == "logo"), let u = URL(string: text),
               u.scheme != nil, feedImageURL == nil {
                feedImageURL = u
            }
            return
        }

        switch name {
        case "title":
            if current?.title.isEmpty ?? false { current?.title = text }
        case "link":
            if current?.link == nil, !text.isEmpty, text.hasPrefix("http") {
                current?.link = URL(string: text)
            }
        case "guid", "id":
            if let c = current, c.guid.isEmpty { current?.guid = text }
        case "pubdate", "published", "updated", "date":
            if let d = DateParsing.parse(text) {
                // Prefer the earliest date we see (pubDate in RSS, published in Atom).
                if let existing = current?.published {
                    current?.published = min(existing, d)
                } else {
                    current?.published = d
                }
            }
        case "description", "summary":
            if current?.summaryHTML.isEmpty ?? false { current?.summaryHTML = text }
        case "content", "encoded":
            if current?.contentHTML.isEmpty ?? false { current?.contentHTML = text }
        case "name":
            if path.contains("author") || path.contains("owner"), !text.isEmpty {
                current?.authors.append(text)
            }
        case "creator":
            if !text.isEmpty { current?.authors.append(text) }
        case "category":
            if !text.isEmpty, !(current?.categories.contains(text) ?? false) {
                current?.categories.append(text)
            }
        default:
            break
        }
    }
}

/// Date parsing for the many shapes feeds use.
enum DateParsing {

    private static let formats: [String] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm:ss zzzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd",
        // A WordPress endpoint writes its dates as "2026-10-22T02:55:04" with
        // no zone at all, and "2026-10-22T02:55:04.000". A date that carries
        // no zone is read as the publisher's own local time.
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.SSS"
    ]

    private static let formatters: [DateFormatter] = formats.map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = fmt
        return f
    }

    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        for f in formatters {
            if let d = f.date(from: t) { return d }
        }
        if let d = ISO8601DateFormatter().date(from: t) { return d }
        // Last resort for named-timezone RSS dates such as "-0500 (EST)" or
        // "(Eastern Standard Time)": strip the zone name, then rebuild the date
        // from the offset rather than silently shifting it.
        if let range = t.range(of: "\\([^)]*\\)", options: .regularExpression) {
            let cleaned = t.replacingCharacters(in: range, with: "")
                .trimmingCharacters(in: .whitespaces)
            for f in formatters {
                if let d = f.date(from: cleaned) { return d }
            }
        }
        return nil
    }

    /// RFC 1123 formatting for GitHub's conditional requests / display.
    static let rfc1123: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    static func iso8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}

/// HTML → plain text, plus image discovery.
enum HTMLText {

    static func plain(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var s = html
        s = s.replacingOccurrences(of: "<![CDATA[", with: "")
        s = s.replacingOccurrences(of: "]]>", with: "")
        // Drop scripts/styles entirely.
        s = stripElement(s, "script")
        s = stripElement(s, "style")
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p>", with: "\n", options: [.caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips the tags from a fragment and reports where each character of the
    /// plain text came from in the original.
    ///
    /// A listing page is searched for the date printed nearest a given link.
    /// The link has to be located inside the plain text, and its place cannot
    /// be measured by stripping the part before the link on its own: a tag cut
    /// in half by that cut has no closing bracket, so it is not a tag any more
    /// and it survives the stripping as literal characters. The count then
    /// comes out larger than the link's real position, and the nearest date is
    /// looked for in the wrong place — which is how every story on a listing
    /// page ended up carrying the date of the card above it.
    ///
    /// So the plain text is built once, and every character remembers the
    /// character of the original it came from. The link's place in the plain
    /// text is then known exactly.
    static func plainWithOrigins(_ html: String) -> (text: String, origins: [Int]) {
        var text = ""
        var origins: [Int] = []
        var i = html.startIndex
        var raw = 0
        while i < html.endIndex {
            let ch = html[i]
            if ch == "<" {
                // A tag, if it closes; otherwise it is text that happens to
                // start with a bracket, and it is kept.
                if let close = html[i...].firstIndex(of: ">"), close < html.endIndex {
                    let span = html.distance(from: i, to: close) + 1
                    text.append(" ")
                    origins.append(raw)
                    raw += span
                    i = html.index(i, offsetBy: span)
                    continue
                }
            }
            if ch == "&", let semi = html[i...].firstIndex(of: ";"),
               semi < html.endIndex {
                let entity = String(html[i...semi])
                let decoded = decodeEntities(entity)
                if decoded != entity {
                    for c in decoded {
                        text.append(c)
                        origins.append(raw)
                    }
                    raw += html.distance(from: i, to: semi) + 1
                    i = html.index(after: semi)
                    continue
                }
            }
            text.append(ch)
            origins.append(raw)
            raw += 1
            i = html.index(after: i)
        }
        // Trailing whitespace is dropped, and the origins go with it.
        while let last = text.last, last == " " || last == "\n" || last == "\t" {
            text.removeLast()
            origins.removeLast()
        }
        return (text, origins)
    }

    private static func stripElement(_ s: String, _ name: String) -> String {
        // (?s) so a multi-line <script> is removed; `.` stops at a newline otherwise.
        s.replacingOccurrences(of: "(?s)<\(name)[^>]*>.*?</\(name)>", with: " ",
                               options: [.regularExpression, .caseInsensitive])
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
            "&apos;": "'", "&nbsp;": " ", "&hellip;": "…", "&#8230;": "…",
            "&#8217;": "’", "&#8216;": "‘", "&#8220;": "“", "&#8221;": "”",
            "&#8211;": "–", "&#8212;": "—", "&mdash;": "—", "&ndash;": "–",
            "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
            "&#038;": "&", "&sect;": "§", "&middot;": "·", "&#x27;": "'"
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities.
        out = replaceNumericEntities(out)
        return out
    }

    private static func replaceNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "#" {
                var j = s.index(i, offsetBy: 2)
                let hex = j < s.endIndex && (s[j] == "x" || s[j] == "X")
                if hex { j = s.index(after: j) }
                var digits = ""
                while j < s.endIndex, s[j] != ";", digits.count < 8 {
                    digits.append(s[j])
                    j = s.index(after: j)
                }
                if j < s.endIndex, s[j] == ";", !digits.isEmpty,
                   let code = UInt32(digits, radix: hex ? 16 : 10),
                   let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                    i = s.index(after: j)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    /// The first picture in a fragment of HTML, with the size the page declares.
    ///
    /// The size matters. The old rule judged a picture by its file name, so
    /// `tropical-logo-sign-01.jpg` was treated as branding and thrown away —
    /// on a logo-design blog "logo" is the subject, not the publisher's mark.
    /// The declared dimensions tell the two apart: a publisher's mark is a small
    /// square, an article picture is large.
    static func firstImage(in html: String) -> (url: URL, width: Int, height: Int)? {
        guard !html.isEmpty else { return nil }
        let patterns = [
            #"<img[^>]*?\ssrc\s*=\s*["']([^"']+)["']"#,
            #"<img[^>]*?\sdata-src\s*=\s*["']([^"']+)["']"#,
            #"<img[^>]*?\ssrcset\s*=\s*["']([^"'\s,]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: range) {
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: html) else { continue }
                let raw = decodeEntities(String(html[r]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let url: URL?
                if raw.hasPrefix("//") {
                    url = URL(string: "https:" + raw)
                } else if raw.hasPrefix("http") {
                    url = URL(string: raw)
                } else {
                    url = nil
                }
                guard let url else { continue }
                // The size is on the same tag as the source.
                var width = 0
                var height = 0
                if let tagRange = Range(match.range, in: html) {
                    let tag = String(html[tagRange])
                    if let w = HTMLText.pixels(forAttribute: "width", in: tag) { width = w }
                    if let h = HTMLText.pixels(forAttribute: "height", in: tag) { height = h }
                }
                return (url, width, height)
            }
        }
        return nil
    }

    /// The first picture in a fragment of HTML, as a plain URL.
    static func firstImageURL(in html: String) -> URL? {
        firstImage(in: html)?.url
    }

    /// Reads a `width="600"` or `width='600'` attribute and returns the pixels.
    static func pixels(forAttribute name: String, in tag: String) -> Int? {
        let pattern = #"\b\#(name)\s*=\s*["']?\s*(\d{1,5})"#
            .replacingOccurrences(of: "#(name)", with: name)
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let m = regex.firstMatch(in: tag, range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: tag),
              let v = Int(tag[r]) else { return nil }
        return v
    }

    /// Extracts an OpenGraph/Twitter card image and description from a page.
    /// The publication date an article page declares about itself.
    ///
    /// The order matters: the structured data (`datePublished`) is written by
    /// the publisher's own tooling, while the meta tags are often a template
    /// default that can be wrong.
    static func publishedDate(in html: String) -> Date? {
        if let raw = RX.first(#"(?s)"datePublished"\s*:\s*"([^"]+)""#, in: html),
           let d = DateParsing.parse(raw) { return d }
        for pattern in [#"<meta[^>]+property=[\"']article:published_time[\"'][^>]*content=[\"']([^\"']+)"#,
                        #"<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*property=[\"']article:published_time[\"']"#,
                        #"<meta[^>]+name=[\"']pubdate[\"'][^>]*content=[\"']([^\"']+)"#,
                        #"<time[^>]+datetime=[\"']([^\"']+)"#] {
            if let raw = RX.first(pattern, in: html), let d = DateParsing.parse(raw) { return d }
        }
        return nil
    }

    static func openGraph(in html: String) -> (image: URL?, description: String?) {
        func meta(_ key: String) -> String? {
            let patterns = [
                "<meta[^>]*(?:property|name)=[\"']\(key)[\"'][^>]*content=[\"']([^\"']+)[\"']",
                "<meta[^>]*content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"']\(key)[\"']"
            ]
            for p in patterns {
                if let r = html.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                    let block = String(html[r])
                    if let m = block.range(of: "[\"']([^\"']+)[\"']\\s*/?>?$", options: .regularExpression) {
                        var v = String(block[m])
                        v = v.replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "'", with: "")
                            .replacingOccurrences(of: "/>", with: "")
                            .replacingOccurrences(of: ">", with: "")
                        return decodeEntities(v).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            return nil
        }
        let img = meta("og:image") ?? meta("twitter:image")
        let desc = meta("og:description") ?? meta("description") ?? meta("twitter:description")
        // The scraper returns the *value* of the tag, but a page that writes the
        // attribute without quotes (`<meta property=og:image content=...>`) made it
        // return the attribute *name*, which then became an "image URL" of
        // "og:image" on seventeen stories. A picture must be an absolute http
        // address or there is none.
        let imageURL = img.flatMap { value -> URL? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("http") else { return nil }
            return URL(string: trimmed)
        }
        return (imageURL, desc)
    }

    static func absolute(_ href: String, base: URL?) -> URL? {
        if href.hasPrefix("http") { return URL(string: href) }
        guard let base else { return nil }
        return URL(string: href, relativeTo: base)?.absoluteURL
    }
}
