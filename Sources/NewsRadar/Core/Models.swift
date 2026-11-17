import Foundation

// MARK: - Sources

// MARK: - Categories

enum Category: String, CaseIterable, Codable, Identifiable, Hashable {
    case llm
    case agent
    case coding
    case imageVideo
    case audio
    case localLLM
    case hardware
    case research
    case business
    case policy
    case tools
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .llm: return "Language Models"
        case .agent: return "AI Agents"
        case .coding: return "Coding Tools"
        case .imageVideo: return "Image, Video & Motion"
        case .audio: return "Audio & Speech"
        case .localLLM: return "Local Models"
        case .hardware: return "Hardware & Chips"
        case .research: return "Research"
        case .business: return "Business & Funding"
        case .policy: return "Policy & Regulation"
        case .tools: return "Tools & Platforms"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .llm: return "brain"
        case .agent: return "cpu"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .imageVideo: return "photo.on.rectangle.angled"
        case .audio: return "waveform"
        case .localLLM: return "desktopcomputer"
        case .hardware: return "memorychip"
        case .research: return "doc.text.magnifyingglass"
        case .business: return "dollarsign.circle"
        case .policy: return "building.columns"
        case .tools: return "wrench.and.screwdriver"
        case .other: return "sparkles"
        }
    }

    /// A restrained wine and slate ramp instead of a full rainbow: maroon leads,
    /// then muted reds, then desaturated slate-greys for the smaller categories, so
    /// the chart reads as one palette rather than twelve unrelated colours.
    var accentHex: String {
        switch self {
        case .llm: return "#C02434"
        case .agent: return "#A81E2B"
        case .coding: return "#8C1622"
        case .imageVideo: return "#D9434F"
        case .audio: return "#B8443F"
        case .localLLM: return "#7A2A33"
        case .hardware: return "#66202A"
        case .research: return "#9C8A8E"
        case .business: return "#7C6A6E"
        case .policy: return "#5E4B50"
        case .tools: return "#4A4E58"
        case .other: return "#3A3D45"
        }
    }
}

// MARK: - Item

enum ItemKind: String, Codable, Hashable {
    case news
    case product
    case newsletter
    case repository
}

/// A single radar entry: a news story, product launch or repository.
struct RadarItem: Identifiable, Codable, Hashable {
    /// Stable identity across refreshes (guid / link).
    var id: String
    var source: SourceID
    var kind: ItemKind
    /// The headline exactly as the source published it.
    var title: String
    var link: URL
    var published: Date
    /// True when the date is the moment the listing page was read rather than
    /// the story's own publication date. The date is corrected from the article
    /// page's metadata as soon as the page is read.
    var publishedFromListing: Bool = false
    /// Cleaned body text supplied by the source feed.
    var rawSummary: String
    var imageURL: URL?
    var author: String?
    var sourceCategories: [String]

    // Classification (computed once, persisted with the item).
    var category: Category = .other
    var tags: [String] = []
    var openSource: Bool = false
    var free: Bool = false
    var localExecution: Bool = false
    var appleSilicon: Bool = false
    var paidAPI: Bool = false
    var score: Double = 0

    /// Display summary: the source's own text, or a digest composed from
    /// measured data, or a local-model rewrite.
    var summary: String = ""
    /// Headline as shown in the UI. Falls back to `title` when empty.
    var headline: String = ""
    /// Factual bullet points (stars, language, licence, flags).
    var keyPoints: [String] = []
    /// "source", "digest" or "ollama:<model>".
    var summaryEngine: String = "source"

    /// Repository payload when the item came from GitHub.
    var repo: RepoStats?

    /// The section this story belongs to in the Tech News tab.
    ///
    /// Only a story from a Tech News publisher has one. The news taxonomy
    /// (Language Models, AI Agents, …) has no place for a story about a
    /// graphics card or a ransomware advisory, and forcing one into it is how
    /// a feed ends up filed under the wrong heading. So the Tech tab carries
    /// its own sections, stored with the story like every other fact.
    var techCategory: TechCategory? = nil

