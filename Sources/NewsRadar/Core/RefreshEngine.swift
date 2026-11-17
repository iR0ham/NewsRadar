import Foundation

/// Orchestrates a full refresh.
///
/// Split deliberately in two phases so no `Store` is ever touched off the main
/// thread:
///   * `fetchAll` runs on a background task — network, parsing, classification,
///     Persian rendering — and touches nothing shared except its own locals.
///   * `apply` runs on the main actor and owns every store mutation.
enum RefreshEngine {

    struct Progress {
        var done: Int
        var total: Int
        var current: String?
    }

    /// Everything the background phase produced, ready to be persisted.
    struct Prepared {
        var items: [RadarItem] = []
        var statuses: [SourceStatus] = []
        var snapshots: [StarSnapshot] = []
        var fetched: Int = 0
        var newCount: Int = 0
        var sourceFailures: [String] = []
        var ollamaUsed: Bool = false
        var ollamaModel: String?
        var duration: TimeInterval = 0
        /// Sources that answered "not modified", so nothing was parsed for them.
        var unchangedSources: Int = 0
        var checkedSources: Int = 0
        /// Briefing sizes chosen in Settings, carried to the apply phase.
        var briefingNews: Int = Summarizer.defaultNewsPicks
        var briefingRepos: Int = Summarizer.defaultRepoPicks
        /// The ranking the picks are ordered by, chosen in Settings.
        var rank: RankMode = .fresh
    }

    struct Outcome {
        var fetched: Int = 0
        var newItems: Int = 0
        var statuses: [SourceStatus] = []
        var sourceFailures: [String] = []
        var briefing: DailyBriefing?
        var ollamaUsed: Bool = false
        var ollamaModel: String?
        var duration: TimeInterval = 0
        var okSources: Int = 0
        var unchangedSources: Int = 0
        var checkedSources: Int = 0

        var summary: String {
            if newItems == 0 && unchangedSources > 0 && unchangedSources == checkedSources {
                return "No new stories since the last check"
            }
            var s = "\(TextFormat.number(fetched)) items from \(TextFormat.number(okSources)) sources"
            if newItems > 0 { s += ", \(TextFormat.number(newItems)) new" }
            if unchangedSources > 0 { s += " · \(unchangedSources) unchanged" }
            return s
        }
    }

    /// Number of top-ranked items re-written by the local model when Ollama is
    /// configured. Keeps a refresh bounded even on a slow local model.
    static let ollamaBudget = 12

    // MARK: - Phase 1: network + compute (background, no shared state)

