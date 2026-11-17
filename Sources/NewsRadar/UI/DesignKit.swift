import AppKit
import SwiftUI

/// Image tile for a card. Loads through `ImageLoader` (memory + disk cache),
/// shows a deterministic coloured placeholder while loading, and falls back to
/// the source symbol when the image is missing or fails.
struct RemoteImage: View {
    var url: URL?
    var accentHex: String
    var symbol: String
    var aspect: CGFloat? = nil
    /// When true the tile fills the frame with the picture (.fill) so it
    /// covers the whole card. The bottom gradient ensures text on top is
    /// readable. Fixed-size callers (rows, briefing) leave this off and
    /// use .fit instead.
    var fillFrame: Bool = false

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fillFrame ? .fill : .fit)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .clipped()
        .overlay {
            if aspect != nil {
                LinearGradient(colors: [.clear, .black.opacity(0.28)],
                               startPoint: .center, endPoint: .bottom)
            }
        }
        .task(id: url) { await load() }
        .animation(.smooth(duration: 0.3), value: image == nil)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [
                Color(hex: accentHex).opacity(0.42),
                Color(hex: accentHex).opacity(0.16)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: failed ? "photo.badge.exclamationmark" : symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func load() async {
        guard let url else {
            // No image is normal (GitHub repos, text-only feeds): keep the
            // symbol placeholder rather than showing an error badge.
            failed = false
            image = nil
            return
        }
        failed = false
        // `load` checks memory, then the disk copy decoded off the main thread,
        // then the network, and calls back on the main queue in every case.
        ImageLoader.shared.load(url) { loaded in
            if let loaded {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// 16:9 (or custom) image frame with rounded corners, used by cards.
struct Thumb: View {
    var item: RadarItem
    var width: CGFloat
    var height: CGFloat
    var overlay: Bool = false
    var badge: Bool = false
    /// When true the tile fills the frame with the picture (.fill) so it
    /// covers the whole card. Grid opts in; rows and briefing use .fit.
    var fillFrame: Bool = false

    var body: some View {
        RemoteImage(url: item.imageURL,
                    accentHex: item.displaySectionAccentHex,
                    symbol: item.isGitHub ? "chevron.left.forwardslash.chevron.right"
                                          : item.displaySectionSymbol,
                    aspect: height,
                    fillFrame: fillFrame)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7)
            }
            .overlay(alignment: .bottomLeading) {
                if badge {
                    HStack(spacing: 5) {
                        SourceBadge(source: item.source, compact: true)
                        if item.isGitHub, let repo = item.repo {
                            TagPill(text: TextFormat.compact(repo.stars),
                                    symbol: "star.fill", tint: .white)
                        }
                    }
                    .padding(7)
                }
            }
    }
}

struct CardActions: View {
    var item: RadarItem
    var isBookmarked: Bool
    var onBookmark: () -> Void
    var onOpen: () -> Void
    var onCopy: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onBookmark) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isBookmarked ? Theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isBookmarked ? "Remove bookmark" : "Bookmark")

            Button(action: onCopy) {
                Image(systemName: "link").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Copy link")

            Button(action: onOpen) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Open original article")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(.ultraThinMaterial)
        }
    }
}

/// Says, on the card itself, that this story can be read without opening a browser.
///
/// A project has no reading mode — its full text is the README on the detail sheet —
/// so it gets no badge rather than a misleading one.
struct ReadHereBadge: View {
    var item: RadarItem

    var body: some View {
        if !item.isGitHub && !ArticleReader.isAppPage(item.link) {
            HStack(spacing: 3) {
                Image(systemName: "book").font(.system(size: 8.5, weight: .semibold))
                Text("Read here").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background {
                Capsule().fill(Theme.accent.opacity(0.12))
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.5))
            }
            .help("Full text is readable inside the app")
            .fixedSize()
        }
    }
}

/// The button that actually opens the story, in this window.
///
/// The old "Read here" was a nine-point badge: too small to aim at, and a
/// plain label, so a click on it did nothing at all. This is a real button with
/// a real hit area, and it says what it does.
struct ReadHereButton: View {
    var item: RadarItem
    var onRead: () -> Void

    var body: some View {
        Button(action: onRead) {
            HStack(spacing: 4) {
                Image(systemName: "book.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Read here")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accentGradient)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Read the full article inside the app")
    }
}

/// Empty-state panel with a title, a hint and an optional action.
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 58, height: 58)
                    .opacity(0.14)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .glassCard()
        .padding(.horizontal, 2)
    }
}

/// Section header used above lists.
struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var symbol: String
    var count: Int?

    init(title: String, symbol: String, subtitle: String? = nil, count: Int? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.count = count
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            Text(title).font(.system(size: 14, weight: .semibold))
            if let count {
                Text(TextFormat.number(count))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background { Capsule().fill(Color.secondary.opacity(0.12)) }
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Tiny source health dot.
struct StatusDot: View {
    var ok: Bool
    var fromCache: Bool = false

    var body: some View {
        Circle()
            .fill(ok ? (fromCache ? Color(hex: "#A8792F") : Color(hex: "#4E8A6B"))
                     : Color(hex: "#B3323F"))
            .frame(width: 7, height: 7)
            .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5) }
    }
}

/// A compact switch.
///
/// A native `.toggleStyle(.switch)` with `controlSize(.small)` draws its thumb in
/// the off position in this app's custom window chrome even when the bound value
/// is true, so the state it showed could not be trusted. This draws the state
/// straight from the value it is handed.
struct PillSwitch: View {
    var isOn: Bool
    var onToggle: () -> Void
    var help: String = ""

    var body: some View {
        Button(action: onToggle) {
            Capsule()
                .fill(isOn ? Theme.accent : Color.white.opacity(0.14))
                .frame(width: 30, height: 17)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white)
                        .frame(width: 13, height: 13)
                        .padding(.horizontal, 2)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