    var isGitHub: Bool { repo != nil }

    /// The section shown on the card.
    ///
    /// A Tech News story shows its own section; everything else shows the news
    /// taxonomy. The card is the same card in every tab, so the question has to
    /// be answered by the item, not by the view that draws it.
    var displaySectionTitle: String {
        techCategory?.title ?? category.title
    }

    var displaySectionSymbol: String {
        techCategory?.symbol ?? category.symbol
    }

    var displaySectionAccentHex: String {
        techCategory?.accentHex ?? category.accentHex
    }

    /// What a card shows as its title.
    var displayTitle: String { headline.isEmpty ? title : headline }

    /// The memberwise initialiser, written out by hand.
    ///
    /// Declaring a custom `init(from:)` removed the one the compiler would have
    /// synthesised, and four call sites build items directly. Rather than
    /// change every caller, the initialiser is restated here — with the same
    /// argument order, so a new field is added in one place and defaults to
    /// nothing.
    init(id: String,
         source: SourceID,
         kind: ItemKind,
         title: String,
         link: URL,
         published: Date,
         rawSummary: String,
         imageURL: URL?,
         author: String?,
         sourceCategories: [String],
         category: Category = .other,
         tags: [String] = [],
         openSource: Bool = false,
         free: Bool = false,
         localExecution: Bool = false,
         appleSilicon: Bool = false,
         paidAPI: Bool = false,
         score: Double = 0,
         summary: String = "",
         headline: String = "",
         keyPoints: [String] = [],
         summaryEngine: String = "source",
         repo: RepoStats? = nil,
         publishedFromListing: Bool = false,
         techCategory: TechCategory? = nil) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.link = link
        self.published = published
        self.rawSummary = rawSummary
        self.imageURL = imageURL
        self.author = author
        self.sourceCategories = sourceCategories
        self.category = category
        self.tags = tags
        self.openSource = openSource
        self.free = free
        self.localExecution = localExecution
        self.appleSilicon = appleSilicon
        self.paidAPI = paidAPI
        self.score = score
        self.summary = summary
        self.headline = headline
        self.keyPoints = keyPoints
        self.summaryEngine = summaryEngine
        self.repo = repo
        self.publishedFromListing = publishedFromListing
        self.techCategory = techCategory
    }

    enum CodingKeys: String, CodingKey {
        case id, source, kind, title, link, published, rawSummary, imageURL, author
        case sourceCategories, category, tags, openSource, free, localExecution
        case appleSilicon, paidAPI, score, summary, headline, keyPoints, summaryEngine, repo
        case publishedFromListing, techCategory
    }

    /// Decoded key by key, with a default for every optional field.
    ///
    /// The synthesised decoder required every key, so one new field on this
    /// struct would have made the whole `items.json` fail to decode — and
    /// `Store.load` answers a failed decode with an empty archive. The reader
    /// would have opened the app to a blank list with no warning at all. A
    /// field added today must not cost the reader yesterday's stories.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(SourceID.self, forKey: .source)
        kind = try c.decodeIfPresent(ItemKind.self, forKey: .kind) ?? .news
        title = try c.decode(String.self, forKey: .title)
        link = try c.decode(URL.self, forKey: .link)
        published = try c.decodeIfPresent(Date.self, forKey: .published)
            ?? Date(timeIntervalSince1970: 0)
        rawSummary = try c.decodeIfPresent(String.self, forKey: .rawSummary) ?? ""
        imageURL = try c.decodeIfPresent(URL.self, forKey: .imageURL)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        sourceCategories = try c.decodeIfPresent([String].self, forKey: .sourceCategories) ?? []
        category = try c.decodeIfPresent(Category.self, forKey: .category) ?? .other
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        openSource = try c.decodeIfPresent(Bool.self, forKey: .openSource) ?? false
        free = try c.decodeIfPresent(Bool.self, forKey: .free) ?? false
        localExecution = try c.decodeIfPresent(Bool.self, forKey: .localExecution) ?? false
        appleSilicon = try c.decodeIfPresent(Bool.self, forKey: .appleSilicon) ?? false
        paidAPI = try c.decodeIfPresent(Bool.self, forKey: .paidAPI) ?? false
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        summaryEngine = try c.decodeIfPresent(String.self, forKey: .summaryEngine) ?? "source"
        repo = try c.decodeIfPresent(RepoStats.self, forKey: .repo)
        publishedFromListing = try c.decodeIfPresent(Bool.self, forKey: .publishedFromListing) ?? false
        techCategory = try c.decodeIfPresent(TechCategory.self, forKey: .techCategory)
    }
}

