import Foundation

// MARK: - Sources

enum SourceKind: String, Codable, Hashable {
    case feed
    case github
}

/// How a source's items are collected. Most sources publish RSS/Atom, but two
/// publishers deliberately expose no feed, and one community page blocks feed
/// readers, so each has a documented alternative.
enum SourceAccess: String, Codable, Hashable {
    /// RSS or Atom document.
    case rss
    /// Wiki page listing new repositories.
    case githubPage
    /// A JSON API (Hugging Face models, sitemap-derived lists).
    case api
    /// A sitemap used to discover new article URLs.
    case sitemap
    /// A community JSON API (Reddit).
    case communityAPI
}

/// One configured source. Specs live in `SourceID.spec` so every per-source
/// switch in the app reads from a single table instead of 28 parallel switches.
struct SourceSpec {
    var title: String
    var host: String
    var homeURL: String
    var feedURL: String?
    var access: SourceAccess
    var symbol: String
    var accentHex: String
    var kind: SourceKind = .feed
    /// Default item kind, used for classification and the digest wording.
    var itemKind: ItemKind = .news
    /// Shown in the sources panel so the collection method is never a secret.
    var accessDescription: String?
    /// Extra gate applied to entries from this source, e.g. Hacker News only
    /// passes stories that are actually about technology the app covers.
    var filter: SourceFilter = .none
    /// How many further pages of the same feed to read.
    ///
    /// Most publishers put twenty entries in their feed and stop; that is their
    /// choice, not a bug here. A few serve an older page for a page parameter —
    /// verified against each live site before being set, because a parameter
    /// that is quietly ignored returns page one again and only doubles the work.
    var extraPages: Int = 0
    /// The query parameter that asks for an older page.
    ///
    /// There is no convention: TechCrunch and MIT Technology Review answer
    /// `?paged=N`, WIRED and The Register answer `?page=N`, and the rest ignore
    /// both. It is declared per source because it was checked per source —
    /// a guessed parameter returns page one again and only doubles the work.
    var pageParameter: String = "paged"
}

