import AppKit
import Foundation

// MARK: - Headless diagnostic entry points
//
// The app exposes `--selftest`, `--livetest` and `--probe` modes. They print to
// stdout and exit with a real status code, which is what makes the build script
// and CI able to prove the engine works without a GUI.
//
// Run:
//   ./build/bin/NewsRadar --selftest     # offline checks, no network
//   ./build/bin/NewsRadar --livetest     # real fetch against every configured source
//   ./build/bin/NewsRadar --probe        # environment report

enum SelfCheck {

    private static var passed = 0
    private static var failed = 0

    private static func ok(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  ✓ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } else {
            failed += 1
            print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    /// Deliberately shadows Swift's global `assert`.
    ///
    /// Swift's `assert` is removed by the optimiser, so every check written with it
    /// silently did nothing in the shipped binary while the run still reported a
    /// pass count. This one always executes and always counts.
    private static func assert(_ condition: Bool, _ name: String, _ detail: String = "") {
        ok(name, condition, detail)
    }

    private static func eq<T: Equatable>(_ name: String, _ a: T, _ b: T) {
        ok(name, a == b, "\(a)" + (a == b ? "" : " ≠ \(b)"))
    }

    // MARK: - Entry points

    /// Offline suite: parsing, classification, rendering, persistence, filtering
    /// and scoring. No network access.
    static func runSelfTest() -> Int32 {
        print("News Radar — offline engine self-test")
        print("———————————————————————————————————————")
        passed = 0
        failed = 0

        testHTMLText()
        testDateParsing()
        testRSSParsing()
        testAtomParsing()
        testTrendingScraping()
        testClassification()
        testRendering()
        testScoring()
        testFiltering()
        testSectionSplit()
        testListModel()
        testArticleAuthor()
        testStoreIndex()
        testStoreRoundTrip()
        testOllamaJSON()
        testBriefing()
        testNewSources()

        print("———————————————————————————————————————")
        if failed == 0 {
            print("Result: all \(passed) checks passed.")
            return 0
        }
        print("Result: \(passed) passed, \(failed) failed.")
        return 1
    }

    /// Live suite: actually refresh from the network and report per source.
    static func runLiveTest() -> Int32 {
        print("News Radar — live source test")
        print("———————————————————————————————————————")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-livetest-\(UUID().uuidString)", isDirectory: true)
        let store = Store(directory: scratch)
        let outcome = RefreshEngine.refresh(store: store, ollama: OllamaConfig())
        var failures = 0

        for source in SourceID.all {
            let s = store.status(for: source)
            let state = (s?.ok ?? false) ? "✓" : "✗"
            if !(s?.ok ?? false) { failures += 1 }
            print("\(state) \(source.title.padding(toLength: 22, withPad: " ", startingAt: 0)) "
                  + "\(s?.itemCount ?? 0) items"
                  + ((s?.fromCache ?? false) ? "  (from cache)" : "")
                  + ((s?.message.isEmpty == false) ? "  → \(s!.message)" : ""))
        }

        print("———————————————————————————————————————")
        print("Total items: \(outcome.fetched)   new: \(outcome.newItems)   "
              + "time: \(String(format: "%.1f", outcome.duration))s")

        let classified = store.items.filter { $0.category != .other }.count
        let withImage = store.items.filter { $0.imageURL != nil }.count
        let rendered = store.items.filter { !$0.headline.isEmpty && !$0.summary.isEmpty }.count
        let repos = store.items.filter { $0.isGitHub }
        print("Classified: \(classified)/\(store.items.count)   "
              + "with image: \(withImage)   "
              + "rendered: \(rendered)   "
              + "repositories: \(repos.count)")

        // The Tech News tab is its own surface, so it reports its own numbers:
        // a tab that is empty, or one whose sections are all one heading, is a
        // problem this run should catch rather than a surprise in the window.
        let tech = store.items.filter { $0.source.isTech }
        if tech.isEmpty {
            print("✗ The Tech News tab has no stories")
            failures += 1
        } else {
            let bySection = Dictionary(grouping: tech, by: { $0.techCategory?.shortTitle ?? "—" })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: " · ")
            print("Tech News: \(tech.count) stories across "
                  + "\(Set(tech.map { $0.source }).count) publishers")
            print("  \(bySection)")
            let unclassified = tech.filter { $0.techCategory == nil }.count
            if unclassified > 0 {
                print("✗ \(unclassified) tech stories have no section")
                failures += 1
            }
        }

        if let b = outcome.briefing {
            print("Daily briefing: \(b.paragraphs.count) paragraphs, engine: \(b.engine)")
        } else {
            print("✗ The daily briefing was not built")
            failures += 1
        }

        // Sanity: every item must have a link and a non-empty headline.
        let broken = store.items.filter { $0.headline.isEmpty || $0.link.host == nil }
        print("Incomplete items: \(broken.count)")
        failures += broken.isEmpty ? 0 : 1

        print("———————————————————————————————————————")
        if failures == 0 {
            print("Result: every configured source answered and the engine is healthy.")
        } else {
            print("Result: \(failures) failure(s); the rest of the app still works.")
        }

        let sample = store.items.sorted { $0.score > $1.score }.prefix(3)
        for i in sample {
            print("\n• [\(i.source.title)] \(i.headline)")
            print("  \(i.summary.prefix(160))")
            print("  \(i.link.absoluteString)")
        }
        try? FileManager.default.removeItem(at: scratch)
        return failures == 0 ? 0 : 1
    }

    /// Prints what the app can rely on in this environment.
    /// `--checkfeed <url>`: runs the add-source validator against a real address and
    /// prints its verdict. The sheet calls exactly this code, so a passing run here
    /// is the same answer the user sees there.
    static func runFeedCheck(_ raw: String) -> Int32 {
        print("Add-source check: \(raw)")
        let verdict = SourceValidator.validate(urlString: raw, title: nil)
        switch verdict {
        case .valid(let s):
            print("  ADDED  \(s.title)")
            print("  feed   \(s.feedURL)")
            print("  host   \(s.host)   items \(s.itemCount)")
            print("  note   \(s.note)")
            return 0
        case .duplicate(let title):
            print("  ALREADY CONFIGURED as \(title)")
            return 0
        case .notAFeed(let reason, let suggestion):
            print("  NOT A FEED  \(reason)")
            if let suggestion { print("  suggestion  \(suggestion)") }
            return 1
        case .unreachable(let reason):
            print("  UNREACHABLE  \(reason)")
            return 1
        }
    }

    /// `--images [n]`: times the real image loader.
    ///
    /// The grid's slowness is not visible in a screenshot, and a `curl` loop
    /// measures a different code path. This drives `ImageLoader` itself — the
    /// same queue, cache and decode — against the pictures the app actually holds,
    /// and reports how long a screenful takes from cold.
    static func runImageBenchmark(count: Int = 12) -> Int32 {
        let store = Store()
        var seen = Set<String>()
        var urls: [URL] = []
        for item in store.items {
            guard let u = item.imageURL, u.absoluteString.hasPrefix("http") else { continue }
            guard seen.insert(u.absoluteString).inserted else { continue }
            urls.append(u)
            if urls.count >= count { break }
        }
        guard !urls.isEmpty else {
            print("No stored pictures to measure. Run the app once first.")
            return 1
        }
        print("News Radar — picture load test")
        print("———————————————————————————————————————")
        print("\(urls.count) pictures from the live archive")

        // A cold start: no memory cache, and the disk copies of these exact
        // pictures are removed so the first pass is what a reader sees on a new
        // screen. The second pass is what a revisit costs.
        //
        // The loader calls back on the main queue, so this must not block the
        // main thread waiting: that deadlocks, and the first version of this
        // benchmark did exactly that and reported 0/9 after two minutes. The
        // wait below pumps the run loop instead.
        let lock = NSLock()
        var loaded = 0
        var finished = 0
        var failures: [String] = []
        let start = Date()

        for url in urls {
            ImageLoader.shared.load(url) { image in
                lock.lock()
                finished += 1
                if image != nil { loaded += 1 } else { failures.append(url.absoluteString) }
                lock.unlock()
            }
        }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            lock.lock()
            let all = finished == urls.count
            lock.unlock()
            if all { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        lock.lock()
        let cold = Date().timeIntervalSince(start)
        let finishedCount = finished
        lock.unlock()
        _ = finishedCount

        var cached = 0
        let start2 = Date()
        for url in urls {
            if ImageLoader.shared.cachedImage(for: url) != nil { cached += 1 }
        }
        let warm = Date().timeIntervalSince(start2)

        print(String(format: "  cold: %d/%d pictures in %.2fs", loaded, urls.count, cold))
        print(String(format: "  warm: %d from memory in %.3fs", cached, warm))
        if !failures.isEmpty {
            print("  could not load:")
            for f in failures.prefix(8) { print("    \(f.prefix(110))") }
        }
        let okCount = loaded == urls.count && cold < 15
        print(okCount ? "  ✓ a screenful loads in reasonable time"
                      : "  ✗ a screenful is slow or incomplete")
        return okCount ? 0 : 1
    }

    /// `--readarticle <url>`: runs the in-app reader against a real page.
    static func runArticleRead(_ url: URL) -> Int32 {
        print("Reader: \(url.absoluteString)")
        switch ArticleReader.read(url: url, fallbackTitle: url.absoluteString, feedSummary: "") {
        case .success(let a):
            print("  title      \(a.title)")
            print("  byline     \(a.byline ?? "—")")
            print("  words      \(a.wordCount)  paragraphs \(a.paragraphs.count)")
            print("  source     \(a.source)")
            print("  truncated? \(a.possiblyTruncated)")
            for p in a.paragraphs.prefix(3) {
                print("  · \(p.prefix(160))")
            }
            // The body shape, so a live page can be checked for inline images and
            // links without opening a window.
            var shape: [String] = []
            for block in a.blocks {
                switch block {
                case .paragraph: shape.append("text")
                case .image(let url, let caption):
                    shape.append("image" + (caption == nil ? "" : "+caption"))
                    print("  [image]    \(url.absoluteString)")
                case .linked(_, let runs, _):
                    shape.append("linked")
                    for r in runs.prefix(3) { print("  [link]     \(r.text) -> \(r.url.absoluteString)") }
                }
            }
            print("  body       \(shape.joined(separator: ", "))")
            return a.wordCount >= 120 ? 0 : 1
        case .failure(let e):
            print("  FAILED  \(e.localizedDescription)")
            return 1
        }
    }

    static func runProbe() -> Int32 {
        print("News Radar — environment report")
        print("———————————————————————————————————————")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Architecture: \(archName())")
        print("Swift: \(swiftVersion())")

        // Ask the store where it actually writes instead of rebuilding the path
        // here: the probe printed the folder under the old name long after the app
        // had moved to "NewsRadar", so the report named a directory it no longer used.
        let store = Store()
        let dir = store.directory
        print("Data directory: \(dir.path)")
        print("Stored items: \(store.items.count)   bookmarks: \(store.state.bookmarkedIDs.count)   "
              + "history: \(store.history.count)")
        print("Data size: \(ByteCountFormatter.string(fromByteCount: store.sizeOnDisk, countStyle: .file))")
        print("Last refresh: \(store.state.lastRefresh.map { TextFormat.date($0) } ?? "never")")
        print("Sources: \(SourceID.all.count) configured, \(Set(SourceID.all.map { $0.rawValue }).count) unique")

        let probe = store.state.ollama
        let models = ModelClient.availableModels(config: probe)
        if models.isEmpty {
            print("\(probe.engine.title): unreachable (\(probe.baseURL)) — summaries use the offline digest.")
        } else {
            print("\(probe.engine.title): reachable — \(models.count) models: \(models.prefix(5).joined(separator: ", "))")
        }
        print("Image cache: \(ByteCountFormatter.string(fromByteCount: ImageLoader.shared.diskUsage, countStyle: .file))")
        return 0
    }

    private static func archName() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine
    }

    private static func swiftVersion() -> String {
        #if swift(>=6.0)
        return "6.0+"
        #elseif swift(>=5.0)
        return "5.x"
        #else
        return "unknown"
        #endif
    }

    // MARK: - Fixtures

    private static let rssFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
      <title>TechCrunch AI</title>
      <item>
        <title>Nvidia launches new open models to run agents on PCs</title>
        <link>https://techcrunch.com/2026/10/19/nvidia-open-models/</link>
        <dc:creator><![CDATA[Julie Bort]]></dc:creator>
        <pubDate>Mon, 19 Oct 2026 15:37:09 +0000</pubDate>
        <category><![CDATA[AI]]></category>
        <description><![CDATA[Nvidia is leaning hard into open models that run locally on your machine.]]></description>
      </item>
      <item>
        <title>Google announces Gemini 4 with a larger context window</title>
        <link>https://techcrunch.com/2026/10/18/gemini-4/</link>
        <pubDate>Sun, 18 Oct 2026 10:00:00 +0000</pubDate>
        <media:content url="https://techcrunch.com/img/gemini4.jpg" medium="image"/>
        <description><![CDATA[The new Gemini model ships to developers on Tuesday.]]></description>
      </item>
    </channel>
    </rss>
    """

    private static let atomFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>The Verge AI</title>
      <icon>https://www.theverge.com/icon.png</icon>
      <entry>
        <title type="html"><![CDATA[Apple adds on-device AI to the Mac]]></title>
        <link rel="alternate" type="text/html" href="https://www.theverge.com/apple-mac-ai"/>
        <id>tag:theverge,2026:1</id>
        <published>2026-10-19T10:30:00-04:00</published>
        <category scheme="https://www.theverge.com" term="AI"/>
        <summary type="html"><![CDATA[Apple is bringing more of its AI stack to Apple Silicon Macs, running locally.]]></summary>
        <content type="html"><![CDATA[<figure><img src="https://platform.theverge.com/img/mac.jpg" /></figure>]]></content>
      </entry>
    </feed>
    """

    private static let trendingFixture = """
    <html><body>
    <article class="Box-row">
      <h2 class="h3 lh-condensed">
        <a href="/anomalyco/opencode" data-view-component="true" class="Link">
          <span class="text-normal">anomalyco / </span>opencode</a>
      </h2>
      <p class="col-9 color-fg-muted my-1 pr-4">The open source coding agent.</p>
      <div class="f6 color-fg-muted mt-2">
        <span itemprop="programmingLanguage">TypeScript</span>
        <a href="/anomalyco/opencode/stargazers" class="Link"> 217,440 </a>
        <span class="d-inline-block float-sm-right">1,310 stars today</span>
      </div>
    </article>
    <article class="Box-row">
      <h2 class="h3 lh-condensed"><a href="/akitaonrails/ai-memory" class="Link">ai-memory</a></h2>
      <p class="col-9 color-fg-muted my-1 pr-4">Local memory for AI coding agents.</p>
      <div class="f6 color-fg-muted mt-2">
        <span itemprop="programmingLanguage">Rust</span>
        <a href="/akitaonrails/ai-memory/stargazers" class="Link"> 11,047 </a>
        <span class="d-inline-block float-sm-right">666 stars today</span>
      </div>
    </article>
    </body></html>
    """

