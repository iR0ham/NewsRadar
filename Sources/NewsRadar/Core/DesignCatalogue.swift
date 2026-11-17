import Foundation

// MARK: - Design & Web Intelligence
//
// A second reading surface, built on the same feed pipeline as the news list.
// Nothing here fetches its own way: each entry is an ordinary RSS/Atom source,
// so retries, caching, dedupe, image enrichment and the reader all apply
// unchanged.
//
// Only feeds that answered with real entries at build time are listed. A source
// whose site publishes no feed is named in `unavailable` rather than quietly
// dropped or pointed at a guessed URL — a source that always fails is worse than
// one that is honestly absent.

/// The eight sections the tab is organised by. Each source belongs to exactly
/// one, because a reader looking for fonts is not looking for web hosts.
/// The two reading surfaces built on this catalogue.
///
/// The tabs are separate because the questions are separate: "how do I rank"
/// and "what did Adobe ship" have nothing to do with each other, and mixing
/// them made one list nobody could scan.
enum DesignSurface: String, CaseIterable, Identifiable, Hashable {
    case web
    case design

    var id: String { rawValue }

    var title: String {
        switch self {
        case .web: return "Web & SEO"
        case .design: return "Design & Creative AI"
        }
    }

    var symbol: String {
        switch self {
        case .web: return "globe"
        case .design: return "paintpalette.fill"
        }
    }

    /// One line under the title, naming what the tab actually covers.
    var subtitle: String {
        switch self {
        case .web: return "Builders, search, analytics and web performance"
        case .design: return "Creative software, AI image and video, type and motion"
        }
    }
}

enum DesignCategory: String, CaseIterable, Codable, Identifiable, Hashable {
    case creative
    case aiCreative
    case branding
    case logos
    case packaging
    case typography
    case advertising
    case uiux
    case webBuild
    case search
    case analytics
    case motion
    case resources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .creative: return "Graphic Design & Creative Software"
        case .aiCreative: return "AI Creative Tools"
        case .branding: return "Branding & Visual Identity"
        case .logos: return "Logo Design & Rebranding"
        case .packaging: return "Packaging Design"
        case .typography: return "Typography & Fonts"
        case .advertising: return "Advertising & Creative Campaigns"
        case .uiux: return "UI/UX & Web Design"
        case .webBuild: return "Website Builders & Web Dev"
        case .search: return "SEO & Search"
        case .analytics: return "Analytics & Digital Marketing"
        case .motion: return "Motion Graphics & 3D"
        case .resources: return "Design Resources"
        }
    }

    /// Used on chips where the full title does not fit.
    var shortTitle: String {
        switch self {
        case .creative: return "Design"
        case .aiCreative: return "AI Creative"
        case .branding: return "Branding"
        case .logos: return "Logos"
        case .packaging: return "Packaging"
        case .typography: return "Type"
        case .advertising: return "Advertising"
        case .uiux: return "UI/UX"
        case .webBuild: return "Web Dev"
        case .search: return "SEO"
        case .analytics: return "Analytics"
        case .motion: return "Motion & 3D"
        case .resources: return "Resources"
        }
    }

    /// The tab this section is read in. UI/UX sits with design because the
    /// requested split puts product design under creative, not under SEO.
    var surface: DesignSurface {
        switch self {
        case .webBuild, .search, .analytics: return .web
        case .creative, .aiCreative, .branding, .logos, .packaging,
             .typography, .advertising, .uiux, .motion, .resources: return .design
        }
    }

    /// Dot colour in the filter panel. Distinct per section, muted enough to sit
    /// on the dark card without competing with the accent.
    var accentHex: String {
        switch self {
        case .creative: return "#8E2C3C"
        case .aiCreative: return "#6B5B95"
        case .branding: return "#8C6A3C"
        case .logos: return "#A05A6A"
        case .packaging: return "#6B7A3C"
        case .typography: return "#4E6E8C"
        case .advertising: return "#96503C"
        case .uiux: return "#3F6B7A"
        case .webBuild: return "#3E5C8C"
        case .search: return "#546F94"
        case .analytics: return "#8C4A5A"
        case .motion: return "#6B4A8C"
        case .resources: return "#4E7A4A"
        }
    }

    var symbol: String {
        switch self {
        case .creative: return "paintpalette"
        case .aiCreative: return "wand.and.stars"
        case .branding: return "seal"
        case .logos: return "circle.hexagonpath"
        case .packaging: return "shippingbox"
        case .typography: return "textformat.alt"
        case .advertising: return "megaphone"
        case .uiux: return "rectangle.3.group"
        case .webBuild: return "hammer"
        case .search: return "magnifyingglass.circle"
        case .analytics: return "chart.bar.xaxis"
        case .motion: return "cube.transparent"
        case .resources: return "square.stack.3d.down.right"
        }
    }
}

