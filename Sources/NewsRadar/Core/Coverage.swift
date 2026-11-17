import Foundation

/// How much a source has given us, measured by date window.
///
/// This exists because a working source looked broken. The news list defaults to a
/// twelve-hour window; a publisher that posts twice a day has one story in it, and
/// a weekly one has none. Filtering to that source showed an empty page under a
/// sidebar count of twenty, and there was nothing on screen to say why.
///
/// The fix is not a wider default window — that would bury today's news under a
/// week of it. It is to measure, and to let the app say what it measured.
enum Coverage {

    /// One count per range, narrow to wide, for a single source.
    static func byRange(_ items: [RadarItem], source: SourceID,
                        now: Date) -> [(range: DateRange, count: Int)] {
        let mine = items.filter { $0.source == source && !$0.isGitHub }
        return DateRange.allCases.map { range in
            guard let seconds = range.seconds else { return (range, mine.count) }
            let cutoff = now.addingTimeInterval(-seconds)
            return (range, mine.filter { $0.published >= cutoff }.count)
        }
    }

    /// The narrowest window that holds anything from this source.
    ///
    /// `allCases` runs narrow to wide, so the first non-empty one is the answer.
    /// When the source is genuinely empty the caller's window is kept: silently
    /// widening to "all time" would claim there is something to see.
    static func narrowest(_ items: [RadarItem], source: SourceID,
                          now: Date, fallback: DateRange) -> DateRange {
        let measured = byRange(items, source: source, now: now)
        return measured.first { $0.count > 0 && $0.range != .all }?.range
            ?? measured.first { $0.count > 0 }?.range
            ?? fallback
    }
}