    // MARK: - Tests

    private static func testHTMLText() {
        print("\nHTML and text:")
        let html = "<p>Hello &amp; welcome</p><script>var x=1;</script><p>Second&nbsp;line</p>"
        let plain = HTMLText.plain(html)
        ok("tags stripped", !plain.contains("<") && !plain.contains("script"))
        ok("entities decoded", plain.contains("Hello & welcome"), plain)
        ok("image detected", HTMLText.firstImageURL(in: "<img src=\"https://x.com/a.jpg\">") != nil)
        // The order of attributes must not matter. A feed that writes width
        // before src produced no picture, because the extractor took the first
        // quoted string in the tag rather than the src value.
        eq("src after other attributes",
           HTMLText.firstImageURL(in: "<img width=\"2560\" height=\"817\" src=\"https://x.com/b.png\" class=\"c\">")?
            .absoluteString, "https://x.com/b.png")
        eq("lazy-loaded image",
           HTMLText.firstImageURL(in: "<img data-src=\"https://x.com/l.png\" src=\"data:image/gif;base64,R0\">")?
            .absoluteString, "https://x.com/l.png")
        eq("protocol-relative image",
           HTMLText.firstImageURL(in: "<img src=\"//x.com/p.png\">")?.absoluteString,
           "https://x.com/p.png")
        eq("image with no src", HTMLText.firstImageURL(in: "<img width=\"10\" height=\"10\">"), nil)
        // The declared size is read from the same tag, so a story photo can be
        // told apart from a publisher's mark even when the file name says
        // "logo" — which on a logo-design blog is the subject, not the mark.
        let sized = HTMLText.firstImage(in: "<img width=\"2560\" height=\"817\" src=\"https://x.com/p.png\">")
        eq("declared width", sized?.width, 2560)
        eq("declared height", sized?.height, 817)
        ok("a large picture called logo is a story photo",
           !FeedSource.isBrandingImage(URL(string: "https://x.com/tropical-logo-01.jpg")!,
                                       width: 1568, height: 882))
        ok("a small picture is branding",
           FeedSource.isBrandingImage(URL(string: "https://x.com/tropical-logo-01.jpg")!,
                                      width: 32, height: 32))
        ok("with no size the file name decides",
           FeedSource.isBrandingImage(URL(string: "https://x.com/site-logo.png")!))
        let og = HTMLText.openGraph(in: "<meta property=\"og:image\" content=\"https://x.com/b.png\">")
        eq("og image", og.image?.absoluteString, "https://x.com/b.png")
        // An unquoted attribute made the scraper return the attribute name, and
        // seventeen stories ended up with a picture URL of "og:image": a broken
        // thumbnail on every one of them.
        let ogBare = HTMLText.openGraph(in: "<meta property=og:image content=og:image>")
        eq("an og:image that is not a URL is no image", ogBare.image, nil)
        let ogRelative = HTMLText.openGraph(in: "<meta property=\"og:image\" content=\"/img/a.png\">")
        eq("a relative og:image is no image", ogRelative.image, nil)
        let decoded = HTMLText.plain("Gemini&nbsp;4&#8217;s launch &#038; more")
        ok("numeric entities", decoded.contains("Gemini 4’s launch & more"), decoded)
    }

    private static func testDateParsing() {
        print("\nDates:")
        let rfc = DateParsing.parse("Mon, 19 Oct 2026 15:37:09 +0000")
        ok("RFC 1123", rfc != nil)
        let iso = DateParsing.parse("2026-10-19T10:30:00-04:00")
        ok("ISO 8601", iso != nil)
        if let rfc, let iso {
            // 15:37:09Z vs 10:30:00-04:00 (= 14:30:00Z) → 1h07m09s, i.e. 4029s.
            // A locale-naive parser that ignored the offset would report 5h07m.
            let diff = abs(rfc.timeIntervalSince(iso) - 4029)
            ok("timezone offset respected", diff < 60, String(format: "%.0fs off", diff))
        }
        ok("invalid string rejected", DateParsing.parse("not a date") == nil)
        ok("named timezone", DateParsing.parse("Mon, 19 Oct 2026 15:37:09 -0400 (EDT)") != nil)
        eq("thousands separator", TextFormat.number(217_440), "217,440")
        eq("compact thousands", TextFormat.compact(217_440), "217k")
        eq("compact millions", TextFormat.compact(2_500_000), "2.5M")
        eq("small numbers stay exact", TextFormat.compact(1_310), "1,310")
        ok("relative time", TextFormat.relative(Date().addingTimeInterval(-7200)) == "2h ago",
           TextFormat.relative(Date().addingTimeInterval(-7200)))
        ok("future time", TextFormat.relative(Date().addingTimeInterval(600)).hasPrefix("in "))
        eq("long date", TextFormat.longDate(Date(timeIntervalSince1970: 0)), "Thursday, January 1, 1970")
    }