/// One source in the tab. `feed` is the address that actually returned entries;
/// `home` is the page the spec asked for, kept for the source card's link.
struct DesignSource {
    var id: String
    var title: String
    var home: String
    /// The RSS/Atom feed, or an empty string when the publisher has none and
    /// the source is read from its own listing page instead.
    var feed: String
    /// Where the articles live in the listing page's URLs, when there is no
    /// feed. Every article link of the site contains this path.
    var listingPath: String = ""
    /// How the headline of a listed article is found.
    var listingTitle: AltSource.ListingTitleSelector = .heading
    /// Where the date of a listed article comes from.
    var listingDate: AltSource.ListingDateSelector = .card
    /// The sitemap that lists this publisher's articles, when it publishes one
    /// instead of a feed.
    var sitemapURL: String = ""
    /// The WordPress JSON endpoint, for a publisher whose feed is broken or
    /// advertising something else. The endpoint gives every post with its real
    /// publication date, its headline and its picture.
    var jsonEndpoint: String = ""
    var category: DesignCategory
    var symbol: String
    var accent: String
    /// The source this entry is collected as.
    ///
    /// Most catalogue entries are their own source (`design:<id>`). A publisher
    /// the app already collected — Creative Bloq, It's Nice That — keeps its
    /// existing source, so the same story is stored once and shown once.
    var sourceID: SourceID? = nil

    /// True when this source is read from its listing page rather than a feed.
    var usesListing: Bool { feed.isEmpty && sitemapURL.isEmpty && jsonEndpoint.isEmpty }
    /// True when this source is read from a sitemap.
    var usesSitemap: Bool { feed.isEmpty && !sitemapURL.isEmpty }
}

enum DesignCatalogue {

