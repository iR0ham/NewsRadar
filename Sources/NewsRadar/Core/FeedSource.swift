import Foundation

/// RSS/Atom news sources: blog.google, TechCrunch AI, TLDR, The Verge AI and
/// Product Hunt.
struct FeedSource {

    struct Outcome {
        var items: [RadarItem]
        var status: SourceStatus
    }

    /// How many entries may be enriched with one extra page fetch per refresh to
    /// recover a missing image or body text. Each fetched page is cached on disk
    /// for a week, so this cost is paid once per article and later refreshes hit
    /// the cache instead of the network.
    static let enrichmentBudget = 30

    /// - Parameter repopulateFromCache: when the server answers "unchanged" and the
    ///   app holds no stories for this source yet (a source added a moment ago, or
    ///   an archive that was cleared), the stored copy is parsed so the source is
    ///   not stuck showing an empty row until the publisher next updates.
    static func fetch(_ source: SourceID, now: Date = Date(),
                      repopulateFromCache: Bool = false) -> Outcome {
        var status = SourceStatus(source: source, lastAttempt: now)
        guard let feedURL = source.feedURL else {
            status.message = source.spec.accessDescription ?? "This source has no RSS feed."
            return Outcome(items: [], status: status)
        }
        // A conditional request: when the feed has not changed the server
        // answers 304 and the source reports "nothing new" without any parsing,
        // classification or summarisation. That is what keeps a re-open cheap.
        guard let result = HTTP.getConditionalCached(feedURL) else {
            status.ok = false
            status.message = "The feed could not be reached and no cached copy exists."
            return Outcome(items: [], status: status)
        }
        let body: String
        let fromCache: Bool
        switch result {
        case .unchanged:
            status.ok = true
            status.fromCache = true
            status.unchanged = true
            // Report the real count from the stored copy. "0 items" on an
            // unchanged source read exactly like a broken source, which is
            // what made a working feed look like it never connected.
            if let cached = HTTP.readCacheIgnoringAge(for: feedURL) {
                let (entries, _) = FeedXMLParser.parse(cached)
                status.itemCount = entries.filter { $0.link != nil }.count
                if repopulateFromCache, status.itemCount > 0 {
                    // Parse the stored copy into real stories. Deduplication
                    // downstream is by id, so this cannot double a story.
                    var rebuilt: [RadarItem] = []
                    for e in entries where e.link != nil {
                        if source.spec.filter == .researchOnly, !isResearchEntry(e) { continue }
                        if source.spec.filter == .technical,
                           !passesTechnicalGate(e, source: source) { continue }
                        rebuilt.append(makeItem(e, source: source, feedImage: nil, now: now))
                    }
                    status.message = "Read \(rebuilt.count) stories from the stored copy."
                    status.fromCache = true
                    status.unchanged = false
                    return Outcome(items: rebuilt, status: status)
                }
            }
            status.message = "No change since the last check."
            return Outcome(items: [], status: status)
        case .body(let text, _):
            body = text
            fromCache = false
        case .cached(let text, let reason):
            body = text
            fromCache = true
            status.message = "Served from cache (\(reason))"
        }
        var (entries, feedImage) = FeedXMLParser.parse(body)
        // Publishers that serve only twenty entries per page can still be read
        // further back, but only where the site actually honours the parameter
        // and only with the name that site uses. A parameter that is ignored
        // returns page one again, which is why both are declared per source
        // and not applied everywhere.
        if source.spec.extraPages > 0 {
            let seen = Set(entries.compactMap { $0.link?.absoluteString })
            var known = seen
            for page in 2...(source.spec.extraPages + 1) {
                let raw = feedURL.absoluteString
                let base = raw.contains("?")
                    ? String(raw[..<raw.firstIndex(of: "?")!]) : raw
                let sep = raw.contains("?") ? "&" : "?"
                guard let url = URL(string: base + sep
                                    + "\(source.spec.pageParameter)=\(page)") else { break }
                // Page one is cached for the conditional request; older pages
                // are cheap and change rarely, so the short cache is enough.
                guard let older = try? HTTP.getWithCache(url, maxAge: 6 * 3600).body else { break }
                let (more, _) = FeedXMLParser.parse(older)
                var added = 0
                for e in more {
                    guard let link = e.link?.absoluteString, !known.contains(link) else { continue }
                    known.insert(link)
                    entries.append(e)
                    added += 1
                }
                // Nothing new means this publisher ignores the parameter.
                if added == 0 { break }
            }
        }
        guard !entries.isEmpty else {
            status.message = "Feed read but it contained no items."
            status.fromCache = fromCache
            return Outcome(items: [], status: status)
        }
        var items: [RadarItem] = []
        let feedCover = usableFeedImage(feedImage, entryCount: entries.count)
        var droppedForRelevance = 0
        for e in entries {
            guard e.link != nil else { continue }
            // OpenAI's one feed carries every post; the research source keeps
            // only the ones the company itself filed as research.
            if source.spec.filter == .researchOnly, !isResearchEntry(e) {
                droppedForRelevance += 1
                continue
            }
            // The AI-vocabulary gate belongs to the news tab, where the app is
            // about models and libraries. The Tech News tab is about technology
            // in general, so the same rule there would throw away most of the
            // front page: a compiler release, a security advisory, a database
            // outage. None of them name a model.
            if source.spec.filter == .technical,
               !TechCatalogue.keepsWithoutTechnicalGate(source),
               !passesTechnicalGate(e, source: source) {
                droppedForRelevance += 1
                continue
            }
            items.append(makeItem(e, source: source, feedImage: feedCover, now: now))
        }
        // Drop branding before enriching, so an entry whose image was the
        // publication's logo still gets its real article image fetched.
        stripRepeatedImages(&items)
        var enriched = 0
        for idx in items.indices where enriched < enrichmentBudget {
            guard items[idx].imageURL == nil || items[idx].rawSummary.isEmpty else { continue }
            enriched += 1
            enrich(&items[idx], base: items[idx].link)
        }
        status.ok = !items.isEmpty
        status.itemCount = items.count
        status.fromCache = fromCache
        status.lastSuccess = now
        var note = (fromCache && status.message.isEmpty)
            ? "Served from cache (network request failed)" : ""
        if droppedForRelevance > 0 {
            let kept = "\(items.count) of \(entries.count) entries matched this source's filter"
            note = note.isEmpty ? kept : note + " · " + kept
        }
        status.message = note
        return Outcome(items: items, status: status)

    }

