import Foundation

/// Date, number and text formatting helpers (English).
enum TextFormat {

    // MARK: - Numbers

    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 217440 -> "217,440"
    static func number(_ n: Int) -> String {
        decimal.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Compact form for tight rows: 217440 -> "217.4k", 1310 -> "1,310"
    static func compact(_ n: Int) -> String {
        switch abs(n) {
        case 1_000_000...:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        case 100_000...:
            return String(format: "%.0fk", Double(n) / 1_000)
        case 10_000...:
            return String(format: "%.1fk", Double(n) / 1_000)
        default:
            return number(n)
        }
    }

    // MARK: - Dates

    private static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d"
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    /// "Oct 19, 2026"
    static func date(_ d: Date) -> String { mediumDate.string(from: d) }

    /// "Oct 19"
    static func shortDate(_ d: Date) -> String { shortDate.string(from: d) }

    /// "14:37"
    static func time(_ d: Date) -> String { clock.string(from: d) }

    /// "Monday, October 19, 2026"
    static func longDate(_ d: Date) -> String { weekday.string(from: d) }

    /// "3h ago", "2d ago", "just now"
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 0 {
            let ahead = -delta
            if ahead < 3600 { return "in \(max(1, Int(ahead / 60)))m" }
            if ahead < 86400 { return "in \(max(1, Int(ahead / 3600)))h" }
            return "in \(max(1, Int(ahead / 86400)))d"
        }
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        if delta < 7 * 86400 { return "\(Int(delta / 86400))d ago" }
        if delta < 30 * 86400 { return "\(Int(delta / (7 * 86400)))w ago" }
        if delta < 365 * 86400 { return "\(Int(delta / (30 * 86400)))mo ago" }
        return "\(Int(delta / (365 * 86400)))y ago"
    }

    /// "2 years old" — used for repository age.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        let days = Int(delta / 86400)
        if days < 30 { return "\(days)d old" }
        if days < 365 { return "\(days / 30)mo old" }
        let years = Double(days) / 365.0
        return String(format: "%.1fy old", years)
    }

    // MARK: - Text

    /// Collapses whitespace and trims.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates on a word boundary, adding an ellipsis.
    static func truncate(_ s: String, to limit: Int) -> String {
        let t = clean(s)
        guard t.count > limit else { return t }
        let slice = String(t.prefix(limit))
        if let lastSpace = slice.lastIndex(of: " ") {
            return String(slice[..<lastSpace]) + "…"
        }
        return slice + "…"
    }
}
