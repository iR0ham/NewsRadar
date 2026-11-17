import SwiftUI

/// The three layout modes.
///
/// All three render the same data with the same ordering — only density changes,
/// so switching never changes *what* you see, only how much of it.

// MARK: - Compact row

struct CompactRow: View {
    var item: RadarItem
    var isBookmarked: Bool
    var isRead: Bool
    var onBookmark: () -> Void
    var onOpen: () -> Void
    var onDetail: () -> Void

    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            // The tap target is the story itself. The "Read here" button sits
            // outside it, so a click on the button is a click on the button —
            // a button inside a tap gesture is a race the button can lose.
            HStack(spacing: 10) {
                Thumb(item: item, width: 64, height: 42)
                    .opacity(isRead ? 0.72 : 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.system(size: 12.5, weight: isRead ? .regular : .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        SourceBadge(source: item.source, compact: true)
                        ReadHereBadge(item: item)
                        DateLine(date: item.published)
                        if item.isGitHub, let repo = item.repo {
                            RepoStatsRow(repo: repo, compact: true)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onDetail)

            Spacer(minLength: 4)

            if item.localExecution { Image(systemName: "desktopcomputer")
                .font(.system(size: 10)).foregroundStyle(Color(hex: "#4B7FA6"))
                .help("Runs locally") }
            if item.free { Image(systemName: "gift")
                .font(.system(size: 10)).foregroundStyle(Color(hex: "#4E8A6B"))
                .help("Free") }
            if item.paidAPI && !item.free { Image(systemName: "creditcard")
                .font(.system(size: 10)).foregroundStyle(Color(hex: "#A8792F"))
                .help("Paid API") }

            if !item.isGitHub && !ArticleReader.isAppPage(item.link) {
                ReadHereButton(item: item) { model.readHere(item) }
            }

            if hovered {
                CardActions(item: item, isBookmarked: isBookmarked, onBookmark: onBookmark,
                            onOpen: onOpen, onCopy: { copyLink(item.link) })
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .contentShape(Rectangle())
        .glassInteractiveCard(hovered: hovered, radius: 13)
        .opacity(isRead ? 0.86 : 1)
        .onHover { hovered = $0 }
        .contextMenu { ItemContextMenu(item: item, isBookmarked: isBookmarked,
                                       onBookmark: onBookmark, onOpen: onOpen,
                                       onDetail: onDetail) }
    }
}

// MARK: - Comfortable row

struct ComfortableRow: View {
    var item: RadarItem
    var isBookmarked: Bool
    var isRead: Bool
    var onBookmark: () -> Void
    var onOpen: () -> Void
    var onDetail: () -> Void

    @Environment(AppModel.self) private var model
    @State private var hovered = false

    private var imageWidth: CGFloat { 168 }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            // The story is the tap target; the "Read here" button is a sibling
            // of it, so clicking the button can never be swallowed by the row.
            HStack(alignment: .top, spacing: 13) {
                Thumb(item: item, width: imageWidth, height: 108, badge: false)
                    .opacity(isRead ? 0.8 : 1)

                VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SourceBadge(source: item.source)
                    ReadHereBadge(item: item)
                    CategoryChip(item: item)
                        .opacity(0.95)
                    Spacer(minLength: 4)
                    if hovered {
                        CardActions(item: item, isBookmarked: isBookmarked,
                                    onBookmark: onBookmark, onOpen: onOpen,
                                    onCopy: { copyLink(item.link) })
                            .transition(.opacity)
                    }
                }

                Text(item.displayTitle)
                    .font(.system(size: 14.5, weight: isRead ? .medium : .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !item.keyPoints.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(item.keyPoints.prefix(3).enumerated()), id: \.offset) { _, point in
                            TagPill(text: point, symbol: nil, tint: .secondary)
                        }
                    }
                    .lineLimit(1)
                }

                FlagPills(item: item)

                HStack(spacing: 8) {
                    if !item.isGitHub && !ArticleReader.isAppPage(item.link) {
                        ReadHereButton(item: item) { model.readHere(item) }
                    }
                    DateLine(date: item.published)
                    if item.isGitHub, let repo = item.repo {
                        RepoStatsRow(repo: repo, compact: true)
                    }
                    // Name the engine that actually wrote this summary. The badge
                    // used to test only for "ollama", so a 9router summary showed
                    // nothing at all.
                    let engine = EngineLabel.describe(item.summaryEngine)
                    if engine.isModel {
                        TagPill(text: engine.title, symbol: engine.symbol, tint: Theme.accent)
                    }
                }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onDetail)
        }
        .padding(Theme.cardPadding)
        .contentShape(Rectangle())
        .glassInteractiveCard(hovered: hovered)
        .opacity(isRead ? 0.88 : 1)
        .onHover { hovered = $0 }
        .contextMenu { ItemContextMenu(item: item, isBookmarked: isBookmarked,
                                       onBookmark: onBookmark, onOpen: onOpen,
                                       onDetail: onDetail) }
    }
}

