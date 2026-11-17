import SwiftUI
import AppKit

/// Design tokens for the Liquid Glass look: translucent surfaces, hairline
/// strokes, soft shadows and a single accent gradient.
enum Theme {

    // Geometry
    static let cardRadius: CGFloat = 18
    static let tileRadius: CGFloat = 12
    static let chipRadius: CGFloat = 9
    static let cardPadding: CGFloat = 14
    static let sidebarWidth: CGFloat = 232
    static let gridMin: CGFloat = 268

    // Accents
    //
    // The palette is wine, not violet: a deep maroon base with a lighter red
    // highlight, and a near-neutral slate for the secondary surfaces so the dark
    // window stays dark instead of glowing magenta. `accent` is the colour of
    // selection and primary action; `accent2` is only ever used as the far end of
    // the gradient.
    static let accent = Color(hex: "#B3202E")
    static let accent2 = Color(hex: "#7A1220")
    static let accentSoft = Color(hex: "#E0424F")
    static let accentGradient = LinearGradient(
        colors: [Color(hex: "#C02434"), Color(hex: "#7A1220")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Dark, desaturated slate used behind panels and the GitHub block, so
    /// secondary areas read as "dark" rather than as tinted accent.
    static let slate = Color(hex: "#16181D")
    static let slateLine = Color(hex: "#23262D")

    // MARK: Text ramp
    //
    // Deliberately separated from the hue. The filter panel previously used the
    // accent for its labels, so a red label sat on a maroon card and disappeared.
    // Text is always neutral; only interactive state carries the accent.

    /// Primary text: near-white in dark mode, near-black in light mode.
    static let textPrimary = Color.primary
    /// Secondary text that still has to be readable on glass.
    static let textSecondary = Color.primary.opacity(0.82)
    /// Labels, captions and units.
    static let textTertiary = Color.primary.opacity(0.66)

    /// Separators. These were hard-coded black, which is invisible on a dark
    /// window: the sidebar and toolbar edges looked like cut-off panels rather than
    /// seams. `Color.primary` flips with the appearance, so one constant is a light
    /// hairline in dark mode and a dark one in light.
    static let separator = Color.primary.opacity(0.10)
    static let separatorSoft = Color.primary.opacity(0.06)

    static let hairlineTop = LinearGradient(
        colors: [Color.white.opacity(0.55), Color.white.opacity(0.06)],
        startPoint: .top, endPoint: .bottom)

    static let imageGradient = LinearGradient(
        colors: [Color.black.opacity(0.0), Color.black.opacity(0.45)],
        startPoint: .center, endPoint: .bottom)

    static let shadow = Color.black.opacity(0.16)

    /// A deeper, flatter backdrop for the dark appearance: the previous one put a
    /// red wash over a near-white system background, which was the "pale and
    /// washed out" look. In dark mode the base is genuinely dark and the wash is
    /// only a hint.
    static func backdrop(isDark: Bool) -> (base: Color, topTint: Color, bottomTint: Color) {
        if isDark {
            // The top tint used to be the accent at 16%, which tinted everything
            // behind the glass a warm maroon. The sidebar (that material) then read
            // as a red slab pasted onto a slate window — three surfaces, three
            // colours. The wash is neutral slate now, so the accent appears only
            // where it means something: selection and the primary action.
            return (Color(hex: "#121317"),
                    Color(hex: "#1C1F26").opacity(0.85),
                    Color(hex: "#08090B").opacity(0.9))
        }
        return (Color(hex: "#F6F4F3"),
                Color(hex: "#FFFFFF").opacity(0.9),
                Color(hex: "#E7E2E1").opacity(0.9))
    }
}

// MARK: - Glass surfaces

/// Base translucent card surface: thin material, hairline top highlight and a
/// soft drop shadow. Everything that looks like a "card" uses this.
struct GlassSurface: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var interactive = false
    var hovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairlineTop, lineWidth: 0.8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
            }
            .shadow(color: Theme.shadow.opacity(hovered ? 1.0 : 0.55),
                    radius: hovered ? 16 : 8, x: 0, y: hovered ? 6 : 3)
            .scaleEffect(interactive && hovered ? 1.006 : 1)
            .animation(.smooth(duration: 0.22), value: hovered)
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(GlassSurface(radius: radius))
    }

    /// A card that lifts slightly on hover.
    func glassInteractiveCard(hovered: Bool, radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(GlassSurface(radius: radius, interactive: true, hovered: hovered))
    }
}

/// Frosted bar used for the custom toolbar and section headers.
struct GlassBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 0.6)
            }
    }
}

extension View {
    func glassBar() -> some View { modifier(GlassBar()) }
}

// MARK: - Colour helpers

extension Color {
    init(hex: String) {
        self = Color(nsColor: NSColor(hex: hex) ?? .controlAccentColor)
    }
}

// MARK: - Small UI atoms

