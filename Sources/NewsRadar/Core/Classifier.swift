import Foundation

/// Classifies a radar item: category, tags, openness flags and a ranking score.
///
/// Everything is keyword driven and deterministic so results are reproducible
/// and testable from `--selftest`.
enum Classifier {

    // MARK: - Public API

    static func classify(_ item: RadarItem, now: Date = Date()) -> RadarItem {
        var out = item
        let haystack = (item.title + " " + item.rawSummary + " "
                        + item.sourceCategories.joined(separator: " ") + " "
                        + (item.repo?.descriptionEN ?? "") + " "
                        + (item.repo?.topics.joined(separator: " ") ?? "") + " "
                        + (item.repo?.language ?? "")).lowercased()

        out.category = category(for: haystack)
        out.tags = tags(for: haystack)
        out.openSource = item.repo != nil
            ? openSourceRepo(item.repo!)
            : matches(haystack, Signals.openSource)
        out.free = matches(haystack, Signals.free) || out.openSource
        out.localExecution = matches(haystack, Signals.local)
        out.appleSilicon = matches(haystack, Signals.appleSilicon)
        out.paidAPI = matches(haystack, Signals.paidAPI)
            || (matches(haystack, ["api", "endpoint", "per token"])
                && !out.localExecution && !out.openSource)
        // A strictly paid API is not "free" just because the copy said "free trial".
        if out.paidAPI && !out.openSource {
            out.free = matches(haystack, ["free tier", "free plan", "open weights"])
        }
        out.keyPoints = facts(for: out)
        out.score = score(out, now: now)
        // A Tech News story carries its own section. The news taxonomy still
        // classifies it, because the score and the facts are built from that,
        // but the tab the reader is in is the one that shows the section.
        if item.source.isTech {
            out.techCategory = TechCatalogue.category(for: item)
        }
        return out
    }

    // MARK: - Category

    static func category(for haystack: String) -> Category {
        strongest(haystack, Signals.category) ?? .other
    }

    /// Returns the category whose signal list matches best.
    ///
    /// Weighting matters more than hit count here: a specific phrase like
    /// "image generation" must beat a scattered generic word like "pricing", and
    /// generic single nouns (see `Signals.weak`) count as tie-breakers only. Ties
    /// resolve by `Category.allCases` order, never by dictionary iteration,
    /// which would make classification non-deterministic between runs.
    static func strongest(_ haystack: String, _ table: [Category: [String]]) -> Category? {
        var best: (category: Category, total: Int)?
        for (category, signals) in table {
            var total = 0
            var hits = 0
            for s in signals where contains(haystack, s) {
                hits += 1
                total += Signals.weak.contains(s) ? 1 : (s.count * s.count / 4 + s.count)
            }
            guard hits > 0 else { continue }
            total += hits * 8
            if let current = best {
                if total > current.total { best = (category, total) }
                else if total == current.total,
                        index(of: category) < index(of: current.category) {
                    best = (category, total)
                }
            } else {
                best = (category, total)
            }
        }
        return best?.category
    }

    private static func index(of category: Category) -> Int {
        Category.allCases.firstIndex(of: category) ?? Category.allCases.count
    }

    // MARK: - Tags

    static func tags(for haystack: String) -> [String] {
        var out: [String] = []
        for group in Signals.tagGroups where matches(haystack, group.signals) {
            out.append(group.label)
        }
        return Array(out.prefix(5))
    }

    // MARK: - Facts (key-point bullets)

