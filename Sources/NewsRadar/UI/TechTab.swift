import SwiftUI

/// The Tech News tab: a premium editorial feed from ten publishers.
///
/// The tab is its own reading surface, like Web & SEO and Design & Creative AI,
/// and it is drawn with the same pieces as the rest of the app: the same cards,
/// the same badges, the same hairline borders, the same typography. Nothing
/// here is a second design language — it is the app, reading a different set
/// of publishers.
///
/// Its filters are local to the tab. The news taxonomy (Language Models, AI
/// Agents, …) has no place for a story about a graphics card, and the Tech
/// sections would be meaningless in it. The toolbar's search still applies,
/// because a reader looking for "TSMC" wants it wherever it was published.
struct TechTab: View {
    @Environment(AppModel.self) private var model

    @State private var showSources = false

    // The tab's filters live on the model: the toolbar's Filter button and this
    // header must edit one state, or the panel would show something other than
    // what the list is doing.
    private var category: TechCategory? { model.techSection }
    private var sourceID: String? { model.techSource }
    private var range: DateRange { model.techRange }

    /// Everything the tab's window and the toolbar's shared controls select.
    ///
    /// Built by the model so the filter panel and this list cannot disagree
    /// about what the window contains.
    private var windowItems: [RadarItem] {
        model.techWindowItems()
    }

    /// The window narrowed to the publisher chosen in this tab's own panel.
    private var sourceItems: [RadarItem] {
        guard let sourceID, let entry = TechCatalogue.source(sourceID) else { return windowItems }
        return windowItems.filter { $0.source == entry.sourceID }
    }

    /// Everything this tab's filters select, before the list cap.
    private var allItems: [RadarItem] {
        guard let category else { return sourceItems }
        return sourceItems.filter { $0.techCategory == category }
    }

    /// What is drawn: the same list, capped. The cap is applied after the tab's
    /// own filters, so a narrow publisher can never be hidden by the cap itself.
    private var items: [RadarItem] {
        model.listLimit > 0 ? Array(allItems.prefix(model.listLimit)) : allItems
    }

    /// The list is already narrowed to this tab's two filters.
    private var filtered: [RadarItem] { items }