/// The publisher's logo, loaded from the favicon service and falling back to the
/// source's SF Symbol while it loads or if it never arrives.
struct SourceLogo: View {
    var source: SourceID
    var size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Image(systemName: source.symbol)
                    .font(.system(size: size * 0.78, weight: .bold))
            }
        }
        .frame(width: size, height: size)
        .task(id: source) {
            guard let url = source.logoURL else { return }
            ImageLoader.shared.load(url) { img in
                if let img { image = img }
            }
        }
    }
}

/// Source badge: the publisher's logo + name in the source's accent colour.
struct SourceBadge: View {
    var source: SourceID
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            SourceLogo(source: source, size: compact ? 11 : 13)
            Text(compact ? source.shortTitle : source.title)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color(hex: source.accentHex))
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(Color(hex: source.accentHex).opacity(0.13))
        }
        .overlay {
            Capsule().strokeBorder(Color(hex: source.accentHex).opacity(0.22), lineWidth: 0.6)
        }
    }
}

/// Section chip with the section's own icon and colour.
///
/// The chip asks the item which section it belongs to rather than the news
/// taxonomy directly: a Tech News story is filed under its own seven sections
/// (Hardware, Cybersecurity, …), and showing "Language Models" on a story about
/// a graphics card would be a label that means nothing to the reader.
struct CategoryChip: View {
    var title: String
    var symbol: String
    var accentHex: String
    var showsTitle = true

    init(category: Category, showsTitle: Bool = true) {
        self.title = category.title
        self.symbol = category.symbol
        self.accentHex = category.accentHex
        self.showsTitle = showsTitle
    }

    init(item: RadarItem, showsTitle: Bool = true) {
        self.title = item.displaySectionTitle
        self.symbol = item.displaySectionSymbol
        self.accentHex = item.displaySectionAccentHex
        self.showsTitle = showsTitle
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            if showsTitle {
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
        }
        .foregroundStyle(Color(hex: accentHex))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background { Capsule().fill(Color(hex: accentHex).opacity(0.12)) }
    }
}

/// Neutral pill used for tags and stat labels.
struct TagPill: View {
    var text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .semibold)) }
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background { Capsule().fill(tint.opacity(0.12)) }
    }
}

/// Free / open source / local / Apple Silicon markers, shown only when true.
struct FlagPills: View {
    var item: RadarItem
    var limit = 3

    var body: some View {
        HStack(spacing: 5) {
            if item.localExecution && item.appleSilicon {
                TagPill(text: "Local on Mac", symbol: "apple.logo", tint: Color(hex: "#4B7FA6"))
            } else if item.localExecution {
                TagPill(text: "Runs locally", symbol: "desktopcomputer", tint: Color(hex: "#4B7FA6"))
            } else if item.appleSilicon {
                TagPill(text: "Apple Silicon", symbol: "apple.logo", tint: Color(hex: "#4B7FA6"))
            }
            if item.free {
                TagPill(text: item.openSource ? "Open & free" : "Free",
                        symbol: "gift", tint: Color(hex: "#4E8A6B"))
            } else if item.openSource {
                TagPill(text: "Open source", symbol: "chevron.left.forwardslash.chevron.right",
                        tint: Color(hex: "#4E8A6B"))
            }
            if item.paidAPI && !item.free {
                TagPill(text: "Paid API", symbol: "creditcard", tint: Color(hex: "#A8792F"))
            }
        }
        .lineLimit(1)
    }
}

/// Repo statistics line: stars, growth, language, license, creation date.
struct RepoStatsRow: View {
    var repo: RepoStats
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            stat("star.fill", TextFormat.compact(repo.stars), Color(hex: "#A8792F"))
            if let today = repo.starsToday, today > 0 {
                stat("arrow.up.right", "+" + TextFormat.compact(today), Color(hex: "#4E8A6B"))
            } else if let growth = repo.starGrowth7d, growth != 0 {
                stat(growth > 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                     (growth > 0 ? "+" : "−") + TextFormat.compact(abs(growth)),
                     growth > 0 ? Color(hex: "#4E8A6B") : Color(hex: "#B3323F"))
            }
            if let lang = repo.language {
                stat("chevron.left.forwardslash.chevron.right", lang, .secondary)
            }
            if let license = repo.license, !compact {
                stat("checkmark.seal", license, .secondary)
            }
            if let created = repo.created, !compact {
                stat("calendar", TextFormat.shortDate(created), .secondary)
            }
        }
        .lineLimit(1)
    }

    private func stat(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: compact ? 8 : 9, weight: .semibold))
            Text(text).font(.system(size: compact ? 10 : 11, weight: .medium))
        }
        .foregroundStyle(tint)
    }
}

/// Date + relative time line.
struct DateLine: View {
    var date: Date
    var source: SourceID?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 9, weight: .medium))
            Text(TextFormat.relative(date))
            Text("·")
            Text(TextFormat.shortDate(date))
        }
        .font(.system(size: 10.5, weight: .regular))
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
    }
}