/// Per-source relevance gates. A source can publish everything, but the radar
/// only keeps what it covers.
enum SourceFilter: String, Codable, Hashable {
    case none
    /// Keep only stories matching the AI / developer / open-source vocabulary.
    case technical
    /// Keep only entries the publication filed as research, as OpenAI does with
    /// its own category tags.
    case researchOnly
}
/// A source identity.
///
/// This is a struct rather than an enum so that a source the user adds from
/// inside the app is a first-class source: the same lists, the same cards, the
/// same status rows. Every built-in source is still a `static let`, so the
/// existing `switch self { case .openAINews: … }` code keeps working verbatim,
/// and `allCasesOrdered` is the list the app iterates.
struct SourceID: RawRepresentable, Hashable, Codable, Identifiable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    // Built-in sources. Their raw values are host-like strings, because that is
    // how they were already stored in bookmarks, history and settings.
    static let blogGoogle = SourceID(rawValue: "blog.google")
    static let techCrunch = SourceID(rawValue: "techcrunch.com/category/artificial-intelligence")
    static let tldr = SourceID(rawValue: "tldr.tech")
    static let theVerge = SourceID(rawValue: "theverge.com/ai-artificial-intelligence")
    static let productHunt = SourceID(rawValue: "producthunt.com")
    static let gitHubTrending = SourceID(rawValue: "github.com/trending")
    static let gitHubExplore = SourceID(rawValue: "github.com/explore")

    // Added sources.
    static let huggingFaceBlog = SourceID(rawValue: "huggingface.co/blog")
    static let huggingFaceModels = SourceID(rawValue: "huggingface.co/models")
    static let openAINews = SourceID(rawValue: "openai.com/news")
    static let openAIResearch = SourceID(rawValue: "openai.com/research")
    static let anthropicNews = SourceID(rawValue: "anthropic.com/news")
    static let anthropicResearch = SourceID(rawValue: "anthropic.com/research")
    static let deepMind = SourceID(rawValue: "deepmind.google/blog")
    static let hackerNews = SourceID(rawValue: "news.ycombinator.com")
    static let showHN = SourceID(rawValue: "news.ycombinator.com/show")
    static let arsTechnica = SourceID(rawValue: "arstechnica.com/ai")
    static let mitTechReview = SourceID(rawValue: "technologyreview.com")
    static let nvidia = SourceID(rawValue: "nvidianews.nvidia.com")
    static let mistral = SourceID(rawValue: "mistral.ai/news")
    static let simonWillison = SourceID(rawValue: "simonwillison.net")
    static let localLLaMA = SourceID(rawValue: "reddit.com/r/LocalLLaMA")
    static let creativeBloq = SourceID(rawValue: "creativebloq.com")
    static let itsNiceThat = SourceID(rawValue: "itsnicethat.com")

    /// A source in the Design & Web Intelligence tab. Raw value is
    /// `design:<id>`; the spec is read from the catalogue so the tab has one
    /// list of sources rather than a second table to keep in sync.
    static func design(_ id: String) -> SourceID { SourceID(rawValue: "design:\(id)") }

    var isDesign: Bool { rawValue.hasPrefix("design:") }

    /// A source in the Tech News tab. Raw value is `tech:<id>`, the same shape
    /// as a design source, so the tab's publishers live in one catalogue rather
    /// than a second table to keep in sync.
    static func tech(_ id: String) -> SourceID { SourceID(rawValue: "tech:\(id)") }

    var isTech: Bool { rawValue.hasPrefix("tech:") }

    /// A source the user added. Raw value is `custom:<uuid>`.
    static func custom(_ uuid: String) -> SourceID { SourceID(rawValue: "custom:\(uuid)") }

    var isCustom: Bool { rawValue.hasPrefix("custom:") }
    var id: String { rawValue }

    /// The single table every other property derives from.
    var spec: SourceSpec {
        switch self {
        // MARK: Existing
        case .blogGoogle:
            return SourceSpec(title: "Google AI Blog", host: "blog.google",
                              homeURL: "https://blog.google/technology/ai/",
                              feedURL: "https://blog.google/technology/ai/rss/",
                              access: .rss, symbol: "g.circle.fill", accentHex: "#5B7FA8")
        case .techCrunch:
            return SourceSpec(title: "TechCrunch AI", host: "techcrunch.com",
                              homeURL: "https://techcrunch.com/category/artificial-intelligence/",
                              feedURL: "https://techcrunch.com/category/artificial-intelligence/feed/",
                              access: .rss, symbol: "chart.line.uptrend.xyaxis", accentHex: "#4E7F4A",
                              extraPages: 2)
        case .tldr:
            return SourceSpec(title: "TLDR", host: "tldr.tech",
                              homeURL: "https://tldr.tech/",
                              feedURL: "https://tldr.tech/api/rss/tech",
                              access: .rss, symbol: "text.badge.checkmark", accentHex: "#A8563C",
                              itemKind: .newsletter)
        case .theVerge:
            return SourceSpec(title: "The Verge AI", host: "theverge.com",
                              homeURL: "https://www.theverge.com/ai-artificial-intelligence",
                              feedURL: "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml",
                              access: .rss, symbol: "v.circle.fill", accentHex: "#A34733")
        case .productHunt:
            return SourceSpec(title: "Product Hunt", host: "producthunt.com",
                              homeURL: "https://www.producthunt.com/",
                              feedURL: "https://www.producthunt.com/feed",
                              access: .rss, symbol: "p.circle.fill", accentHex: "#9E4C32",
                              itemKind: .product)
        case .gitHubTrending:
            return SourceSpec(title: "GitHub Trending", host: "github.com/trending",
                              homeURL: "https://github.com/trending",
                              feedURL: nil, access: .githubPage,
                              symbol: "chart.bar.fill", accentHex: "#8C3A46",
                              kind: .github, itemKind: .repository,
                              accessDescription: "Trending page HTML")
        case .gitHubExplore:
            return SourceSpec(title: "GitHub Explore", host: "github.com/explore",
                              homeURL: "https://github.com/explore",
                              feedURL: nil, access: .githubPage,
                              symbol: "safari.fill", accentHex: "#4F6C8F",
                              kind: .github, itemKind: .repository,
                              accessDescription: "Web page + GitHub REST API")

        // MARK: Hugging Face
        case .huggingFaceBlog:
            return SourceSpec(title: "Hugging Face Blog", host: "huggingface.co",
                              homeURL: "https://huggingface.co/blog",
                              feedURL: "https://huggingface.co/blog/feed.xml",
                              access: .rss, symbol: "face.smiling", accentHex: "#B08A3A")
        case .huggingFaceModels:
            // Model cards are not articles: the API returns one item per notable
            // new model release, filtered by trending score so the feed is not a
            // list of every upload.
            return SourceSpec(title: "Hugging Face Models", host: "huggingface.co/models",
                              homeURL: "https://huggingface.co/models",
                              feedURL: nil, access: .api,
                              symbol: "cube.box", accentHex: "#9A6B32",
                              itemKind: .product,
                              accessDescription: "Hugging Face models API")

        // MARK: OpenAI
        case .openAINews:
            return SourceSpec(title: "OpenAI News", host: "openai.com/news",
                              homeURL: "https://openai.com/news/",
                              feedURL: "https://openai.com/news/rss.xml",
                              access: .rss, symbol: "sparkle", accentHex: "#4C7F6C")
        case .openAIResearch:
            // openai.com/research/rss.xml returns 404; the single news feed carries
            // every OpenAI post and tags each one, so research items are selected
            // from it by category rather than by a separate endpoint.
            return SourceSpec(title: "OpenAI Research", host: "openai.com/research",
                              homeURL: "https://openai.com/news/",
                              feedURL: "https://openai.com/news/rss.xml",
                              access: .rss, symbol: "atom", accentHex: "#3E6F60",
                              filter: .researchOnly)

        // MARK: Anthropic
        case .anthropicNews:
            // No RSS feed exists (every candidate returns 404), but /news is
            // server-rendered, so its article links are read from the HTML.
            return SourceSpec(title: "Anthropic News", host: "anthropic.com/news",
                              homeURL: "https://www.anthropic.com/news",
                              feedURL: nil, access: .sitemap,
                              symbol: "a.circle", accentHex: "#9A6047",
                              accessDescription: "News page HTML")
        case .anthropicResearch:
            return SourceSpec(title: "Anthropic Research", host: "anthropic.com/research",
                              homeURL: "https://www.anthropic.com/research",
                              feedURL: nil, access: .sitemap,
                              symbol: "doc.text.magnifyingglass", accentHex: "#8C4A28",
                              accessDescription: "Research page HTML")

        // MARK: Google DeepMind
        case .deepMind:
            return SourceSpec(title: "Google DeepMind", host: "deepmind.google",
                              homeURL: "https://deepmind.google/discover/blog/",
                              feedURL: "https://deepmind.google/blog/rss.xml",
                              access: .rss, symbol: "circle.hexagongrid", accentHex: "#5B7FA8")

        // MARK: Hacker News
        case .hackerNews:
            return SourceSpec(title: "Hacker News", host: "news.ycombinator.com",
                              homeURL: "https://news.ycombinator.com/",
                              feedURL: "https://news.ycombinator.com/rss",
                              access: .rss, symbol: "y.square", accentHex: "#A24E28",
                              filter: .technical)
        case .showHN:
            // hnrss.org publishes the Show HN view as a feed; the official site
            // has no Show HN feed of its own.
            return SourceSpec(title: "Show HN", host: "hnrss.org/show",
                              homeURL: "https://news.ycombinator.com/show",
                              feedURL: "https://hnrss.org/show",
                              access: .rss, symbol: "hammer", accentHex: "#95532A",
                              itemKind: .product, filter: .technical)

        // MARK: Directories & magazines
        case .arsTechnica:
            return SourceSpec(title: "Ars Technica AI", host: "arstechnica.com",
                              homeURL: "https://arstechnica.com/ai/",
                              feedURL: "https://arstechnica.com/ai/feed/",
                              access: .rss, symbol: "flame", accentHex: "#8F4528",
                              extraPages: 2)
        case .mitTechReview:
            return SourceSpec(title: "MIT Technology Review", host: "technologyreview.com",
                              homeURL: "https://www.technologyreview.com/",
                              feedURL: "https://www.technologyreview.com/topic/artificial-intelligence/feed/",
                              access: .rss, symbol: "graduationcap", accentHex: "#A03038",
                              extraPages: 2)
        case .nvidia:
            // nvidianews.nvidia.com/rss and /rss/all return the HTML site; the
            // working document is rss.xml.
            return SourceSpec(title: "NVIDIA News", host: "nvidianews.nvidia.com",
                              homeURL: "https://nvidianews.nvidia.com/",
                              feedURL: "https://nvidianews.nvidia.com/rss.xml",
                              access: .rss, symbol: "n.circle", accentHex: "#5A7A34")
        case .mistral:
            // The news page has no feed path; rss.xml at the site root works.
            return SourceSpec(title: "Mistral AI", host: "mistral.ai",
                              homeURL: "https://mistral.ai/news/",
                              feedURL: "https://mistral.ai/rss.xml",
                              access: .rss, symbol: "wind", accentHex: "#8F4B32")

        // MARK: Practitioners & community
        case .simonWillison:
            return SourceSpec(title: "Simon Willison", host: "simonwillison.net",
                              homeURL: "https://simonwillison.net/",
                              feedURL: "https://simonwillison.net/atom/everything/",
                              access: .rss, symbol: "text.book.closed", accentHex: "#3D625F")
        case .localLLaMA:
            return SourceSpec(title: "r/LocalLLaMA", host: "reddit.com/r/LocalLLaMA",
                              homeURL: "https://www.reddit.com/r/LocalLLaMA/",
                              feedURL: "https://www.reddit.com/r/LocalLLaMA/.rss",
                              access: .rss, symbol: "bubble.left.and.bubble.right",
                              accentHex: "#8F4528")

        // MARK: Design
        case .creativeBloq:
            return SourceSpec(title: "Creative Bloq", host: "creativebloq.com",
                              homeURL: "https://www.creativebloq.com/",
                              // /feeds/rss redirects to an http:// URL, which App
                              // Transport Security refuses; feeds.xml is the same
                              // feed served directly over https.
                              feedURL: "https://www.creativebloq.com/feeds.xml",
                              access: .rss, symbol: "paintpalette", accentHex: "#8E2C3C")
        case .itsNiceThat:
            // /rss and /feed both return 404; /articles.rss is the live feed.
            return SourceSpec(title: "It's Nice That", host: "itsnicethat.com",
                              homeURL: "https://www.itsnicethat.com/",
                              feedURL: "https://www.itsnicethat.com/articles.rss",
                              access: .rss, symbol: "sparkles.rectangle.stack",
                              accentHex: "#3F3A3C")
        default:
            // A source in the Tech News tab. The catalogue holds the feed that
            // was fetched and answered, so the spec is read from there.
            if isTech, let t = TechCatalogue.entry(for: self) {
                return SourceSpec(title: t.title, host: t.host,
                                  homeURL: t.home, feedURL: t.feed,
                                  access: .rss, symbol: TechCatalogue.symbol(for: t),
                                  accentHex: TechCatalogue.accent(for: t),
                                  extraPages: t.extraPages,
                                  pageParameter: t.pageParameter)
            }
            // A source in the design tab.
            // A publisher the app already collected keeps its own spec; the
            // catalogue only says which tab it belongs to.
            if let d = DesignCatalogue.entry(for: self), d.sourceID == self,
               !isDesign {
                return SourceSpec(title: d.title, host: URL(string: d.home)?.host ?? d.home,
                                  homeURL: d.home, feedURL: d.feed,
                                  access: .rss, symbol: d.symbol, accentHex: d.accent)
            }
            if isDesign, let d = DesignCatalogue.source(String(rawValue.dropFirst("design:".count))) {
                // A publisher with no feed is read from its own listing page, and
                // the spec says so, so the source status can explain it.
                if d.usesSitemap {
                    return SourceSpec(title: d.title, host: URL(string: d.home)?.host ?? d.home,
                                      homeURL: d.home, feedURL: nil,
                                      access: .sitemap, symbol: d.symbol, accentHex: d.accent,
                                      accessDescription: "Sitemap of article URLs")
                }
                if d.usesListing {
                    return SourceSpec(title: d.title, host: URL(string: d.home)?.host ?? d.home,
                                      homeURL: d.home, feedURL: nil,
                                      access: .sitemap, symbol: d.symbol, accentHex: d.accent,
                                      accessDescription: "Listing page HTML")
                }
                if !d.jsonEndpoint.isEmpty {
                    // The publisher's own WordPress endpoint: every post with
                    // its real date, because its feed is broken.
                    return SourceSpec(title: d.title, host: URL(string: d.home)?.host ?? d.home,
                                      homeURL: d.home, feedURL: nil,
                                      access: .api, symbol: d.symbol, accentHex: d.accent,
                                      accessDescription: "WordPress JSON endpoint")
                }
                return SourceSpec(title: d.title, host: URL(string: d.home)?.host ?? d.home,
                                  homeURL: d.home, feedURL: d.feed,
                                  access: .rss, symbol: d.symbol, accentHex: d.accent)
            }
            // A source added from inside the app. Its details live in the user's
            // sources file, so the spec is built from there at read time.
            return SourceID.customSpec(for: self) ?? SourceSpec(
                title: rawValue, host: rawValue, homeURL: "https://\(rawValue)",
                feedURL: nil, access: .rss, symbol: "antenna.radiowaves.left.and.right",
                accentHex: "#8C3A46")
        }
    }

    var title: String { spec.title }
    var host: String { spec.host }

    /// The name as a badge, in the smallest space it can still be read.
    ///
    /// The compact badge used to print the host, which is a domain name: a
    /// reader looking at a card wants to know it came from The Register, not
    /// from "theregister.com". The tech publishers need no shortening — those
    /// are already mastheads — while the news sources keep the host they were
    /// always shown with.
    var shortTitle: String {
        if isTech { return spec.title }
        return spec.host
    }
    var kind: SourceKind { spec.kind }
    var symbol: String { spec.symbol }
    var accentHex: String { spec.accentHex }
    var homeURL: URL { URL(string: spec.homeURL)! }
    var feedURL: URL? { spec.feedURL.flatMap { URL(string: $0) } }

    /// The publication's real logo, used on source badges so a card identifies
    /// its publisher at a glance. DuckDuckGo's icon service is used because the
    /// publishers' own /favicon.ico files are inconsistent: some are 16px, some
    /// redirect, and Product Hunt serves quarter-megabyte originals.
    var logoURL: URL? {
        // Hugging Face, Hacker News and Reddit all serve their icons from a
        // domain that differs from the display host.
        let domain: String
        switch self {
        case .huggingFaceBlog, .huggingFaceModels: domain = "huggingface.co"
        case .hackerNews, .showHN: domain = "news.ycombinator.com"
        case .localLLaMA: domain = "reddit.com"
        case .anthropicNews, .anthropicResearch: domain = "anthropic.com"
        case .openAINews, .openAIResearch: domain = "openai.com"
        case .itsNiceThat: domain = "itsnicethat.com"
        default: domain = host.split(separator: "/").first.map(String.init) ?? host
        }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico")
    }

    /// How this source is read, shown in the sources panel.
    var accessDescription: String {
        if let d = spec.accessDescription { return d }
        switch spec.access {
        case .rss: return "RSS / Atom feed"
        case .githubPage: return "Web page"
        case .api: return "JSON API"
        case .sitemap: return "Page HTML"
        case .communityAPI: return "Community JSON API"
        }
    }

    /// Sources grouped for the sidebar and the sources panel.
    static let publishers: [SourceID] = [
        .blogGoogle, .techCrunch, .theVerge, .tldr, .productHunt,
        .arsTechnica, .mitTechReview
    ]
    static let labs: [SourceID] = [
        .openAINews, .openAIResearch, .anthropicNews, .anthropicResearch,
        .deepMind, .mistral, .nvidia, .huggingFaceBlog, .huggingFaceModels
    ]
    static let community: [SourceID] = [
        .hackerNews, .showHN, .simonWillison, .localLLaMA
    ]
    static let design: [SourceID] = [.creativeBloq, .itsNiceThat]
    static let code: [SourceID] = [.gitHubTrending, .gitHubExplore]
}