/// GitHub statistics for a repository entry.
struct RepoStats: Codable, Hashable {
    var fullName: String
    var htmlURL: URL
    var stars: Int
    var forks: Int?
    var language: String?
    var license: String?
    var created: Date?
    var pushed: Date?
    var topics: [String] = []
    var descriptionEN: String?
    var homepage: URL?
    /// Stars gained today, scraped from the trending page when available.
    var starsToday: Int?
    /// Growth measured from locally snapshotted star counts.
    var starGrowth7d: Int?
    /// Shown in place of growth until enough local history exists.
    var starGrowthNote: String?
}

// MARK: - Layout & filtering

enum LayoutMode: String, CaseIterable, Codable, Identifiable {
    case compact
    case comfortable
    case grid

    var id: String { rawValue }

    /// The suffix the row views carry in their `.id`, so a scroll target can name
    /// the row that is actually on screen for the current layout.
    var idSuffix: String {
        switch self {
        case .compact: return "c"
        case .comfortable: return "f"
        case .grid: return "g"
        }
    }

    var title: String {
        switch self {
        case .compact: return "Compact List"
        case .comfortable: return "Comfortable List"
        case .grid: return "Visual Grid"
        }
    }

    var symbol: String {
        switch self {
        case .compact: return "list.bullet"
        case .comfortable: return "rectangle.grid.1x2"
        case .grid: return "square.grid.2x2"
        }
    }
}

enum SortMode: String, CaseIterable, Identifiable, Codable {
    case relevance
    case newest
    case oldest
    case stars
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        // The default is not a sort of its own: it draws the standing ranking
        // chosen in Settings, which is what "Ranked order" says.
        case .relevance: return "Ranked order"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .stars: return "Most stars"
        case .source: return "By source"
        }
    }
}

