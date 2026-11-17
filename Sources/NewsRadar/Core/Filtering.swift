import Foundation

// MARK: - Filtering & sorting

/// The one place list filtering and ordering live.
///
/// This used to sit at the bottom of `SelfCheck.swift`, which meant production
/// code was only compiled because the offline test harness was compiled with it.
enum Filtering {

    static func apply(_ items: [RadarItem], filters: Filters,
                      readIDs: Set<String>, now: Date = Date()) -> [RadarItem] {
        var out = items
        if let seconds = filters.range.seconds {
            let cutoff = now.addingTimeInterval(-seconds)
            out = out.filter { $0.published >= cutoff }
        }
        if let cat = filters.category { out = out.filter { $0.category == cat } }
        if !filters.sources.isEmpty { out = out.filter { filters.sources.contains($0.source) } }
        if filters.openSourceOnly { out = out.filter { $0.openSource } }
        if filters.freeOnly { out = out.filter { $0.free } }
        if filters.localOnly { out = out.filter { $0.localExecution } }
        if filters.unreadOnly { out = out.filter { !readIDs.contains($0.id) } }
        let q = filters.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            out = out.filter { matchesQuery($0, q) }
        }
        return out
    }

    /// Search covers the headline, the body text, the summary, the key points,
    /// tags, category and repository metadata, so a company name or an English
    /// phrase finds the card whichever part of it mentions them.
    static func matchesQuery(_ item: RadarItem, _ q: String) -> Bool {
        let haystacks: [String] = [item.title, item.rawSummary, item.headline, item.summary,
                                   item.source.title, item.source.host,
                                   item.keyPoints.joined(separator: " "),
                                   item.tags.joined(separator: " "),
                                   item.category.title,
                                   item.repo?.fullName ?? "",
                                   item.repo?.language ?? "",
                                   item.repo?.license ?? "",
                                   item.repo?.descriptionEN ?? ""]
        for h in haystacks where h.lowercased().contains(q) { return true }
        return false
    }

    /// Orders the list the way the reader's ranking setting says.
    ///
    /// The toolbar's sort menu and this are different things: the sort menu
    /// reorders one list for one look, while the ranking is the app's standing
    /// answer to "what comes first" — a choice made in Settings and applied
    /// everywhere, including the briefing.
    static func rank(_ items: [RadarItem], by mode: RankMode,
                     appleSiliconFirst: Bool,
                     manualOrder: [SourceID] = []) -> [RadarItem] {
        switch mode {
        case .fresh:
            // Freshest first, with the relevance score only breaking ties
            // between stories published in the same second.
            return items.sorted { a, b in
                if a.published != b.published { return a.published > b.published }
                if a.score != b.score { return a.score > b.score }
                return a.id < b.id
            }
        case .relevance:
            return sort(items, by: .relevance, appleSiliconFirst: appleSiliconFirst)
        case .projects:
            // Repositories and tools before news; within each group, relevance.
            return items.sorted { a, b in
                let ap = a.isGitHub || a.kind == .repository
                let bp = b.isGitHub || b.kind == .repository
                if ap != bp { return ap }
                if a.score != b.score { return a.score > b.score }
                return (a.published, a.id) > (b.published, b.id)
            }
        case .source:
            // The busiest publisher first. The count is of the whole window, not
            // of the rows being shown, so the order does not change as the list
            // is capped.
            let counts = Dictionary(grouping: items, by: { $0.source })
                .mapValues { $0.count }
            return items.sorted { a, b in
                let ac = counts[a.source] ?? 0
                let bc = counts[b.source] ?? 0
                if ac != bc { return ac > bc }
                if a.published != b.published { return a.published > b.published }
                return a.id < b.id
            }
        case .manual:
            // The reader's own order of publishers; anything not named goes last,
            // newest first among itself.
            var position: [SourceID: Int] = [:]
            for (index, id) in manualOrder.enumerated() { position[id] = index }
            return items.sorted { a, b in
                let ap = position[a.source]
                let bp = position[b.source]
                switch (ap, bp) {
                case let (x?, y?): return x == y ? a.published > b.published : x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    if a.published != b.published { return a.published > b.published }
                    return a.id < b.id
                }
            }
        }
    }

    static func sort(_ items: [RadarItem], by mode: SortMode,
                     appleSiliconFirst: Bool) -> [RadarItem] {
        switch mode {
        case .newest:
            return items.sorted { ($0.published, $0.id) > ($1.published, $1.id) }
        case .oldest:
            return items.sorted { ($0.published, $0.id) < ($1.published, $1.id) }
        case .stars:
            return items.sorted {
                (($0.repo?.stars ?? -1), $0.published, $0.id) > (($1.repo?.stars ?? -1), $1.published, $1.id)
            }
        case .source:
            return items.sorted {
                ($0.source.rawValue, $0.published, $0.id) < ($1.source.rawValue, $1.published, $1.id)
            }
        case .relevance:
            return items.sorted { a, b in
                if appleSiliconFirst {
                    let af = a.appleSilicon && a.localExecution
                    let bf = b.appleSilicon && b.localExecution
                    if af != bf { return af }
                }
                if a.score != b.score { return a.score > b.score }
                return (a.published, a.id) > (b.published, b.id)
            }
        }
    }
}
