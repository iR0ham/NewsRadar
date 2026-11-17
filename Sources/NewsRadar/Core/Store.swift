import Foundation

/// On-disk persistence for items, bookmarks, reading history, star snapshots,
/// source health and settings. Everything lives in
/// `~/Library/Application Support/NewsRadar/` as plain JSON so it is easy to
/// inspect, back up or delete.
final class Store {

    struct State: Codable {
        var bookmarkedIDs: Set<String> = []
        var readIDs: Set<String> = []
        var layout: LayoutMode = .comfortable
        /// Which order the lists are in. Previously this lived only in memory, so
        /// every relaunch quietly put the lists back to "Most relevant".
        var sort: SortMode = .relevance
        /// How the lists are ranked, chosen in Settings.
        var rank: RankMode = .fresh
        /// The reader's own order of publishers, used by the "My order" ranking.
        var manualOrder: [String] = []
        var filters: Filters = Filters()
        var ollama: OllamaConfig = OllamaConfig()
        var lastRefresh: Date?
        /// Newest-first cap for the history list.
        var historyLimit: Int = 500

        // MARK: Refresh behaviour

        /// Minutes between automatic checks for new stories while the app is open.
        /// `0` disables the timer; `nil` in an old file means "use the default".
        var autoCheckMinutes: Int = 10
        /// Check once at launch for anything published since the last check.
        var checkOnLaunch: Bool = true
        /// How many days of news to keep. Older items are removed on the next
        /// refresh. `0` keeps everything.
        var retentionDays: Int = 30
        /// Number of news highlights on the Daily Briefing.
        var briefingNewsCount: Int = 6
        /// Number of repository picks on the Daily Briefing. `0` hides the block.
        var briefingRepoCount: Int = 3
        /// Cap on rows in the News and GitHub lists. `0` shows everything.
        var listLimit: Int = 300

        /// Decoded by hand so a state file written by an older build keeps the
        /// user's bookmarks instead of failing to decode and resetting everything.
        init() {}

