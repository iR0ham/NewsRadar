import Foundation
import Observation
import SwiftUI

/// The window's model layer: owns the store, the active filters, the current
/// section and the refresh lifecycle. All mutations happen on the main actor.
@MainActor
@Observable
final class AppModel {

    let store: Store

    // Navigation & presentation
    var section: NavSection = .digest
    var layout: LayoutMode
    var sort: SortMode
    /// How the lists are ranked. Chosen in Settings; the toolbar's sort menu is
    /// a separate, per-look override.
    var rank: RankMode
    /// The reader's own order of publishers, for the "My order" ranking.
    var manualOrder: [SourceID]
    var filters: Filters
    /// Filters belonging to the Web & SEO and Design & Creative AI tabs.
    ///
    /// They live here, not in the view, so the toolbar's Filter button can edit
    /// the same state the tab header draws. Held separately in one pair of
    /// properties rather than per tab: switching tabs and coming back to the
    /// section you were reading is what a reader expects, and a stale chip row
    /// that disagrees with the popover is what they do not.
    var designSection: DesignCategory?
    var designSource: String?
    var designRange: DateRange = .all
    /// Filters belonging to the Tech News tab.
    ///
    /// Held on the model, like the catalogue tabs' own filters, so the
    /// toolbar's Filter button and the tab header edit one state. A chip that
    /// disagrees with the popover is worse than no chip.
    var techSection: TechCategory?
    var techSource: String?
    var techRange: DateRange = .day
    var ollama: OllamaConfig

    // Refresh lifecycle
    var isRefreshing = false
    /// Which refresh is running, so the toolbar can spinner the right button.
    var isChecking = false
    var progress: RefreshEngine.Progress?
    var lastOutcome: RefreshEngine.Outcome?
    var statusMessage: String?
    var toast: String?
    /// When this launch drew its first frame, so the automatic check can be held
    /// off until the window is up.
    private var launchStartedAt: Date = Date()

    // Ollama discovery
    var ollamaModels: [String] = []
    var checkingOllama = false
    var ollamaReachable = false

    // Refresh & display settings, mirrored from the store so the UI can bind.
    /// The interval to restore when auto-check is switched back on.
    var lastAutoCheckMinutes: Int = 10
    var autoCheckMinutes: Int
    var checkOnLaunch: Bool
    var retentionDays: Int
    var briefingNewsCount: Int
    var briefingRepoCount: Int
    var listLimit: Int

    // Detail sheet
    var detailItem: RadarItem?
    /// The article being read inside the app, if any.
    var readerItem: RadarItem?
    /// Whether the "add a source" sheet is open.
    var showAddSource = false
    /// Set once at launch to open the filter popover, for screenshots.
    var openFiltersOnLaunch = false
    /// Bumped whenever stored items change, so list views recompute.
    var revision = 0
    /// Bumped by the ⌘F shortcut to focus the search field.
    var focusSearchTick = 0

    private var didBootstrap = false
    private var filterPersistTask: Task<Void, Never>?