    /// Every source verified to serve a live feed. Order is the order the tab
    /// lists them, grouped by category.
    static let sources: [DesignSource] = [
        // MARK: Graphic design & creative software
        DesignSource(id: "figma.com/blog", title: "Figma Blog",
                     home: "https://www.figma.com/blog/",
                     feed: "https://www.figma.com/blog/feed/atom.xml",
                     category: .creative, symbol: "square.on.circle", accent: "#8C3A46"),
        DesignSource(id: "sketch.com/blog", title: "Sketch Blog",
                     home: "https://www.sketch.com/blog/",
                     feed: "https://www.sketch.com/blog/feed.xml",
                     category: .creative, symbol: "diamond", accent: "#96703C"),
        DesignSource(id: "creativeboom.com", title: "Creative Boom",
                     home: "https://www.creativeboom.com/",
                     feed: "https://www.creativeboom.com/feed/",
                     category: .creative, symbol: "sparkles", accent: "#8E2C3C"),

        // MARK: Newly verified feeds
        //
        // Each of these was checked against the live site: the feed answered
        // with entries, not with an error page.
        // These two the app already collected. They keep their existing source
        // so no story is stored twice, and they move into the design tab, where
        // a design publisher belongs.
        DesignSource(id: "creativebloq.com", title: "Creative Bloq",
                     home: "https://www.creativebloq.com/",
                     feed: "https://www.creativebloq.com/feeds.xml",
                     category: .creative, symbol: "paintpalette", accent: "#8E2C3C",
                     sourceID: .creativeBloq),
        DesignSource(id: "itsnicethat.com", title: "It's Nice That",
                     home: "https://www.itsnicethat.com/",
                     feed: "https://www.itsnicethat.com/articles.rss",
                     category: .creative, symbol: "sparkles.rectangle.stack", accent: "#3F3A3C",
                     sourceID: .itsNiceThat),
        DesignSource(id: "freepik.com/blog", title: "Freepik Blog",
                     home: "https://www.freepik.com/blog/",
                     feed: "https://www.freepik.com/blog/feed/",
                     category: .resources, symbol: "photo.on.rectangle", accent: "#5B7FA8"),
        DesignSource(id: "socialmediatoday.com", title: "Social Media Today",
                     home: "https://www.socialmediatoday.com/",
                     feed: "https://www.socialmediatoday.com/feeds/news/",
                     category: .analytics, symbol: "person.2", accent: "#8A5A3C"),
        DesignSource(id: "venturebeat.com/ai", title: "VentureBeat AI",
                     home: "https://venturebeat.com/ai/",
                     feed: "https://venturebeat.com/category/ai/feed/",
                     category: .aiCreative, symbol: "chart.line.uptrend.xyaxis", accent: "#4E7F4A"),

        // MARK: Publishers with no feed, read from their own listing page
        //
        // A third of the requested design publishers publish no RSS at all, and
        // several refuse automated clients. Their pages are server-rendered, so
        // the listing is the source of truth: the article links are read out of
        // it, and the date comes from the article page itself.
        DesignSource(id: "blog.adobe.com", title: "Adobe Blog",
                     home: "https://blog.adobe.com/en/",
                     feed: "",
                     listingPath: "/en/publish/",
                     sitemapURL: "https://blog.adobe.com/en/sitemap.xml",
                     category: .creative, symbol: "paintbrush.pointed", accent: "#8C2F3E"),
        DesignSource(id: "news.adobe.com", title: "Adobe Newsroom",
                     home: "https://news.adobe.com/",
                     feed: "",
                     listingPath: "/news/",
                     sitemapURL: "https://news.adobe.com/assets/sitemap.xml",
                     category: .creative, symbol: "megaphone", accent: "#9A3A46"),
        DesignSource(id: "runwayml.com", title: "Runway",
                     home: "https://runwayml.com/",
                     feed: "",
                     listingPath: "/news/",
                     category: .aiCreative, symbol: "film", accent: "#4E6B8F"),
        DesignSource(id: "bfl.ai", title: "Black Forest Labs",
                     home: "https://bfl.ai/",
                     feed: "",
                     listingPath: "/blog/",
                     category: .aiCreative, symbol: "flame", accent: "#8A5A2C"),
        DesignSource(id: "lumalabs.ai", title: "Luma",
                     home: "https://lumalabs.ai/",
                     feed: "",
                     listingPath: "/news/",
                     category: .aiCreative, symbol: "sparkles", accent: "#6B5B95"),
        DesignSource(id: "recraft.ai", title: "Recraft",
                     home: "https://www.recraft.ai/",
                     feed: "",
                     listingPath: "/blog/",
                     category: .aiCreative, symbol: "square.3.layers.3d", accent: "#7A4A6B"),
        DesignSource(id: "heygen.com/blog", title: "HeyGen Blog",
                     home: "https://www.heygen.com/blog",
                     feed: "",
                     listingPath: "/blog/",
                     listingTitle: .attribute,
                     listingDate: .articlePage,
                     category: .aiCreative, symbol: "person.crop.rectangle.stack", accent: "#4E7F6A"),
        DesignSource(id: "schoolofmotion.com/blog", title: "School of Motion",
                     home: "https://www.schoolofmotion.com/blog",
                     feed: "",
                     listingPath: "/blog/",
                     listingDate: .articlePage,
                     category: .motion, symbol: "figure.walk.motion", accent: "#8A4A2C"),
        DesignSource(id: "affinity.serif.com", title: "Affinity",
                     home: "https://affinity.serif.com/",
                     feed: "",
                     listingPath: "/blog/",
                     listingDate: .articlePage,
                     category: .creative, symbol: "diamond", accent: "#5B7FA8"),
        DesignSource(id: "framer.com/blog", title: "Framer Blog",
                     home: "https://www.framer.com/blog/",
                     feed: "",
                     listingPath: "/blog/",
                     listingDate: .articlePage,
                     category: .uiux, symbol: "rectangle.3.group", accent: "#5B6B8F"),
        DesignSource(id: "framer.com/updates", title: "Framer Updates",
                     home: "https://www.framer.com/updates/",
                     feed: "",
                     listingPath: "/updates/",
                     listingDate: .articlePage,
                     category: .uiux, symbol: "arrow.triangle.2.circlepath", accent: "#5B6B8F"),

        // MARK: AI creative tools
        DesignSource(id: "stability.ai/news", title: "Stability AI",
                     home: "https://stability.ai/news",
                     feed: "https://stability.ai/news-updates?format=rss",
                     category: .aiCreative, symbol: "circle.hexagongrid", accent: "#6B5B95"),
        DesignSource(id: "higgsfield.ai", title: "Higgsfield",
                     home: "https://higgsfield.ai/",
                     feed: "https://higgsfield.ai/blog/rss.xml",
                     category: .aiCreative, symbol: "film", accent: "#7A4A6B"),
        DesignSource(id: "krea.ai", title: "Krea",
                     home: "https://www.krea.ai/",
                     feed: "https://www.krea.ai/blog/feed/atom.xml",
                     category: .aiCreative, symbol: "paintbrush.pointed", accent: "#8A5A3C"),
        DesignSource(id: "elevenlabs.io/blog", title: "ElevenLabs",
                     home: "https://elevenlabs.io/blog",
                     feed: "https://elevenlabs.io/blog/rss.xml",
                     category: .aiCreative, symbol: "waveform", accent: "#4E6E8C"),

        DesignSource(id: "petapixel.com", title: "PetaPixel",
                     home: "https://petapixel.com/",
                     feed: "https://petapixel.com/feed/",
                     category: .creative, symbol: "camera.aperture", accent: "#8C5A32"),
        DesignSource(id: "fstoppers.com", title: "Fstoppers",
                     home: "https://fstoppers.com/",
                     feed: "https://fstoppers.com/feed",
                     category: .creative, symbol: "camera", accent: "#6B6B72"),
        DesignSource(id: "dezeen.com", title: "Dezeen",
                     home: "https://www.dezeen.com/",
                     feed: "https://www.dezeen.com/feed/",
                     category: .creative, symbol: "building.columns", accent: "#4E6B7A"),
        DesignSource(id: "printmag.com", title: "PRINT Magazine",
                     home: "https://www.printmag.com/",
                     feed: "https://www.printmag.com/feed/",
                     category: .creative, symbol: "text.book.closed", accent: "#96503C"),

        // MARK: UI/UX & web design
        DesignSource(id: "nngroup.com", title: "Nielsen Norman Group",
                     home: "https://www.nngroup.com/articles/",
                     feed: "https://www.nngroup.com/feed/rss/",
                     category: .uiux, symbol: "eye", accent: "#3F6B7A"),
        DesignSource(id: "smashingmagazine.com", title: "Smashing Magazine",
                     home: "https://www.smashingmagazine.com/",
                     feed: "https://www.smashingmagazine.com/feed",
                     category: .uiux, symbol: "square.stack.3d.up", accent: "#A8553C"),

        // MARK: Website builders & web development
        DesignSource(id: "css-tricks.com", title: "CSS-Tricks",
                     home: "https://css-tricks.com/",
                     feed: "https://css-tricks.com/feed/",
                     category: .webBuild, symbol: "curlybraces", accent: "#A8642C"),

        // Web Design Weekly's feed is broken in a way that cannot be read
        // around: every one of its ten entries is the same issue, all with
        // the same date, and the site has been rebuilt so that the database
        // says every post was written on one day. The publisher has not put
        // out a new issue since May 2025, so it has been moved to the
        // unavailable list, and these two newsletters that are still going out
        // every week take its place.
        DesignSource(id: "frontendfoc.us", title: "Frontend Focus",
                     home: "https://frontendfoc.us/",
                     feed: "https://frontendfoc.us/rss/",
                     category: .webBuild, symbol: "curlybraces", accent: "#4E7A6B"),

        DesignSource(id: "web.dev", title: "web.dev",
                     home: "https://web.dev/",
                     feed: "https://web.dev/feed.xml",
                     category: .webBuild, symbol: "globe", accent: "#3A7A7A"),
        DesignSource(id: "webflow.com/blog", title: "Webflow Blog",
                     home: "https://webflow.com/blog",
                     feed: "https://webflow.com/blog/rss.xml",
                     category: .webBuild, symbol: "w.circle", accent: "#3E5C8C"),
        DesignSource(id: "webflow.com/updates", title: "Webflow Updates",
                     home: "https://webflow.com/updates",
                     feed: "https://webflow.com/updates/rss.xml",
                     category: .webBuild, symbol: "arrow.up.circle", accent: "#48688F"),
        DesignSource(id: "wordpress.org/news", title: "WordPress News",
                     home: "https://wordpress.org/news/",
                     feed: "https://wordpress.org/news/feed/",
                     category: .webBuild, symbol: "w.square", accent: "#4E6B8C"),
        DesignSource(id: "elementor.com/blog", title: "Elementor",
                     home: "https://elementor.com/blog/",
                     feed: "https://elementor.com/blog/feed/",
                     category: .webBuild, symbol: "square.grid.2x2", accent: "#96343F"),
        DesignSource(id: "wix.com/blog", title: "Wix Blog",
                     home: "https://www.wix.com/blog",
                     feed: "https://www.wix.com/blog/blog-feed.xml",
                     category: .webBuild, symbol: "x.square", accent: "#5A5A7A"),
        // Shopify's feed stopped in December 2023 while the newsroom carried
        // on publishing every week. The newsroom's own page still carries each
        // story with the date printed beside it, so the source is read from
        // there instead of from the dead feed.
        DesignSource(id: "shopify.com/news", title: "Shopify News",
                     home: "https://www.shopify.com/news",
                     feed: "",
                     listingPath: "/news/",
                     category: .webBuild, symbol: "bag", accent: "#4E7A4A"),
        DesignSource(id: "vercel.com/changelog", title: "Vercel Changelog",
                     home: "https://vercel.com/changelog",
                     feed: "https://vercel.com/changelog/feed",
                     category: .webBuild, symbol: "triangle", accent: "#6E6E76"),
        DesignSource(id: "netlify.com/blog", title: "Netlify",
                     home: "https://www.netlify.com/blog/",
                     feed: "https://www.netlify.com/feed.xml",
                     category: .webBuild, symbol: "n.square", accent: "#3E7A78"),
        DesignSource(id: "nextjs.org/blog", title: "Next.js Blog",
                     home: "https://nextjs.org/blog",
                     feed: "https://nextjs.org/feed.xml",
                     category: .webBuild, symbol: "chevron.left.forwardslash.chevron.right", accent: "#6A6A72"),
        DesignSource(id: "tailwindcss.com/blog", title: "Tailwind CSS",
                     home: "https://tailwindcss.com/blog",
                     feed: "https://tailwindcss.com/feeds/feed.xml",
                     category: .webBuild, symbol: "wind", accent: "#3E7A8C"),

        // MARK: SEO & search
        DesignSource(id: "developers.google.com/search/blog", title: "Google Search Central",
                     home: "https://developers.google.com/search/blog",
                     feed: "https://developers.google.com/search/blog/feed.xml",
                     category: .search, symbol: "g.circle", accent: "#5B7FA8"),
        DesignSource(id: "blog.google/products/search", title: "Google Search Blog",
                     home: "https://blog.google/products/search/",
                     feed: "https://blog.google/products/search/rss",
                     category: .search, symbol: "magnifyingglass", accent: "#546F94"),
        DesignSource(id: "blogs.bing.com/webmaster", title: "Bing Webmaster",
                     home: "https://blogs.bing.com/webmaster",
                     feed: "https://blogs.bing.com/webmaster/feed",
                     category: .search, symbol: "b.circle", accent: "#3E7A94"),
        DesignSource(id: "ahrefs.com/blog", title: "Ahrefs",
                     home: "https://ahrefs.com/blog/",
                     feed: "https://ahrefs.com/blog/feed/",
                     category: .search, symbol: "link", accent: "#8C5A32"),
        DesignSource(id: "semrush.com/blog", title: "Semrush",
                     home: "https://www.semrush.com/blog/",
                     feed: "https://www.semrush.com/blog/feed/",
                     category: .search, symbol: "chart.line.uptrend.xyaxis", accent: "#A8563C"),
        DesignSource(id: "moz.com/blog", title: "Moz",
                     home: "https://moz.com/blog",
                     feed: "https://moz.com/feeds/blog.rss",
                     category: .search, symbol: "m.circle", accent: "#3E6B7A"),
        DesignSource(id: "searchenginejournal.com", title: "Search Engine Journal",
                     home: "https://www.searchenginejournal.com/",
                     feed: "https://www.searchenginejournal.com/feed/atom/",
                     category: .search, symbol: "doc.text.magnifyingglass", accent: "#96503C"),
        DesignSource(id: "seroundtable.com", title: "Search Engine Roundtable",
                     home: "https://www.seroundtable.com/",
                     feed: "https://www.seroundtable.com/index.rdf",
                     category: .search, symbol: "bubble.left.and.text.bubble.right", accent: "#7A5A3C"),
        DesignSource(id: "screamingfrog.co.uk/blog", title: "Screaming Frog",
                     home: "https://www.screamingfrog.co.uk/blog/",
                     feed: "https://www.screamingfrog.co.uk/feed/",
                     category: .search, symbol: "f.circle", accent: "#4E7A5A"),
        DesignSource(id: "onely.com/blog", title: "Onely",
                     home: "https://www.onely.com/blog/",
                     feed: "https://www.onely.com/feed/",
                     category: .search, symbol: "o.circle", accent: "#6B6B8C"),
        DesignSource(id: "blog.cloudflare.com", title: "Cloudflare Blog",
                     home: "https://www.cloudflare.com/blog/",
                     feed: "https://blog.cloudflare.com/rss/",
                     category: .search, symbol: "cloud", accent: "#A8642C"),

        // MARK: Analytics & digital marketing
        DesignSource(id: "adweek.com", title: "Adweek",
                     home: "https://www.adweek.com/",
                     feed: "https://www.adweek.com/feed/",
                     category: .analytics, symbol: "a.circle", accent: "#96503C"),
        DesignSource(id: "marketingbrew.com", title: "Marketing Brew",
                     home: "https://www.marketingbrew.com/",
                     feed: "https://www.marketingbrew.com/feed.xml",
                     category: .analytics, symbol: "cup.and.saucer", accent: "#7A4A3C"),

        // MARK: Motion, 3D & design resources
        DesignSource(id: "motionographer.com", title: "Motionographer",
                     home: "https://motionographer.com/",
                     feed: "https://motionographer.com/feed/",
                     category: .motion, symbol: "play.rectangle", accent: "#6B4A8C"),
        DesignSource(id: "blender.org/news", title: "Blender",
                     home: "https://www.blender.org/news/",
                     feed: "https://www.blender.org/feed/",
                     category: .motion, symbol: "cube", accent: "#A8642C"),
        DesignSource(id: "unrealengine.com", title: "Unreal Engine",
                     home: "https://www.unrealengine.com/en-US/blog",
                     feed: "https://www.unrealengine.com/en-US/rss.xml",
                     category: .motion, symbol: "gamecontroller", accent: "#5A5A66"),
        DesignSource(id: "unsplash.com/blog", title: "Unsplash",
                     home: "https://unsplash.com/blog/",
                     feed: "https://unsplash.com/blog/rss/",
                     category: .resources, symbol: "camera", accent: "#6B6B72"),

        // MARK: Branding & visual identity
        //
        // Asked for by name, and one of the few parts of this beat that does
        // publish a feed. Each was fetched and read before being listed.
        DesignSource(id: "bpando.org", title: "BP&O",
                     home: "https://bpando.org/",
                     feed: "https://bpando.org/feed",
                     category: .branding, symbol: "seal", accent: "#8C6A3C"),
        DesignSource(id: "brandingmag.com", title: "Brandingmag",
                     home: "https://www.brandingmag.com/",
                     feed: "https://www.brandingmag.com/feed/",
                     category: .branding, symbol: "seal.fill", accent: "#96703C"),
        // Identity Designed's feed is live and answers, but its newest entry is
        // from December 2024: the publisher slowed to a stop, not a crawl. Listed
        // as unavailable rather than as a source whose page is permanently empty.

        // Brand New publishes a feed, but the only one advertised is its
        // podcast: 87 episodes and nothing from the blog. The blog's own feed
        // file answers with a server error, and its archive is a plain
        // server-rendered page. The publisher's WordPress endpoint does answer,
        // with every post, its real date, its headline and its picture — so
        // that is what is read.
        DesignSource(id: "underconsideration.com/brandnew", title: "Brand New",
                     home: "https://www.underconsideration.com/brandnew/",
                     feed: "",
                     jsonEndpoint: "https://www.underconsideration.com/brandnew/wp-json/wp/v2/posts?per_page=20",
                     category: .branding, symbol: "textformat.size.larger",
                     accent: "#7A4A5A"),

        // The same publisher's second blog. UnderConsideration runs two: Brand
        // New for outside identity work, and In-house In-focus for the design
        // teams inside companies. This one publishes a real feed — ten entries
        // with dates and pictures — so it is read from that, not from a listing.
        DesignSource(id: "underconsideration.com/inhouseinfocus", title: "In-house In-focus",
                     home: "https://underconsideration.com/inhouseinfocus/",
                     feed: "https://underconsideration.com/inhouseinfocus/feed/",
                     category: .branding, symbol: "person.2.fill",
                     accent: "#6A4A7A"),

        // Publishers added on 22 October 2026 to replace the ones whose feeds
        // had gone quiet, so no section is left without something current in it.
        // Each of these was checked for a feed that still carries this week's
        // material; none of them duplicates a publisher already in the tab.
        DesignSource(id: "ilovetypography.com", title: "I Love Typography",
                     home: "https://ilovetypography.com/",
                     feed: "https://ilovetypography.com/feed/",
                     category: .typography, symbol: "textformat", accent: "#7A5A3A"),

        DesignSource(id: "thetype.com", title: "The Type",
                     home: "https://www.thetype.com/",
                     feed: "https://www.thetype.com/feed/",
                     category: .typography, symbol: "character.cursor.ibeam",
                     accent: "#3A6B7A"),

        DesignSource(id: "designshack.net", title: "Design Shack",
                     home: "https://www.designshack.net/",
                     feed: "https://www.designshack.net/feed/",
                     category: .resources, symbol: "square.stack.3d.down.right",
                     accent: "#4E7A6B"),

        DesignSource(id: "logomoose.com", title: "LogoMoose",
                     home: "https://www.logomoose.com/",
                     feed: "https://www.logomoose.com/feed/",
                     category: .logos, symbol: "seal", accent: "#7A4A4A"),

        DesignSource(id: "yellowtrace.com.au", title: "Yellowtrace",
                     home: "https://www.yellowtrace.com.au/",
                     feed: "https://www.yellowtrace.com.au/feed/",
                     category: .uiux, symbol: "paintbrush", accent: "#7A6A3A"),

        DesignSource(id: "thisiscolossal.com", title: "Colossal",
                     home: "https://www.thisiscolossal.com/",
                     feed: "https://www.thisiscolossal.com/feed/",
                     category: .creative, symbol: "cube.transparent",
                     accent: "#6A4A5A"),

        DesignSource(id: "design-milk.com", title: "Design Milk",
                     home: "https://design-milk.com/",
                     feed: "https://design-milk.com/feed/",
                     category: .uiux, symbol: "drop", accent: "#4A6B7A"),

        DesignSource(id: "marketingland.com", title: "Marketing Land",
                     home: "https://marketingland.com/",
                     feed: "https://marketingland.com/feed/",
                     category: .analytics, symbol: "chart.line.uptrend.xyaxis",
                     accent: "#5A6B7A"),

        // MARK: Logo design & rebranding
        DesignSource(id: "logogeek.uk", title: "Logo Geek",
                     home: "https://logogeek.uk/",
                     feed: "https://logogeek.uk/feed",
                     category: .logos, symbol: "circle.hexagonpath",
                     accent: "#A05A6A"),
        DesignSource(id: "logodesignlove.com", title: "Logo Design Love",
                     home: "https://www.logodesignlove.com/",
                     feed: "https://www.logodesignlove.com/feed",
                     category: .logos, symbol: "heart.circle", accent: "#96506A"),

        // MARK: Packaging design
        DesignSource(id: "thedieline.com", title: "The Dieline",
                     home: "https://thedieline.com/",
                     feed: "https://thedieline.com/feed/",
                     category: .packaging, symbol: "shippingbox",
                     accent: "#6B7A3C"),
        DesignSource(id: "packagingoftheworld.com", title: "Packaging of the World",
                     home: "https://packagingoftheworld.com/",
                     feed: "https://packagingoftheworld.com/feed",
                     category: .packaging, symbol: "shippingbox.fill",
                     accent: "#7A7A3C"),
        DesignSource(id: "packagingnews.co.uk", title: "Packaging News",
                     home: "https://www.packagingnews.co.uk/",
                     feed: "https://www.packagingnews.co.uk/feed",
                     category: .packaging, symbol: "newspaper",
                     accent: "#5E6E3C"),

        // MARK: Typography & fonts
        DesignSource(id: "fontfabric.com", title: "Fontfabric",
                     home: "https://www.fontfabric.com/",
                     feed: "https://www.fontfabric.com/feed",
                     category: .typography, symbol: "textformat.alt",
                     accent: "#4E6E8C"),
        // Communication Arts runs a full feed, but a short one: the current
        // competition and the latest exhibit. Two live entries, both real
        // stories, which is what the feed holds and all it holds.
        DesignSource(id: "commarts.com", title: "Communication Arts",
                     home: "https://www.commarts.com/",
                     feed: "https://www.commarts.com/feed",
                     category: .typography, symbol: "character.book.closed",
                     accent: "#3F5E7A"),

        // MARK: Advertising & creative campaigns
        DesignSource(id: "campaignbrief.com", title: "Campaign Brief",
                     home: "https://www.campaignbrief.com/",
                     feed: "https://www.campaignbrief.com/feed/",
                     category: .advertising, symbol: "megaphone",
                     accent: "#96503C"),
        DesignSource(id: "marketingdive.com", title: "Marketing Dive",
                     home: "https://www.marketingdive.com/",
                     feed: "https://www.marketingdive.com/feeds/news/",
                     category: .advertising, symbol: "megaphone.fill",
                     accent: "#8C4A3C"),

        // MARK: Graphic design & creative trends
        DesignSource(id: "abduzeedo.com", title: "Abduzeedo",
                     home: "https://abduzeedo.com/",
                     feed: "https://abduzeedo.com/rss.xml",
                     category: .creative, symbol: "sparkles",
                     accent: "#8E3C4C"),
        DesignSource(id: "designboom.com", title: "designboom",
                     home: "https://www.designboom.com/",
                     feed: "https://www.designboom.com/feed",
                     category: .creative, symbol: "lightbulb",
                     accent: "#7A4A4A")
    ]