        private enum CodingKeys: String, CodingKey {
            case bookmarkedIDs, readIDs, layout, sort, filters, ollama, lastRefresh, historyLimit
            case rank, manualOrder
            case autoCheckMinutes, checkOnLaunch, retentionDays
            case briefingNewsCount, briefingRepoCount, listLimit
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = State()
            bookmarkedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .bookmarkedIDs) ?? []
            readIDs = try c.decodeIfPresent(Set<String>.self, forKey: .readIDs) ?? []
            layout = try c.decodeIfPresent(LayoutMode.self, forKey: .layout) ?? fallback.layout
            sort = try c.decodeIfPresent(SortMode.self, forKey: .sort) ?? fallback.sort
            rank = try c.decodeIfPresent(RankMode.self, forKey: .rank) ?? fallback.rank
            manualOrder = try c.decodeIfPresent([String].self, forKey: .manualOrder) ?? []
            filters = try c.decodeIfPresent(Filters.self, forKey: .filters) ?? fallback.filters
            ollama = try c.decodeIfPresent(OllamaConfig.self, forKey: .ollama) ?? fallback.ollama
            lastRefresh = try c.decodeIfPresent(Date.self, forKey: .lastRefresh)
            historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 500
            autoCheckMinutes = try c.decodeIfPresent(Int.self, forKey: .autoCheckMinutes) ?? 10
            checkOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .checkOnLaunch) ?? true
            retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
            briefingNewsCount = try c.decodeIfPresent(Int.self, forKey: .briefingNewsCount) ?? 6
            briefingRepoCount = try c.decodeIfPresent(Int.self, forKey: .briefingRepoCount) ?? 3
            listLimit = try c.decodeIfPresent(Int.self, forKey: .listLimit) ?? 300
        }
    }

    private let dir: URL
    private let fm = FileManager.default

    private(set) var items: [RadarItem] = [] {
        didSet { indexRevision &+= 1 }
    }
    /// A lazily rebuilt id index. `item(id:)` used to scan the whole archive,
    /// and the history list calls it once per row: 500 rows against 3,000
    /// stories was 1.5 million comparisons per draw.
    private var index: [String: RadarItem] = [:]
    private var indexRevision = 0
    private var indexedRevision = -1

    private func indexed() -> [String: RadarItem] {
        if indexedRevision != indexRevision {
            index = Dictionary(items.map { ($0.id, $0) },
                               uniquingKeysWith: { a, _ in a })
            indexedRevision = indexRevision
        }
        return index
    }
    private(set) var history: [HistoryEntry] = []
    private(set) var snapshots: [StarSnapshot] = []
    private(set) var sources: [SourceStatus] = []
    /// Sources the user added from inside the app. Kept beside the status list so
    /// a source and its health survive a relaunch together.
    private(set) var customSources: [CustomSource] = []
    /// Repository READMEs, keyed by "owner/name". Kept in its own file because a
    /// refresh rewrites items.json wholesale; text stored on an item was lost on the
    /// next check, which is why a project's README never appeared.
    private(set) var readmes: [String: String] = [:]
    private(set) var briefings: [String: DailyBriefing] = [:]
    private(set) var state = State()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL? = nil) {
        if let directory {
            dir = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            // The folder is the app's name, and the name changed. The old one is
            // moved on first launch rather than abandoned: it holds the archive,
            // the bookmarks and every setting, and leaving it behind would look
            // exactly like the app having forgotten everything.
            let legacy = base.appendingPathComponent("AIRadar", isDirectory: true)
            let current = base.appendingPathComponent("NewsRadar", isDirectory: true)
            if !FileManager.default.fileExists(atPath: current.path),
               FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.moveItem(at: legacy, to: current)
            }
            dir = current
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    var directory: URL { dir }

    // MARK: - Paths

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name + ".json") }

    // MARK: - Load / save

    func load() {
        // A state file that fails to decode must say so. Falling back to a default
        // State() is what "my settings reset themselves" looked like from outside:
        // silent, total, and every launch.
        if let data = try? Data(contentsOf: url("state")) {
            do {
                state = try Self.decoder.decode(State.self, from: data)
            } catch {
                FileHandle.standardError.write(
                    Data("state could not be decoded, so settings fall back to defaults: \(error)\n".utf8))
                state = State()
            }
        } else {
            state = State()
        }
        items = read("items", as: [RadarItem].self) ?? []
        history = read("history", as: [HistoryEntry].self) ?? []
        snapshots = read("snapshots", as: [StarSnapshot].self) ?? []
        sources = read("sources", as: [SourceStatus].self) ?? []
        briefings = read("briefings", as: [String: DailyBriefing].self) ?? [:]
        readmes = read("readmes", as: [String: String].self) ?? [:]
        // Dates in this file are ISO-8601 without fractional seconds; the shared
        // decoder is strict about it, so a decode failure here would silently drop
        // every source the user added. Report rather than swallow.
        if let data = try? Data(contentsOf: url("custom_sources")) {
            do {
                customSources = try Self.decoder.decode([CustomSource].self, from: data)
            } catch {
                FileHandle.standardError.write(
                    Data("custom_sources could not be decoded: \(error)\n".utf8))
                customSources = []
            }
        } else {
            customSources = []
        }
        // The fetch engine resolves a source id to its feed without being handed
        // state, so the registry is loaded here, before anything can fetch.
        SourceRegistry.shared.replaceAll(customSources)
        pruneSnapshots()
    }

    private func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        let u = url(name)
        guard let data = try? Data(contentsOf: u) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ name: String, _ value: T) {
        let u = url(name)
        guard let data = try? Self.encoder.encode(value) else { return }
        // Atomic write: a crash mid-refresh must not leave a truncated items.json.
        try? data.write(to: u, options: .atomic)
    }

    /// Adds a validated source and writes it. Returns false when the same feed is
    /// already configured.
    @discardableResult
    func addCustomSource(_ source: CustomSource) -> Bool {
        guard SourceRegistry.shared.add(source) else { return false }
        customSources = SourceRegistry.shared.all
        write("custom_sources", customSources)
        return true
    }

    func removeCustomSource(id: String) {
        guard let removed = SourceRegistry.shared.remove(id) else { return }
        customSources = SourceRegistry.shared.all
        write("custom_sources", customSources)
        sources.removeAll { $0.source == removed.sourceID }
        items.removeAll { $0.source == removed.sourceID }
        write("sources", sources)
        write("custom_sources", customSources)
        saveAll()
    }

    func saveAll() {
        write("state", state)
        write("items", items)
        write("history", history)
        write("snapshots", snapshots)
        write("sources", sources)
        write("custom_sources", customSources)
        write("briefings", briefings)
    }

    // MARK: - Items

    /// Merges freshly fetched items with what is on disk. Existing items keep
    /// their rendering and bookmarks; the newest fields win.
    func merge(newItems: [RadarItem], now: Date = Date(),
               retentionDays: Int? = nil) {
        var byID: [String: RadarItem] = [:]
        for i in items { byID[i.id] = i }
        for var n in newItems {
            if let old = byID[n.id] {
                // Preserve the previous rendering unless the raw content changed,
                // so a re-render only happens when it is warranted.
                if old.rawSummary == n.rawSummary && old.title == n.title
                    && !old.headline.isEmpty {
                    n.headline = old.headline
                    n.summary = old.summary
                    n.keyPoints = old.keyPoints
                    n.summaryEngine = old.summaryEngine
                }
                if n.imageURL == nil { n.imageURL = old.imageURL }
            }
            byID[n.id] = n
        }
        var merged = Array(byID.values)
        merged.sort { $0.published > $1.published }
        // The archive window is a setting. `0` means keep everything, which the
        // user asked for as the alternative to "delete news older than N days".
        let days = retentionDays ?? state.retentionDays
        if days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86400)
            merged = Self.keepingSlowPublishers(merged, cutoff: cutoff)
        }
        items = merged
    }

    /// Applies the retention window, but leaves a slow publisher one story.
    ///
    /// The window was written for the news firehose, where a 14-day cut removes
    /// hundreds of stories a day. Applied to a design blog that posts twice a
    /// month it removes the only story there is, and the section then reads as
    /// broken: the source answers, its status is green, and its list is empty.
    ///
    /// So a source with nothing inside the window keeps its newest few, up to a
    /// year old. Past that the publisher has stopped rather than slowed, and
    /// showing a two-year-old post as though it were current would be the lie
    /// the retention window exists to prevent.
    private static func keepingSlowPublishers(_ items: [RadarItem],
                                              cutoff: Date,
                                              now: Date = Date()) -> [RadarItem] {
        let recent = items.filter { $0.published > cutoff }
        let floor = now.addingTimeInterval(-365 * 86400)
        var kept = Set(recent.map { $0.id })
        var bySource: [SourceID: [RadarItem]] = [:]
        for item in items where item.published <= cutoff && item.published > floor {
            bySource[item.source, default: []].append(item)
        }
        var extra: [RadarItem] = []
        // A set, not a `contains` over the recent array: with a hundred mostly
        // quiet publishers the old check compared every old item against every
        // recent one, which is why a prune on a full archive took a visible pause.
        let recentSources = Set(recent.map { $0.source })
        for (source, old) in bySource where !recentSources.contains(source) {
            extra.append(contentsOf: old.sorted { $0.published > $1.published }.prefix(3))
        }
        for item in extra { kept.insert(item.id) }
        return items.filter { kept.contains($0.id) }
    }

    /// Removes stored items older than the retention window right now, without a
    /// network refresh. Returns how many were removed.
    @discardableResult
    func pruneOlderThanRetention(now: Date = Date()) -> Int {
        guard state.retentionDays > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(state.retentionDays) * 86400)
        let before = items.count
        items = Self.keepingSlowPublishers(items, cutoff: cutoff, now: now)
        let removed = before - items.count
        if removed > 0 { saveAll() }
        return removed
    }

    func item(id: String) -> RadarItem? { indexed()[id] }

    func items(ids: [String]) -> [RadarItem] {
        let index = indexed()
        return ids.compactMap { index[$0] }
    }

    // MARK: - Bookmarks

    func isBookmarked(_ id: String) -> Bool { state.bookmarkedIDs.contains(id) }

    @discardableResult
    func toggleBookmark(_ id: String) -> Bool {
        if state.bookmarkedIDs.contains(id) {
            state.bookmarkedIDs.remove(id)
            write("state", state)
            return false
        }
        state.bookmarkedIDs.insert(id)
        write("state", state)
        return true
    }

    var bookmarkedItems: [RadarItem] {
        let ids = state.bookmarkedIDs
        return items.filter { ids.contains($0.id) }
            .sorted { ($0.published, $0.id) > ($1.published, $1.id) }
    }

    // MARK: - Reading history

    func isRead(_ id: String) -> Bool { state.readIDs.contains(id) }

    /// Records that an item was opened. Bumps the timestamp and counter instead
    /// of duplicating the entry.
    /// Caches a repository README and writes it, so the next launch does not fetch
    /// it again and a refresh cannot drop it.
    func setReadme(_ text: String, for fullName: String) {
        readmes[fullName] = text
        write("readmes", readmes)
    }

    func markOpened(_ item: RadarItem, now: Date = Date()) {
        let previousCount = history.first { $0.itemID == item.id }?.readCount ?? 0
        history.removeAll { $0.itemID == item.id }
        history.insert(HistoryEntry(id: item.id,
                                    itemID: item.id,
                                    title: item.title,
                                    source: item.source,
                                    link: item.link,
                                    openedAt: now,
                                    readCount: previousCount + 1), at: 0)
        if history.count > state.historyLimit {
            history = Array(history.prefix(state.historyLimit))
        }
        state.readIDs.insert(item.id)
        saveHistory()
    }

    func markRead(_ id: String) {
        state.readIDs.insert(id)
        write("state", state)
    }

    func markAllRead(_ ids: [String]) {
        for id in ids { state.readIDs.insert(id) }
        write("state", state)
    }

    private func saveHistory() {
        write("history", history)
        write("state", state)
    }

    func clearHistory() {
        history = []
        state.readIDs = []
        write("history", history)
        write("state", state)
    }

    var historyItems: [(entry: HistoryEntry, item: RadarItem?)] {
        history.map { ($0, self.item(id: $0.itemID)) }
    }

    // MARK: - Snapshots (star growth)

    func appendSnapshots(_ new: [StarSnapshot]) {
        guard !new.isEmpty else { return }
        for s in new {
            if let idx = snapshots.firstIndex(where: { $0.fullName == s.fullName && abs($0.takenAt.timeIntervalSince(s.takenAt)) < 600 }) {
                snapshots[idx] = s
            } else {
                snapshots.append(s)
            }
        }
        pruneSnapshots()
        write("snapshots", snapshots)
    }

    /// Keeps at most one snapshot per repo per day, and at most 45 days.
    private func pruneSnapshots() {
        let cutoff = Date().addingTimeInterval(-45 * 86400)
        var keep: [StarSnapshot] = []
        var seen = Set<String>()
        for s in snapshots.sorted(by: { $0.takenAt > $1.takenAt }) {
            guard s.takenAt > cutoff else { continue }
            let day = Digest.dayKey(s.takenAt)
            let key = "\(s.fullName)|\(day)"
            if seen.contains(key) { continue }
            seen.insert(key)
            keep.append(s)
        }
        snapshots = keep
    }

    /// Growth measured from the oldest snapshot at least 12h old.
    func growth(for fullName: String, current: Int, now: Date = Date()) -> Int? {
        let prior = snapshots
            .filter { $0.fullName == fullName }
            .sorted { $0.takenAt < $1.takenAt }
            .first
        guard let prior, now.timeIntervalSince(prior.takenAt) > 12 * 3600 else { return nil }
        return current - prior.stars
    }

    // MARK: - Sources

    func setStatuses(_ list: [SourceStatus]) {
        var byID: [String: SourceStatus] = [:]
        for s in sources { byID[s.source.rawValue] = s }
        for s in list { byID[s.source.rawValue] = s }
        sources = SourceID.all.compactMap { byID[$0.rawValue] }
        write("sources", sources)
        write("custom_sources", customSources)
    }

    func status(for source: SourceID) -> SourceStatus? {
        sources.first { $0.source == source }
    }

    // MARK: - Briefings

    func setBriefing(_ b: DailyBriefing) {
        briefings[b.dayKey] = b
        // Keep the last 30 days of briefings.
        let keys = briefings.keys.sorted()
        if keys.count > 30 {
            for k in keys.dropLast(30) { briefings.removeValue(forKey: k) }
        }
        write("briefings", briefings)
    }

    func briefing(for date: Date) -> DailyBriefing? { briefings[Digest.dayKey(date)] }

    func previousTopIDs(before date: Date) -> Set<String> {
        let yesterday = date.addingTimeInterval(-86400)
        guard let b = briefing(for: yesterday) else { return [] }
        return Set(b.highlightIDs)
    }

    // MARK: - Settings

    /// Applies a change to the settings and writes them.
    ///
    /// The on-disk file is re-read first and the change is applied to *that*, not to
    /// this process's copy. Without it a second copy of the app (or a window opened
    /// before the user changed something in another window) wrote its stale settings
    /// over the newer file, which is why settings appeared to reset themselves
    /// between launches.
    func updateState(_ mutate: (inout State) -> Void) {
        if let fresh = read("state", as: State.self) { state = fresh }
        mutate(&state)
        write("state", state)
    }

    var sizeOnDisk: Int64 {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(into: Int64(0)) { acc, u in
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            acc += Int64(size)
        }
    }

    func resetEverything() {
        items = []
        history = []
        snapshots = []
        sources = []
        briefings = [:]
        state = State()
        for name in ["items", "history", "snapshots", "sources", "briefings", "state"] {
            try? fm.removeItem(at: url(name))
        }
    }
}