    var body: some View {
        ItemList(items: filtered,
                 emptySymbol: "cpu",
                 emptyTitle: emptyTitle,
                 emptyMessage: emptyMessage,
                 emptyActionTitle: emptyAction,
                 emptyAction: emptyActionRun,
                 header: AnyView(header))
        // UI-testing hook: the source panel is inline, but a screenshot still
        // needs a way to open it without a synthesised click.
        .onAppear {
            if ProcessInfo.processInfo.environment["NEWSRADAR_TECH_SOURCES"] == "1" {
                showSources = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Tech News")
                    .font(.system(size: 15, weight: .semibold))
                // The window is named, because the sidebar badge counts what is
                // stored and this counts what the window holds. Two numbers that
                // look like rivals are one number each, and saying which is which
                // is the difference between that and a bug.
                Text(TextFormat.number(sourceItems.count) + " stories in "
                     + (range == .all ? "the archive" : "the last " + range.label))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                if items.count < allItems.count {
                    Text("· showing \(TextFormat.number(items.count))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                rangePicker
                Button {
                    showSources.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Sources")
                            .font(.system(size: 11, weight: .medium))
                        Text(TextFormat.number(TechCatalogue.sources.count))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
                .buttonStyle(.plain)
                .help("Every publisher in this tab")
            }

            Text("The whole of technology, from ten publishers")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)

            if let sourceID, let s = TechCatalogue.source(sourceID) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 10))
                    Text("Only \(s.title)")
                        .font(.system(size: 10.5))
                    Button {
                        model.techSource = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.accent)
            }

            if showSources { sourcePanel }

            categoryChips
        }
        .padding(.top, 4)
    }

    /// Quick window chips. The same property the filter panel edits, so the two
    /// controls can never show different windows.
    private var rangePicker: some View {
        HStack(spacing: 3) {
            ForEach([DateRange.twelveHours, .day, .threeDays, .week, .all]) { r in
                Button {
                    model.techRange = r
                } label: {
                    Text(r.shortTitle)
                        .font(.system(size: 10, weight: range == r ? .semibold : .regular))
                        .foregroundStyle(range == r ? AnyShapeStyle(.white)
                                                    : AnyShapeStyle(Theme.textSecondary))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(range == r ? AnyShapeStyle(Theme.accent)
                                                 : AnyShapeStyle(Color.primary.opacity(0.06)))
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One chip per section of this tab. The count is what it would show, so an
    /// empty section is visible before it is chosen.
    private var categoryChips: some View {
        let counts = self.counts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All Tech", symbol: "square.grid.3x3", count: sourceItems.count,
                     selected: category == nil) { model.techSection = nil }
                ForEach(TechCategory.allCases) { cat in
                    chip(title: cat.shortTitle, symbol: cat.symbol,
                         count: counts[cat] ?? 0, selected: category == cat) {
                        model.techSection = (category == cat) ? nil : cat
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func chip(title: String, symbol: String, count: Int,
                      selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                Text(TextFormat.number(count))
                    .font(.system(size: 9.5))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75))
                                              : AnyShapeStyle(Theme.textTertiary))
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.accentGradient)
                                   : AnyShapeStyle(Color.primary.opacity(0.06)))
            }
        }
        .buttonStyle(.plain)
        .help("\(title) — \(count) stories in this window")
    }

    /// How many stories each section of this tab would show right now.
    ///
    /// Counted from the publisher-filtered window, not from the category-
    /// filtered list: counting the list would zero every other chip the moment
    /// one section was selected.
    private var counts: [TechCategory: Int] {
        var out: [TechCategory: Int] = [:]
        for item in sourceItems {
            guard let cat = item.techCategory else { continue }
            out[cat, default: 0] += 1
        }
        return out
    }

    // MARK: - Source panel
    //
    // Inline rather than a popover. A popover anchored inside this scrolling
    // header is dismissed before its first layout and never appears at all.

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sources").font(.system(size: 11.5, weight: .semibold))
                Text("Tech News")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Text("\(TechCatalogue.sources.count) publishers")
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                ForEach(TechCatalogue.sources, id: \.id) { s in
                    Button {
                        model.techSource = (sourceID == s.id) ? nil : s.id
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: TechCatalogue.symbol(for: s))
                                .font(.system(size: 10))
                                .frame(width: 14)
                                .foregroundStyle(Color(hex: TechCatalogue.accent(for: s)))
                            Text(s.title).font(.system(size: 11))
                            Spacer(minLength: 4)
                            Text(TextFormat.number(storedCount(s)))
                                .font(.system(size: 9.5)).monospacedDigit()
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(s.home)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.7)
        }
    }

    /// How many stories this publisher has in the store.
    ///
    /// Counted from the store rather than from the last fetch's report: the
    /// reader is choosing a publisher to read, and the number that answers that
    /// is what the app holds, not what one request happened to return.
    private func storedCount(_ s: TechSource) -> Int {
        _ = model.revision
        return model.store.items.reduce(0) { $0 + ($1.source == s.sourceID ? 1 : 0) }
    }

    // MARK: - Empty state

    /// Whether the archive holds any Tech story at all.
    ///
    /// The empty state used to read "Nothing from these publishers yet" whenever
    /// the current window was empty, even with 990 stories stored — the reader
    /// was told the feeds had never answered when the only problem was the 24h
    /// window.
    private var hasStoredStories: Bool {
        _ = model.revision
        return model.store.items.contains { $0.source.isTech }
    }

    private var emptyTitle: String {
        if category != nil { return "Nothing in this section" }
        if sourceID != nil { return "Nothing from this publisher" }
        return hasStoredStories ? "Nothing in this window" : "Nothing from these publishers yet"
    }

    private var emptyMessage: String {
        if !model.filters.query.isEmpty {
            return "No story matches “\(model.filters.query)” in the \(range.shortTitle) window. "
                + "Clear the search, or widen the window."
        }
        if model.filters.unreadOnly {
            return "Every story in the \(range.shortTitle) window has been read. "
                + "Widen the window, or show read stories too."
        }
        if let category {
            return "\(category.title) has nothing in the \(range.shortTitle) window. "
                + "Widen the window, or pick all sections."
        }
        if let sourceID, let s = TechCatalogue.source(sourceID) {
            return "\(s.title) has nothing in the \(range.shortTitle) window. "
                + "Widen the window, or pick another publisher."
        }
        if hasStoredStories {
            return "These publishers have stories outside the \(range.shortTitle) window. "
                + "Widen the window to see them."
        }
        return "These ten publishers update through the day, but a refresh has not "
            + "reached them yet. Press Refresh, or widen the window."
    }

    private var emptyAction: String? {
        if !model.filters.query.isEmpty { return "Clear the search" }
        if model.filters.unreadOnly { return "Show read stories" }
        if category != nil { return "Show all sections" }
        if sourceID != nil { return "Show every publisher" }
        return hasStoredStories ? "Show all time" : "Refresh"
    }

    private var emptyActionRun: (() -> Void)? {
        if !model.filters.query.isEmpty {
            return { model.filters.query = "" }
        }
        if model.filters.unreadOnly {
            return { model.filters.unreadOnly = false }
        }
        if category != nil {
            return { model.techSection = nil }
        }
        if sourceID != nil {
            return { model.techSource = nil }
        }
        if hasStoredStories {
            return { model.techRange = .all }
        }
        return { model.refresh(userInitiated: true) }
    }
}
