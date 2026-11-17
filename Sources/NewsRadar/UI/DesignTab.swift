import SwiftUI

/// One reading surface built on the design catalogue: either Web & SEO or
/// Design & Creative AI.
///
/// Both tabs are the same view over a different surface, so they cannot drift
/// apart in behaviour — only in which sources and sections they show. The
/// filters are local to the tab on purpose: the toolbar's category filter speaks
/// the news taxonomy (Language Models, Hardware, …), and a font release has no
/// meaningful place in it. The toolbar's search still applies to both.
struct DesignTab: View {
    var surface: DesignSurface

    @Environment(AppModel.self) private var model

    @State private var showSources = false
    // The tab's filters live on the model: the toolbar's Filter button and this
    // header must edit one state, or the panel would show something other than
    // what the list is doing.
    private var category: DesignCategory? { model.designSection }
    private var sourceID: String? { model.designSource }
    private var range: DateRange { model.designRange }

    /// Everything the tab's window and the toolbar's shared controls select.
    ///
    /// Built by the model so the filter panel and this list cannot disagree
    /// about what the window contains.
    private var windowItems: [RadarItem] {
        model.designWindowItems(surface)
    }

    /// The window narrowed to the publisher chosen in this tab's own panel.
    private var sourceItems: [RadarItem] {
        guard let sourceID,
              let entry = DesignCatalogue.source(sourceID) else { return windowItems }
        let id = DesignCatalogue.sourceID(of: entry)
        return windowItems.filter { $0.source == id }
    }

    /// Everything this tab's filters select, before the list cap.
    private var allItems: [RadarItem] {
        guard let category else { return sourceItems }
        return sourceItems.filter { item in
            DesignCatalogue.entry(for: item.source)?.category == category
        }
    }

    /// What is drawn: the same list, capped. The cap is applied after the tab's
    /// own filters, so a narrow publisher can never be hidden by the cap itself.
    private var items: [RadarItem] {
        model.listLimit > 0 ? Array(allItems.prefix(model.listLimit)) : allItems
    }

    /// The list is already narrowed to this tab's two filters.
    private var filtered: [RadarItem] { items }

    private var categories: [DesignCategory] {
        DesignCategory.allCases.filter { $0.surface == surface }
    }

    var body: some View {
        ItemList(items: filtered,
                 emptySymbol: surface.symbol,
                 emptyTitle: emptyTitle,
                 emptyMessage: emptyMessage,
                 emptyActionTitle: emptyAction,
                 emptyAction: emptyActionRun,
                 header: AnyView(header))
        // UI-testing hook: the source panel is inline, but a screenshot still
        // needs a way to open it without a synthesised click.
        .onAppear {
            if ProcessInfo.processInfo.environment["NEWSRADAR_DESIGN_SOURCES"] == "1" {
                showSources = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: surface.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(surface.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(TextFormat.number(sourceItems.count) + " stories")
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
                        Text(TextFormat.number(DesignCatalogue.sources(for: surface).count))
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
                .help("Every source in this tab, and the ones that serve no feed")
            }

            Text(surface.subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)

            if let sourceID, let s = DesignCatalogue.source(sourceID) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 10))
                    Text("Only \(s.title)")
                        .font(.system(size: 10.5))
                    Button {
                        model.designSource = nil
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
            ForEach([DateRange.twelveHours, .day, .week, .all]) { r in
                Button {
                    model.designRange = r
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
                chip(title: "All", symbol: "square.grid.3x3", count: sourceItems.count,
                     selected: category == nil) { model.designSection = nil }
                ForEach(categories) { cat in
                    chip(title: cat.shortTitle, symbol: cat.symbol,
                         count: counts[cat] ?? 0, selected: category == cat) {
                        model.designSection = (category == cat) ? nil : cat
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
    private var counts: [DesignCategory: Int] {
        var out: [DesignCategory: Int] = [:]
        for item in sourceItems {
            guard let id = designID(for: item),
                  let src = DesignCatalogue.source(id) else { continue }
            out[src.category, default: 0] += 1
        }
        return out
    }

    /// The catalogue entry id for an item's source.
    private func designID(for item: RadarItem) -> String? {
        DesignCatalogue.entry(for: item.source)?.id
    }

    // MARK: - Source panel
    //
    // Inline rather than a popover. A popover anchored inside this scrolling
    // header is dismissed before its first layout and never appears at all —
    // which is exactly what it did when this was a popover.

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sources").font(.system(size: 11.5, weight: .semibold))
                Text(surface.title)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Text("\(DesignCatalogue.sources(for: surface).count) feeds")
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                ForEach(DesignCatalogue.grouped(surface), id: \.category) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.category.title.uppercased())
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        ForEach(group.sources, id: \.id) { s in
                            Button {
                                model.designSource = (sourceID == s.id) ? nil : s.id
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: s.symbol)
                                        .font(.system(size: 10))
                                        .frame(width: 14)
                                        .foregroundStyle(Color(hex: s.accent))
                                    Text(s.title).font(.system(size: 11))
                                    Spacer(minLength: 4)
                                    Text(TextFormat.number(storedCount(s.id)))
                                        .font(.system(size: 9.5)).monospacedDigit()
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(s.home)
                        }
                    }
                }

                // A publisher the request named that serves nothing a reader can
                // consume. Saying so is more useful than silence.
                if !DesignCatalogue.unavailable.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NOT AVAILABLE")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        ForEach(DesignCatalogue.unavailable, id: \.title) { u in
                            HStack(spacing: 7) {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 10)).frame(width: 14)
                                Text(u.title).font(.system(size: 11))
                                Spacer(minLength: 4)
                                Text(u.reason)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
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

    private func storedCount(_ id: String) -> Int {
        model.availability(for: SourceID.design(id)).last?.count ?? 0
    }

    // MARK: - Empty state

    /// Whether the archive holds any story for this surface at all. An empty
    /// window over a full archive must not read as feeds that never answered.
    private var hasStoredStories: Bool {
        _ = model.revision
        return model.store.items.contains {
            DesignCatalogue.surface(of: $0.source) == surface
        }
    }

    private var emptyTitle: String {
        if category != nil { return "Nothing in this section" }
        if sourceID != nil { return "Nothing from this publisher" }
        return hasStoredStories ? "Nothing in this window" : "Nothing from these feeds yet"
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
        if let sourceID, let s = DesignCatalogue.source(sourceID) {
            return "\(s.title) has nothing in the \(range.shortTitle) window. "
                + "Widen the window, or pick another publisher."
        }
        if hasStoredStories {
            return "These feeds have stories outside the \(range.shortTitle) window. "
                + "Widen the window to see them."
        }
        return "These feeds update far less often than the AI publishers — a design "
            + "blog may post twice a month. Widen the window, or refresh."
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
            return { model.designSection = nil }
        }
        if sourceID != nil {
            return { model.designSource = nil }
        }
        if hasStoredStories {
            return { model.designRange = .all }
        }
        return { model.refresh(userInitiated: true) }
    }
}