    private static func testRSSParsing() {
        print("\nRSS parsing:")
        let (entries, _) = FeedXMLParser.parse(rssFixture)
        eq("entry count", entries.count, 2)
        guard entries.count == 2 else { return }
        eq("title", entries[0].title, "Nvidia launches new open models to run agents on PCs")
        eq("author", entries[0].authors.first, "Julie Bort")
        eq("category", entries[0].categories.first, "AI")
        ok("link", entries[0].link?.absoluteString.hasSuffix("nvidia-open-models/") == true)
        ok("media:content image", entries[1].imageURL?.absoluteString.hasSuffix("gemini4.jpg") == true)
        ok("summary", entries[0].plainSummary().contains("open models"))
        ok("dates", entries[0].published != nil && entries[1].published != nil)
        ok("newest first", entries[0].published! > entries[1].published!)
        ok("stable guid", !entries[0].guid.isEmpty)

        // A bare `&` in a URL inside a CDATA body aborts XMLParser and loses every
        // story in the feed. Motionographer published exactly that on every image
        // and the whole source read as zero items while reporting success.
        let strayAmp = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Broken</title>
        <item><title>One</title><link>https://example.com/a</link>
        <pubDate>Mon, 20 Oct 2026 10:00:00 +0000</pubDate>
        <description><![CDATA[<img src="https://cdn.example.com/x.jpg?w=800&quality=80&ssl=1">]]></description>
        </item></channel></rss>
        """
        let recovered = FeedXMLParser.parse(strayAmp)
        eq("stray ampersand does not lose the feed", recovered.entries.count, 1)
        eq("stray ampersand keeps the title", recovered.entries.first?.title, "One")
        // A well-formed document must be left exactly as it is.
        eq("valid entities are untouched",
           FeedXMLParser.escapeStrayAmpersands("<a>AT&amp;T &#38; &#x26; b</a>"),
           "<a>AT&amp;T &#38; &#x26; b</a>")
        eq("only the stray one is escaped",
           FeedXMLParser.escapeStrayAmpersands("<a>x?a=1&b=2&amp;c=3</a>"),
           "<a>x?a=1&amp;b=2&amp;c=3</a>")
    }

    private static func testAtomParsing() {
        print("\nAtom parsing:")
        let (entries, feedImage) = FeedXMLParser.parse(atomFixture)
        eq("entry count", entries.count, 1)
        guard let e = entries.first else { return }
        eq("title", e.title, "Apple adds on-device AI to the Mac")
        ok("link from href", e.link?.absoluteString == "https://www.theverge.com/apple-mac-ai")
        ok("image from content", e.imageURL?.absoluteString.hasSuffix("mac.jpg") == true)
        eq("category", e.categories.first, "AI")
        ok("published date", e.published != nil)
        ok("feed image", feedImage?.absoluteString.hasSuffix("icon.png") == true)

        // A feed-level image is the publication's cover art: using it on every
        // entry would stamp unrelated stories with the same picture, so it is
        // dropped for multi-entry feeds and for anything named like branding.
        eq("feed image dropped for a multi-entry feed",
           FeedSource.usableFeedImage(feedImage, entryCount: 12), nil)
        eq("feed image kept for a single-entry feed",
           FeedSource.usableFeedImage(URL(string: "https://x.com/cover.jpg"), entryCount: 1)?
            .absoluteString, "https://x.com/cover.jpg")
        eq("branding image rejected by name",
           FeedSource.usableFeedImage(URL(string: "https://x.com/logo-jpg.jpg"), entryCount: 1), nil)
        eq("favicon rejected by name",
           FeedSource.usableFeedImage(URL(string: "https://x.com/favicon.png"), entryCount: 1), nil)
        ok("article image is not branding",
           !FeedSource.isBrandingImage(URL(string: "https://tc.com/wp-content/uploads/2026/10/tv.jpeg")!))
        ok("root-level logo is branding",
           FeedSource.isBrandingImage(URL(string: "https://tldr.tech/logo-jpg.jpg")!))
        ok("token match does not catch real filenames",
           !FeedSource.isBrandingImage(URL(string: "https://cdn.example.com/silicon-valley.jpg")!))
        ok("UUID image filename is not branding",
           !FeedSource.isBrandingImage(URL(string:
            "https://ph-files.imgix.net/6c34ef89-b200-49bd-a3fc-5c982d073dea.png?fit=crop")!))
        ok("media path logo is branding",
           FeedSource.isBrandingImage(URL(string: "https://x.com/media/site-logo.png")!))
        // TLDR declares its logo as twitter:image, so enrichment must reject it.
        ok("publisher twitter:image logo rejected",
           FeedSource.isBrandingImage(URL(string: "https://tldr.tech/logo-jpg.jpg")!))

        // A logo repeated across a feed's entries must be stripped.
        var feedItems = (0..<5).map { n -> RadarItem in
            var i = makeItem(title: "TLDR story \(n)", summary: "Body \(n)", source: .tldr)
            i.imageURL = URL(string: "https://tldr.tech/logo-jpg.jpg")
            return i
        }
        feedItems[0].imageURL = URL(string: "https://cdn.example.com/story-hero.jpg")
        FeedSource.stripRepeatedImages(&feedItems)
        eq("repeated logo removed", feedItems.filter { $0.imageURL != nil }.count, 1)
        ok("real story image kept",
           feedItems[0].imageURL?.absoluteString == "https://cdn.example.com/story-hero.jpg")
        ok("unique image kept",
           { var one = [makeItem(title: "a", summary: "b")]; one[0].imageURL = URL(string: "https://x.com/a.jpg")
             FeedSource.stripRepeatedImages(&one); return one[0].imageURL != nil }())
    }

    private static func testTrendingScraping() {
        print("\nTrending scrape:")
        let repos = GitHubTrendingScraper.parse(trendingFixture)
        eq("repository count", repos.count, 2)
        guard repos.count == 2 else { return }
        eq("full name", repos[0].fullName, "anomalyco/opencode")
        eq("language", repos[0].language, "TypeScript")
        eq("stars", repos[0].stars, 217_440)
        eq("stars today", repos[0].starsToday, 1_310)
        eq("second repo stars", repos[1].stars, 11_047)
        ok("description", repos[0].description?.contains("coding agent") == true)
        ok("url", repos[1].url.absoluteString == "https://github.com/akitaonrails/ai-memory")
    }

    private static func testClassification() {
        print("\nClassification and tags:")
        let local = makeItem(title: "Run Llama locally on your Mac with Ollama",
                             summary: "A free and open source local model runner for Apple Silicon.")
        let c = Classifier.classify(local)
        eq("local model category", c.category, .localLLM)
        ok("open source", c.openSource)
        ok("free", c.free)
        ok("local execution", c.localExecution)
        ok("Apple Silicon", c.appleSilicon)
        ok("local tag", c.tags.contains("local"), c.tags.joined(separator: ", "))
        ok("high local score", c.score > 60, String(format: "%.1f", c.score))

        let paid = Classifier.classify(makeItem(
            title: "Startup launches a paid API for image generation",
            summary: "Per token pricing, enterprise plan only. No local execution."))
        ok("paid API detected", paid.paidAPI)
        ok("paid API is not free", !paid.free)
        eq("image category", paid.category, .imageVideo)

        let coding = Classifier.classify(makeItem(
            title: "A new open source coding agent for your IDE",
            summary: "An open-source coding agent that writes pull requests."))
        eq("coding category", coding.category, .coding)

        let policy = Classifier.classify(makeItem(
            title: "EU regulators open an antitrust investigation into AI models",
            summary: "The court will examine copyright and regulation compliance."))
        eq("policy category", policy.category, .policy)

        let research = Classifier.classify(makeItem(
            title: "New research paper sets a state of the art benchmark",
            summary: "The preprint on arXiv introduces a new evaluation dataset."))
        eq("research category", research.category, .research)

        let agent = Classifier.classify(makeItem(
            title: "An autonomous agent that browses the web for you",
            summary: "Multi-agent orchestration with tool use and MCP."))
        eq("agent category", agent.category, .agent)

        // Openness: a reported licence is proof, a neutral public repo counts as
        // open source, and an explicitly proprietary description does not.
        func repoItem(_ license: String?, _ description: String?) -> RadarItem {
            Classifier.classify(GitHubSource.makeItem(
                repo: RepoStats(fullName: "a/b", htmlURL: URL(string: "https://github.com/a/b")!,
                                stars: 10, license: license,
                                topics: [], descriptionEN: description,
                                starsToday: nil, starGrowth7d: nil),
                source: .gitHubTrending, now: Date(), fallbackSummary: nil))
        }
        ok("licence means open source", repoItem("MIT", "A tool").openSource)
        ok("public repo without licence is open source", repoItem(nil, "A tool").openSource)
        ok("proprietary description is not open source",
           !repoItem(nil, "A proprietary tool, closed source").openSource)
        ok("repo gets a preview image",
           GitHubSource.previewImage("anomalyco/opencode")?.absoluteString
            == "https://opengraph.githubassets.com/1/anomalyco/opencode")
        ok("repo facts mention stars",
           repoItem("MIT", "A tool").keyPoints.contains { $0.contains("stars on GitHub") },
           repoItem("MIT", "A tool").keyPoints.joined(separator: " | "))
        ok("repo without licence says so explicitly",
           repoItem(nil, "A tool").keyPoints.contains("No licence declared"),
           repoItem(nil, "A tool").keyPoints.joined(separator: " | "))
        ok("repo with a licence states it",
           repoItem("MIT", "A tool").keyPoints.contains("Licence: MIT"),
           repoItem("MIT", "A tool").keyPoints.joined(separator: " | "))
    }

    private static func testRendering() {
        print("\nRendering:")
        let item = Classifier.classify(makeItem(
            title: "Google announces Gemini 4 for developers",
            summary: "Google said the new model runs locally on Apple Silicon Macs and is free to use. "
                + "The company shipped an SDK alongside it and promised a wider rollout next quarter."))
        let r = Summarizer.offlineRender(item)
        ok("headline kept verbatim", r.headline == "Google announces Gemini 4 for developers", r.headline)
        ok("summary from the source", r.summaryEngine == "source", r.summaryEngine)
        ok("summary non-empty", r.summary.count > 30, String(r.summary.prefix(90)))
        ok("summary stays English", r.summary.allSatisfy { !$0.isArabicLetter }, r.summary)
        ok("key points", !r.keyPoints.isEmpty, r.keyPoints.joined(separator: " | "))

        // A feed that supplies no body text must still get an honest summary.
        let bare = Classifier.classify(makeItem(title: "Zxqv announces Blorptron", summary: ""))
        let rb = Summarizer.offlineRender(bare)
        ok("digest fallback", rb.summaryEngine == "digest", rb.summaryEngine)
        ok("digest is not empty", rb.summary.count > 20, rb.summary)
        ok("digest names the source", rb.summary.contains(bare.source.title), rb.summary)
        ok("digest never claims a model", !EngineLabel.describe(rb.summaryEngine).isModel)

        // A one-line teaser is too short to be a summary; the digest takes over.
        let teaser = Classifier.classify(makeItem(title: "Short teaser", summary: "Coming soon."))
        eq("short summary triggers digest", Summarizer.offlineRender(teaser).summaryEngine, "digest")

        // Feeds that only repeat the headline, or append navigation words, must
        // not produce a card whose "summary" is just the title again.
        let echo = Classifier.classify(makeItem(
            title: "Apple's robotic arm, datacenter debt crisis",
            summary: "Apple's robotic arm, datacenter debt crisis",
            source: .tldr))
        eq("headline echo triggers digest", Summarizer.offlineRender(echo).summaryEngine, "digest")
        ok("digest restates the headline in a sentence",
           Summarizer.offlineRender(echo).summary.count > 60,
           Summarizer.offlineRender(echo).summary)

        let navText = Summarizer.cleanedSummary(makeItem(
            title: "croft",
            summary: "Data pipelines written entirely in TypeScript and stored in a single "
                + "DuckDB file you can commit to the repo. Discussion | Link",
            source: .productHunt))
        ok("navigation words stripped",
           navText?.contains("Discussion") == false && navText?.contains("| Link") == false,
           navText ?? "(rejected)")
        eq("tagline still rejected as a summary", Summarizer.cleanedSummary(makeItem(
            title: "croft", summary: "Data pipelines in TypeScript, on one DuckDB file Discussion | Link",
            source: .productHunt)), nil)

        // "TBD" is a publishing placeholder, not a summary.
        let tbd = Classifier.classify(makeItem(
            title: "Gemini 4 Argon: Built to solve your hardest problems",
            summary: "TBD", source: .blogGoogle))
        let tbdRendered = Summarizer.offlineRender(tbd)
        ok("placeholder body rejected", tbdRendered.summaryEngine == "digest", tbdRendered.summaryEngine)
        ok("placeholder never quoted",
           !tbdRendered.summary.lowercased().contains("tbd"), tbdRendered.summary)
        ok("placeholder digest still says something",
           tbdRendered.summary.count > 70, tbdRendered.summary)

        // A real body paragraph is still used verbatim as the summary.
        let real = Classifier.classify(makeItem(
            title: "Meta launches an open-weight model",
            summary: "Meta and Apple have teamed up for the launch of the social media giant's newest model, which will run locally on Apple Silicon hardware."))
        eq("real description becomes the summary",
           Summarizer.offlineRender(real).summaryEngine, "source")

        // Trailing publisher suffixes are stripped from headlines.
        let noisy = makeItem(title: "Nvidia ships new chips | TechCrunch", summary: "")
        eq("publisher suffix stripped", Summarizer.cleanedHeadline(noisy), "Nvidia ships new chips")

        let repo = GitHubSource.makeItem(
            repo: RepoStats(fullName: "anomalyco/opencode",
                            htmlURL: URL(string: "https://github.com/anomalyco/opencode")!,
                            stars: 217_440, forks: 1000, language: "TypeScript", license: "MIT",
                            created: Date(timeIntervalSince1970: 1_700_000_000), pushed: Date(),
                            topics: ["ai", "agents"], descriptionEN: "The open source coding agent.",
                            homepage: nil, starsToday: 1310, starGrowth7d: nil),
            source: .gitHubTrending, now: Date(), fallbackSummary: nil)
        let rc = Classifier.classify(repo)
        let rr = Summarizer.offlineRender(rc)
        eq("repo headline is its name", rr.headline, "anomalyco/opencode")
        ok("repo points mention stars",
           rr.keyPoints.contains { $0.contains("217,440 stars") }, rr.keyPoints.joined(separator: " | "))
        ok("repo points mention 24h growth",
           rr.keyPoints.contains { $0.contains("24 hours") }, rr.keyPoints.joined(separator: " | "))
        ok("repo points mention licence", rr.keyPoints.contains { $0.contains("MIT") })
        ok("repo digest states language", rr.summary.contains("TypeScript"), rr.summary)
    }

    private static func testScoring() {
        print("\nScoring:")
        let now = Date()
        let freshLocal = Classifier.classify(makeItem(
            title: "Open source local LLM for Apple Silicon", summary: "Free offline model.",
            published: now.addingTimeInterval(-3600)))
        let oldPaid = Classifier.classify(makeItem(
            title: "Paid API for text generation", summary: "Enterprise subscription only.",
            published: now.addingTimeInterval(-20 * 86400)))
        ok("fresh local ranks higher", freshLocal.score > oldPaid.score,
           String(format: "%.1f > %.1f", freshLocal.score, oldPaid.score))
        ok("freshness contributes", freshLocal.score > Classifier.classify(
            makeItem(title: freshLocal.title, summary: freshLocal.rawSummary,
                     published: now.addingTimeInterval(-10 * 86400))).score)
        ok("score stays bounded", freshLocal.score < 400, String(format: "%.1f", freshLocal.score))
    }

    private static func testFiltering() {
        print("\nFiltering and search:")
        let now = Date()

        // A duplicate key must never trap the process. `Dictionary(uniqueKeys-
        // withValues:)` on a restored sources file with two equal ids used to
        // crash the app on launch (EXC_BREAKPOINT), which is what "it closes by
        // itself" was.
        let dupA = CustomSource(id: "same", title: "A", feedURL: "https://a.example/feed",
                                homeURL: "https://a.example/", host: "a.example",
                                symbol: "a.circle", addedAt: now)
        let dupB = CustomSource(id: "same", title: "B", feedURL: "https://b.example/feed",
                                homeURL: "https://b.example/", host: "b.example",
                                symbol: "b.circle", addedAt: now)
        SourceRegistry.shared.replaceAll([dupA, dupB])
        eq("duplicate custom ids do not crash", SourceRegistry.shared.all.count, 1)
        SourceRegistry.shared.replaceAll([])
        let dupItems = [makeItem(title: "twin", summary: "x"), makeItem(title: "twin", summary: "x")]
        let dupStore = Store(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-dup-\(UUID().uuidString)", isDirectory: true))
        dupStore.merge(newItems: dupItems, now: now)
        eq("duplicate ids collapse to one stored item", dupStore.items.count, 1)
        ok("ids lookup survives duplicates",
           dupStore.items(ids: dupItems.map { $0.id }).count >= 0)

        let items = [
            Classifier.classify(makeItem(title: "Free local LLM runs on Mac", summary: "offline open source", published: now.addingTimeInterval(-7200))),
            Classifier.classify(makeItem(title: "Paid image generation API launch", summary: "per token pricing", published: now.addingTimeInterval(-3 * 86400))),
            Classifier.classify(makeItem(title: "Open source coding agent", summary: "free tool for developers", published: now.addingTimeInterval(-20 * 86400)))
        ]
        let store = Store(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-filter-\(UUID().uuidString)", isDirectory: true))
        store.merge(newItems: items, now: now)

        var f = Filters(); f.range = .week
        eq("weekly range", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 2)
        f.range = .threeDays
        eq("72 hour range", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 2)
        f.range = .day
        eq("24 hour range", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 1)
        f.range = .twelveHours
        eq("12 hour range", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 1)
        f.range = .all
        eq("all time", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 3)
        f.openSourceOnly = true
        eq("open source only", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 2)
        f = Filters(); f.range = .all; f.freeOnly = true
        eq("free only", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 2)
        f = Filters(); f.range = .all; f.localOnly = true
        eq("local only", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 1)
        f = Filters(); f.range = .all; f.category = .imageVideo
        eq("category filter", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 1)
        ok("expected category present", items.contains { $0.category == .imageVideo })
        f = Filters(); f.range = .all; f.query = "agent"
        eq("english search", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 1)
        f = Filters(); f.range = .all; f.query = "offline"
        eq("search hits summaries", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 1)
        f = Filters(); f.range = .all; f.query = "apple silicon"
        eq("search hits key points", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 0)
        f = Filters(); f.range = .all; f.sources = [.productHunt]
        eq("source filter", Filtering.apply(items, filters: f, readIDs: [], now: now).count, 0)
        f = Filters(); f.range = .all; f.unreadOnly = true
        eq("unread only", Filtering.apply(items, filters: f, readIDs: [items[0].id], now: now).count, 2)

        // Sorting: default ranking must be deterministic.
        let sorted = Filtering.sort(items, by: .relevance, appleSiliconFirst: true)
        eq("stable sort", sorted.map { $0.id },
           Filtering.sort(items, by: .relevance, appleSiliconFirst: true).map { $0.id })
        ok("sorted by score", sorted.first!.score >= sorted.last!.score)
        let byStars = Filtering.sort(items, by: .stars, appleSiliconFirst: false)
        eq("star sort keeps non-repos last",
           byStars.last?.isGitHub, false)
        try? FileManager.default.removeItem(at: store.directory)
    }

    /// The news feed and the repository section must not contain each other, and
    /// the quick time windows must be ordered narrow to wide.
    private static func testSectionSplit() {
        print("\nSection split and time windows:")
        eq("four quick ranges", DateRange.quick.map { $0.shortTitle }, ["12h", "24h", "72h", "1w"])
        ok("quick ranges widen",
           zip(DateRange.quick, DateRange.quick.dropFirst()).allSatisfy {
               ($0.seconds ?? 0) < ($1.seconds ?? 0)
           })
        eq("12h is 12 hours", DateRange.twelveHours.seconds, 12 * 3600)
        eq("72h is three days", DateRange.threeDays.seconds, 72 * 3600)

        let now = Date()
        let news = Classifier.classify(makeItem(title: "A news story about models",
                                                summary: "Something happened.",
                                                published: now.addingTimeInterval(-3600)))
        let repo = Classifier.classify(GitHubSource.makeItem(
            repo: RepoStats(fullName: "a/b", htmlURL: URL(string: "https://github.com/a/b")!,
                            stars: 100, topics: [], descriptionEN: "Tool"),
            source: .gitHubTrending, now: now.addingTimeInterval(-3600), fallbackSummary: nil))
        ok("news item is not a repo", !news.isGitHub)
        ok("repo item is a repo", repo.isGitHub)
        let store = Store(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-split-\(UUID().uuidString)", isDirectory: true))
        store.merge(newItems: [news, repo], now: now)
        let newsOnly = store.items.filter { !$0.isGitHub }
        let reposOnly = store.items.filter { $0.isGitHub }
        eq("news list excludes repos", newsOnly.count, 1)
        eq("repo list excludes news", reposOnly.count, 1)
        ok("split keeps everything", newsOnly.count + reposOnly.count == store.items.count)
        try? FileManager.default.removeItem(at: store.directory)
    }

    /// The window's lists must agree with the section on screen.
    ///
    /// These are the counts the toolbar and the filter panel draw, and every one
    /// of them used to be computed from the whole archive: the Tech tab's "Show
    /// all" counted AI news as well. The same fixtures also prove that the
    /// toolbar's sort menu now overrides the standing ranking.
    private static func testListModel() {
        print("\nList model:")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-list-\(UUID().uuidString)", isDirectory: true)
        let store = Store(directory: dir)
        let now = Date()
        let newsNew = Classifier.classify(makeItem(
            title: "Fresh news", summary: "A story about AI agents.",
            published: now.addingTimeInterval(-60)))
        let newsOld = Classifier.classify(makeItem(
            title: "Older news", summary: "A story about models.",
            published: now.addingTimeInterval(-7200)))
        let tech = Classifier.classify(makeItem(
            title: "A new GPU", summary: "Hardware news.",
            published: now.addingTimeInterval(-600), source: .tech("theverge")))
        let design = Classifier.classify(makeItem(
            title: "A poster", summary: "Design news.",
            published: now.addingTimeInterval(-900), source: .design("figma.com/blog")))
        let repo = GitHubSource.makeItem(
            repo: RepoStats(fullName: "a/b", htmlURL: URL(string: "https://github.com/a/b")!,
                            stars: 100, topics: [], descriptionEN: "Tool"),
            source: .gitHubTrending, now: now.addingTimeInterval(-300), fallbackSummary: nil)
        store.merge(newItems: [newsNew, newsOld, tech, design, repo], now: now)

        MainActor.assumeIsolated {
            let model = AppModel(store: store)
            model.listLimit = 0
            model.filters = Filters()
            model.filters.range = .all

            model.section = .all
            eq("news base excludes every other tab", model.sectionBase.count, 2)
            eq("news count", model.unfilteredCount, 2)
            ok("news list has no tech, design or repos",
               model.visibleItems.allSatisfy { !$0.source.isTech && !$0.isGitHub
                   && DesignCatalogue.surface(of: $0.source) == nil })

            model.section = .tech
            model.techRange = .all
            eq("tech base", model.sectionBase.count, 1)
            eq("tech count is the tab's own", model.unfilteredCount, 1)
            eq("tech window", model.techWindowItems().count, 1)
            eq("tech header count", model.currentSectionCount, 1)

            model.section = .all
            model.rank = .fresh
            model.sort = .newest
            eq("toolbar newest first", model.visibleItems.map { $0.id },
               [newsNew.id, newsOld.id])
            model.sort = .oldest
            eq("toolbar oldest overrides the ranking", model.visibleItems.map { $0.id },
               [newsOld.id, newsNew.id])
            model.sort = .relevance
            eq("ranked order follows the setting", model.visibleItems.map { $0.id },
               [newsNew.id, newsOld.id])
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// The author line is read from the page's own metadata. The regex used to
    /// search for a literal "(author)" and never matched anything.
    private static func testArticleAuthor() {
        print("\nArticle author:")
        ok("name + content",
           ArticleReader.metaAuthor("<meta name=\"author\" content=\"Jane Doe\">") == "Jane Doe")
        ok("property article:author",
           ArticleReader.metaAuthor("<meta property=\"article:author\" content=\"A. Writer\">")
               == "A. Writer")
        ok("content before name",
           ArticleReader.metaAuthor("<meta content=\"Backwards Order\" property=\"author\">")
               == "Backwards Order")
        ok("entities decoded",
           ArticleReader.metaAuthor("<meta name=\"author\" content=\"Ada &amp; Bob\">")
               == "Ada & Bob")
        ok("another name is not an author",
           ArticleReader.metaAuthor("<meta name=\"description\" content=\"Not an author\">") == nil)
        ok("no metadata", ArticleReader.metaAuthor("<p>No author here</p>") == nil)
        ok("overlong value rejected", ArticleReader.metaAuthor(
            "<meta name=\"author\" content=\"" + String(repeating: "x", count: 100) + "\">") == nil)
    }

    /// The store's id index must follow the array it indexes, including after a
    /// merge that replaces an existing story.
    private static func testStoreIndex() {
        print("\nStore index:")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-index-\(UUID().uuidString)", isDirectory: true)
        let store = Store(directory: dir)
        let now = Date()
        let a = Classifier.classify(makeItem(
            title: "Index A", summary: "First story.", published: now))
        let b = Classifier.classify(makeItem(
            title: "Index B", summary: "Second story.",
            published: now.addingTimeInterval(-120)))
        store.merge(newItems: [a, b], now: now)

        eq("item by id", store.item(id: a.id)?.id, a.id)
        ok("unknown id is nil", store.item(id: "missing") == nil)
        eq("ids keep their requested order", store.items(ids: [b.id, a.id]).map { $0.id },
           [b.id, a.id])
        eq("unknown ids are dropped", store.items(ids: [a.id, "missing"]).count, 1)

        var renamed = a
        renamed.title = "Index A renamed"
        store.merge(newItems: [renamed], now: now)
        eq("index follows a merge", store.item(id: a.id)?.title, "Index A renamed")
        eq("merge still holds both", store.items.count, 2)
        try? FileManager.default.removeItem(at: dir)
    }

    private static func testStoreRoundTrip() {
        print("\nPersistence:")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-store-\(UUID().uuidString)", isDirectory: true)
        var store: Store? = Store(directory: dir)
        // The engine always merges rendered items; render here too so the test
        // exercises what production actually writes.
        let item = Summarizer.render(
            Classifier.classify(makeItem(title: "Test item", summary: "Body text here.")),
            ollama: nil)
        ok("precondition: rendered before saving", !item.headline.isEmpty, item.headline)
        store!.merge(newItems: [item], now: Date())
        _ = store!.toggleBookmark(item.id)
        store!.markOpened(item, now: Date())
        store!.updateState { $0.layout = .grid; $0.ollama.model = "llama3"; $0.ollama.enabled = true }
        store!.setBriefing(Summarizer.localBriefing(items: [item], now: Date(), previousDayTopIDs: []))
        store!.saveAll()

        // Fresh instance reads what the first one wrote.
        store = nil
        let reloaded = Store(directory: dir)
        eq("items", reloaded.items.count, 1)
        ok("bookmark", reloaded.isBookmarked(item.id))
        ok("read state", reloaded.isRead(item.id))
        eq("history", reloaded.history.count, 1)
        eq("layout", reloaded.state.layout, .grid)
        eq("ollama model", reloaded.state.ollama.model, "llama3")
        ok("daily briefing", reloaded.briefing(for: Date()) != nil)
        ok("rendering preserved", !reloaded.items[0].headline.isEmpty)

        // Merge must not duplicate or lose the rendering.
        reloaded.merge(newItems: [item], now: Date())
        eq("merge does not duplicate", reloaded.items.count, 1)
        ok("merge keeps the rendering", !reloaded.items[0].headline.isEmpty)
        eq("merge keeps the engine", reloaded.items[0].summaryEngine, item.summaryEngine)

        // Growth maths.
        let now = Date()
        reloaded.appendSnapshots([StarSnapshot(fullName: "a/b", stars: 100, takenAt: now.addingTimeInterval(-2 * 86400))])
        eq("star growth", reloaded.growth(for: "a/b", current: 150, now: now), 50)
        ok("growth needs 12h of history", reloaded.growth(
            for: "a/b", current: 150, now: now.addingTimeInterval(-2 * 86400 + 3600)) == nil)
        ok("size on disk", reloaded.sizeOnDisk > 0)

        try? FileManager.default.removeItem(at: dir)
    }

    private static func testOllamaJSON() {
        print("\nLocal model output:")
        let good = """
        Sure, here it is:
        {"headline": "Google ships Gemini 4", "summary": "The new model runs on the Mac.", "points": ["Free", "Local"]}
        """
        let r = Summarizer.parseModelJSON(good)
        ok("JSON inside prose", r != nil)
        eq("headline", r?.headline, "Google ships Gemini 4")
        eq("point count", r?.points.count, 2)
        ok("invalid JSON rejected", Summarizer.parseModelJSON("no json here") == nil)
        ok("prompt asks for JSON", Summarizer.prompt(
            for: makeItem(title: "x", summary: "y")).contains("\"headline\""))
        ok("prompt forbids invention", Summarizer.prompt(
            for: makeItem(title: "x", summary: "y")).contains("Only use facts present in the input"))
    }

    private static func testBriefing() {
        print("\nDaily briefing:")
        let now = Date()
        let items = [
            Classifier.classify(makeItem(title: "Google announces Gemini 4", summary: "New model released today.", published: now.addingTimeInterval(-3600))),
            Classifier.classify(makeItem(title: "Free local model for Apple Silicon", summary: "Open source and offline.", published: now.addingTimeInterval(-7200))),
            Classifier.classify(makeItem(title: "EU opens AI regulation review", summary: "Regulators examine the law.", published: now.addingTimeInterval(-10800)))
        ]
        let b = Summarizer.localBriefing(items: items, now: now, previousDayTopIDs: [])
        eq("day key", b.dayKey, Digest.dayKey(now))
        ok("paragraph count", b.paragraphs.count >= 3, "\(b.paragraphs.count)")
        ok("first paragraph counts the day", b.paragraphs[0].contains("3 new"), b.paragraphs[0])
        ok("highlights", !b.highlightIDs.isEmpty)
        ok("categories counted", b.categoryCounts.values.reduce(0, +) >= 3)
        ok("text is English", b.paragraphs.joined(separator: " ").allSatisfy { !$0.isArabicLetter })

        let prior = Set([items[0].id, items[1].id])
        let b2 = Summarizer.localBriefing(items: items, now: now, previousDayTopIDs: prior)
        ok("compares with yesterday", b2.paragraphs.contains { $0.contains("yesterday") })

        let empty = Summarizer.localBriefing(items: [], now: now, previousDayTopIDs: [])
        ok("empty input handled", empty.paragraphs.count >= 1)
        ok("no briefing claims a model", !EngineLabel.describe(b.engine).isModel)

        // A repo pick must appear when repositories are present.
        let repo = Classifier.classify(GitHubSource.makeItem(
            repo: RepoStats(fullName: "a/b", htmlURL: URL(string: "https://github.com/a/b")!,
                            stars: 5000, language: "Rust",
                            topics: [], descriptionEN: "Tool"),
            source: .gitHubTrending, now: now, fallbackSummary: nil))
        let withRepo = Summarizer.localBriefing(items: [repo], now: now, previousDayTopIDs: [])
        ok("repo appears in the briefing",
           withRepo.paragraphs.contains { $0.contains("a/b") },
           withRepo.paragraphs.joined(separator: " / "))
        ok("repo pick recorded", !withRepo.repoPickIDs.isEmpty)
        ok("a repo-only briefing says stories are missing",
           withRepo.paragraphs[0].contains("No new stories"),
           withRepo.paragraphs[0])

        // Mixed input: a heavily starred repo must not take the news highlight
        // slots, and the two pools must stay separate.
        let newsA = Classifier.classify(makeItem(
            title: "Meta ships an open-weight model",
            summary: "Meta released a model that runs locally on Apple Silicon and can be downloaded today by anyone.",
            published: now.addingTimeInterval(-1800)))
        let newsB = Classifier.classify(makeItem(
            title: "EU opens an AI regulation review",
            summary: "Regulators said they will examine how the AI Act applies to foundation models over the next year.",
            published: now.addingTimeInterval(-5400)))
        let starRepo = Classifier.classify(GitHubSource.makeItem(
            repo: RepoStats(fullName: "x/huge", htmlURL: URL(string: "https://github.com/x/huge")!,
                            stars: 400_000, topics: [], descriptionEN: "Tool"),
            source: .gitHubTrending, now: now, fallbackSummary: nil))
        let mixed = Summarizer.localBriefing(items: [newsA, newsB, starRepo],
                                            now: now, previousDayTopIDs: [])
        let ownerOf: (String) -> RadarItem? = { id in
            [newsA, newsB, starRepo].first { $0.id == id }
        }
        ok("highlights hold only news",
           mixed.highlightIDs.allSatisfy { ownerOf($0)?.isGitHub == false },
           mixed.highlightIDs.joined(separator: ","))
        ok("repo picks hold only repos",
           mixed.repoPickIDs.allSatisfy { ownerOf($0)?.isGitHub == true },
           mixed.repoPickIDs.joined(separator: ","))
        eq("both stories highlighted", mixed.highlightIDs.count, 2)
        eq("one repo picked", mixed.repoPickIDs.count, 1)
        ok("briefing leads with the story count",
           mixed.paragraphs[0].contains("2 new stories"), mixed.paragraphs[0])
        ok("github gets its own paragraph",
           mixed.paragraphs.contains { $0.contains("Trending on GitHub") },
           mixed.paragraphs.joined(separator: " / "))
        ok("repo is not called the top story",
           !mixed.paragraphs.contains { $0.contains("Top story: x/huge") },
           mixed.paragraphs.joined(separator: " / "))
    }

    /// Every source added in the second integration pass: the configured
    /// endpoint, the collection method and the per-source filter, checked offline
    /// so a mistake in the table is caught without a network round trip.
    private static func testNewSources() {
        print("\nNew sources:")

        // The seven original sources must still be exactly as they were.
        let originals: [SourceID] = [.blogGoogle, .techCrunch, .tldr, .theVerge,
                                     .productHunt, .gitHubTrending, .gitHubExplore]
        eq("original sources kept", originals.filter { SourceID.all.contains($0) }.count, 7)
        eq("blog feed unchanged", SourceID.blogGoogle.feedURL?.absoluteString,
           "https://blog.google/technology/ai/rss/")
        eq("verge feed unchanged", SourceID.theVerge.feedURL?.absoluteString,
           "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml")

        // No duplicate source, and every source has a unique identity.
        eq("no duplicate sources", Set(SourceID.all.map { $0.rawValue }).count,
           SourceID.all.count)
        // A publisher can be read in two scopes of the same publication: MIT
        // Technology Review's AI topic feed lives in News, its general feed in
        // Tech News, and both carry the same name because they are the same
        // publication. Titles are unique within a scope, not across the whole
        // app — a feed that said "AI" or "Tech" twice with no difference in
        // scope would be a real duplicate.
        let scopeTitles = SourceID.all.map {
            $0.title + "\u{1F}" + BriefingSection.section(for: $0).rawValue
        }
        eq("no duplicate titles within a scope",
           Set(scopeTitles).count, scopeTitles.count)
        // The two publishers that share a name across scopes are the two the
        // app deliberately reads twice: MIT Technology Review's AI topic feed
        // and its general feed, and Hacker News in the news list and in the
        // Tech tab. Anything else sharing a name would be a real duplicate.
        let techTitles = Set(SourceID.techSources.map { $0.title })
        let newsTitles = Set(SourceID.all.filter { !$0.isTech }.map { $0.title })
        eq("only the two publishers share a name across scopes",
           techTitles.intersection(newsTitles)
               .filter { $0 != "Hacker News" && $0 != "MIT Technology Review" }
               .sorted(), [])
        eq("twenty-four built-in sources", SourceID.builtIns.count, 24)

        // Nothing in the app may still call itself by the old name. The QA
        // environment variables keep their prefix on purpose — they are not drawn
        // anywhere and the screenshot recipes depend on them.
        //
        // `--selftest` runs from `build/bin/NewsRadar`, which has no Info.plist of
        // its own, so the packaged bundle beside the sources is what gets read.
        var info = Bundle.main.infoDictionary ?? [:]
        if info["CFBundleName"] == nil {
            let packaged = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("News Radar.app/Contents/Info.plist")
            if let data = try? Data(contentsOf: packaged),
               let plist = try? PropertyListSerialization.propertyList(
                   from: data, options: [], format: nil) as? [String: Any] {
                info = plist
            }
        }
        let bundleName = info["CFBundleName"] as? String ?? ""
        ok("the bundle is named News Radar", bundleName == "News Radar", bundleName)
        let windowTitle = info["CFBundleDisplayName"] as? String ?? ""
        ok("the display name is News Radar", windowTitle == "News Radar", windowTitle)
        let bundleID = info["CFBundleIdentifier"] as? String ?? Bundle.main.bundleIdentifier ?? ""
        ok("the bundle id carries the new name",
           bundleID.isEmpty || bundleID == "com.newsradar.reader", bundleID)
        // The old name must not survive in the executable's own identity either.
        ok("the executable is NewsRadar",
           (info["CFBundleExecutable"] as? String ?? "NewsRadar") == "NewsRadar",
           info["CFBundleExecutable"] as? String ?? "-")
        // The design feeds are added to the same collection pass, so the totals
        // move with the catalogue instead of being pinned to a stale number.
        // --- Design & Web Intelligence catalogue ---------------------------
        let ds = DesignCatalogue.sources
        ok("the design tab has sources", !ds.isEmpty, "\(ds.count)")
        eq("design source ids are unique", Set(ds.map { $0.id }).count, ds.count)
        eq("design source titles are unique", Set(ds.map { $0.title }).count, ds.count)
        // A source read from its listing page has no feed at all; every other
        // source must name an https feed.
        eq("every design feed is https",
           ds.filter { $0.feed.isEmpty == false && !$0.feed.hasPrefix("https://") }
               .map { $0.title }, [])
        // A source read from a WordPress JSON endpoint must name an https one.
        eq("every json endpoint is https",
           ds.filter { !$0.jsonEndpoint.isEmpty && !$0.jsonEndpoint.hasPrefix("https://") }
               .map { $0.title }, [])
        // A source must use exactly one route: a feed, a listing, a sitemap or
        // a JSON endpoint. Two of them at once means one of them is never read.
        eq("no source declares two routes",
           ds.filter { d in
               let routes = [d.feed.isEmpty ? 0 : 1,
                             d.usesListing ? 1 : 0,
                             d.usesSitemap ? 1 : 0,
                             d.jsonEndpoint.isEmpty ? 0 : 1]
               return routes.reduce(0, +) > 1
           }.map { $0.title }, [])
        // A listing source must say where its articles live, or nothing can be
        // read from it.
        eq("every listing source names its path",
           ds.filter { $0.usesListing && $0.listingPath.isEmpty }.map { $0.title }, [])
        // A sitemap source must name an https sitemap.
        eq("every sitemap source names an https sitemap",
           ds.filter { $0.usesSitemap && !$0.sitemapURL.hasPrefix("https://") }.map { $0.title }, [])
        eq("every design home is https", ds.filter { !$0.home.hasPrefix("https://") }.map { $0.title }, [])
        eq("every design source is described",
           ds.filter { $0.title.isEmpty || $0.id.isEmpty || $0.symbol.isEmpty || $0.accent.isEmpty }.map { $0.id }, [])
        // A WordPress endpoint writes its dates without a zone, so a date that
        // carries no zone has to be read rather than thrown away. Otherwise
        // every story looks like it was published at the moment of the
        // refresh, and the whole list carries today's date.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? gregorian.timeZone
        let noZone = DateParsing.parse("2026-10-22T02:55:04")
        let parts = noZone.map { gregorian.dateComponents([.year, .month, .day, .hour], from: $0) }
        ok("a date without a zone is read",
           parts?.year == 2026 && parts?.month == 10 && parts?.day == 22 && parts?.hour == 2,
           "\(parts.map { "\($0.year ?? -1)-\($0.month ?? -1)-\($0.day ?? -1) \($0.hour ?? -1):00" } ?? "nil")")
        let withMillis = DateParsing.parse("2026-10-22T02:55:04.000")
        ok("a date with milliseconds is read", withMillis != nil, "read")

        // A publisher whose feed stopped is named as unavailable rather than
        // left in the catalogue as a source that shows nothing.
        for stopped in ["Envato", "Photopea", "MeasureSchool", "Web Design Weekly",
                        "Google Fonts", "Sidebar"] {
            ok("\(stopped) is named as unavailable",
               DesignCatalogue.unavailable.contains { $0.title == stopped },
               "named with the reason it stopped")
            ok("\(stopped) is not a configured source",
               !ds.contains { $0.title == stopped },
               "removed from the catalogue")
        }
        // Every publisher added to replace a stopped one must have a feed that
        // is not empty, so the section it joins is not left empty.
        for added in ["ilovetypography.com", "thetype.com", "designshack.net",
                      "logomoose.com", "yellowtrace.com.au", "thisiscolossal.com",
                      "design-milk.com", "marketingland.com", "frontendfoc.us",
                      "web.dev"] {
            ok("\(added) has a feed",
               ds.first { $0.id == added }?.feed.hasPrefix("https://") == true,
               "feed address")
        }
        // A source listed as unavailable must not also be configured, or the tab
        // would claim a publisher is missing while showing its stories.
        let unavailableTitles = Set(DesignCatalogue.unavailable.map { $0.title })
        eq("no source is both listed and unavailable",
           ds.map { $0.title }.filter { unavailableTitles.contains($0) }, [])
        // All eight sections are represented: a chip that always reads zero is a
        // question the tab cannot answer.
        eq("every design section has at least one source",
           DesignCategory.allCases.filter { DesignCatalogue.count(for: $0) == 0 }.map { $0.shortTitle }, [])
        // The two catalogue tabs must partition the catalogue: every source is
        // readable in exactly one of them, and neither is empty.
        for surface in DesignSurface.allCases {
            ok("\(surface.title) has sources", !DesignCatalogue.sources(for: surface).isEmpty,
               "\(DesignCatalogue.sources(for: surface).count)")
            ok("\(surface.title) has sections", !DesignCatalogue.grouped(surface).isEmpty,
               "\(DesignCatalogue.grouped(surface).count)")
        }
        eq("the two tabs together are the whole catalogue",
           DesignCatalogue.sources(for: .web).count + DesignCatalogue.sources(for: .design).count,
           ds.count)
        // A section belongs to one surface only, so no source can be counted twice.
        let surfacesPerCategory = DesignCategory.allCases.map { cat in
            DesignSurface.allCases.filter { cat.surface == $0 }.count
        }
        eq("each section belongs to one tab", surfacesPerCategory.filter { $0 != 1 }.count, 0)
        // Routed, not guessed: every catalogue source resolves to its tab.
        let unrouted = ds.compactMap { s -> String? in
            let id = DesignCatalogue.sourceID(of: s)
            return DesignCatalogue.surface(of: id) == nil ? s.id : nil
        }
        eq("every design source is routed to a tab", unrouted, [])
        // Two publishers the app already collected live in the design tab now:
        // that is a move, not a duplicate.
        eq("the design tab keeps the two publishers it already had",
           ds.filter { $0.sourceID != nil }.count, 2)
        // A built-in source must not be hijacked by the catalogue.
        eq("only the two moved publishers are built-ins in a catalogue tab",
           SourceID.builtIns.filter { DesignCatalogue.surface(of: $0) != nil }
               .filter { $0 != .creativeBloq && $0 != .itsNiceThat }.count, 0)

        // The design pool and the news pool must not overlap in the list.
        let designIDs = Set(ds.map { DesignCatalogue.sourceID(of: $0) })
        // A listing source resolves to a spec with no feed and a stated method;
        // every other source resolves to a spec with a feed.
        eq("design sources resolve to specs",
           designIDs.filter { id in
               let d = DesignCatalogue.entry(for: id)
               // A source read from a listing page, a sitemap or a WordPress
               // endpoint has no feed; every other source must have one.
               if d?.usesListing == true || d?.usesSitemap == true
                   || (d?.jsonEndpoint.isEmpty == false) { return id.spec.feedURL != nil }
               return id.spec.feedURL == nil
           }.map { $0.rawValue }, [])
        // A publisher the app already collected keeps its own id, so no story
        // is stored twice; every other catalogue entry is a source of its own.
        eq("no publisher is collected twice",
           ds.map { DesignCatalogue.sourceID(of: $0) }.count,
           Set(ds.map { DesignCatalogue.sourceID(of: $0) }).count)
        eq("every catalogue entry has a source",
           ds.filter { DesignCatalogue.sourceID(of: $0).rawValue.isEmpty }.count, 0)

        eq("every design feed is registered",
           SourceID.designSources.count, DesignCatalogue.sources.count)
        // Two of the catalogue's publishers are already among the built-ins, so
        // the total is the catalogue plus the built-ins minus those two.
        let moved = ds.filter { $0.sourceID != nil }.count
        // The Tech News tab's publishers are collected too, so the total is
        // the built-ins, the design feeds, and the tech feeds, minus the
        // publishers that were already collected as built-ins.
        let techExtra = SourceID.techSources.filter { !Set(SourceID.builtIns).contains($0) }.count
        eq("the design and tech feeds are collected too",
           SourceID.all.count,
           SourceID.builtIns.count + DesignCatalogue.sources.count - moved + techExtra)

        // Every source is configured completely: nothing may reach the UI with an
        // empty title, host or method label.
        let incomplete = SourceID.all.filter {
            $0.title.isEmpty || $0.host.isEmpty || $0.accessDescription.isEmpty
        }
        eq("every source is fully described", incomplete.count, 0)

        // The Tech News tab's contract, checked without the network.
        //
        // Every advertised section must be reachable, and the sections must
        // partition the tab: the chip counts have to add up to the All Tech
        // figure, or a reader can see a story in the list that no chip can find.
        eq("the tech tab offers the sections that were asked for",
           TechCategory.allCases.map { $0.rawValue },
           ["startups", "gadgets", "hardware", "security", "science", "developerTools"])
        eq("every tech section has a distinct name",
           Set(TechCategory.allCases.map { $0.title }).count,
           TechCategory.allCases.count)
        let sampleSource = SourceID.tech("wired")
        let sample = RadarItem(id: "t1", source: sampleSource, kind: .news,
                               title: "AMD's next GPU doubles the memory bandwidth",
                               link: URL(string: "https://www.wired.com/story/x")!,
                               published: Date(), rawSummary: "", imageURL: nil,
                               author: nil, sourceCategories: [])
        eq("a tech story is classified", TechCatalogue.category(for: sample) == .hardware, true)
        // A commit on github.com is a developer story whatever its title says.
        let commit = RadarItem(id: "t2", source: SourceID.tech("hackernews"), kind: .news,
                               title: "mitmproxy adds --emudhra option",
                               link: URL(string: "https://github.com/mitmproxy/mitmproxy/commit/1")!,
                               published: Date(), rawSummary: "", imageURL: nil,
                               author: nil, sourceCategories: [])
        eq("a code host files a story under developer tools",
           TechCatalogue.category(for: commit) == .developerTools, true)
        // The tab is not the news tab: a tech publisher's stories are not in it.
        eq("tech publishers are not counted as news",
           BriefingSection.section(for: sampleSource) == .tech, true)
        // A tech story with no body gets no filler sentence.
        var bodyless = sample
        bodyless.techCategory = .hardware
        let rendered = Summarizer.render(bodyless, ollama: nil)
        eq("a tech story with no body gets no filler summary",
           rendered.summary.contains("has the full details"), false)
        eq("a tech story is summarised without a dangling article",
           rendered.summary.contains("A other"), false)
        // The badge shows a masthead rather than a domain name.
        eq("a tech badge shows the publisher's name",
           sampleSource.shortTitle, "WIRED")

        // Every source that reads a feed must have an HTTPS URL. Sources read by
        // page, API or not at all legitimately carry no feed URL.
        let badFeeds = SourceID.all.filter { s in
            guard s.spec.access == .rss else { return false }
            guard let f = s.spec.feedURL else { return true }
            return !f.hasPrefix("https://")
        }
        eq("every feed URL is https", badFeeds.map { $0.title }, [])

        // Creative Bloq served its feed through an http:// redirect, which App
        // Transport Security refuses at runtime; the direct https path is used.
        eq("creative bloq feed is https and direct",
           SourceID.creativeBloq.feedURL?.absoluteString,
           "https://www.creativebloq.com/feeds.xml")

        // The sources with no feed must say how they are read instead of
        // pretending to be RSS.
        for s in [SourceID.anthropicNews, .anthropicResearch, .huggingFaceModels] {
            ok("\(s.title) declares a non-RSS method",
               s.spec.access != .rss || s.spec.accessDescription != "RSS / Atom feed",
               s.accessDescription)
        }

        // App Transport Security refuses plain http, so a feed URL that redirects
        // to http fails at runtime even though the source looks configured. None
        // may be declared with an http scheme.
        let plainHTTP = SourceID.all.compactMap { $0.spec.feedURL }
            .filter { $0.hasPrefix("http://") }
        eq("no feed uses plain http", plainHTTP, [])

        // Item kinds drive the digest wording and the card layout.
        eq("product hunt is a product", SourceID.productHunt.spec.itemKind, .product)
        eq("show hn is a product", SourceID.showHN.spec.itemKind, .product)
        eq("hugging face models are products", SourceID.huggingFaceModels.spec.itemKind, .product)
        eq("tldr is a newsletter", SourceID.tldr.spec.itemKind, .newsletter)
        eq("anthropic news is news", SourceID.anthropicNews.spec.itemKind, .news)

        // The two new GitHub-backed sources do not count as repositories, so they
        // cannot leak into the GitHub & Code section.
        ok("hugging face models are not repos", SourceID.huggingFaceModels.kind != .github)
        ok("gitHub sources are repos", SourceID.gitHubTrending.kind == .github)

        // The gates: Hacker News keeps technology, drops everything else.
        ok("HN keeps an AI story",
           FeedSource.passesTechnicalGate(entry("Show HN: Local LLM on a MacBook with 16GB"),
                                          source: .hackerNews))
        ok("HN keeps a developer story",
           FeedSource.passesTechnicalGate(entry("A new Rust database engine, written in Zig"),
                                          source: .hackerNews))
        ok("HN drops a gardening story",
           !FeedSource.passesTechnicalGate(entry("My tomato plants are doing well this summer"),
                                           source: .hackerNews))
        ok("HN drops a political story",
           !FeedSource.passesTechnicalGate(entry("The mayor resigned after a long dispute"),
                                           source: .hackerNews))
        ok("word matching is not substring matching",
           !FeedSource.passesTechnicalGate(entry("She said the train was late again"),
                                           source: .hackerNews))

        // 9router is a second summary engine beside Ollama. Both must agree on
        // where their endpoints live, or a model id from one gets sent to the
        // other and the refresh silently degrades to the offline digest.
        ok("ollama default endpoint", SummaryEngine.ollama.defaultBaseURL.hasSuffix(":11434"))
        ok("9router default endpoint", SummaryEngine.router9.defaultBaseURL.hasSuffix("/v1"))
        ok("only 9router needs a key", SummaryEngine.router9.needsAPIKey
           && !SummaryEngine.ollama.needsAPIKey)

        // The engine tag is what a card shows, so it must name both service and
        // model, and must be distinct per engine.
        var o = OllamaConfig(); o.engine = .ollama; o.model = "qwen2.5:7b"
        var r = OllamaConfig(); r.engine = .router9; r.model = "openrouter/openrouter/free"
        r.apiKey = "sk-test"
        eq("ollama engine tag", o.engineTag, "ollama:qwen2.5:7b")
        eq("9router engine tag", r.engineTag, "9router:openrouter/openrouter/free")

        // A 9router config without a key is not usable, and must say so rather
        // than failing at request time.
        var noKey = r; noKey.apiKey = ""
        ok("a keyed 9router is configured", { var c = r; c.enabled = true; return c.isConfigured }())
        ok("9router needs a key to be configured", !noKey.isConfigured)
        var ollamaOn = o; ollamaOn.enabled = true
        ok("ollama needs no key", ollamaOn.isConfigured)

        // URL building must work for a base with and without the /v1 prefix, since
        // users paste either form from the gateway.
        eq("9router url with /v1",
           ModelClient.url("http://127.0.0.1:20128/v1", "v1/models")?.absoluteString,
           "http://127.0.0.1:20128/v1/models")
        eq("9router url without /v1",
           ModelClient.url("http://127.0.0.1:20128", "v1/models")?.absoluteString,
           "http://127.0.0.1:20128/v1/models")
        eq("url tolerates a trailing slash",
           ModelClient.url("http://127.0.0.1:11434/", "api/tags")?.absoluteString,
           "http://127.0.0.1:11434/api/tags")

        // A headline that already ends in a full stop must not produce ".." when
        // it is embedded in a briefing sentence.
        eq("sentence-safe strips a final full stop",
           Summarizer.sentenceSafe("Drops came from NVIDIA, of all companies."),
           "Drops came from NVIDIA, of all companies")
        eq("sentence-safe strips repeats",
           Summarizer.sentenceSafe("Really?"), "Really")
        eq("sentence-safe leaves internal stops",
           Summarizer.sentenceSafe("GPT-4.1 ships"), "GPT-4.1 ships")

        // The category chart must add up to the number the briefing quotes, so no
        // category may be dropped from it.
        let catItems = [
            Classifier.classify(makeItem(
                title: "A quantised model for llama.cpp",
                summary: "Run this GGUF model locally with llama.cpp on your Mac.")),
            Classifier.classify(makeItem(
                title: "An agent framework for tool use",
                summary: "An AI agent framework that plans and calls tools.")),
            Classifier.classify(makeItem(
                title: "Regulators publish AI rules",
                summary: "A policy story about regulation and compliance for AI."))
        ]
        let brief = Summarizer.localBriefing(items: catItems, now: Date(),
                                             previousDayTopIDs: [])
        eq("every category counted", brief.categoryCounts.count, 3)

        // A stored state file written before these settings existed must decode
        // with the documented defaults instead of throwing and losing bookmarks.
        let legacy = """
        {"bookmarkedIDs":["a"],"readIDs":["b"],"layout":"grid","lastRefresh":null}
        """
        if let data = legacy.data(using: .utf8),
           let st = try? JSONDecoder().decode(Store.State.self, from: data) {
            ok("legacy state keeps bookmarks", st.bookmarkedIDs.contains("a"))
            eq("legacy state defaults auto-check", st.autoCheckMinutes, 10)
            ok("legacy state defaults check-on-launch", st.checkOnLaunch)
            eq("legacy state defaults retention", st.retentionDays, 30)
            eq("legacy state defaults briefing size", st.briefingNewsCount, 6)
            eq("legacy state defaults list limit", st.listLimit, 300)
        } else {
            ok("legacy state decodes", false)
        }

        // A picker silently renders blank when its selection is not one of its
        // tags, so every label must exist and the stored value must be offered.
        eq("label for 0", AppModel.autoCheckLabel(0), "Off")
        eq("label for 1", AppModel.autoCheckLabel(1), "Every minute")
        eq("label for 10", AppModel.autoCheckLabel(10), "Every 10 minutes")
        eq("label for 60", AppModel.autoCheckLabel(60), "Every hour")
        eq("label for 180", AppModel.autoCheckLabel(180), "Every 3 hours")
        ok("non-standard interval still has a label",
           !AppModel.autoCheckLabel(7).isEmpty, AppModel.autoCheckLabel(7))

        // The cache key must be identical across processes, or the disk cache
        // never hits. String.hashValue is seeded per process; this must not be.
        eq("cache key is stable for a URL",
           HTTP.stableKey("https://example.com/feed.xml"),
           HTTP.stableKey("https://example.com/feed.xml"))
        eq("cache key is the documented FNV-1a value",
           HTTP.stableKey("a"), "af63dc4c8601ec8c")
        ok("different URLs get different keys",
           HTTP.stableKey("https://a.example/") != HTTP.stableKey("https://b.example/"))

        // A story named in "Top story" must not be named again two paragraphs later:
        // that repetition is what made the briefing read as a jumble.
        do {
            let now = Date()
            let same = (0..<4).map { i -> RadarItem in
                var it = makeItem(title: "Shared story \(i)", summary: "Body \(i)",
                                  published: now.addingTimeInterval(-3600))
                it.free = true; it.openSource = true
                it.localExecution = true; it.appleSilicon = true
                return it
            }
            let b = Summarizer.localBriefing(items: same, now: now, previousDayTopIDs: [])
            let all = b.paragraphs.joined(separator: " ")
            let repeats = (0..<4).filter { all.components(separatedBy: "Shared story \($0)").count > 2 }
            eq("a story is not repeated across paragraphs", repeats.count, 0)
        }

        // The two figures the card shows must be the two the prose quotes.
        do {
            let now = Date()
            let mixed = (0..<5).map { i in
                makeItem(title: "Figure story \(i)", summary: "Body \(i)",
                         published: now.addingTimeInterval(-3600))
            }
            let b = Summarizer.localBriefing(items: mixed, now: now, previousDayTopIDs: [])
            eq("the stored story count matches the sentence", b.newsCount, 5)
            ok("the sentence quotes the stored count",
               b.paragraphs.first?.contains("\(b.newsCount ?? -1) new") == true,
               b.paragraphs.first ?? "")
        }

        // A single publisher filtered in at a window it cannot fill is the reason
        // a working source looked broken. The measurement must be exact, and an
        // empty source must not be widened to all time behind the reader's back.
        do {
            let now = Date()
            let items = [
                makeItem(title: "Old one", summary: "b", published: now.addingTimeInterval(-50 * 3600)),
                makeItem(title: "Older one", summary: "b", published: now.addingTimeInterval(-9 * 24 * 3600)),
            ]
            let measured = Coverage.byRange(items, source: .techCrunch, now: now)
            eq("a source's numbers cover every window", measured.count, DateRange.allCases.count)
            eq("nothing is counted in 12 hours", measured.first { $0.range == .twelveHours }?.count, 0)
            eq("24h is still empty", measured.first { $0.range == .day }?.count, 0)
            eq("72h holds one", measured.first { $0.range == .threeDays }?.count, 1)
            eq("all time holds both", measured.first { $0.range == .all }?.count, 2)
            eq("the narrowest populated window is chosen",
               Coverage.narrowest(items, source: .techCrunch, now: now, fallback: .twelveHours),
               .threeDays)
            eq("an empty source keeps the fallback",
               Coverage.narrowest([], source: .mistral, now: now, fallback: .day), .day)
            // GitHub repositories are not news and must not be counted here.
            var repo = makeItem(title: "org/repo", summary: "b", published: now)
            repo.kind = .repository
            repo.source = .techCrunch
            repo.repo = RepoStats(fullName: "org/repo", htmlURL: URL(string: "https://github.com/org/repo")!, stars: 10)
            eq("repositories are not counted as stories",
               Coverage.byRange([repo], source: .techCrunch, now: now)
                .first { $0.range == .all }?.count, 0)
        }

        // A story title used inside a sentence is shortened, and the cut lands on
        // a word boundary: a feed title can be a whole paragraph.
        do {
            let long = String(repeating: "benchmarks of the engine ", count: 8)
            let cut = Summarizer.shortTitle(long, limit: 60)
            ok("a long title is shortened", cut.count <= 61, "\(cut.count)")
            ok("the shortened title ends in an ellipsis", cut.hasSuffix("…"), cut)
            ok("it does not end mid-word", !cut.hasSuffix(" …") && !cut.contains("  "), cut)
            eq("a short title is untouched", Summarizer.shortTitle("Short one", limit: 60), "Short one")
        }

        // "Other" is the classifier's remainder. A sentence that leads with it
        // says the biggest bucket was the one nothing landed in.
        do {
            let now = Date()
            let items = [makeItem(title: " text", summary: "prompt", published: now)]
            let b = Summarizer.localBriefing(items: items, now: now, previousDayTopIDs: [])
            let volume = b.paragraphs.first { $0.contains("volume") || $0.contains("did not fit") }
            ok("the volume sentence does not lead with Other",
               volume?.hasPrefix("Most of the volume was Other") != true,
               volume ?? "none")
        }

        // Labels are split for typography, but only a short opening clause counts.
        do {
            let split = DigestTab.splitLabel("Top story: A thing happened — TechCrunch.")
            eq("a label is recognised", split.label, "Top story")
            eq("its body survives", split.body, "A thing happened — TechCrunch.")
            let plain = DigestTab.splitLabel("The industry spent the day arguing about a "
                + "question that has no short answer: who pays for inference.")
            ok("a colon mid-sentence is not a label", plain.label == nil, plain.label ?? "nil")
        }

        // Paging is opt-in per source, because a publisher that ignores ?paged
        // returns page one again and would only double the fetching.
        do {
            eq("TechCrunch pages back", SourceID.techCrunch.spec.extraPages, 2)
            eq("Ars Technica pages back", SourceID.arsTechnica.spec.extraPages, 2)
            eq("MIT Technology Review pages back", SourceID.mitTechReview.spec.extraPages, 2)
            eq("a source that ignores ?paged asks for one page", SourceID.theVerge.spec.extraPages, 0)
            eq("the blog feed is not paged", SourceID.blogGoogle.spec.extraPages, 0)
        }

        // The briefing must state the window its first number covers, so the count
        // is not read as "today" when it is 36 hours.
        let bdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-window-\(UUID().uuidString)")
        do {
            let store = Store(directory: bdir)
            let now = Date()
            var it = makeItem(title: "Something shipped today",
                              summary: "A model was released for local use.")
            it.id = "w1"; it.published = now.addingTimeInterval(-3600)
            store.merge(newItems: [it], now: now, retentionDays: 0)
            let b = Summarizer.localBriefing(items: store.items, now: now,
                                             previousDayTopIDs: [])
            ok("briefing states its window",
               b.paragraphs.first?.contains("\(Int(Summarizer.hourWindow)) hours") == true,
               b.paragraphs.first ?? "")
            try? FileManager.default.removeItem(at: bdir)
        }

        // A briefing built with a different size must not be reused: changing the
        // highlights from 6 to 3 has to change what is on screen immediately.
        let sized = (0..<9).map { i -> RadarItem in
            var it = makeItem(title: "Headline number \(i)",
                              summary: "A short summary of story number \(i).")
            it.id = "sz\(i)"
            it.published = Date().addingTimeInterval(-Double(i) * 600)
            return it
        }
        let three = Summarizer.localBriefing(items: sized, now: Date(),
                                             previousDayTopIDs: [], newsPicks: 3)
        let six = Summarizer.localBriefing(items: sized, now: Date(),
                                           previousDayTopIDs: [], newsPicks: 6)
        eq("a briefing honours a smaller highlights count", three.highlightIDs.count, 3)
        eq("a briefing honours a larger highlights count", six.highlightIDs.count, 6)
        eq("a briefing honours a hidden GitHub block",
           Summarizer.localBriefing(items: sized, now: Date(), previousDayTopIDs: [],
                                    repoPicks: 0).repoPickIDs.count, 0)

        // The in-app reader must not read JavaScript as prose. This is the failure
        // that shipped once: `.` stops at a newline, multi-line <script> survived,
        // and 1,847 "words" of minified audio-player code were presented as an
        // article. The check drives the same extraction the reader uses.
        let page = """
        <html><head><title>Real Title | Site Name</title>
        <link rel="alternate" type="application/rss+xml" href="/feed.xml">
        </head><body>
        <script>
        function(a){var x=1;document.write("<p>not an article</p>");}
        </script>
        <nav><a href="/">Home</a><a href="/about">About</a></nav>
        <article>
        <h1>Real Title</h1>
        <p>This is the first paragraph of the article and it is long enough to be kept as prose by the extractor.</p>
        <p>This is the second paragraph, also long enough to survive, and it says something different from the first one.</p>
        <p>Cookie policy: this site uses cookies.</p>
        </article>
        <footer>All rights reserved.</footer>
        </body></html>
        """
        let extracted = ArticleReader.extract(html: page, url: URL(string: "https://example.com/story")!,
                                             fallbackTitle: "fallback")
        assert(extracted != nil, "the reader extracts an article from a page")
        if let a = extracted {
            let joined = a.paragraphs.joined(separator: " ")
            assert(!joined.contains("document.write"), "JavaScript is never article text")
            assert(!joined.contains("not an article"), "a <script> body is removed entirely")
            assert(!joined.contains("All rights reserved"), "the footer is not article text")
            assert(!joined.contains("cookies"), "a cookie line is furniture")
            assert(joined.contains("first paragraph"), "real prose is kept")
            eq("the title comes from <title>, not the body",
               a.title, "Real Title")
            assert(a.paragraphs.count == 2, "two real paragraphs after filtering, got \(a.paragraphs.count)")
        }

        // Inline images and links survive extraction. The reader used to return a
        // flat list of paragraphs, so a diagram mid-article vanished and every link
        // became plain words — the reader was a transcription, not the story.
        let rich = """
        <html><head><title>Rich story | Site</title></head><body>
        <article>
        <p>The opening paragraph is long enough to be kept as prose, and it mentions a
        real finding worth reading about in some detail for a while.</p>
        <figure><img src="/diagram.png" alt="How the system works"/>
          <figcaption>The pipeline, end to end.</figcaption></figure>
        <p>A second paragraph carries an <a href="https://example.com/source">inline
        citation</a> so the reader can follow the evidence without leaving the app.</p>
        </article></body></html>
        """
        if let rich = ArticleReader.extract(html: rich,
                                            url: URL(string: "https://site.test/story")!,
                                            fallbackTitle: "fallback") {
            let images = rich.blocks.compactMap { block -> URL? in
                if case .image(let u, _) = block { return u }
                return nil
            }
            eq("an inline image is kept", images.first?.absoluteString,
               "https://site.test/diagram.png")
            let captions = rich.blocks.compactMap { block -> String? in
                if case .image(_, let c) = block { return c }
                return nil
            }
            eq("the image caption is kept", captions.first, "The pipeline, end to end.")
            let linked = rich.blocks.compactMap { block -> [ArticleReader.Block.LinkRun]? in
                if case .linked(_, let runs, _) = block { return runs }
                return nil
            }
            eq("the inline link is kept", linked.first?.first?.url.absoluteString,
               "https://example.com/source")
            eq("the link keeps its words", linked.first?.first?.text, "inline citation")
            // Order matters: the image sits between the two paragraphs.
            var shape: [String] = []
            for block in rich.blocks {
                switch block {
                case .paragraph: shape.append("p")
                case .image: shape.append("img")
                case .linked: shape.append("p")
                }
            }
            eq("the body keeps page order", shape.joined(separator: ","), "p,img,p")
        } else {
            assert(false, "the rich page extracts")
        }

        // A tracking pixel is not an illustration.
        let pixelPage = """
        <html><body><article>
        <p>A paragraph long enough to matter, with enough words in it to survive the
        furniture filter and be counted as real prose by the extractor.</p>
        <img src="/beacon.gif" width="1" height="1"/>
        <p>Another paragraph, also long, so the article has more than one of them and
        the container scores above the threshold for a real body.</p>
        </article></body></html>
        """
        if let pixel = ArticleReader.extract(html: pixelPage,
                                             url: URL(string: "https://site.test/p")!,
                                             fallbackTitle: "t") {
            let hasPixel = pixel.blocks.contains { block in
                if case .image(let u, _) = block { return u.path.contains("beacon") }
                return false
            }
            assert(!hasPixel, "a 1x1 beacon is not an article image")
        }

        // A README becomes readable text, not markdown and not badge soup.
        let md = """
        # Awesome Project

        [![Build](https://img.shields.io/badge/build-passing.svg)](https://ci.test)

        A tool that does **one** thing well.

        ## Install

        ```bash
        brew install awesome
        ```

        - Fast
        - Small

        See [the docs](https://docs.test) for more.
        """
        let text = GitHubSource.markdownText(md)
        assert(!text.contains("```"), "code fences are removed")
        assert(!text.contains("img.shields.io"), "badges are removed")
        assert(!text.contains("](http"), "markdown links are unwrapped")
        assert(text.contains("the docs"), "the link words survive")
        assert(text.contains("Awesome Project"), "the title survives")
        assert(text.contains("Fast"), "list items survive")
        assert(!text.contains("**"), "emphasis markers are removed")
        assert(!text.contains("]("), "no link syntax survives")
        // A badge wrapped in a link must not leave "[ ](url)" as an empty bracket.
        let badges = "[![CI](https://x/b.svg)](https://ci.test)\n\nReal content."
        let cleaned = GitHubSource.markdownText(badges)
        assert(!cleaned.contains("[]"), "an empty badge link leaves no brackets: \(cleaned)")
        assert(cleaned.contains("Real content"), "the real text survives the badge")

        // --- A project must not advertise a reading mode it does not have.
        var project = RadarItem(id: "p1", source: SourceID(rawValue: "github-trending"),
                                kind: .repository, title: "owner/project",
                                link: URL(string: "https://github.com/owner/project")!,
                                published: Date(), rawSummary: "A project.",
                                imageURL: nil, author: nil, sourceCategories: [],
                                category: .coding,
                                repo: RepoStats(fullName: "owner/project",
                                                htmlURL: URL(string: "https://github.com/owner/project")!,
                                                stars: 10))
        project.summary = "A project."
        assert(project.isGitHub, "the fixture is a project")
        assert(ArticleReader.isAppPage(project.link), "a repository page is not a prose page")
        let article = RadarItem(id: "a1", source: SourceID(rawValue: "the-verge"), kind: .news,
                                title: "A story",
                                link: URL(string: "https://www.theverge.com/x")!,
                                published: Date(), rawSummary: "s",
                                imageURL: nil, author: nil, sourceCategories: [],
                                category: .llm)
        assert(!ArticleReader.isAppPage(article.link), "an article page is readable")

        // --- The body must not keep the page's furniture or a doubled picture.
        let richPage = """
        <article>
        <figure><img src="/a.png"/><figcaption>Fig one</figcaption></figure>
        <p>\(String(repeating: "This is a real sentence of the story. ", count: 4))</p>
        <img src="/a.png"/>
        <img src="/author_profile/jane.jpg"/>
        <p>Subscribe to the newsletter for details of our events.</p>
        <p>\(String(repeating: "And the story continues properly here. ", count: 4))</p>
        </article>
        """
        guard let read = ArticleReader.extract(html: richPage,
                                              url: URL(string: "https://x.test/a")!,
                                              fallbackTitle: "Fallback") else {
            return ok("the rich fixture reads at all", false)
        }
        let images = read.blocks.compactMap { b -> String? in
            if case .image(let u, _) = b { return u.lastPathComponent } else { return nil }
        }
        assert(images == ["a.png"], "the picture is drawn once and the headshot dropped: \(images)")
        let body = read.blocks.compactMap { b -> String? in
            switch b {
            case .paragraph(let t), .linked(let t, _, _): return t
            case .image: return nil
            }
        }.joined(separator: " ")
        assert(!body.lowercased().contains("subscribe to the newsletter"),
               "the sign-up line is not part of the story")

        // A section front and a feed are refused as articles: both are lists, and
        // reading one yields unrelated teasers joined into fake prose.
        let teasers = (1...8).map { "Teaser number \($0) is a short summary of one story." }
        assert(ArticleReader.listingReason(url: URL(string: "https://site.test/ai/")!,
                                           title: "Category: AI", paragraphs: teasers) != nil,
               "a category front is a listing")
        assert(ArticleReader.listingReason(url: URL(string: "https://site.test/feed/")!,
                                           title: "The Decoder", paragraphs: teasers) != nil,
               "a feed URL is a listing")
        assert(ArticleReader.listingReason(
            url: URL(string: "https://site.test/story")!, title: "A real story",
            paragraphs: (1...4).map { _ in String(repeating: "word ", count: 60) }) == nil,
           "a real article is not a listing")

        // A repository or forum page is never read as an article: extracting one
        // produced a file listing presented as prose.
        assert(ArticleReader.isAppPage(URL(string: "https://github.com/foo/bar")!),
               "a GitHub repository is an app page")
        assert(ArticleReader.isAppPage(URL(string: "https://news.ycombinator.com/item?id=1")!),
               "a forum thread is an app page")
        assert(ArticleReader.isAppPage(URL(string: "https://huggingface.co/models")!),
               "a model listing is an app page")
        assert(!ArticleReader.isAppPage(URL(string: "https://huggingface.co/blog/x")!),
               "a Hugging Face blog post is still readable")
        assert(!ArticleReader.isAppPage(URL(string: "https://arstechnica.com/ai/some-story")!),
               "an article page is readable")

        // A page that advertises its feed must yield that feed's URL.
        let alt = SourceValidator.advertisedFeeds(in: page,
                                                  base: URL(string: "https://example.com/story")!)
        eq("the advertised feed is found", alt?.first?.absoluteString,
           "https://example.com/feed.xml")

        // An address that is not a URL is refused in words, not with a code.
        if case .unreachable(let why) = SourceValidator.validate(urlString: "not a url", title: nil) {
            assert(why.contains("https://"), "a malformed address explains itself: \(why)")
        } else {
            assert(false, "a malformed address is refused")
        }

        // A feed that is already configured must not be added twice.
        let dupe = CustomSource(id: "x", title: "Existing", feedURL: "https://example.com/feed.xml",
                                homeURL: "https://example.com/", host: "example.com",
                                addedAt: Date())
        SourceRegistry.shared.replaceAll([dupe])
        let again = SourceRegistry.shared.add(CustomSource(id: "y", title: "Copy",
                                                           feedURL: "https://example.com/feed.xml",
                                                           homeURL: "https://example.com/",
                                                           host: "example.com", addedAt: Date()))
        assert(!again, "the same feed is never added twice")
        eq("the registry keeps one copy", SourceRegistry.shared.all.count, 1)
        SourceRegistry.shared.replaceAll([])

        // The retry policy: transient failures are retried, refusals are not.
        var transient = SourceStatus(source: .openAINews)
        transient.ok = false
        transient.message = "The request timed out. The source was too slow to answer."
        assert(transient.failedRetryably, "a timeout is worth retrying")

        var refused = SourceStatus(source: .openAINews)
        refused.ok = false
        refused.message = HTTP.explain(HTTP.HTTPError.badStatus(403))
        assert(!refused.failedRetryably, "a 403 is not worth retrying")

        var gone = SourceStatus(source: .openAINews)
        gone.ok = false
        gone.message = HTTP.explain(HTTP.HTTPError.badStatus(404))
        assert(!gone.failedRetryably, "a 404 is not worth retrying")

        var healthy = SourceStatus(source: .openAINews)
        healthy.ok = true
        assert(!healthy.failedRetryably, "a source that answered is not retried")

        // The guard in fetchOne must ask "did it fail, and is it retryable?". It
        // once asked "is it NOT retryable", which refetched every healthy source and
        // never retried a failing one.
        assert(RefreshEngine.shouldRetry(transient), "a transient failure is retried")
        assert(!RefreshEngine.shouldRetry(refused), "a refusal is not retried")
        assert(!RefreshEngine.shouldRetry(healthy), "a success is not retried")
        // The status is what decides, so the message text stays the only input.
        var rateLimited = SourceStatus(source: .openAINews)
        rateLimited.message = HTTP.explain(HTTP.HTTPError.badStatus(429))
        assert(RefreshEngine.shouldRetry(rateLimited), "a 429 is retried")

        // A first attempt that succeeded is not retried at all.
        var firstOk = SourceStatus(source: .openAINews)
        firstOk.ok = true
        assert(!firstOk.failedRetryably, "a healthy source is left alone")

        // A failing source must explain itself in words. Bare status codes are
        // what made "a source is not connecting" unanswerable.
        let blocked = HTTP.explain(HTTP.HTTPError.badStatus(403))
        assert(blocked.localizedCaseInsensitiveContains("refuses automated"),
               "403 explains itself: \(blocked)")
        let missing = HTTP.explain(HTTP.HTTPError.badStatus(404))
        assert(missing.localizedCaseInsensitiveContains("does not exist"),
               "404 explains itself: \(missing)")
        assert(HTTP.explain(HTTP.HTTPError.badStatus(429)).localizedCaseInsensitiveContains("Rate limited"),
               "429 explains itself")
        assert(HTTP.explain(HTTP.HTTPError.empty).localizedCaseInsensitiveContains("no content"),
               "an empty body explains itself")
        assert(!HTTP.explain(HTTP.HTTPError.badStatus(403)).contains("403 instead of"),
               "the explanation replaces the bare code rather than repeating it")

        // The sort order has to be stored. It used to live only in memory, so the
        // lists silently went back to "Most relevant" on every launch.
        let odir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-sort-\(UUID().uuidString)")
        let o1 = Store(directory: odir)
        o1.updateState { $0.sort = .oldest }
        eq("sort order is written to disk", Store(directory: odir).state.sort, .oldest)

        // Settings must survive a relaunch: a write applies to the file as it is
        // now, not to a snapshot taken at launch.
        let sdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-state-\(UUID().uuidString)")
        let s1 = Store(directory: sdir)
        s1.updateState { $0.layout = .compact; $0.retentionDays = 7 }
        // A second store instance stands in for a second window or a second copy
        // of the app, which is what used to clobber newer settings.
        let s2 = Store(directory: sdir)
        s2.updateState { $0.briefingNewsCount = 9 }
        let reread = Store(directory: sdir)
        eq("settings from one writer survive another writer's save",
           reread.state.layout, .compact)
        eq("a second writer does not lose the first writer's retention",
           reread.state.retentionDays, 7)
        eq("a second writer's own setting is kept", reread.state.briefingNewsCount, 9)

        // Every build must move the version, so two builds are never confusable.
        assert(!AppVersion.marketing.isEmpty, "a marketing version is present")
        // Two components, one step per build: "1.6", never "1.2.136". A third
        // component is what made the version read as a counter rather than a release.
        eq("the version is major.minor", AppVersion.marketing.split(separator: ".").count, 2)
        // The number and the notes must describe the same release. They drifted
        // once: the counter said 1.10 while the list stopped at 1.7.
        eq("the changelog is headed by the running version",
           AppVersion.changelog.first?.0, AppVersion.marketing)
        eq("no release appears twice",
           Set(AppVersion.changelog.map { $0.0 }).count, AppVersion.changelog.count)
        ok("the running version has notes", !AppVersion.releaseNotes.isEmpty,
           "\(AppVersion.releaseNotes.count) notes")
        ok("no note is a placeholder",
           !AppVersion.releaseNotes.contains { $0.contains("no notes filed") },
           AppVersion.releaseNotes.first ?? "")
        // A two-digit minor reads as a third component: 1.9 → 2.0, never 1.10.
        let minor = Int(AppVersion.marketing.split(separator: ".").last ?? "0") ?? 0
        ok("the minor number stays a single digit", minor < 10, "\(minor)")
        assert(AppVersion.changelog.first?.0 == AppVersion.marketing,
               "the notes are labelled with the version that is running")

        // The list cap must never look like data loss: the header has to be able
        // to say how many rows it is hiding.
        let cdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-cap-\(UUID().uuidString)")
        do {
            let store = Store(directory: cdir)
            let now = Date()
            let items = (0..<12).map { i -> RadarItem in
                var it = makeItem(title: "Story number \(i)",
                                  summary: "A summary for story number \(i).")
                it.id = "cap\(i)"
                it.published = now.addingTimeInterval(-Double(i) * 60)
                return it
            }
            store.merge(newItems: items, now: now, retentionDays: 0)
            // The cap itself is a property of the model, which needs a main-actor
            // context; the store-level check is that all twelve survive.
            eq("a capped list still stores every row", store.items.count, 12)
            try? FileManager.default.removeItem(at: cdir)
        }

        // The status line must describe what a check did, not leave the user to
        // infer it from a raw number.
        var chk = RefreshEngine.Outcome()
        chk.fetched = 2000; chk.okSources = 24; chk.newItems = 0
        chk.unchangedSources = 24; chk.checkedSources = 24
        eq("an all-unchanged check says nothing is new", chk.summary,
           "No new stories since the last check")
        chk.newItems = 7
        ok("a check with new stories mentions them", chk.summary.contains("7 new"), chk.summary)

        // "new" must describe what the archive gained, not what was fetched: a
        // 7-day window dropping old stories must not report them as new.
        let ndir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-newcount-\(UUID().uuidString)")
        do {
            let store = Store(directory: ndir)
            store.updateState { $0.retentionDays = 7 }
            let now = Date()
            func made(_ id: String, daysAgo: Double) -> RadarItem {
                var it = makeItem(title: "Story \(id)", summary: "Summary for \(id).")
                it.id = id
                it.published = now.addingTimeInterval(-daysAgo * 86400)
                return it
            }
            var prepared = RefreshEngine.Prepared()
            prepared.items = [made("inside", daysAgo: 1), made("outside", daysAgo: 300)]
            prepared.fetched = 2
            let outcome = RefreshEngine.apply(prepared, ollama: OllamaConfig(),
                                              to: store, now: now)
            eq("only stories inside the window count as new", outcome.newItems, 1)
            eq("only the story inside the window is stored", store.items.count, 1)
            try? FileManager.default.removeItem(at: ndir)
        }

        // Retention: 0 means keep everything, and a positive value must actually
        // drop older stories rather than being ignored.
        let rdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-retention-\(UUID().uuidString)")
        do {
            let store = Store(directory: rdir)
            let now = Date()
            func item(_ id: String, daysAgo: Double) -> RadarItem {
                var it = makeItem(title: "Story \(id)", summary: "A summary of \(id).")
                it.id = id
                it.published = now.addingTimeInterval(-daysAgo * 86400)
                return it
            }
            store.merge(newItems: [item("old", daysAgo: 40), item("new", daysAgo: 1)],
                        now: now, retentionDays: 7)
            eq("retention drops stories older than the window",
               Set(store.items.map(\.id)), ["new"])

            store.merge(newItems: [item("older", daysAgo: 400), item("fresh", daysAgo: 0)],
                        now: now, retentionDays: 0)
            ok("retention 0 keeps everything", store.items.count >= 2,
               "\(store.items.count) stored")

            store.updateState { $0.retentionDays = 7 }
            let removed = store.pruneOlderThanRetention(now: now)
            ok("manual prune removes old stories", removed > 0, "removed \(removed)")
            ok("manual prune keeps recent stories",
               store.items.contains { $0.id == "fresh" })
            try? FileManager.default.removeItem(at: rdir)
        }

        // A publisher that posts twice a month must not be erased by a window
        // written for the news firehose: its status stays green while its list
        // reads empty, which looks like a broken source.
        let spdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-slowpublisher-\(UUID().uuidString)")
        do {
            let store = Store(directory: spdir)
            let now = Date()
            var slow = makeItem(title: "A slow publisher's only story",
                                summary: "One story, published last month.")
            slow.id = "slow"
            slow.source = SourceID(rawValue: "test.example/slow")
            slow.published = now.addingTimeInterval(-30 * 86400)
            var busy = makeItem(title: "A busy publisher's fresh story",
                                summary: "Published today.")
            busy.id = "busy"
            busy.source = SourceID(rawValue: "test.example/busy")
            busy.published = now.addingTimeInterval(-3600)
            var stale = makeItem(title: "A publisher that stopped two years ago",
                                 summary: "Nothing since.")
            stale.id = "stale"
            stale.source = SourceID(rawValue: "test.example/stale")
            stale.published = now.addingTimeInterval(-700 * 86400)

            store.merge(newItems: [slow, busy, stale], now: now, retentionDays: 7)
            let kept: Set<String> = Set(store.items.map { $0.id })
            ok("a slow publisher keeps its newest story", kept.contains("slow"), "\(kept)")
            ok("a busy publisher keeps only the window", kept.contains("busy"), "\(kept)")
            ok("a publisher silent for years is dropped", !kept.contains("stale"), "\(kept)")
            try? FileManager.default.removeItem(at: spdir)
        }

        // A merge must never wipe what is stored: that was the complaint that
        // reopening the app lost the archive.
        let mdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("newsradar-merge-\(UUID().uuidString)")
        do {
            let store = Store(directory: mdir)
            let now = Date()
            var keep = makeItem(title: "Kept story", summary: "A kept story summary.")
            keep.id = "keep"
            keep.published = now.addingTimeInterval(-3600)
            store.merge(newItems: [keep], now: now, retentionDays: 30)
            let before = store.items.count
            store.merge(newItems: [], now: now, retentionDays: 30)
            eq("an empty check keeps the archive", store.items.count, before)
            ok("the kept story survives", store.items.contains { $0.id == "keep" })
            try? FileManager.default.removeItem(at: mdir)
        }

        // The engine badge must name the service that actually ran. Before this,
        // only an "ollama:" prefix was recognised, so a 9router summary was
        // labelled "Offline digest" on the briefing and blank on a card.
        let local = EngineLabel.describe("local")
        eq("digest label", local.title, "Offline digest")
        ok("digest is not a model", !local.isModel)
        let r9 = EngineLabel.describe("9router:oc/deepseek-v4.1-flash-free")
        ok("9router label names the service", r9.title.hasPrefix("9router: "), r9.title)
        ok("9router label is a model", r9.isModel)
        ok("9router label is not an offline digest", r9.title != "Offline digest")
        let ol = EngineLabel.describe("ollama:qwen2.5:7b")
        ok("ollama label keeps the model name", ol.title.contains("qwen2.5:7b"), ol.title)
        ok("source label is not a model", !EngineLabel.describe("source").isModel)

        // Hacker News describes every item with the same scaffolding, which must
        // never be shown as a summary.
        let hnRaw = "Article URL: https://mediationbench.com/  Comments URL: "
            + "https://news.ycombinator.com/item?id=50159226  Points: 1  # Comments: 0"
        eq("HN boilerplate stripped", FeedSource.stripHNBoilerplate(hnRaw), "")
        eq("HN comments-only body stripped", FeedSource.stripHNBoilerplate("Comments"), "")
        let hnReal = "Article URL: https://x.com/y  Points: 12  A benchmark suite for "
            + "testing AI mediators across 62 simulated scenarios in practice."
        ok("HN keeps the real description",
           FeedSource.stripHNBoilerplate(hnReal).hasPrefix("A benchmark suite"),
           FeedSource.stripHNBoilerplate(hnReal))

        // OpenAI's feed carries every post; only research-tagged ones pass.
        ok("research category kept",
           FeedSource.isResearchEntry(researchEntry("Research", "A new result")))
        ok("publication category kept",
           FeedSource.isResearchEntry(researchEntry("Publication", "A paper")))
        ok("product post is not research",
           !FeedSource.isResearchEntry(researchEntry("Product", "A new button")))
        ok("company post is not research",
           !FeedSource.isResearchEntry(researchEntry("Company", "An announcement")))

        // The Anthropic listing parser, against the markup the site actually
        // serves today: one <article> card per story, the date in the card header,
        // and the anchor wrapping the headline and summary.
        let listing = """
        <main>
        <article class="tile"><header><p><a href="/news/announcements">Announcements</a></p>
          <time>Oct 18, 2026</time></header>
          <a class="tileLink" href="/news/public-benefit-fund">
            <h3 class="tileTitle">Investing in the public benefit</h3>
            <p class="summary">A long-term fund for the people building with our models.</p>
          </a></article>
        <article class="tile"><header><p><a href="/news/policy">Policy</a></p>
          <time>Oct 14, 2026</time></header>
          <a class="tileLink" href="/news/2026-us-midterms">
            <h3 class="tileTitle">Preparing for the 2026 US midterms</h3>
          </a></article>
        <article class="tile"><a href="/news"><h3>All news</h3></a></article>
        </main>
        """
        let parsed = AltSource.parseAnthropicListing(listing,
                                                     base: URL(string: "https://www.anthropic.com/news")!,
                                                     isResearch: false)
        eq("anthropic rows parsed", parsed.count, 2)
        eq("anthropic title read", parsed.first?.title, "Investing in the public benefit")
        eq("anthropic link resolved", parsed.first?.link?.absoluteString,
           "https://www.anthropic.com/news/public-benefit-fund")
        ok("anthropic summary read", parsed.first?.summaryHTML.contains("long-term fund") == true,
           parsed.first?.summaryHTML ?? "nil")
        ok("anthropic date read", parsed.first?.published != nil,
           parsed.first?.published.map { "\($0)" } ?? "nil")
        ok("undated row dropped", !parsed.contains { $0.title == "All news" })

        // A listing page may print its links in the short form it was
        // written with, and the date beside the card is then only found when
        // that short form is searched too.
        let shortLinkListing = """
        <article><a href="/news/the-entrepreneur-effect"><img src="a.png"/></a>
          <p><span>Insights</span><span>October 13, 2026</span></p>
          <h2><a href="/news/the-entrepreneur-effect">The Entrepreneur Effect</a></h2>
        </article>
        """
        let shortParsed = AltSource.parseListing(
            shortLinkListing, base: URL(string: "https://www.shopify.com/news")!,
            pathPrefix: "/news/")
        eq("a short link is found", shortParsed.count, 1)
        let shortDate = shortParsed.first?.published
        var shopifyGregorian = Calendar(identifier: .gregorian)
        shopifyGregorian.timeZone = TimeZone(identifier: "UTC") ?? shopifyGregorian.timeZone
        let shortParts = shortDate.map {
            shopifyGregorian.dateComponents([.year, .month, .day], from: $0)
        }
        ok("the date beside a short link is read",
           shortParts?.year == 2026 && shortParts?.month == 10 && shortParts?.day == 13,
           "\(shortParts.map { "\($0.year ?? -1)-\($0.month ?? -1)-\($0.day ?? -1)" } ?? "nil")")

        // A listing page groups its cards by day, and the date printed at the
        // top of a group belongs to the first card of that group, not to the
        // one next to it. The date nearest the link is the one that belongs to
        // it; the first date in the window is the date of the card above.
        let datedListing = """
        <div class="post"><span class="date">October 21, 2026</span>
          <a class="postlink" href="https://example.com/news/first-story">
            <h3>The first story of the day</h3></a>
          <p>Something about the first story.</p></div>
        <div class="post"><span class="date">October 15, 2026</span>
          <a class="postlink" href="https://example.com/news/older-story">
            <h3>A story from last week</h3></a>
          <p>Something about the older story.</p></div>
        """
        let datedParsed = AltSource.parseListing(
            datedListing, base: URL(string: "https://example.com/news")!,
            pathPrefix: "/news/")
        eq("listing rows parsed", datedParsed.count, 2)
        let firstDate = datedParsed.first?.published
        let secondDate = datedParsed.dropFirst().first?.published
        ok("the nearest date belongs to the story",
           firstDate != nil && secondDate != nil && firstDate! > secondDate!,
           "\(firstDate?.description ?? "nil") vs \(secondDate?.description ?? "nil")")

        // The research listing puts the anchor *inside* the heading instead:
        // <h3><a href=…>Title</a></h3>, so both shapes must be read.
        let researchListing = """
        <article class="card"><figure><img src="/x.png"/></figure>
          <div class="meta"><h3 class="metaTitle">
            <a class="metaTitleLink" href="/research/ai-expectations-gap">The AI expectations gap</a>
          </h3></div><time>Oct 16, 2026</time></article>
        """
        let researchParsed = AltSource.parseAnthropicListing(
            researchListing, base: URL(string: "https://www.anthropic.com/research")!,
            isResearch: true)
        eq("research row parsed", researchParsed.count, 1)
        eq("research title", researchParsed.first?.title, "The AI expectations gap")
        eq("news parser rejects research rows",
           AltSource.parseAnthropicListing(researchListing,
                                           base: URL(string: "https://www.anthropic.com/research")!,
                                           isResearch: false).count, 0)

        // A Hugging Face model becomes one item, not a list of files.
        let model = AltSource.HFModel(id: "deepseek-ai/DeepSeek-V4", likes: 1200,
                                      downloads: 50_000, trendingScore: 900,
                                      pipeline_tag: "text-generation",
                                      library_name: "transformers",
                                      tags: ["license:mit", "gguf", "region:us"],
                                      createdAt: "2026-10-17T02:40:38.000Z")
        guard let item = AltSource.modelItem(model, now: Date()) else {
            ok("hugging face model item", false, "modelItem returned nil")
            return
        }
        ok("model item is a product", item.kind == .product)
        eq("model link", item.link.absoluteString, "https://huggingface.co/deepseek-ai/DeepSeek-V4")
        ok("model summary states likes", item.rawSummary.contains("1,200 likes"), item.rawSummary)
        ok("model summary states licence", item.rawSummary.contains("Licence: mit"), item.rawSummary)
        ok("model summary names the task", item.rawSummary.contains("text generation"), item.rawSummary)

        // "local" in an unrelated sense must not be read as local inference: an
        // NVIDIA product release was labelled "Runs locally on this Mac".
        let pressRelease = Classifier.classify(makeItem(
            title: "RTX Spark ignites global celebration as new Windows PCs arrive",
            summary: "Local retailers and partners celebrate the launch of new laptops "
                + "with up to 128GB of unified memory, starting at $2,399."))
        ok("local celebration is not local inference", !pressRelease.localExecution,
           "local=\(pressRelease.localExecution)")
        let realLocal = Classifier.classify(makeItem(
            title: "Run Llama 3 locally with llama.cpp",
            summary: "A guide to local inference on your Mac, fully offline."))
        ok("real local inference is detected", realLocal.localExecution,
           "local=\(realLocal.localExecution)")

        // Cross-source duplicates: an aggregator's copy loses to the publisher's.
        let publisher = Classifier.classify(makeItem(
            title: "Meta ships a new model", summary: "A story published by the publisher itself today.",
            source: .techCrunch, link: "https://techcrunch.com/2026/10/19/meta-model/"))
        let aggregator = Classifier.classify(makeItem(
            title: "Meta ships a new model", summary: "Short blurb.",
            source: .hackerNews, link: "https://techcrunch.com/2026/10/19/meta-model/?utm_source=hn"))
        let deduped = RefreshEngine.dedupeAcrossSources([aggregator, publisher])
        eq("duplicate collapsed", deduped.count, 1)
        eq("publisher copy kept", deduped.first?.source, .techCrunch)
        let different = Classifier.classify(makeItem(
            title: "Another story", summary: "A different article entirely, on another topic.",
            source: .techCrunch, link: "https://techcrunch.com/2026/10/19/other/"))
        eq("distinct links survive",
           RefreshEngine.dedupeAcrossSources([publisher, different]).count, 2)
    }

    private static func entry(_ title: String, summary: String = "") -> RawFeedEntry {
        var e = RawFeedEntry()
        e.title = title
        e.summaryHTML = summary
        e.guid = title
        e.link = URL(string: "https://example.com/\(title.count)")
        return e
    }

    private static func researchEntry(_ category: String, _ title: String) -> RawFeedEntry {
        var e = entry(title)
        e.categories = [category]
        return e
    }

    // MARK: - Fixture helper

    private static func makeItem(title: String, summary: String,
                                 published: Date = Date(),
                                 source: SourceID = .techCrunch,
                                 link: String? = nil) -> RadarItem {
        RadarItem(id: "test::" + title, source: source, kind: .news, title: title,
                  link: URL(string: link ?? "https://example.com/\(abs(title.hashValue))")!,
                  published: published, rawSummary: summary, imageURL: nil,
                  author: nil, sourceCategories: [])
    }
}

// MARK: - Character helpers

private extension Character {
    /// True for Arabic-script letters, used to assert the UI text is English.
    var isArabicLetter: Bool {
        unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }
}