// MARK: - Visual grid tile

struct GridTile: View {
    var item: RadarItem
    var isBookmarked: Bool
    var isRead: Bool
    var onBookmark: () -> Void
    var onOpen: () -> Void
    var onDetail: () -> Void

    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Thumb(item: item, width: .infinity, height: 164, badge: false, fillFrame: true)
                HStack(spacing: 4) {
                    SourceBadge(source: item.source, compact: true)
                    if hovered {
                        CardActions(item: item, isBookmarked: isBookmarked,
                                    onBookmark: onBookmark, onOpen: onOpen,
                                    onCopy: { copyLink(item.link) })
                    }
                }
                .padding(7)
            }
            .overlay(alignment: .bottomLeading) {
                if let repo = item.repo {
                    HStack(spacing: 5) {
                        TagPill(text: TextFormat.compact(repo.stars), symbol: "star.fill", tint: .white)
                        if let today = repo.starsToday, today > 0 {
                            TagPill(text: "+" + TextFormat.compact(today), symbol: "arrow.up.right",
                                    tint: Color(hex: "#7FB39D"))
                        }
                    }
                    .padding(8)
                }
            }

            // The tile's text is the tap target; the "Read here" button is a
            // sibling of it, so a click on the button is never swallowed by the
            // tile's own gesture.
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: isRead ? .medium : .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !item.keyPoints.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(item.keyPoints.prefix(2).enumerated()), id: \.offset) { _, point in
                            TagPill(text: point, symbol: nil, tint: .secondary)
                        }
                    }
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    CategoryChip(item: item)
                        .opacity(0.95)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if item.localExecution {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 10)).foregroundStyle(Color(hex: "#4B7FA6"))
                    }
                    if item.free {
                        Image(systemName: "gift")
                            .font(.system(size: 10)).foregroundStyle(Color(hex: "#4E8A6B"))
                    }
                    if item.paidAPI && !item.free {
                        Image(systemName: "creditcard")
                            .font(.system(size: 10)).foregroundStyle(Color(hex: "#A8792F"))
                    }
                }
                if let repo = item.repo {
                    RepoStatsRow(repo: repo, compact: true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onDetail)

            HStack(spacing: 8) {
                if !item.isGitHub && !ArticleReader.isAppPage(item.link) {
                    ReadHereButton(item: item) { model.readHere(item) }
                }
                DateLine(date: item.published)
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassInteractiveCard(hovered: hovered)
        .opacity(isRead ? 0.88 : 1)
        .onHover { hovered = $0 }
        .contextMenu { ItemContextMenu(item: item, isBookmarked: isBookmarked,
                                       onBookmark: onBookmark, onOpen: onOpen,
                                       onDetail: onDetail) }
    }
}

// MARK: - Shared pieces

/// Right-click menu shared by all three layouts.
struct ItemContextMenu: View {
    var item: RadarItem
    var isBookmarked: Bool
    var onBookmark: () -> Void
    var onOpen: () -> Void
    var onDetail: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        // Reading the article is the primary action now: it is what "open this
        // story" means. The original page is still one item below.
        //
        // A project has no reading mode, so it must not offer one: its full text is
        // the README, which the detail sheet already shows. Offering "Read here" and
        // then refusing is worse than not offering it.
        if !item.isGitHub && !ArticleReader.isAppPage(item.link) {
            Button("Read here") { model.readerItem = item }
        }
        Button("Show details", action: onDetail)
        Button(item.isGitHub ? "Open project" : "Open original article", action: onOpen)
        Divider()
        Button(isBookmarked ? "Remove bookmark" : "Bookmark", action: onBookmark)
        Button("Copy link") { copyLink(item.link) }
        if let repo = item.repo {
            Divider()
            Button("Copy repository name") { copyToPasteboard(repo.fullName) }
            if let home = repo.homepage {
                Button("Project website") { NSWorkspace.shared.open(home) }
            }
        }
        Divider()
        Button("Copy summary") {
            copyToPasteboard("\(item.displayTitle)\n\n\(item.summary)\n\n\(item.link.absoluteString)")
        }
    }
}

func copyLink(_ url: URL) {
    copyToPasteboard(url.absoluteString)
}

func copyToPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}