    /// Debounced filter persistence: typing in the search box must not write JSON
    /// on every keystroke.
    func scheduleFilterPersist() {
        filterPersistTask?.cancel()
        filterPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.persistFilters() }
        }
    }

    /// `NEWSRADAR_DATA_DIR` points the app at an alternative data directory, which
    /// lets the UI be exercised against a throwaway store without touching the
    /// user's bookmarks and history. Ignored when unset.
    static func defaultStore() -> Store {
        if let path = ProcessInfo.processInfo.environment["NEWSRADAR_DATA_DIR"], !path.isEmpty {
            return Store(directory: URL(fileURLWithPath: path, isDirectory: true))
        }
        return Store()
    }

    init(store: Store? = nil) {
        let store = store ?? AppModel.defaultStore()
        self.store = store
        self.layout = store.state.layout
        self.sort = store.state.sort
        self.rank = store.state.rank
        self.manualOrder = store.state.manualOrder.compactMap { SourceID(rawValue: $0) }
        self.filters = store.state.filters
        self.ollama = store.state.ollama
        self.autoCheckMinutes = store.state.autoCheckMinutes
        self.checkOnLaunch = store.state.checkOnLaunch
        self.retentionDays = store.state.retentionDays
        self.briefingNewsCount = store.state.briefingNewsCount
        self.briefingRepoCount = store.state.briefingRepoCount
        self.listLimit = store.state.listLimit
        if ollama.enabled {
            ollamaModels = ollama.knownModels
            if ollama.model.isEmpty { ollama.model = ollamaModels.first ?? "" }
        }
        // UI-testing hook: `NEWSRADAR_SECTION=settings` opens the window on that
        // tab, so the build script can capture every screen without synthesising
        // clicks. Ignored when unset or unknown.
        // UI-testing hook: `NEWSRADAR_FILTER_SOURCE=blog.google` opens the news list
        // filtered to one source, which is the state that looked broken.
        if let raw = ProcessInfo.processInfo.environment["NEWSRADAR_FILTER_SOURCE"], !raw.isEmpty {
            filters.sources = [SourceID(rawValue: raw)]
        }
        if let raw = ProcessInfo.processInfo.environment["NEWSRADAR_SECTION"],
           let requested = NavSection(rawValue: raw) {
            section = requested
        }
        // UI-testing hook: `NEWSRADAR_TECH_SECTION=hardware` and
        // `NEWSRADAR_TECH_SOURCE=wired` open the Tech News tab already filtered,
        // which is the state a screenshot of a chip or a publisher needs.
        if let raw = ProcessInfo.processInfo.environment["NEWSRADAR_TECH_SECTION"],
           let requested = TechCategory(rawValue: raw) {
            techSection = requested
        }
        if let raw = ProcessInfo.processInfo.environment["NEWSRADAR_TECH_SOURCE"],
           TechCatalogue.source(raw) != nil {
            techSource = raw
        }
        // `NEWSRADAR_SHEET=addsource|reader` opens that sheet on launch, so the
        // build script can capture it without synthesising a click.
        // A sheet assigned during init is presented before the window exists, and
        // SwiftUI silently drops it. Set it one runloop later.
        switch ProcessInfo.processInfo.environment["NEWSRADAR_SHEET"] {
        case "addsource":
            DispatchQueue.main.async { self.showAddSource = true }
        case "filters":
            // Set synchronously: the toolbar's onAppear runs before any
            // DispatchQueue.main.async queued here, so an async flag was never seen.
            openFiltersOnLaunch = true
        case "detail":
            // Pick a project so the README block is exercised. Deferred two turns:
            // one for the window, one for SwiftUI to finish its first layout.
            let project = store.items.first { $0.isGitHub }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.detailItem = project }
        case "reader":
            // Choose inside the block, not here: at init the archive has not been
            // read yet, so filtering now always yields nothing and the sheet opens
            // empty. A story the reader can actually read is preferred, and one
            // with a picture beats one without, since inline media is the point.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let readable = self.store.items.filter {
                    !$0.isGitHub && !ArticleReader.isAppPage($0.link)
                }
                // `NEWSRADAR_READER_MATCH=<text>` pins the sheet to one story, so a
                // screenshot can show the case under test — inline media, say —
                // instead of whichever story happens to come first.
                let match = ProcessInfo.processInfo.environment["NEWSRADAR_READER_MATCH"]
                let picked = match.flatMap { m in
                    readable.first { $0.link.absoluteString.contains(m) }
                }
                self.readerItem = picked ?? readable.first { $0.imageURL != nil } ?? readable.first
            }
        default: break
        }
    }

    // MARK: - Bootstrap

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        launchStartedAt = Date()
        // Discover a local Ollama server without blocking launch.
        let config = ollama
        Task.detached(priority: .utility) {
            let models = ModelClient.availableModels(config: config)
            await MainActor.run {
                self.ollamaModels = models
                self.ollamaReachable = !models.isEmpty
                if self.ollama.enabled && self.ollama.model.isEmpty {
                    self.ollama.model = models.first ?? ""
                }
                self.persistOllama()
            }
        }
        // A stored briefing carries the sizes it was built with. If the settings
        // disagree, rebuild before drawing: otherwise the page shows six
        // highlights while Settings says three, with no refresh in between.
        if let existing = store.briefing(for: Date()),
           existing.highlightIDs.count != store.state.briefingNewsCount
            || existing.repoPickIDs.count != store.state.briefingRepoCount
            || (existing.revision ?? 0) != Digest.revision {
            rebuildBriefingForDisplaySettings()
        }

        // Checking on launch is a *check*, not a rebuild: the archive is already
        // on disk and is drawn as it stands, so the app opens with the reader's
        // stories visible and the network works in the background. Reopening the
        // app must never look like it is loading everything again.
        if store.state.checkOnLaunch {
            // Let the first frame draw from the stored archive before the
            // refresh starts competing for the main actor and the network.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.isRefreshing else { return }
                self.refresh(userInitiated: false, kind: .check)
            }
        }
        startAutoCheck()
    }

    /// Refresh automatically when the stored data is older than the configured
    /// interval. The interval is a setting, not a constant.
    var shouldAutoRefresh: Bool {
        guard let last = store.state.lastRefresh else { return true }
        let interval = Double(max(1, store.state.autoCheckMinutes)) * 60
        return Date().timeIntervalSince(last) > interval
    }

    // MARK: - Automatic checking

    private var autoCheckTask: Task<Void, Never>?

    /// Starts (or restarts) the timer that checks for new stories while the app is
    /// open. `autoCheckMinutes == 0` switches it off.
    func startAutoCheck() {
        autoCheckTask?.cancel()
        let minutes = store.state.autoCheckMinutes
        guard minutes > 0 else { autoCheckTask = nil; return }
        let interval = UInt64(minutes) * 60 * 1_000_000_000
        autoCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await MainActor.run {
                    // Never interrupt a refresh that is already running, and never
                    // stack checks when the window is in the background.
                    guard !self.isRefreshing else { return }
                    self.refresh(userInitiated: false, kind: .check)
                }
            }
        }
    }

    /// The intervals offered, always including the value currently stored so the
    /// picker can never render an empty control.
    nonisolated static let standardAutoCheckMinutes = [0, 5, 10, 15, 30, 60, 180]

    var autoCheckOptions: [Int] {
        var options = Self.standardAutoCheckMinutes
        if !options.contains(autoCheckMinutes) { options.append(autoCheckMinutes) }
        return options.sorted()
    }

    nonisolated static func autoCheckLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Off"
        case 1: return "Every minute"
        case 60: return "Every hour"
        case 180: return "Every 3 hours"
        default:
            if minutes % 60 == 0 { return "Every \(minutes / 60) hours" }
            return minutes < 5 ? "Every \(minutes) min" : "Every \(minutes) minutes"
        }
    }

    /// Called when the user changes the interval, so the running timer is
    /// replaced rather than left on the old value.
    /// Rebuilds only the briefing with the newly chosen sizes. Called when a
    /// briefing-size setting changes, because an existing briefing keeps the item
    /// IDs it was built with: without this, moving the highlights from 6 to 3
    /// visibly did nothing until the next refresh.
    func rebuildBriefingForDisplaySettings() {
        guard !store.items.isEmpty else { return }
        let config = ollama
        let news = briefingNewsCount
        let repos = briefingRepoCount
        var briefing: DailyBriefing?
        if config.isConfigured {
            briefing = Summarizer.ollamaBriefing(items: store.items, now: Date(),
                                                 config: config,
                                                 newsPicks: news, repoPicks: repos,
                                                 rank: rank)
        }
        if briefing == nil {
            briefing = Summarizer.localBriefing(
                items: store.items, now: Date(),
                previousDayTopIDs: store.previousTopIDs(before: Date()),
                newsPicks: news, repoPicks: repos,
                rank: rank)
        }
        if let b = briefing {
            store.setBriefing(b)
            store.saveAll()
            revision &+= 1
        }
    }

    func persistRefreshSettings() {
        if autoCheckMinutes > 0 { lastAutoCheckMinutes = autoCheckMinutes }
        let sizesChanged = briefingNewsCount != store.state.briefingNewsCount
            || briefingRepoCount != store.state.briefingRepoCount
        store.updateState {
            $0.autoCheckMinutes = self.autoCheckMinutes
            $0.checkOnLaunch = self.checkOnLaunch
            $0.retentionDays = self.retentionDays
            $0.briefingNewsCount = self.briefingNewsCount
            $0.briefingRepoCount = self.briefingRepoCount
            $0.listLimit = self.listLimit
        }
        startAutoCheck()
        // Only the briefing's own sizes need a rebuild; changing the interval must
        // not touch the stored briefing.
        if sizesChanged { rebuildBriefingForDisplaySettings() }
    }

    // MARK: - Refresh

    /// How a refresh was started. A "check" is the cheap path: it asks each source
    /// whether anything was published since the last check and only summarises what
    /// is genuinely new, so reopening the app never re-summarises the whole archive.
    enum RefreshKind {
        case check     // new stories only
        case full      // re-render everything that is stored

        var title: String { self == .check ? "Checking…" : "Refreshing…" }
    }

    func refresh(userInitiated: Bool = true, kind: RefreshKind = .check) {
        guard !isRefreshing else { return }
        isRefreshing = true
        isChecking = kind == .check
        if userInitiated { statusMessage = kind.title }
        let config = ollama
        // A check passes what is already stored, so the engine skips re-rendering
        // anything it has seen before and only sends new items to the model.
        let priorItems = store.items
        let priorSnapshots = store.snapshots
        // Read the settings on the main actor before leaving it.
        let newsPicks = briefingNewsCount
        let repoPicks = briefingRepoCount

        Task.detached(priority: .userInitiated) {
            let prepared = RefreshEngine.fetchAll(
                ollama: config,
                // A full refresh re-renders from scratch, which is what the
                // "re-render summaries" button needs after changing engine.
                priorItems: kind == .check ? priorItems : [],
                priorSnapshots: priorSnapshots,
                briefingNews: newsPicks,
                briefingRepos: repoPicks,
                progress: { p in
                    Task { @MainActor in
                        self.progress = p
                        self.statusMessage = "Fetching \(p.current ?? "")… (\(p.done)/\(p.total))"
                    }
                })
            await MainActor.run { self.apply(prepared, config: config, userInitiated: userInitiated) }
        }
    }

    private func apply(_ prepared: RefreshEngine.Prepared, config: OllamaConfig,
                       userInitiated: Bool) {
        let outcome = RefreshEngine.apply(prepared, ollama: config, to: store, now: Date())
        lastOutcome = outcome
        isRefreshing = false
        isChecking = false
        progress = nil
        revision &+= 1
        statusMessage = outcome.summary
            + (outcome.ollamaUsed ? " · model summary: \(outcome.ollamaModel ?? "")" : "")
        if !outcome.sourceFailures.isEmpty {
            let n = outcome.sourceFailures.count
            statusMessage = (statusMessage ?? "")
                + " · \(TextFormat.number(n)) " + (n == 1 ? "source failed" : "sources failed")
        }
        if userInitiated {
            toast = outcome.fetched == 0
                ? "Nothing was fetched — check the network connection."
                : "Refresh finished — " + outcome.summary
        }
    }

    /// Switches tab, dropping filters that belong to the tab being left.
    func go(to section: NavSection) {
        guard section != self.section else { return }
        let leaving = self.section
        self.section = section
        let surfaces: Set<NavSection> = [.web, .design]
        if surfaces.contains(leaving) || surfaces.contains(section) {
            designSection = nil
            designSource = nil
        }
        // The Tech News tab's own filters are dropped the same way the
        // catalogue tabs' are: a filter that belongs to the tab being left
        // must not silently apply to the tab being entered.
        if leaving == .tech || section == .tech {
            techSection = nil
            techSource = nil
        }
    }

    // MARK: - Derived lists

    /// The narrowest window that would put something on the page for the filter
    /// currently set, ignoring only the date range.
    ///
    /// This is what makes an empty list recoverable: "no matches" is true but not
    /// useful, and the usual reason is a window narrower than the sources update at.
    func widestWindowWithContent() -> DateRange? {
        _ = revision
        var withoutRange = filters
        withoutRange.range = .all
        let matching = Filtering.apply(sectionBase, filters: withoutRange,
                                       readIDs: store.state.readIDs, now: Date())
        for range in DateRange.allCases where range != .all {
            guard let seconds = range.seconds else { continue }
            let cutoff = Date().addingTimeInterval(-seconds)
            if matching.contains(where: { $0.published >= cutoff }) { return range }
        }
        return nil
    }

    /// How many stories one source actually has, window by window.
    func availability(for source: SourceID) -> [(range: DateRange, count: Int)] {
        _ = revision
        return Coverage.byRange(store.items, source: source, now: Date())
    }

    /// The narrowest window in which this source has anything at all.
    func narrowestPopulatedRange(for source: SourceID, fallback: DateRange) -> DateRange {
        Coverage.narrowest(store.items, source: source, now: Date(), fallback: fallback)
    }

    /// Items that pass the current filters and belong to the current section.
    ///
    /// This is read by the toolbar, the header, the list and every card, several
    /// times per frame. Computing it each time means re-filtering and re-sorting
    /// the whole archive on every read, which is what made the window feel heavy
    /// once the archive grew past a couple of thousand stories. It is memoised
    /// instead, and the cache key names everything it depends on — so the list is
    /// rebuilt when the archive, the section, or a filter actually changes, and
    /// read for free otherwise.
    var visibleItems: [RadarItem] {
        let key = visibleItemsKey
        if key == cachedVisibleKey { return cachedVisible }
        let value = computeVisibleItems()
        cachedVisibleKey = key
        cachedVisible = value
        return value
    }

    @ObservationIgnored private var cachedVisible: [RadarItem] = []
    @ObservationIgnored private var cachedVisibleKey: String = ""
    @ObservationIgnored private var cachedCounts: (all: Int, unread: Int, bookmarks: Int, github: Int)?
    @ObservationIgnored private var cachedCountsRevision = -1
    @ObservationIgnored private var cachedTabCounts: (revision: Int, web: Int, design: Int, tech: Int)?

    /// Everything `visibleItems` depends on, as one comparable value.
    private var visibleItemsKey: String {
        // `revision` moves on every mutation of the store, which is the only way
        // the archive changes; `store.items.count` and the newest date guard the
        // case where something rewrote the store without bumping it.
        let f = filters
        let newest = store.items.first?.published.timeIntervalSince1970 ?? 0
        return [
            String(revision), String(store.items.count), String(newest),
            section.rawValue, layout.rawValue, sort.rawValue, rank.rawValue,
            listLimit.description,
            f.query, f.range.rawValue, f.category?.rawValue ?? "-",
            f.sources.map(\.rawValue).sorted().joined(separator: ","),
            f.openSourceOnly ? "1" : "0", f.freeOnly ? "1" : "0",
            f.localOnly ? "1" : "0", f.unreadOnly ? "1" : "0",
            f.appleSiliconFirst ? "1" : "0",
            manualOrder.map(\.rawValue).joined(separator: ","),
            String(store.state.readIDs.count), String(store.state.bookmarkedIDs.count),
            designSection?.rawValue ?? "-", designSource ?? "-", designRange.rawValue,
            techSection?.rawValue ?? "-", techSource ?? "-", techRange.rawValue,
        ].joined(separator: "|")
    }

    private func computeVisibleItems() -> [RadarItem] {
        _ = revision // dependency so observers recompute after a refresh
        let effective = effectiveFilters
        let filtered = Filtering.apply(sectionBase, filters: effective,
                                       readIDs: store.state.readIDs)
        let sorted = ordered(filtered, effective: effective)
        // A cap keeps a long list responsive. The stored archive is untouched;
        // this only limits what is drawn, and the header says so.
        guard listLimit > 0, section != .bookmarks, section != .history,
              sorted.count > listLimit else { return sorted }
        return Array(sorted.prefix(listLimit))
    }

    /// The archive narrowed to the section on screen, before any filters.
    ///
    /// Every list, count and empty-state check goes through this one switch.
    /// It used to be copied into four places, and the copies drifted: the Tech
    /// tab's "Show all N" counted the whole archive, and the News list's cap
    /// counted Tech stories it never drew.
    var sectionBase: [RadarItem] {
        switch section {
        case .github:
            return store.items.filter { $0.isGitHub }
        case .web, .design:
            let surface: DesignSurface = section == .web ? .web : .design
            return store.items.filter { DesignCatalogue.surface(of: $0.source) == surface }
        case .tech:
            return store.items.filter { $0.source.isTech }
        case .bookmarks:
            return store.bookmarkedItems
        case .history:
            return historyAsItems()
        case .all, .digest:
            return store.items.filter { !$0.isGitHub && !$0.source.isTech
                && DesignCatalogue.surface(of: $0.source) == nil }
        case .sources, .settings:
            return store.items
        }
    }

    /// The toolbar filters, adjusted for what the current section can mean.
    /// A bookmark is a bookmark whatever its date; a repository has no news
    /// category. Both used to be re-derived inside each list computation.
    private var effectiveFilters: Filters {
        var f = filters
        if section == .bookmarks || section == .history {
            f.range = .all
            f.openSourceOnly = false
            f.freeOnly = false
            f.localOnly = false
            f.unreadOnly = false
            f.category = nil
        }
        if section == .github {
            f.category = nil
            f.appleSiliconFirst = false
        }
        return f
    }

    /// The order a list is drawn in. The Settings ranking is the standing
    /// answer; the toolbar's sort menu is a per-look override of one list.
    ///
    /// The override was stored and displayed but never applied, so choosing
    /// "Newest first" changed a saved setting and nothing on screen.
    private func ordered(_ items: [RadarItem], effective: Filters) -> [RadarItem] {
        // The history list is a log: it is always newest first, whatever the
        // ranking says.
        if section == .history {
            return Filtering.sort(items, by: .newest, appleSiliconFirst: false)
        }
        return orderedForDisplay(items, appleSiliconFirst: effective.appleSiliconFirst)
    }

    /// Applies the toolbar override, or the Settings ranking when it is left
    /// on "Ranked order". Shared with the Tech, Web and Design tabs, which had
    /// the same stored-but-ignored override.
    func orderedForDisplay(_ items: [RadarItem],
                           appleSiliconFirst: Bool) -> [RadarItem] {
        if sort == .relevance {
            return Filtering.rank(items, by: rank,
                                  appleSiliconFirst: appleSiliconFirst,
                                  manualOrder: manualOrder)
        }
        return Filtering.sort(items, by: sort, appleSiliconFirst: appleSiliconFirst)
    }

    /// The Tech News window: the tab's own range plus the toolbar controls that
    /// are actually visible there (search and unread).
    ///
    /// The news tab's publishers and taxonomy are deliberately absent. They are
    /// not shown in this tab, so a filter set in AI News would silently empty
    /// Tech News with no visible control to undo it.
    func techWindowItems() -> [RadarItem] {
        _ = revision
        var f = Filters()
        f.query = filters.query
        f.unreadOnly = filters.unreadOnly
        f.range = techRange
        let base = store.items.filter { $0.source.isTech }
        return orderedForDisplay(
            Filtering.apply(base, filters: f, readIDs: store.state.readIDs),
            appleSiliconFirst: false)
    }

    /// The same window for one of the two catalogue tabs.
    func designWindowItems(_ surface: DesignSurface) -> [RadarItem] {
        _ = revision
        var f = Filters()
        f.query = filters.query
        f.unreadOnly = filters.unreadOnly
        f.range = designRange
        let base = store.items.filter { DesignCatalogue.surface(of: $0.source) == surface }
        return orderedForDisplay(
            Filtering.apply(base, filters: f, readIDs: store.state.readIDs),
            appleSiliconFirst: false)
    }

    /// How many rows the tab on screen would draw. The filter panel's header
    /// used the News list count on every tab, so it could claim "0 items" above
    /// a Tech list that was full.
    var currentSectionCount: Int {
        switch section {
        case .tech:
            var items = techWindowItems()
            if let id = techSource, let entry = TechCatalogue.source(id) {
                items = items.filter { $0.source == entry.sourceID }
            }
            if let category = techSection {
                items = items.filter { $0.techCategory == category }
            }
            return items.count
        case .web, .design:
            var items = designWindowItems(section == .web ? .web : .design)
            if let id = designSource, let entry = DesignCatalogue.source(id) {
                let source = DesignCatalogue.sourceID(of: entry)
                items = items.filter { $0.source == source }
            }
            if let category = designSection {
                items = items.filter {
                    DesignCatalogue.entry(for: $0.source)?.category == category
                }
            }
            return items.count
        default:
            return visibleItems.count
        }
    }

    /// How many filters are active on the tab being read. The toolbar used the
    /// News count everywhere, so a filter that did not apply to Tech News still
    /// lit the Filter button there.
    var activeFilterCount: Int {
        switch section {
        case .tech:
            var n = techSection == nil ? 0 : 1
            if techSource != nil { n += 1 }
            if techRange != .day { n += 1 }
            if filters.unreadOnly { n += 1 }
            return n
        case .web, .design:
            var n = designSection == nil ? 0 : 1
            if designSource != nil { n += 1 }
            if designRange != .all { n += 1 }
            if filters.unreadOnly { n += 1 }
            return n
        default:
            return filters.activeCount
        }
    }

    /// History rows: the stored item when it is still in the archive, otherwise a
    /// lightweight shell so the original link still works.
    private func historyAsItems() -> [RadarItem] {
        store.history.map { entry in
            if let live = store.item(id: entry.itemID) { return live }
            var shell = RadarItem(id: entry.itemID, source: entry.source, kind: .news,
                                 title: entry.title, link: entry.link,
                                 published: entry.openedAt,
                                 rawSummary: "", imageURL: nil, author: nil,
                                 sourceCategories: [])
            shell.headline = entry.title
            shell.summary = "This item is no longer in the local archive; the original article is still available through the link."
            shell.summaryEngine = "source"
            return shell
        }
    }

    /// Items for the daily briefing tab.
    var briefingItems: [RadarItem] {
        _ = revision
        guard let b = briefing else { return [] }
        let ids = b.highlightIDs + b.repoPickIDs
        return store.items(ids: ids)
    }

    /// Briefing highlights, news only, honouring the active filters.
    ///
    /// The briefing used to be a frozen list built at refresh time, so every
    /// filter control on that tab silently did nothing. The stored picks are now
    /// passed through the same filter pipeline as every other list, which keeps
    /// the briefing consistent with the toolbar above it.
    var briefingNews: [RadarItem] {
        _ = revision
        guard let b = briefing else { return [] }
        let news = store.items(ids: b.highlightIDs).filter { !$0.isGitHub }
        return filterForBriefing(news)
    }

    /// The briefing's repository picks, in the briefing's own order, also filtered.
    var briefingRepos: [RadarItem] {
        _ = revision
        guard let b = briefing else { return [] }
        let byID = Dictionary(store.items(ids: b.repoPickIDs).map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        return filterForBriefing(b.repoPickIDs.compactMap { byID[$0] })
    }

    /// The picks of one reading surface, in the briefing's own order.
    ///
    /// The home page shows a block per tab, so a reader who follows the web
    /// and SEO side does not have to scroll past forty AI headlines.
    func briefingPicks(for section: BriefingSection) -> [RadarItem] {
        _ = revision
        guard let b = briefing else { return [] }
        let ids = b.sectionPickIDs[section.rawValue] ?? []
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary(store.items(ids: ids).map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        return filterForBriefing(ids.compactMap { byID[$0] })
    }

    /// How many stories one surface contributed in the briefing's window.
    func briefingCount(for section: BriefingSection) -> Int {
        _ = revision
        guard let b = briefing else { return 0 }
        return b.sectionCounts[section.rawValue] ?? 0
    }

    /// The surfaces that have something to show, in the order the sidebar uses.
    var briefingSections: [BriefingSection] {
        _ = revision
        return BriefingSection.allCases.filter { !briefingPicks(for: $0).isEmpty }
    }

    /// True when the toolbar filters are hiding some of the briefing's picks, so
    /// the page can say so instead of looking arbitrarily short.
    var briefingIsFiltered: Bool {
        _ = revision
        guard let b = briefing else { return false }
        let all = store.items(ids: b.highlightIDs + b.repoPickIDs)
        let shown = filterForBriefing(all)
        return shown.count != all.count
    }

    /// The briefing's picks honour every filter except the time window: a daily
    /// briefing is about today by definition, and applying "12 hours" to a list
    /// chosen for the day would empty it late at night.
    private func filterForBriefing(_ items: [RadarItem]) -> [RadarItem] {
        guard !items.isEmpty else { return [] }
        var effective = filters
        effective.range = .all
        let filtered = Filtering.apply(items, filters: effective,
                                       readIDs: store.state.readIDs)
        // Keep the briefing's own ranking instead of re-sorting.
        let keep = Set(filtered.map { $0.id })
        return items.filter { keep.contains($0.id) }
    }

    var briefing: DailyBriefing? {
        _ = revision
        return store.briefing(for: Date()) ?? store.briefings.keys.sorted().last.flatMap { store.briefings[$0] }
    }

    /// Total in the current section after filtering, before the list cap. Used to
    /// tell the user how many rows the cap is hiding.
    var unfilteredCount: Int {
        _ = revision
        guard listLimit > 0, section != .bookmarks, section != .history else {
            return visibleItems.count
        }
        return Filtering.apply(sectionBase, filters: effectiveFilters,
                               readIDs: store.state.readIDs).count
    }

    /// True when the list cap is hiding rows, so the header can say so.
    var isListCapped: Bool {
        listLimit > 0 && unfilteredCount > visibleItems.count
    }

    /// Drops the list cap for this session without changing the stored setting:
    /// "Show all 533" in the header means exactly that.
    func showAllRows() {
        listLimit = 0
        revision &+= 1
    }

    var counts: (all: Int, unread: Int, bookmarks: Int, github: Int) {
        _ = revision
        if cachedCountsRevision == revision, let cachedCounts { return cachedCounts }
        // Design feeds are collected alongside the news but counted separately,
        // so "News 412" does not silently include thirty font releases.
        let news = store.items.filter { !$0.isGitHub && !$0.source.isTech
            && DesignCatalogue.surface(of: $0.source) == nil }
        let value = (news.count,
                     news.reduce(0) { $0 + (store.state.readIDs.contains($1.id) ? 0 : 1) },
                     store.state.bookmarkedIDs.count,
                     store.items.reduce(0) { $0 + ($1.isGitHub ? 1 : 0) })
        cachedCounts = value
        cachedCountsRevision = revision
        return value
    }

    /// How many stories one of the two catalogue tabs holds.
    ///
    /// Counted here rather than in the sidebar so the badge, the tab header and
    /// the chip row cannot disagree about what a tab contains.
    func designCount(for surface: DesignSurface) -> Int {
        _ = revision
        let c = tabCounts
        return surface == .web ? c.web : c.design
    }

    /// How many stories the Tech News tab holds.
    ///
    /// Counted here rather than in the sidebar so the badge, the tab header
    /// and the chip row cannot disagree about what the tab contains.
    var techCount: Int {
        _ = revision
        return tabCounts.tech
    }

    /// The three tab badges in one pass. The sidebar asks for all of them on
    /// every draw, and each used to filter the whole archive separately.
    private var tabCounts: (web: Int, design: Int, tech: Int) {
        if let cached = cachedTabCounts, cached.revision == revision {
            return (cached.web, cached.design, cached.tech)
        }
        var web = 0, design = 0, tech = 0
        for item in store.items {
            if item.source.isTech { tech += 1 }
            switch DesignCatalogue.surface(of: item.source) {
            case .web: web += 1
            case .design: design += 1
            case nil: break
            }
        }
        cachedTabCounts = (revision, web, design, tech)
        return (web, design, tech)
    }

    /// How many items each of the quick windows would show, counted in one
    /// pass. The toolbar draws four of these side by side; four separate scans
    /// of the archive for four numbers was four times the work per frame.
    func counts(in ranges: [DateRange]) -> [DateRange: Int] {
        _ = revision
        guard section != .history else { return [:] }
        let now = Date()
        let cutoffs = ranges.map { ($0, $0.seconds.map { now.addingTimeInterval(-$0) }) }
        var out: [DateRange: Int] = [:]
        for range in ranges { out[range] = 0 }
        for item in sectionBase {
            for (range, cutoff) in cutoffs {
                if let cutoff {
                    if item.published >= cutoff { out[range, default: 0] += 1 }
                } else {
                    out[range, default: 0] += 1
                }
            }
        }
        return out
    }

    var sourceStatuses: [SourceStatus] {
        _ = revision
        return SourceID.all.map { source in
            store.status(for: source) ?? SourceStatus(source: source)
        }
    }

    var categoryCounts: [(Category, Int)] {
        _ = revision
        var counts: [Category: Int] = [:]
        for i in store.items { counts[i.category, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: - Item actions

    func toggleBookmark(_ item: RadarItem) {
        let on = store.toggleBookmark(item.id)
        revision &+= 1
        toast = on ? "Added to bookmarks" : "Removed from bookmarks"
    }

    /// Records a read and opens the original article in the default browser.
    func open(_ item: RadarItem) {
        store.markOpened(item)
        revision &+= 1
        NSWorkspaceOpen(item.link)
    }

    /// Follows a story without leaving the app. A GitHub project has no article to
    /// read, so it still opens in the browser where its README and issues live.
    func readHere(_ item: RadarItem) {
        store.markOpened(item)
        revision &+= 1
        // A repository, forum thread or video has no article to extract, so it
        // goes straight to the browser instead of into a reader that cannot read it.
        if item.isGitHub || ArticleReader.isAppPage(item.link) {
            NSWorkspaceOpen(item.link)
        } else {
            readerItem = item
        }
    }

    func openURL(_ url: URL) {
        NSWorkspaceOpen(url)
    }

    func markAllVisibleRead() {
        store.markAllRead(visibleItems.map { $0.id })
        revision &+= 1
        toast = "Every item in this view is marked read"
    }

    /// ⌘B target: bookmarks the first visible item (or un-bookmarks it).
    func toggleBookmarkOfFirstVisible() {
        guard let first = visibleItems.first else { return }
        toggleBookmark(first)
    }

    func clearHistory() {
        store.clearHistory()
        revision &+= 1
        toast = "Reading history cleared"
    }

    // MARK: - Settings

    /// Caches a README and republishes the view, so reopening the card does not
    /// refetch it and the text survives both a relaunch and a refresh.
    func attachReadme(_ text: String, for fullName: String) {
        guard store.readmes[fullName] != text else { return }
        store.setReadme(text, for: fullName)
        revision &+= 1
    }

    /// The cached README for a repository, if one has been read.
    func readme(for fullName: String) -> String? {
        _ = revision
        return store.readmes[fullName]
    }

    func persistLayout() {
        store.updateState { $0.layout = self.layout }
    }

    /// Adds an already-validated source and refreshes so it has stories at once.
    @discardableResult
    func addCustomSource(_ source: CustomSource) -> Bool {
        let added = store.addCustomSource(source)
        if added {
            revision &+= 1
            toast = "Added \(source.title) — reading its feed now."
        }
        return added
    }

    func removeCustomSource(_ source: CustomSource) {
        store.removeCustomSource(id: source.id)
        filters.sources.remove(source.sourceID)
        persistFilters()
        revision &+= 1
    }

    var customSources: [CustomSource] { store.customSources }

    func persistSort() {
        store.updateState { $0.sort = self.sort }
    }

    /// Every publisher the app collects that the reader has not already placed
    /// in their own order.
    var manualOrderCandidates: [SourceID] {
        _ = revision
        let placed = Set(manualOrder)
        return SourceID.all.filter { !placed.contains($0) }
    }

    /// Moves a publisher up or down in the reader's own order.
    func moveManualOrder(_ id: SourceID, by delta: Int) {
        guard let index = manualOrder.firstIndex(of: id) else { return }
        let target = index + delta
        guard target >= 0, target < manualOrder.count else { return }
        manualOrder.swapAt(index, target)
        persistRank()
    }

    /// Removes a publisher from the reader's own order.
    func removeManualOrder(_ id: SourceID) {
        manualOrder.removeAll { $0 == id }
        persistRank()
    }

    /// Puts a publisher at the top of the reader's own order.
    func addManualOrder(_ id: SourceID) {
        guard !manualOrder.contains(id) else { return }
        manualOrder.insert(id, at: 0)
        persistRank()
    }

    /// Saves the ranking and the reader's own publisher order together: they
    /// are one decision, and saving one without the other would leave the
    /// "My order" mode with an empty list.
    func persistRank() {
        store.updateState {
            $0.rank = self.rank
            $0.manualOrder = self.manualOrder.map { $0.rawValue }
        }
    }

    func persistFilters() {
        store.updateState { $0.filters = self.filters }
    }

    func persistOllama() {
        store.updateState {
            $0.ollama = self.ollama
            $0.ollama.knownModels = self.ollamaModels
        }
    }

    func checkOllama() {
        checkingOllama = true
        let config = ollama
        Task.detached(priority: .userInitiated) {
            let models = ModelClient.availableModels(config: config)
            await MainActor.run {
                self.ollamaModels = models
                self.ollamaReachable = !models.isEmpty
                self.checkingOllama = false
                self.ollama.knownModels = models
                if models.isEmpty {
                    self.ollama.lastError = self.failureText(for: config)
                } else {
                    self.ollama.lastError = nil
                    if self.ollama.model.isEmpty || !models.contains(self.ollama.model) {
                        self.ollama.model = models.first ?? ""
                    }
                }
                self.ollama.lastChecked = Date()
                self.persistOllama()
                self.toast = models.isEmpty
                    ? "\(config.engine.title) is unreachable — summaries will use the offline digest."
                    : "\(TextFormat.number(models.count)) models found on \(config.engine.title)."
            }
        }
    }

    /// A message that names the actual cause instead of always blaming the server.
    private func failureText(for config: OllamaConfig) -> String {
        let base = config.baseURL
        if config.engine.needsAPIKey && config.apiKey.isEmpty {
            return "Add the \(config.engine.title) API key first. The gateway at \(base) requires a bearer token on every request."
        }
        return "The \(config.engine.title) service at \(base) did not answer. Check that it is running and that the address is correct."
    }

    /// Re-render every stored item with the currently selected engine. Used after
    /// switching Ollama on or off.
    func reRenderAll() {
        guard !store.items.isEmpty else { return }
        isRefreshing = true
        statusMessage = "Re-rendering summaries…"
        let config = ollama
        let items = store.items
        Task.detached(priority: .userInitiated) {
            var rendered: [RadarItem] = []
            rendered.reserveCapacity(items.count)
            for var item in items {
                item = Summarizer.render(item, ollama: config.isConfigured ? config : nil)
                rendered.append(item)
            }
            let output = rendered
            await MainActor.run {
                let byID = Dictionary(output.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let updated = self.store.items.map { byID[$0.id] ?? $0 }
                self.store.merge(newItems: updated, now: Date())
                if config.isConfigured {
                    if let b = Summarizer.ollamaBriefing(
                        items: self.store.items, now: Date(), config: config,
                        newsPicks: self.briefingNewsCount, repoPicks: self.briefingRepoCount,
                        rank: self.rank) {
                        self.store.setBriefing(b)
                    }
                } else {
                    self.store.setBriefing(Summarizer.localBriefing(
                        items: self.store.items, now: Date(),
                        previousDayTopIDs: self.store.previousTopIDs(before: Date()),
                        newsPicks: self.briefingNewsCount, repoPicks: self.briefingRepoCount,
                        rank: self.rank))
                }
                self.store.saveAll()
                self.isRefreshing = false
                self.statusMessage = config.isConfigured
                    ? "Summaries were rewritten by the local model."
                    : "Summaries were rewritten by the offline digest."
                self.toast = self.statusMessage
                self.revision &+= 1
            }
        }
    }

    func resetAllData() {
        store.resetEverything()
        ImageLoader.shared.clearDiskCache()
        HTTP.clearFetchedCache()
        revision &+= 1
        toast = "All local data was deleted"
    }

    /// Copy the current briefing as plain text (handy for sharing).
    func briefingText() -> String {
        guard let b = briefing else { return "" }
        var out = [b.headline, ""]
        out.append(contentsOf: b.paragraphs)
        out.append("")
        for i in briefingItems {
            out.append("• \(i.displayTitle) — \(i.link.absoluteString)")
        }
        return out.joined(separator: "\n")
    }
}

/// Small helper so AppModel can open links without importing AppKit everywhere.
@MainActor
private func NSWorkspaceOpen(_ url: URL) {
    NSWorkspace.shared.open(url)
}