/// The four reading surfaces of the app, as the Daily Briefing sees them.
///
/// The briefing is the app's home page, so it has to speak about everything the
/// app collects, not only about AI news. Each surface gets its own block, with
/// its own picks, so a reader who only follows the web and SEO side is not made
/// to scroll past forty AI headlines to reach it.
enum BriefingSection: String, CaseIterable, Codable, Identifiable, Hashable {
    case news
    case tech
    case web
    case design
    case code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .news: return "AI News"
        case .tech: return "Tech News"
        case .web: return "Web & SEO"
        case .design: return "Design & Creative AI"
        case .code: return "GitHub & Code"
        }
    }

    var symbol: String {
        switch self {
        case .news: return "newspaper"
        case .tech: return "cpu"
        case .web: return "globe"
        case .design: return "paintpalette.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The sidebar tab this section is read in.
    var navSection: NavSection {
        switch self {
        case .news: return .all
        case .tech: return .tech
        case .web: return .web
        case .design: return .design
        case .code: return .github
        }
    }

    /// Which surface an item belongs to.
    static func section(for item: RadarItem) -> BriefingSection {
        if item.isGitHub { return .code }
        return section(for: item.source)
    }

    /// Which surface a source belongs to.
    ///
    /// A publisher can be read in two tabs with two different feeds — MIT
    /// Technology Review publishes an AI topic feed that the news tab reads
    /// and a general feed that the Tech News tab reads. Those are different
    /// scopes of the same publication, and the same story can legitimately
    /// appear in both tabs. The dedupe has to know which tab a copy belongs
    /// to, or it would delete the story from one of them.
    static func section(for source: SourceID) -> BriefingSection {
        if source.kind == .github { return .code }
        if source.isTech { return .tech }
        guard let surface = DesignCatalogue.surface(of: source) else { return .news }
        return surface == .web ? .web : .design
    }
}

/// How the lists are ranked.
///
/// Sorting by relevance alone was not enough once the app collected more than
/// AI news: a design blog and a search-engine update both scored on freshness
/// and on "is it free", which said nothing about which of them the reader
/// wanted first. Ranking is therefore a choice, made once, in Settings, and it
/// applies to every list in the app.
enum RankMode: String, CaseIterable, Identifiable, Codable {
    /// Freshness first, with the app's own relevance score breaking ties.
    case fresh
    /// The relevance score decides, and freshness breaks ties.
    case relevance
    /// Repositories first, then everything else by relevance. For a reader whose
    /// interest is what can be built rather than what was announced.
    case projects
    /// The publisher with the most items in the window comes first, then
    /// freshness. For a reader tracking one beat from many sources.
    case source
    /// Whatever the reader's own filters have selected, in the order they
    /// selected it.
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fresh: return "Freshest first"
        case .relevance: return "Most relevant"
        case .projects: return "Projects first"
        case .source: return "Busiest source first"
        case .manual: return "My order"
        }
    }

    /// One line explaining what the mode does, shown under the picker.
    var detail: String {
        switch self {
        case .fresh:
            return "Newest stories at the top, whatever the score says. The default, and the right one when you want to know what just happened."
        case .relevance:
            return "The app's own score decides: free, open source, runs locally, Apple Silicon friendly, then recency."
        case .projects:
            return "Repositories and tools first, then news. For a reader who is here to find something to build with."
        case .source:
            return "The publisher with the most stories in this window comes first, then the newest of theirs."
        case .manual:
            return "Your filters decide what is shown, and the order is the one you chose in the list."
        }
    }

    /// Whether this mode needs a source list the reader arranged by hand.
    var needsManualOrder: Bool { self == .manual }
}

/// How far back the feed looks. The first four are the quick filters shown in
/// the toolbar; the last two exist for the filter panel.
enum DateRange: String, CaseIterable, Codable, Identifiable {
    case twelveHours
    case day
    case threeDays
    case week
    case month
    case all

    var id: String { rawValue }

    /// The ranges offered as one-click buttons in the toolbar.
    static let quick: [DateRange] = [.twelveHours, .day, .threeDays, .week]

    var title: String {
        switch self {
        case .twelveHours: return "Last 12 hours"
        case .day: return "Last 24 hours"
        case .threeDays: return "Last 72 hours"
        case .week: return "Last week"
        case .month: return "Last month"
        case .all: return "All time"
        }
    }

    /// Condensed label for the toolbar segmented control.
    var shortTitle: String {
        switch self {
        case .twelveHours: return "12h"
        case .day: return "24h"
        case .threeDays: return "72h"
        case .week: return "1w"
        case .month: return "1m"
        case .all: return "All"
        }
    }

    /// The window in prose, for a sentence that has to say which one it means.
    var label: String {
        switch self {
        case .twelveHours: return "12 hours"
        case .day: return "24 hours"
        case .threeDays: return "72 hours"
        case .week: return "week"
        case .month: return "month"
        case .all: return "archive"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .twelveHours: return 12 * 3600
        case .day: return 24 * 3600
        case .threeDays: return 72 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        case .all: return nil
        }
    }
}

