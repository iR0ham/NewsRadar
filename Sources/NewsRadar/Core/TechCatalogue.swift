import Foundation

/// The Tech News tab: ten publishers, seven sections, one feed each.
///
/// The tab is a reading surface of its own, like Web & SEO and Design & Creative
/// AI. Its sources are ordinary feeds — nothing about them is guessed, and every
/// URL below was fetched and answered before it was written down. A publisher
/// that stops answering is reported in Source Status, not silently dropped.
///
/// The sections are the app's own. The news taxonomy (Language Models, AI
/// Agents, …) has no place for a story about a graphics card or a ransomware
/// advisory, and forcing one into it is how a feed ends up in the wrong list.
/// So the tab classifies its own stories, and the classification is stored with
/// the story like every other fact about it.
enum TechCategory: String, CaseIterable, Codable, Identifiable, Hashable {
    case startups
    case gadgets
    case hardware
    case security
    case science
    case developerTools

    var id: String { rawValue }

    /// The name on the chip and in the filter panel.
    var title: String {
        switch self {
        case .startups: return "Startups & Business"
        case .gadgets: return "Gadgets"
        case .hardware: return "Hardware"
        case .security: return "Cybersecurity"
        case .science: return "Science & Emerging Tech"
        case .developerTools: return "Developer Tools & Open Source"
        }
    }

    /// The name where the full title does not fit.
    var shortTitle: String {
        switch self {
        case .startups: return "Startups"
        case .gadgets: return "Gadgets"
        case .hardware: return "Hardware"
        case .security: return "Security"
        case .science: return "Science"
        case .developerTools: return "Dev Tools"
        }
    }