    /// Removes the boilerplate Hacker News puts in every entry description, plus a
    /// bare "Comments" link body. Returns an empty string when nothing but
    /// scaffolding was there.
    static func stripHNBoilerplate(_ text: String) -> String {
        var t = text
        // Drop whole labelled fragments wherever they appear.
        let patterns = [
            "Article URL:\\s*\\S+",
            "Comments URL:\\s*\\S+",
            "Points:\\s*\\d+",
            "#\\s*Comments:\\s*\\d+",
            "Comments:\\s*\\d+",
            "^\\s*Comments\\s*$"
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -·|,"))
        // Anything left shorter than a sentence is scaffolding, not a description.
        return t.count >= 40 ? t : ""
    }

    // MARK: - Relevance gates

    /// OpenAI tags each post with its section; the research view keeps only the
    /// posts filed under Research, Publication or Safety & Alignment.
    static func isResearchEntry(_ e: RawFeedEntry) -> Bool {
        let researchCats: Set<String> = ["research", "publication", "safety & alignment",
                                        "safety", "research publication"]
        return e.categories.contains { researchCats.contains($0.lowercased()) }
    }

    /// Hacker News and Show HN publish across every subject. An entry is kept when
    /// it names covered technology, or — for Show HN — when it reads as a launch.
    static func passesTechnicalGate(_ e: RawFeedEntry, source: SourceID) -> Bool {
        let body = e.plainSummary(limit: 400)
        if Classifier.isTechnical(title: e.title, body: body) { return true }
        if source == .showHN, Classifier.isLaunch(title: e.title, body: body) { return true }
        return false
    }

    // MARK: - Item building

    /// True when a URL looks like the publication's own branding rather than a
    /// story illustration, judged on whole filename tokens so that a real image
    /// such as `silicon-valley.jpg` is not mistaken for an icon.
    /// True when a picture is the publisher's own mark rather than a story photo.
    ///
    /// The file name was the old test, and it was wrong in both directions. A
    /// publisher's logo is usually small; a story photo is large. On a
    /// logo-design blog the word "logo" in a file name is the subject of the
    /// story, so `tropical-logo-sign-01.jpg` was thrown away and the card fell
    /// back to a placeholder — 96 pictures on one site alone, and the whole
    /// design tab looked like it had no images at all.
    ///
    /// So the size decides, and the file name only breaks a tie when the page
    /// gives no size at all. The size comes from three places: the `width` and
    /// `height` attributes of the tag, the size in the address itself
    /// (`/m/60x60/`, `?s=60`), or nothing.
    static func isBrandingImage(_ url: URL, width: Int = 0, height: Int = 0) -> Bool {
        let declared = max(width, height) > 0 ? max(width, height) : sizeInAddress(url)
        if declared > 0 {
            // A picture the page says is at least 120px wide is a story photo,
            // whatever it is called.
            return declared < 120
        }
        let path = url.absoluteString.split(separator: "?").first.map(String.init) ?? ""
        let lower = path.lowercased()
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        let ext = last.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        // A vector mark is chrome, never a story photo.
        if ext == "svg" || ext == "ico" { return true }
        let rawStem = last.split(separator: ".").first.map(String.init)?.lowercased() ?? ""
        let stem = rawStem.replacingOccurrences(
            of: #"[-_](\d{2,4}x\d{2,4}|\d{1,4})$"#, with: "", options: .regularExpression)
        let tokens = stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard tokens.contains(where: { Signals.brandingImageNames.contains($0) }) else {
            return false
        }
        // A site asset folder holds chrome: a logo in /assets/ is the site's mark.
        if chromePaths.contains(where: { lower.contains($0) }) { return true }
        // A picture the publisher uploaded is their own content.
        if contentPaths.contains(where: { lower.contains($0) }) { return false }
        // A short name that is only a branding word is a mark. A long name that
        // merely mentions "logo" is a story about a logo.
        return tokens.count <= 2
    }

    /// Folders that hold a site's own interface art.
    static let chromePaths = [
        "/themes/", "/theme/", "/static/", "/assets/", "/dist/", "/build/",
        "/wp-includes/", "/icons/", "/banners/", "/buttons/", "/nav/", "/ads/",
        "/css/", "/js/", "/img/", "/images/", "/shared/", "/templates/", "/media/",
    ]

    /// Folders that hold a publisher's editorial content.
    static let contentPaths = ["/uploads/", "/upload/", "/files/"]

    /// The pixel size an address states for itself, if it states one.
    ///
    /// A CDN that serves a 60×60 avatar says so in the address: `/m/60x60/`,
    /// `?s=60`, `?w=150` or `/60x60/`. Without this the rule falls back to the
    /// file name, and every avatar on the web is called "avatar" or "icon" —
    /// which is how 465 pictures of people and small symbols were kept out.
    static func sizeInAddress(_ url: URL) -> Int {
        let text = url.absoluteString
        let patterns = [
            #"/m/(\d{1,4})x(\d{1,4})/"#,
            #"/(\d{1,4})x(\d{1,4})/"#,
            #"[?&](?:s|w|width|h|height)=(\d{1,4})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let m = regex.firstMatch(in: text, range: range) else { continue }
            for index in 1..<m.numberOfRanges {
                guard let r = Range(m.range(at: index), in: text),
                      let value = Int(text[r]) else { continue }
                if value > 0 { return value }
            }
        }
        return 0
    }

    /// A feed-level image (`<image>`, `<icon>`) is the publication's cover art, so
    /// reusing it on every entry would label unrelated stories with the same
    /// picture. It is therefore only used when the feed carries a single entry,
    /// where it genuinely stands for that one item.
    static func usableFeedImage(_ feedImage: URL?, entryCount: Int) -> URL? {
        guard let feedImage, entryCount <= 1, !isBrandingImage(feedImage) else { return nil }
        return feedImage
    }

    /// Some feeds (TLDR) put the same logo in every entry's image element. When
    /// one image URL covers most of a feed it is branding, not a story photo, so
    /// those entries fall back to the placeholder and page enrichment.
    static func stripRepeatedImages(_ items: inout [RadarItem]) {
        guard items.count > 2 else { return }
        var counts: [String: Int] = [:]
        for i in items where i.imageURL != nil {
            counts[i.imageURL!.absoluteString, default: 0] += 1
        }
        let threshold = max(2, items.count / 3)
        let repeated = Set(counts.filter { $0.value >= threshold }.keys)
        guard !repeated.isEmpty else { return }
        for idx in items.indices {
            if let u = items[idx].imageURL, repeated.contains(u.absoluteString) {
                items[idx].imageURL = nil
            }
        }
    }

    static func makeItem(_ e: RawFeedEntry, source: SourceID, feedImage: URL?,
                         now: Date) -> RadarItem {
        let guid = e.guid.isEmpty ? (e.link?.absoluteString ?? e.title) : e.guid
        let kind = source.spec.itemKind
        var item = RadarItem(
            id: "\(source.rawValue)::\(stableID(guid))",
            source: source,
            kind: kind,
            title: e.title,
            link: e.link ?? source.homeURL,
            // A feed that misdates an entry into the future would pin it to the
            // top of every list until that date arrived — Wix dated one post two
            // months ahead. An hour of clock skew is tolerated; beyond that the
            // entry is treated as new now.
            published: min(e.published ?? now, now.addingTimeInterval(3600)),
            rawSummary: e.plainSummary(),
            imageURL: (e.imageURL.flatMap {
                isBrandingImage($0, width: e.imageWidth, height: e.imageHeight) ? nil : $0
            })
                ?? (feedImage.flatMap { isBrandingImage($0) ? nil : $0 }),
            author: e.authors.first,
            sourceCategories: Array(e.categories.prefix(6))
        )
        if item.rawSummary.isEmpty, !e.contentHTML.isEmpty {
            item.rawSummary = HTMLText.plain(String(e.contentHTML.prefix(1200)))
        }
        // Hacker News and hnrss describe every entry with the same scaffolding —
        // "Article URL: … Comments URL: … Points: 1 # Comments: 0" — which is not a
        // summary. Removing it leaves the field empty, so page enrichment can fetch
        // the article's own description instead.
        if source == .hackerNews || source == .showHN {
            item.rawSummary = stripHNBoilerplate(item.rawSummary)
        }
        return item
    }

    /// Product Hunt guids are stable URIs; hashtags keep ids short and safe.
    static func stableID(_ s: String) -> String {
        var hash: UInt64 = 5381
        for b in s.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        var out = ""
        for r in 0..<4 {
            let chunk = UInt8((hash >> (UInt64(r) * 8)) & 0xFF)
            out += String(format: "%02x", chunk)
        }
        return out
    }

    /// Fetch the article page for its OpenGraph image/description when the feed
    /// itself did not carry them (TechCrunch, TLDR, Product Hunt).
    ///
    /// The recovered image is filtered like a feed image: a publisher that only
    /// declares its own logo as `og:image`/`twitter:image` (TLDR does) would
    /// otherwise stamp the same logo on every card.
    static func enrich(_ item: inout RadarItem, base: URL) {
        guard let html = try? HTTP.getWithCache(base, maxAge: 7 * 24 * 3600).body else { return }
        let og = HTMLText.openGraph(in: html)
        if item.imageURL == nil, let img = og.image, !isBrandingImage(img) {
            item.imageURL = img
        }
        if item.rawSummary.isEmpty, let d = og.description, !d.isEmpty {
            item.rawSummary = String(d.prefix(320))
        }
        // A story read from a listing page has no date of its own, so it was
        // filed at the moment the page was read. The article page carries the
        // real publication date in its own metadata, and that date is the
        // honest one: without it every story of such a publisher would look
        // like it was published just now, and would sit at the top of the list
        // for ever.
        if item.publishedFromListing {
            if let real = HTMLText.publishedDate(in: html) {
                item.published = real
                item.publishedFromListing = false
            }
        }
    }
}