enum NavSection: String, CaseIterable, Identifiable, Codable {
    case digest
    case all
    case tech
    case web
    case design
    case bookmarks
    case history
    case github
    case sources
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .digest: return "Daily Briefing"
        case .all: return "AI News"
        case .tech: return "Tech News"
        case .web: return "Web & SEO"
        case .design: return "Design & Creative AI"
        case .bookmarks: return "Bookmarks"
        case .history: return "Reading History"
        case .github: return "GitHub & Code"
        case .sources: return "Source Status"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .digest: return "sun.max.fill"
        case .all: return "newspaper"
        case .tech: return "cpu"
        case .web: return "globe"
        case .design: return "paintpalette.fill"
        case .bookmarks: return "bookmark.fill"
        case .history: return "clock.arrow.circlepath"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .sources: return "antenna.radiowaves.left.and.right"
        case .settings: return "gearshape"
        }
    }
}

/// All user-facing filters. An empty `sources` set means "every source".
struct Filters: Codable, Hashable {
    var category: Category?
    var range: DateRange = .twelveHours
    var sources: Set<SourceID> = []
    var openSourceOnly: Bool = false
    var freeOnly: Bool = false
    var localOnly: Bool = false
    var appleSiliconFirst: Bool = true
    var unreadOnly: Bool = false
    var query: String = ""

    init() {}

    /// Decoded key by key on purpose. The synthesised decoder required every key,
    /// so a filters object written without `sources` (an older build, a hand-edited
    /// file) threw, the whole state file failed to decode, and *every* setting —
    /// layout, sort, refresh interval — silently went back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Filters()
        category = try c.decodeIfPresent(Category.self, forKey: .category)
        range = try c.decodeIfPresent(DateRange.self, forKey: .range) ?? fallback.range
        sources = try c.decodeIfPresent(Set<SourceID>.self, forKey: .sources) ?? []
        openSourceOnly = try c.decodeIfPresent(Bool.self, forKey: .openSourceOnly) ?? false
        freeOnly = try c.decodeIfPresent(Bool.self, forKey: .freeOnly) ?? false
        localOnly = try c.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
        appleSiliconFirst = try c.decodeIfPresent(Bool.self, forKey: .appleSiliconFirst) ?? true
        unreadOnly = try c.decodeIfPresent(Bool.self, forKey: .unreadOnly) ?? false
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
    }

    var isDefault: Bool {
        category == nil && range == .twelveHours && sources.isEmpty && !openSourceOnly
            && !freeOnly && !localOnly && !unreadOnly && query.isEmpty
    }

    var activeCount: Int {
        var n = 0
        if category != nil { n += 1 }
        if range != .twelveHours { n += 1 }
        if !sources.isEmpty { n += 1 }
        if openSourceOnly { n += 1 }
        if freeOnly { n += 1 }
        if localOnly { n += 1 }
        if unreadOnly { n += 1 }
        return n
    }
}

// MARK: - Source health

struct SourceStatus: Codable, Identifiable, Hashable {
    var source: SourceID
    var lastAttempt: Date?
    var lastSuccess: Date?
    var itemCount: Int = 0
    var ok: Bool = false
    var message: String = ""
    var fromCache: Bool = false
    /// The server confirmed nothing was published since the last check, so no
    /// parsing or summarisation happened. Optional so older status files decode.
    var unchanged: Bool? = nil

    /// Whether the failure is the kind that a second attempt can fix. Timeouts,
    /// dropped connections and 5xx are transient; a 403 or a 404 will say the same
    /// thing however many times it is asked.
    var failedRetryably: Bool {
        if ok { return false }
        let m = message.lowercased()
        if m.contains("(403)") || m.contains("(404)") || m.contains("(401)")
            || m.contains("(410)") || m.contains("refuses automated")
            || m.contains("does not exist") || m.contains("requires a sign-in") {
            return false
        }
        return true
    }

    var id: String { source.rawValue }
}

// MARK: - History / bookmarks

struct HistoryEntry: Identifiable, Codable, Hashable {
    var id: String
    var itemID: String
    var title: String
    var source: SourceID
    var link: URL
    var openedAt: Date
    var readCount: Int = 1
}

/// Star snapshot used to compute real growth over time.
struct StarSnapshot: Codable, Hashable {
    var fullName: String
    var stars: Int
    var takenAt: Date
}
