import SwiftUI

/// The scrolling item list. Owns layout switching and section-level empty states.
struct ItemList: View {
    @Environment(AppModel.self) private var model
    var items: [RadarItem]
    var emptySymbol: String
    var emptyTitle: String
    var emptyMessage: String
    var emptyActionTitle: String?
    var emptyAction: (() -> Void)?
    /// Extra header content rendered above the list.
    var header: AnyView?

    /// UI-testing hook: `NEWSRADAR_SCROLL=<n>` scrolls the list to row n on launch,
    /// so the frosted edge under the toolbar can be captured while content is
    /// actually passing beneath it. Real scrolling cannot be synthesised on this
    /// Mac (Accessibility is denied), and a screenshot of the resting state proves
    /// nothing about the blur.
    private var testScrollRow: Int? {
        guard let raw = ProcessInfo.processInfo.environment["NEWSRADAR_SCROLL"] else { return nil }
        return Int(raw)
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollBody
                .onAppear(perform: { scrollIfAsked(proxy) })
        }
    }

    private func scrollIfAsked(_ proxy: ScrollViewProxy) {
        guard let row = testScrollRow, items.count > row else { return }
        let id = items[row].id + "-" + model.layout.idSuffix
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    private var scrollBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let header { header }

                if items.isEmpty {
                    EmptyState(symbol: emptySymbol, title: emptyTitle, message: emptyMessage,
                               actionTitle: emptyActionTitle, action: emptyAction)
                        .padding(.top, 8)
                } else {
                    content
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 22)
            .frame(maxWidth: 1320, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Rows scroll under the frosted toolbar and blur out there, instead of being
        // sheared off at a hard line.
        .scrollIndicators(.automatic)
        .animation(.smooth(duration: 0.25), value: items.count)
        .animation(.smooth(duration: 0.25), value: model.layout)
    }

    @ViewBuilder
    private var content: some View {
        switch model.layout {
        case .compact:
            LazyVStack(spacing: 6) {
                ForEach(items) { item in
                    CompactRow(item: item,
                               isBookmarked: model.store.isBookmarked(item.id),
                               isRead: model.store.isRead(item.id),
                               onBookmark: { model.toggleBookmark(item) },
                               onOpen: { model.readHere(item) },
                               onDetail: { model.detailItem = item })
                    .id(item.id + "-c")
                }
            }
        case .comfortable:
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    ComfortableRow(item: item,
                                   isBookmarked: model.store.isBookmarked(item.id),
                                   isRead: model.store.isRead(item.id),
                                   onBookmark: { model.toggleBookmark(item) },
                                   onOpen: { model.readHere(item) },
                                   onDetail: { model.detailItem = item })
                    .id(item.id + "-f")
                }
            }
        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMin), spacing: 12)],
                      spacing: 12) {
                ForEach(items) { item in
                    GridTile(item: item,
                             isBookmarked: model.store.isBookmarked(item.id),
                             isRead: model.store.isRead(item.id),
                             onBookmark: { model.toggleBookmark(item) },
                             onOpen: { model.readHere(item) },
                             onDetail: { model.detailItem = item })
                    .id(item.id + "-g")
                }
            }
        }
    }
}

/// A single-item card used inside the briefing tab, with an accent rail.
struct BriefingPick: View {
    var item: RadarItem
    var rank: Int?
    var onDetail: () -> Void
    var onOpen: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let rank {
                Text(TextFormat.number(rank))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background { Circle().fill(Theme.accentGradient) }
            }
            Thumb(item: item, width: 132, height: 88)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    SourceBadge(source: item.source)
                    CategoryChip(item: item)
                }
                Text(item.displayTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    FlagPills(item: item)
                    Spacer(minLength: 0)
                    DateLine(date: item.published)
                }
            }
            Spacer(minLength: 0)
            Button {
                onOpen()
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Open original article")
        }
        .padding(12)
        .contentShape(Rectangle())
        .glassInteractiveCard(hovered: hovered)
        .onHover { hovered = $0 }
        .onTapGesture(perform: onDetail)
    }
}