    /// Sources from the requested list that serve no feed and no machine-readable
    /// listing. Named here so the tab can say so instead of the reader wondering
    /// why a publisher they asked for never appears.
    static let unavailable: [(title: String, reason: String)] = [
        ("Canva Newsroom", "publishes no feed and refuses automated clients"),
        ("Ideogram", "publishes no feed and refuses automated clients"),
        ("Leonardo", "publishes no feed and refuses automated clients"),
        ("Midjourney", "publishes no feed and refuses automated clients"),
        ("Design Week", "publishes no feed and refuses automated clients"),
        ("Search Engine Land", "publishes no feed and refuses automated clients"),
        ("Analytics Mania", "the publisher's feed answers with a server error"),
        ("AWN", "publishes no feed and refuses automated clients"),
        ("Creative Market", "publishes no feed and refuses automated clients"),
        ("Shutterstock Blog", "publishes no feed and refuses automated clients"),
        ("Pexels Blog", "publishes no feed and refuses automated clients"),
        ("MarTech", "the feed answers with a server error (500)"),
        ("CreativePro", "the feed refuses automated clients (403)"),
        ("DesignTAXI", "the feed refuses automated clients (403)"),
        ("Codrops", "the feed refuses automated clients (403)"),

        // From the graphic-design list of 22 October. Each was tried against its
        // own site for a feed, a sitemap and a readable listing; none answered
        // with anything a reader could use, so none is listed as a source.
        ("Creative Review", "publishes no feed; the site answers automated clients with a challenge page"),
        ("Identity Designed", "the feed is live but its newest story is from December 2024; the publisher has stopped rather than slowed"),
        ("Lovely Package", "publishes no feed; its listing answers automated clients with a 403 and its sitemap has not been updated since 2024"),
        ("World Brand Design", "publishes no feed; the site is rendered in the browser and serves no article HTML"),
        ("Adobe Fonts", "no feed; the catalogue is generated in the browser"),
        ("MyFonts", "no feed; the site refuses automated clients"),
        ("Eye Magazine", "no feed; the site's article pages carry no date the reader can trust"),
        ("Adobe Photoshop release notes", "no feed and no article listing: the page is a static help article that changes in place, so there is no story to date"),
        ("Adobe Illustrator release notes", "no feed and no article listing: a help page that changes in place"),
        ("OpenAI News", "already read by the AI News tab; adding it here would store every story twice"),

        // Publishers whose feed file still answers but stopped carrying new
        // material, checked on 22 October 2026 against the feed, the sitemap,
        // the listing page and the site's own search.
        ("Envato", "the feed file answers with 226 stories but its newest is from January 2025, and the blog itself answers automated clients with a security challenge; the publisher has stopped"),
        ("Web Design Weekly", "the feed repeats one issue ten times with a single date, and the publisher has not put out a new issue since May 2025"),
        ("Google Fonts", "the blog stopped writing to its feed in June 2024 and there is no live feed of font news anywhere on the publisher's own site; the two typography publishers now in the tab cover the beat"),
        ("Sidebar", "the feed returns 200 but contains zero items — the site appears to have been redesigned without a working feed; Frontend Focus and web.dev cover the same beat"),
        ("Photopea", "the feed answers with 50 stories but its newest is from April 2024, and the company publishes no release notes anywhere else; the publisher has stopped"),
        ("MeasureSchool", "the feed answers with 10 stories but its newest is from April 2025, and the blog has not been written since; the publisher has stopped")
    ]