    var symbol: String {
        switch self {
        case .startups: return "lightbulb"
        case .gadgets: return "iphone"
        case .hardware: return "memorychip"
        case .security: return "lock.shield"
        case .science: return "atom"
        case .developerTools: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// A muted ramp in the app's own palette: the wine leads, the smaller
    /// sections fall back through slate, so the chip row reads as one set.
    var accentHex: String {
        switch self {
        case .startups: return "#C02434"
        case .gadgets: return "#A81E2B"
        case .hardware: return "#8C1622"
        case .security: return "#7A2A33"
        case .science: return "#66202A"
        case .developerTools: return "#4A4E58"
        }
    }
}

/// One publisher in the Tech News tab.
///
/// The feed URL is the whole configuration: it was fetched, it answered, and it
/// carries the publisher's own publication dates and images. Nothing here is
/// derived from the site's appearance or guessed from a URL pattern.
struct TechSource {
    var id: String
    var title: String
    var host: String
    var home: String
    var feed: String
    /// How many further pages of the same feed to read, and under what name.
    ///
    /// Measured against each live feed, not assumed. TechCrunch answers
    /// `?paged=2` with twenty new stories and MIT Technology Review with ten;
    /// WIRED answers `?page=2` with fifty and The Register with fifty. The other
    /// five ignore both parameters and return page one, so they are left alone:
    /// asking would only double the requests for nothing.
    var extraPages: Int = 0
    var pageParameter: String = "paged"

    var sourceID: SourceID { SourceID.tech(id) }
}

/// The tab's publishers and sections.
enum TechCatalogue {
    /// The ten publishers, in the order the tab lists them.
    static let sources: [TechSource] = [
        TechSource(id: "techcrunch",
                   title: "TechCrunch",
                   host: "techcrunch.com",
                   home: "https://techcrunch.com/",
                   feed: "https://techcrunch.com/feed/",
                   extraPages: 2),
        TechSource(id: "theverge",
                   title: "The Verge",
                   host: "theverge.com",
                   home: "https://www.theverge.com/",
                   feed: "https://www.theverge.com/rss/index.xml"),
        TechSource(id: "arstechnica",
                   title: "Ars Technica",
                   host: "arstechnica.com",
                   home: "https://arstechnica.com/",
                   feed: "https://feeds.arstechnica.com/arstechnica/index"),
        TechSource(id: "wired",
                   title: "WIRED",
                   host: "wired.com",
                   home: "https://www.wired.com/",
                   feed: "https://www.wired.com/feed/rss",
                   extraPages: 2,
                   pageParameter: "page"),
        TechSource(id: "engadget",
                   title: "Engadget",
                   host: "engadget.com",
                   home: "https://www.engadget.com/",
                   feed: "https://www.engadget.com/rss.xml"),
        TechSource(id: "mittechreview",
                   title: "MIT Technology Review",
                   host: "technologyreview.com",
                   home: "https://www.technologyreview.com/",
                   feed: "https://www.technologyreview.com/feed/",
                   extraPages: 2),
        TechSource(id: "tomshardware",
                   title: "Tom's Hardware",
                   host: "tomshardware.com",
                   home: "https://www.tomshardware.com/",
                   feed: "https://www.tomshardware.com/feeds.xml"),
        TechSource(id: "theregister",
                   title: "The Register",
                   host: "theregister.com",
                   home: "https://www.theregister.com/",
                   feed: "https://www.theregister.com/headlines.atom",
                   extraPages: 2,
                   pageParameter: "page"),
        TechSource(id: "hackernews",
                   title: "Hacker News",
                   host: "news.ycombinator.com",
                   home: "https://news.ycombinator.com/",
                   feed: "https://news.ycombinator.com/rss"),
        TechSource(id: "cnet",
                   title: "CNET",
                   host: "cnet.com",
                   home: "https://www.cnet.com/",
                   feed: "https://www.cnet.com/rss/all/")
    ]

    static func source(_ id: String) -> TechSource? {
        sources.first { $0.id == id }
    }

    static func entry(for source: SourceID) -> TechSource? {
        guard source.isTech else { return nil }
        return TechCatalogue.source(TechCatalogue.string(from: source))
    }

    /// The symbol shown on the publisher's badge.
    ///
    /// A single letter per publisher, the way a masthead is, so the badge
    /// identifies the source without downloading a logo that would look wrong
    /// at eleven points.
    static func symbol(for source: TechSource) -> String {
        switch source.id {
        case "techcrunch": return "t.circle.fill"
        case "theverge": return "v.circle.fill"
        case "arstechnica": return "flame"
        case "wired": return "w.circle.fill"
        case "engadget": return "e.circle.fill"
        case "mittechreview": return "graduationcap"
        case "tomshardware": return "cpu"
        case "theregister": return "r.circle.fill"
        case "hackernews": return "y.square"
        case "cnet": return "c.circle.fill"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    /// The publisher's own accent, so the badge row is not a wall of one colour.
    static func accent(for source: TechSource) -> String {
        switch source.id {
        case "techcrunch": return "#4E7F4A"
        case "theverge": return "#A34733"
        case "arstechnica": return "#8F4528"
        case "wired": return "#2F5D5A"
        case "engadget": return "#3E6E8C"
        case "mittechreview": return "#A03038"
        case "tomshardware": return "#7A4A22"
        case "theregister": return "#8C3A46"
        case "hackernews": return "#A24E28"
        case "cnet": return "#3F5A7A"
        default: return "#8C3A46"
        }
    }

    /// The catalogue id inside a `tech:` source id.
    static func string(from source: SourceID) -> String {
        String(source.rawValue.dropFirst("tech:".count))
    }

    /// Whether a source's stories are kept without the AI-vocabulary gate.
    ///
    /// The news tab's Hacker News feed only keeps stories that name a model, a
    /// library or a chip, because the app is about that. The Tech News tab is
    /// about technology in general, so the same rule there would throw away
    /// most of the front page — a compiler release, a security advisory, a
    /// database outage — none of which name a model.
    static func keepsWithoutTechnicalGate(_ source: SourceID) -> Bool {
        source.isTech
    }

    /// The section a story belongs to.
    ///
    /// The order matters: the more specific section is tested first, so a story
    /// about a security flaw in a developer tool is filed under security rather
    /// than under developer tools, and a story about a startup's funding round
    /// is filed under startups rather than under business.
    static func category(for item: RadarItem) -> TechCategory {
        // Where a story points is the strongest signal there is. A Hacker News
        // entry titled "mitmproxy adds --emudhra option" names nothing in the
        // vocabulary below, but its link is a commit on github.com, and a commit
        // is a developer story whatever its title. Reading the destination also
        // keeps a paper on arxiv.org out of "Startups & Business".
        switch item.link.host?.lowercased() ?? "" {
        case "github.com", "gitlab.com", "bitbucket.org", "sourcehut.org",
             "sr.ht", "codeberg.org", "news.ycombinator.com":
            return .developerTools
        case "arxiv.org", "nature.com", "science.org", "phys.org",
             "sciencedaily.com", "newscientist.com":
            return .science
        default:
            break
        }
        let hay = (item.title + " " + item.rawSummary + " "
                   + item.sourceCategories.joined(separator: " ")).lowercased()
        if matches(hay, securitySignals) { return .security }
        if matches(hay, scienceSignals) { return .science }
        if matches(hay, hardwareSignals) { return .hardware }
        if matches(hay, gadgetsSignals) { return .gadgets }
        if matches(hay, startupSignals) || matches(hay, businessSignals) {
            return .startups
        }
        if matches(hay, developerSignals) { return .developerTools }
        // "Startups & Business" is the broad section: a general story about a
        // company, a product line or a market is company news. Every story
        // therefore lands in exactly one of the six, so the chip counts always
        // add up to the All Tech figure rather than leaving a silent remainder
        // that no filter can reach.
        return .startups
    }

    /// Whole-word matching, so "ai" cannot match "said" and "chip" cannot match
    /// "chipmunk". Multi-word and hyphenated phrases are matched loosely.
    private static func matches(_ haystack: String, _ signals: [String]) -> Bool {
        let padded = " " + haystack + " "
        for s in signals {
            if s.contains(" ") || s.contains("-") {
                if padded.contains(s) { return true }
            } else if padded.contains(" " + s + " ") {
                return true
            }
        }
        return false
    }

    // MARK: - Signals

    static let securitySignals = [
        "security", "vulnerability", "vulnerabilities", "exploit", "exploits",
        "malware", "ransomware", "phishing", "breach", "breaches", "hacked",
        "hacker", "hackers", "cyberattack", "cybersecurity", "cve", "patch",
        "patches", "backdoor", "zero-day", "zero day", "trojan", "spyware",
        "botnet", "credential", "credentials", "encryption", "decrypt",
        "security flaw", "security bug", "security advisory", "cisa", "encryption key"
    ]

    static let scienceSignals = [
        "science", "research", "researchers", "study", "scientists", "physics",
        "quantum", "biology", "biotech", "space", "nasa", "spacex", "rocket",
        "satellite", "telescope", "astronomy", "mars", "moon", "fusion",
        "climate", "energy", "battery", "batteries", "nuclear", "vaccine",
        "medicine", "medical", "genome", "genetic", "protein", "brain", "neural",
        "dna", "evolution", "laboratory", "experiment", "discovery", "mission"
    ]

    static let hardwareSignals = [
        "gpu", "gpus", "cpu", "cpus", "chip", "chips", "chipmaker", "silicon",
        "processor", "processors", "semiconductor", "semiconductors", "nvidia",
        "amd", "intel", "qualcomm", "apple silicon", "m1", "m2", "m3", "m4",
        "ram", "ssd", "hdd", "nvme", "motherboard", "ram", "graphics card",
        "graphics cards", "gpu", "accelerator", "server", "servers", "data center",
        "data centre", "console", "playstation", "xbox", "nintendo switch",
        "display", "monitor", "keyboard", "mouse", "laptop", "desktop", "pc",
        "smartphone", "phone", "tablet", "wearable", "headphones", "camera",
        "processor node", "wafer", "foundry", "tsmc", "arm"
    ]

    static let gadgetsSignals = [
        "iphone", "ipad", "macbook", "airpods", "apple watch", "vision pro",
        "galaxy", "pixel", "smart watch", "smartwatch", "headphones", "earbuds",
        "gadget", "gadgets", "wearable", "wearables", "review", "hands-on",
        "hands on", "roundup", "deal", "deals", "discount", "launches",
        "unboxing", "teardown", "rumor", "rumour", "foldable", "flip phone",
        "handheld", "console", "playstation", "xbox", "nintendo", "steam deck",
        "camera", "lens", "drone", "ev", "electric car", "electric vehicle"
    ]

    static let startupSignals = [
        "startup", "startups", "seed round", "series a", "series b", "series c",
        "series d", "venture capital", "vc", "funding", "raises", "raised",
        "financing", "led by", "investors", "valuation", "ipo", "acquisition",
        "acquires", "acquired", "merger", "merges", "spin-off", "spinoff",
        "seeded", "pre-seed", "angel round", "y combinator", "demo day",
        "founder", "founders", "co-founder", "cofounder", "term sheet",
        "accelerator", "venture", "pitch", "seed funding", "shuts down",
        "shuts down", "shuttered", "layoffs", "down round", "unicorn"
    ]

    static let developerSignals = [
        "open source", "open-source", "github", "gitlab", "developer",
        "developers", "programming", "programming language", "rust", "golang",
        "go lang", "python", "javascript", "typescript", "swift", "kotlin",
        "java", "c++", "c#", "php", "ruby", "linux", "kernel", "api", "apis",
        "sdk", "framework", "frameworks", "library", "libraries", "compiler",
        "runtime", "cli", "command line", "terminal", "database", "databases",
        "postgres", "postgresql", "mysql", "sqlite", "mongodb", "redis",
        "docker", "kubernetes", "container", "containers", "webassembly", "wasm",
        "release", "releases", "version", "changelog", "pull request",
        "commit", "repository", "codebase", "debugger", "toolchain", "npm",
        "pypi", "crate", "package", "build system", "compiler", "code editor",
        "ide", "vim", "emacs", "neovim", "vs code", "jetbrains", "langchain",
        "hugging face", "pytorch", "tensorflow", "llm", "llms", "model", "models"
    ]

    static let businessSignals = [
        "earnings", "revenue", "profit", "losses", "quarter", "quarterly",
        "annual report", "shares", "stock", "stocks", "nasdaq", "market cap",
        "ceo", "cto", "cfo", "board", "lawsuit", "sues", "sued", "antitrust",
        "regulator", "regulation", "layoffs", "price increase", "price cut",
        "subscription", "pricing", "billion", "million", "b2b", "enterprise",
        "partnership", "partners", "deal", "contract", "customers", "users"
    ]
}