    static func fetchAll(ollama: OllamaConfig,
                         priorItems: [RadarItem],
                         priorSnapshots: [StarSnapshot],
                         briefingNews: Int = Summarizer.defaultNewsPicks,
                         briefingRepos: Int = Summarizer.defaultRepoPicks,
                         rank: RankMode = .fresh,
                         progress: @escaping (Progress) -> Void = { _ in },
                         now: Date = Date()) -> Prepared {
        let started = Date()
        // Reclaim disk from cache files the previous key scheme orphaned, before
        // this run writes fresh ones.
        HTTP.purgeOrphanedCacheFiles()
        var prepared = Prepared()
        prepared.briefingNews = briefingNews
        prepared.briefingRepos = briefingRepos
        prepared.rank = rank

        let priorByID = Dictionary(priorItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let priorIDs = Set(priorItems.map { $0.id })
        // Which sources already have stories, computed once. Asking per source with
        // a `contains` over the whole archive was O(sources × items) on every
        // refresh — tens of millions of comparisons before the first request left.
        let priorIDsForSource: [String: Bool] = Dictionary(
            grouping: priorItems, by: { $0.source.rawValue })
            .mapValues { !$0.isEmpty }
        // A source whose stored stories have no picture needs its cached feed
        // read again even when the server answers "unchanged". Without this, a
        // fix to the image extractor only ever helped stories published after
        // it: the archive kept the empty URLs it was written with, because a 304
        // means the feed is not parsed at all.
        let priorMissingImageForSource: [String: Bool] = Dictionary(
            grouping: priorItems.filter { $0.imageURL == nil }, by: { $0.source.rawValue })
            .mapValues { !$0.isEmpty }
        let sources = SourceID.all

        let lock = NSLock()
        var collected: [RadarItem] = []
        var collectedStatuses: [SourceStatus] = []
        var collectedSnaps: [StarSnapshot] = []
        var doneCount = 0
        let total = SourceID.all.count

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "newsradar.fetch", qos: .userInitiated,
                                  attributes: .concurrent)
        // A fixed number of workers, not one task per source. With ~100 sources an
        // unbounded fan-out opened a hundred simultaneous connections, which is
        // what made a refresh crawl and the whole window stutter while it ran: the
        // system throttles the sockets and every request waits behind the others.
        // Six at a time finishes sooner and leaves the machine responsive.
        let workerCount = 6
        let pending = NSLock()
        var nextIndex = 0

        for _ in 0..<workerCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                while true {
                    pending.lock()
                    let index = nextIndex
                    nextIndex += 1
                    pending.unlock()
                    guard index < sources.count else { return }
                    let source = sources[index]
                    // A source the app has no stories for must fill itself from the
                    // cached feed even when the server says "unchanged", otherwise a
                    // newly added source sits empty until the publisher next updates.
                    let hasStories = priorIDsForSource[source.rawValue] ?? false
                    let missingImage = priorMissingImageForSource[source.rawValue] ?? false
                    let result = fetchOne(source, snapshots: priorSnapshots, now: now,
                                          repopulate: !hasStories || missingImage)
                    lock.lock()
                    collected.append(contentsOf: result.items)
                    collectedStatuses.append(result.status)
                    collectedSnaps.append(contentsOf: result.snapshots)
                    doneCount += 1
                    let p = Progress(done: doneCount, total: total, current: source.title)
                    lock.unlock()
                    progress(p)
                }
            }
        }
        group.wait()

        prepared.statuses = collectedStatuses.sorted { $0.source.rawValue < $1.source.rawValue }
        prepared.fetched = collected.count
        prepared.sourceFailures = collectedStatuses.filter { !$0.ok }
            .map { "\($0.source.title): \($0.message)" }
        prepared.unchangedSources = collectedStatuses.filter { $0.unchanged == true }.count
        prepared.checkedSources = collectedStatuses.count

        // Cross-source duplicates first: the same story often arrives from both a
        // publisher and an aggregator.
        let deduped = dedupeAcrossSources(collected)

        // Then deduplicate on stable id, preferring the copy with an image.
        var unique: [String: RadarItem] = [:]
        for i in deduped {
            if let existing = unique[i.id] {
                let better = (i.imageURL != nil ? 1 : 0, i.rawSummary.count)
                let current = (existing.imageURL != nil ? 1 : 0, existing.rawSummary.count)
                if better > current { unique[i.id] = i }
            } else {
                unique[i.id] = i
            }
        }

        // Classify, then render — with the local model for the most valuable
        // items when it is configured.
        let engineTag = ollama.isConfigured ? "ollama:\(ollama.model)" : "digest"
        let classified = unique.values.map { Classifier.classify($0, now: now) }

        func reuse(_ old: RadarItem, into item: inout RadarItem) -> Bool {
            guard old.rawSummary == item.rawSummary, old.title == item.title,
                  !old.headline.isEmpty,
                  old.summaryEngine == engineTag
                    || (engineTag == "digest" && old.summaryEngine == "source")
            else { return false }
            item.headline = old.headline
            item.summary = old.summary
            item.keyPoints = old.keyPoints
            item.summaryEngine = old.summaryEngine
            return true
        }

        var rendered: [RadarItem] = []
        rendered.reserveCapacity(classified.count)
        if ollama.isConfigured {
            let targets = Set(classified.sorted { $0.score > $1.score }
                .prefix(ollamaBudget).map { $0.id })
            var usedModel = false
            for var item in classified {
                if let old = priorByID[item.id], reuse(old, into: &item) {
                    rendered.append(item)
                    continue
                }
                if targets.contains(item.id) {
                    item = Summarizer.render(item, ollama: ollama)
                    if EngineLabel.describe(item.summaryEngine).isModel { usedModel = true }
                } else {
                    item = Summarizer.render(item, ollama: nil)
                }
                rendered.append(item)
            }
            prepared.ollamaUsed = usedModel
            prepared.ollamaModel = usedModel ? ollama.model : nil
        } else {
            for var item in classified {
                if let old = priorByID[item.id], reuse(old, into: &item) {
                    rendered.append(item)
                    continue
                }
                item = Summarizer.render(item, ollama: nil)
                rendered.append(item)
            }
        }
        // Re-score so ranking reflects the final rendered facts.
        prepared.items = rendered.map { var i = $0; i.score = Classifier.score(i, now: now); return i }
        prepared.snapshots = collectedSnaps
        prepared.newCount = rendered.filter { !priorIDs.contains($0.id) }.count
        prepared.duration = Date().timeIntervalSince(started)
        return prepared
    }

    /// The same story arrives from a publisher and from an aggregator (TLDR links
    /// TechCrunch, HN links everything), and a repo can appear in both GitHub
    /// sources. Only one copy is kept: the one from the original publisher, which
    /// has the full summary and the article image.
    ///
    /// Matching is on the canonicalized link, not the title, because headlines are
    /// reworded between sources.
    static func dedupeAcrossSources(_ items: [RadarItem]) -> [RadarItem] {
        // Aggregators point at other people's pages; their own item links are the
        // ones that need to lose to the publisher's version.
        let aggregators: Set<SourceID> = [.hackerNews, .showHN, .tldr]
        // A source in the Tech News tab that links to another publication is an
        // aggregator too, for the same reason.
        let techAggregators: Set<SourceID> = [SourceID.tech("hackernews")]
        var byCanonical: [String: RadarItem] = [:]
        var order: [String] = []

        /// Strips the tracking parameters and trailing slash that make the same
        /// article look like two different URLs.
        func canonical(_ url: URL) -> String {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let bareHost = comps?.host?.replacingOccurrences(of: "www.", with: "")
            comps?.query = nil
            comps?.fragment = nil
            comps?.host = bareHost
            var s = comps?.string ?? url.absoluteString
            while s.hasSuffix("/") { s.removeLast() }
            return s.lowercased()
        }

        /// HN links to comment pages, which are not the story itself; the story
        /// URL is in the item's own link when it was submitted with one.
        func dedupeKey(_ item: RadarItem) -> String {
            // The tab is part of the key. The same story can be carried by two
            // feeds of the same publication — MIT Technology Review publishes
            // an AI topic feed and a general one — and the two land in two
            // different tabs. They are not duplicates: they are one story read
            // through two scopes, and collapsing them would delete the story
            // from whichever tab lost the race.
            canonical(item.link) + "|" + BriefingSection.section(for: item.source).rawValue
        }

        func isAggregator(_ item: RadarItem) -> Bool {
            aggregators.contains(item.source) || techAggregators.contains(item.source)
        }

        for item in items {
            let key = dedupeKey(item)
            guard let existing = byCanonical[key] else {
                byCanonical[key] = item
                order.append(key)
                continue
            }
            // Keep the publisher's copy over an aggregator's.
            let existingIsAggregator = isAggregator(existing)
            let newIsAggregator = isAggregator(item)
            if existingIsAggregator && !newIsAggregator {
                byCanonical[key] = item
            } else if existingIsAggregator == newIsAggregator {
                // Same tier: prefer the richer record.
                let better = (item.imageURL != nil ? 1 : 0, item.rawSummary.count)
                let current = (existing.imageURL != nil ? 1 : 0, existing.rawSummary.count)
                if better > current { byCanonical[key] = item }
            }
        }
        return order.compactMap { byCanonical[$0] }
    }

    // MARK: - Phase 2: persist (main actor)

    /// Applies a prepared refresh to the store and rebuilds the daily briefing.
    /// Must be called on the main thread.
    static func apply(_ prepared: Prepared, ollama: OllamaConfig,
                      to store: Store, now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        outcome.fetched = prepared.fetched
        outcome.newItems = prepared.newCount
        outcome.statuses = prepared.statuses
        outcome.sourceFailures = prepared.sourceFailures
        outcome.ollamaUsed = prepared.ollamaUsed
        outcome.ollamaModel = prepared.ollamaModel
        outcome.duration = prepared.duration
        outcome.okSources = prepared.statuses.filter { $0.ok }.count
        outcome.unchangedSources = prepared.unchangedSources
        outcome.checkedSources = prepared.checkedSources

        // A refresh is a merge, never a wipe: everything already stored stays, and
        // only the retention window can remove anything.
        let idsBeforeMerge = Set(store.items.map { $0.id })
        store.merge(newItems: prepared.items, now: now,
                    retentionDays: store.state.retentionDays)
        // Count what the archive actually gained. Counting what was *fetched* said
        // "+1,360 new" while only 256 were stored, because the retention window
        // had discarded the rest before it was ever written.
        outcome.newItems = store.items.reduce(into: 0) { n, item in
            if !idsBeforeMerge.contains(item.id) { n += 1 }
        }

        // A source that answered "not modified" produced no items by design, so its
        // stored count and last-success must carry over instead of reading as zero
        // items and a fresh success with nothing in it.
        var carried = prepared.statuses
        for idx in carried.indices where carried[idx].unchanged == true {
            if let prior = store.status(for: carried[idx].source) {
                // Keep the last real success time, and fall back to the stored
                // count only when the cached body could not be re-counted.
                if carried[idx].itemCount == 0 { carried[idx].itemCount = prior.itemCount }
                carried[idx].lastSuccess = prior.lastSuccess
            }
            carried[idx].lastAttempt = now
        }
        store.appendSnapshots(prepared.snapshots)
        store.setStatuses(carried)

        // Rebuild the briefing when the day rolled over, new material arrived,
        // it is stale, or a model became available after a local-only run.
        let existing = store.briefing(for: now)
        let stale = existing == nil
            || existing!.dayKey != Digest.dayKey(now)
            || prepared.newCount > 0
            || now.timeIntervalSince(existing!.generatedAt) > 6 * 3600
            || (ollama.isConfigured && existing!.engine == "local")
            // A briefing written by an older generator is not this build's output;
            // keeping it would show sentences this code no longer writes.
            || (existing!.revision ?? 0) != Digest.revision
        if stale {
            var briefing: DailyBriefing?
            if ollama.isConfigured {
                briefing = Summarizer.ollamaBriefing(
                    items: store.items, now: now, config: ollama,
                    newsPicks: prepared.briefingNews, repoPicks: prepared.briefingRepos,
                    rank: prepared.rank)
            }
            if briefing == nil {
                briefing = Summarizer.localBriefing(
                    items: store.items, now: now,
                    previousDayTopIDs: store.previousTopIDs(before: now),
                    newsPicks: prepared.briefingNews, repoPicks: prepared.briefingRepos,
                    rank: prepared.rank)
            }
            if let briefing {
                store.setBriefing(briefing)
                outcome.briefing = briefing
            }
        } else {
            outcome.briefing = existing
        }

        store.updateState { $0.lastRefresh = now }
        store.saveAll()
        // Keep the picture cache inside its ceiling after a refresh, which is
        // when most of the new pictures arrive.
        ImageLoader.shared.trimDiskCache()
        return outcome
    }

    /// Convenience for headless runs and tests: fetch then apply on this thread.
    static func refresh(store: Store, ollama: OllamaConfig,
                        progress: @escaping (Progress) -> Void = { _ in },
                        now: Date = Date()) -> Outcome {
        let prepared = fetchAll(ollama: ollama,
                                priorItems: store.items,
                                priorSnapshots: store.snapshots,
                                briefingNews: store.state.briefingNewsCount,
                                briefingRepos: store.state.briefingRepoCount,
                                rank: store.state.rank,
                                progress: progress, now: now)
        return apply(prepared, ollama: ollama, to: store, now: now)
    }

    // MARK: - Per source

    private struct SourceResult {
        var items: [RadarItem] = []
        var status: SourceStatus
        var snapshots: [StarSnapshot] = []

        var failedRetryably: Bool { status.failedRetryably }
    }

    /// Fetches one source, retrying once if the first attempt failed.
    ///
    /// A feed that answers with a timeout or a 5xx on the first try usually answers
    /// on the second: the retry is the difference between a source that quietly
    /// disappears from the app and one that is just occasionally slow. A 4xx is
    /// not retried, because a refusal does not become an acceptance.
    private static func fetchOne(_ source: SourceID,
                                 snapshots: [StarSnapshot], now: Date,
                                 repopulate: Bool = false) -> SourceResult {
        let first = fetchOnce(source, snapshots: snapshots, now: now, repopulate: repopulate)
        // Retry only a transient failure. A success is done, and a refusal (403,
        // 404, no such feed) will refuse again — retrying it just doubles the wait.
        guard Self.shouldRetry(first.status) else { return first }
        // A short pause so a rate-limited or overloaded server gets a moment.
        Thread.sleep(forTimeInterval: 1.2)
        var second = fetchOnce(source, snapshots: snapshots, now: now, repopulate: repopulate)
        guard second.status.ok else {
            second.status.message = second.status.message
                + " (retried once: the first attempt also failed)"
            return second
        }
        // Do not overwrite "No change since the last check": a 304 on the retry is
        // still a 304, and the retry note belongs only to a fetch that failed and
        // then returned content.
        if second.status.unchanged != true {
            second.status.message = "Answered on the second attempt after a retry."
        }
        return second
    }

    /// Whether a first attempt is worth repeating: it must have failed, and failed
    /// in a way a second attempt can fix.
    static func shouldRetry(_ status: SourceStatus) -> Bool {
        !status.ok && status.failedRetryably
    }

    private static func fetchOnce(_ source: SourceID,
                                  snapshots: [StarSnapshot], now: Date,
                                  repopulate: Bool = false) -> SourceResult {
        switch source.kind {
        case .feed:
            // Three feed sources publish no RSS document; each has its own
            // collector so the rest of the pipeline stays source-agnostic.
            let out: FeedSource.Outcome
            switch source {
            case .anthropicNews, .anthropicResearch:
                out = AltSource.anthropic(source, now: now)
            case .huggingFaceModels:
                out = AltSource.huggingFaceModels(now: now)
            default:
                // A catalogue publisher that publishes no feed is read from its
                // own listing page, the same way the Anthropic listing is.
                if let design = DesignCatalogue.entry(for: source),
                   design.sourceID == nil, design.usesSitemap,
                   let sitemap = URL(string: design.sitemapURL) {
                    out = AltSource.sitemap(source, now: now, sitemapURL: sitemap,
                                            pathPrefix: design.listingPath)
                    return SourceResult(items: out.items, status: out.status)
                }
                // A publisher whose feed is broken but whose site runs
                // WordPress is read from the site's JSON endpoint, which gives
                // every post with its real date.
                if let design = DesignCatalogue.entry(for: source),
                   design.sourceID == nil, !design.jsonEndpoint.isEmpty,
                   let endpoint = URL(string: design.jsonEndpoint) {
                    out = AltSource.wordPressJSON(source, now: now, endpoint: endpoint)
                    return SourceResult(items: out.items, status: out.status)
                }
                if let design = DesignCatalogue.entry(for: source),
                   design.sourceID == nil, design.usesListing {
                    out = AltSource.listing(source, now: now,
                                            pathPrefix: design.listingPath,
                                            titleSelector: design.listingTitle,
                                            dateSelector: design.listingDate)
                    return SourceResult(items: out.items, status: out.status)
                }
                out = FeedSource.fetch(source, now: now, repopulateFromCache: repopulate)
            }
            return SourceResult(items: out.items, status: out.status)
        case .github:
            let out = source == .gitHubTrending
                ? GitHubSource.fetchTrending(now: now, existingSnapshots: snapshots)
                : GitHubSource.fetchExplore(now: now, existingSnapshots: snapshots)
            return SourceResult(items: out.items, status: out.status, snapshots: out.snapshots)
        }
    }
}