    /// The factual bullets shown on a card and in the detail sheet. Values the
    /// app has not measured are omitted rather than shown as "unknown", so an
    /// item never carries more claims than the data supports.
    static func facts(for item: RadarItem) -> [String] {
        var out: [String] = []
        if let repo = item.repo {
            out.append("\(TextFormat.number(repo.stars)) stars on GitHub")
            if let forks = repo.forks, forks > 0 {
                out.append("\(TextFormat.number(forks)) forks")
            }
            if let today = repo.starsToday, today > 0 {
                out.append("+\(TextFormat.number(today)) stars in the last 24 hours")
            }
            if let g = repo.starGrowth7d {
                let sign = g >= 0 ? "+" : "−"
                out.append("\(sign)\(TextFormat.number(abs(g))) stars since the last local snapshot")
            }
            if let created = repo.created { out.append("Created \(TextFormat.date(created))") }
            if let pushed = repo.pushed {
                out.append("Last commit \(TextFormat.relative(pushed))")
            }
            if let license = repo.license {
                out.append("Licence: \(license)")
            } else {
                out.append("No licence declared")
            }
            if item.localExecution { out.append("Runs locally") }
            if item.appleSilicon { out.append("Apple Silicon ready") }
            return out
        }

        if item.paidAPI { out.append("Paid API only") }
        if item.free { out.append(item.openSource ? "Free and open source" : "Free to use") }
        if item.localExecution {
            out.append(item.appleSilicon ? "Runs locally on this Mac (Apple Silicon)"
                                         : "Runs locally")
        } else if item.appleSilicon {
            out.append("Works with Apple Silicon")
        }
        if let author = item.author, !author.isEmpty { out.append("By \(author)") }
        if !item.sourceCategories.isEmpty {
            out.append("Source tags: " + item.sourceCategories.prefix(4).joined(separator: ", "))
        }
        return out
    }

    // MARK: - Scoring

    /// Ranking prioritises free, local, Apple-Silicon friendly and open-source
    /// items, then freshness and engagement. Higher is better.
    static func score(_ item: RadarItem, now: Date = Date()) -> Double {
        var s = 0.0
        let age = max(0, now.timeIntervalSince(item.published))
        s += max(0, 60 - (age / 3600) * 0.6)          // freshness, decays over ~4 days
        if item.free { s += 18 }
        if item.openSource { s += 20 }
        if item.localExecution { s += 22 }
        if item.appleSilicon { s += 16 }
        if item.paidAPI { s -= 10 }
        switch item.kind {
        case .product: s += 4
        case .repository: s += 6
        case .newsletter: s -= 2
        case .news: break
        }
        if let repo = item.repo {
            s += min(30, log10(Double(max(1, repo.stars))) * 8)
            if let today = repo.starsToday { s += min(25, Double(today) / 40) }
        }
        return (s * 100).rounded() / 100
    }

    /// True when a headline or body from a general-interest source is about the
    /// technology this app covers. Used for Hacker News and Show HN, which publish
    /// far more than AI and developer material.
    ///
    /// Whole-word matching keeps "ai" from matching "said" and "train" from
    /// matching "training wheels".
    static func isTechnical(title: String, body: String) -> Bool {
        let haystack = " " + (title + " " + body).lowercased() + " "
        if Signals.technicalTerms.contains(where: { haystack.contains(" " + $0 + " ") }) {
            return true
        }
        // Phrases and hyphenated compounds need a looser check.
        if Signals.technicalTerms.contains(where: {
            ($0.contains(" ") || $0.contains("-")) && haystack.contains($0)
        }) {
            return true
        }
        return false
    }

    /// Show HN posts are launches by definition, so a launch word counts as a
    /// match even when no model or library is named.
    static func isLaunch(title: String, body: String) -> Bool {
        let haystack = " " + (title + " " + body).lowercased() + " "
        return Signals.launchTerms.contains { haystack.contains($0) }
    }

    // MARK: - Helpers

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var start = haystack.startIndex
        while let r = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let before = r.lowerBound == haystack.startIndex
                ? Character(" ") : haystack[haystack.index(before: r.lowerBound)]
            let after = r.upperBound == haystack.endIndex
                ? Character(" ") : haystack[r.upperBound]
            let boundary = !before.isLetter && !before.isNumber && !after.isLetter && !after.isNumber
            if boundary { return true }
            start = r.upperBound
        }
        return false
    }

    static func matches(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { contains(haystack, $0) }
    }

    /// GitHub repos are open source unless the API reports no licence and the
    /// description says otherwise. Repos are always free to read.
    static func openSourceRepo(_ repo: RepoStats) -> Bool {
        if repo.license != nil { return true }
        let d = (repo.descriptionEN ?? "").lowercased()
        return !matches(d, Signals.closedSignals)
    }
}