    /// The feed or home address for one of these sources, by id.
    private static let byID: [String: DesignSource] =
        Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static func source(_ id: String) -> DesignSource? { byID[id] }

    /// The catalogue for one tab.
    static func sources(for surface: DesignSurface) -> [DesignSource] {
        sources.filter { $0.category.surface == surface }
    }

    /// Every category in one tab, in reading order, with the sources that fill it.
    static func grouped(_ surface: DesignSurface) -> [(category: DesignCategory, sources: [DesignSource])] {
        DesignCategory.allCases.compactMap { cat in
            guard cat.surface == surface else { return nil }
            let hits = sources.filter { $0.category == cat }
            return hits.isEmpty ? nil : (cat, hits)
        }
    }

    /// Sources per category, for the tab's chips.
    static func count(for category: DesignCategory) -> Int {
        sources.filter { $0.category == category }.count
    }

    /// The tab a source is read in, or nil when it is not a design source.
    static func surface(of id: SourceID) -> DesignSurface? {
        if let entry = sources.first(where: { ($0.sourceID ?? SourceID.design($0.id)) == id }) {
            return entry.category.surface
        }
        return nil
    }

    /// The source a catalogue entry is collected as.
    static func sourceID(of entry: DesignSource) -> SourceID {
        entry.sourceID ?? SourceID.design(entry.id)
    }

    /// The catalogue entry a source is read as, if any.
    static func entry(for id: SourceID) -> DesignSource? {
        sources.first { sourceID(of: $0) == id }
    }
}
