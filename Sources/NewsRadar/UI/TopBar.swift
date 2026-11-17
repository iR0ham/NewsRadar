import SwiftUI

/// Custom frosted toolbar: search, filters, sort, layout and refresh.
struct TopBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @State private var showFilters = false
    /// Measured toolbar width; drives the compact layout.
    @State private var availableWidth: CGFloat = 1280

    var body: some View {
        @Bindable var model = model
        // The row used to be chosen with ViewThatFits, which worked for width but
        // swapped the whole subtree whenever the status text changed length. That
        // replaced the view the filter popover was anchored to, so the panel closed
        // itself mid-use while a fetch was running. Measuring the width and keeping
        // one row instance fixes both the overflow and the dismissal.
        toolbarRow(model: model, compact: availableWidth < 1080)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { availableWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in availableWidth = w }
                }
            }
            .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                WindowDragArea().frame(height: 52)
            }
        }
        // The bar has no bottom rule: the page itself fades out under it
        // (`RootView`), which is the only approach that reads on a dark window.
        .onChange(of: model.focusSearchTick) { _, _ in searchFocused = true }
    }

    /// Tabs that carry their own filter set, so the toolbar shows no window
    /// chips: the tab header owns them, and two rival controls would edit
    /// different state.
    private func isCatalogueTab(model: AppModel) -> Bool {
        model.section == .web || model.section == .design || model.section == .tech
    }

    /// One toolbar row. `compact` drops the button labels and the sort title, which
    /// buys roughly 120pt and is what a narrow window gets.
    private func toolbarRow(model: AppModel, compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 9) {
            searchField(model: model, compact: compact)

            FilterButton(isOpen: $showFilters, activeCount: model.activeFilterCount,
                         compact: compact)
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    FilterPanel()
                        .environment(model)
                }

            // In a catalogue tab the window chips live in that tab's header, next
            // to the section chips they belong with; two rival window controls
            // would edit different state.
            if !isCatalogueTab(model: model) { rangePicker(model: model) }

            if !compact { sortMenu(model: model) }

            layoutPicker

            checkButton(compact: compact)

            refreshButton(compact: compact)

            Spacer(minLength: 4)

            statusLabel
        }
        .onAppear {
            guard model.openFiltersOnLaunch else { return }
            model.openFiltersOnLaunch = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showFilters = true }
        }
    }

    // MARK: - Pieces

    private func searchField(model: AppModel, compact: Bool = false) -> some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search stories, projects and summaries…", text: $model.filters.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { model.persistFilters() }
            if !model.filters.query.isEmpty {
                Button {
                    model.filters.query = ""
                    model.persistFilters()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minWidth: compact ? 96 : 130,
               idealWidth: compact ? 130 : 200,
               maxWidth: compact ? 200 : 260)
        .background {
            RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accent.opacity(0.55) : Color.primary.opacity(0.08),
                              lineWidth: searchFocused ? 1.2 : 0.7)
        }
        .animation(.smooth(duration: 0.18), value: searchFocused)
        .onChange(of: model.filters.query) { _, _ in
            model.scheduleFilterPersist()
        }
    }

    /// One-click time window: 12h, 24h, 72h, one week. The count under each label
    /// is how many items in the current section fall inside that window, so an
    /// empty window is obvious before it is selected.
    private func rangePicker(model: AppModel) -> some View {
        // Four windows, one pass over the current section.
        let counts = model.counts(in: DateRange.quick)
        return HStack(spacing: 1) {
            ForEach(DateRange.quick) { range in
                let active = model.filters.range == range
                let count = counts[range] ?? 0
                Button {
                    model.filters.range = range
                    model.persistFilters()
                } label: {
                    Text(range.shortTitle)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        // An empty window is still visible from the menu tooltip, but
                        // the label no longer carries a second number on every button.
                        .opacity(count == 0 ? 0.72 : 1)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? AnyShapeStyle(Theme.accentGradient)
                                         : AnyShapeStyle(Color.clear))
                    }
                }
                .buttonStyle(.plain)
                .help("\(range.title) — \(TextFormat.number(count)) items")
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .fixedSize()
    }

    private func sortMenu(model: AppModel) -> some View {
        Menu {
            ForEach(SortMode.allCases) { mode in
                Button {
                    model.sort = mode
                    model.persistSort()
                } label: {
                    if model.sort == mode { Label(mode.title, systemImage: "checkmark") }
                    else { Text(mode.title) }
                }
            }
            Divider()
            Toggle("Prioritise local Mac tools", isOn: Binding(
                get: { model.filters.appleSiliconFirst },
                set: { model.filters.appleSiliconFirst = $0; model.persistFilters() }))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold))
                Text(model.sort.title).font(.system(size: 11, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .help("Sort order")
    }

    private var layoutPicker: some View {
        @Bindable var model = model
        return Picker("", selection: Binding(
            get: { model.layout },
            set: { model.layout = $0; model.persistLayout() })) {
            ForEach(LayoutMode.allCases) { mode in
                Image(systemName: mode.symbol).help(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 104)
        .help("Layout: compact list, comfortable list, visual grid")
    }

    /// The cheap path, and the one the user reaches for: ask each source whether
    /// anything was published, add only what is new, and summarise only that.
    private func checkButton(compact: Bool = false) -> some View {
        Button {
            model.refresh(userInitiated: true, kind: .check)
        } label: {
            HStack(spacing: 5) {
                if model.isRefreshing && model.isChecking {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "bolt.horizontal").font(.system(size: 11, weight: .semibold))
                }
                if !compact { Text("Check").font(.system(size: 11, weight: .medium)).lineLimit(1) }
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
            }
            .frame(minWidth: compact ? 30 : 68)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(model.isRefreshing)
        .help("Check for new stories only (⌘⇧R). Anything already stored is left alone.")
    }

    private func refreshButton(compact: Bool = false) -> some View {
        Button {
            model.refresh(userInitiated: true)
        } label: {
            HStack(spacing: 5) {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                if !compact {
                    Text(model.isRefreshing ? "Refreshing…" : "Refresh")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                    .fill(Theme.accentGradient)
            }
            .opacity(model.isRefreshing ? 0.72 : 1)
            .frame(minWidth: compact ? 32 : 84)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(model.isRefreshing)
        .help("Fetch every source again and re-render everything (⌘R)")
    }

    private var statusLabel: some View {
        HStack(spacing: 7) {
            // Compact, honest summary: how many sources answered, and how many did
            // not. The detail lives in Source Status, not in a clipped toolbar line.
            if let outcome = model.lastOutcome {
                let answered = outcome.okSources
                let total = outcome.statuses.count
                let failed = outcome.sourceFailures.count
                if failed > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(hex: "#A8792F"))
                        Text("\(answered)/\(total)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(hex: "#A8792F"))
                    }
                    .help(outcome.sourceFailures.joined(separator: "\n"))
                }
                // Show what is stored, not what one check happened to parse: after
                // a check that found nothing, "2,018 items" read as if the archive
                // had grown, when nothing had changed.
                Text("\(TextFormat.number(model.store.items.count)) stored")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if outcome.newItems > 0 {
                    Text("+\(TextFormat.number(outcome.newItems)) new")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                // A check that changed nothing says so, rather than printing a
                // number that invites the user to work out what it meant.
                if outcome.newItems == 0 && outcome.unchangedSources > 0 {
                    Text("no new stories")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            } else {
                Text(model.statusMessage ?? "Ready")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: 212, alignment: .trailing)
        .layoutPriority(-1)
    }
}

// MARK: - Filter button + panel

struct FilterButton: View {
    @Binding var isOpen: Bool
    var activeCount: Int
    var compact = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11, weight: .semibold))
                if !compact { Text("Filter").font(.system(size: 11, weight: .medium)) }
                if activeCount > 0 {
                    Text(TextFormat.number(activeCount))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background { Capsule().fill(Theme.accent) }
                }
            }
            .foregroundStyle(activeCount > 0 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .buttonStyle(.plain)
        .help("Filter by category, date, source, open source, free and local execution")
    }
}

/// The whole filter set in one popover.
struct FilterPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            // Header stays put; only the filter body scrolls, so the panel never
            // grows taller than the window and spills over the toolbar.
            HStack {
                Text("Filters").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(TextFormat.number(model.currentSectionCount)) items")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                Button("Clear") {
                    if model.section == .tech {
                        model.techSection = nil
                        model.techSource = nil
                        model.techRange = .day
                    } else if activeSurface != nil {
                        model.designSection = nil
                        model.designSource = nil
                        model.designRange = .all
                    } else {
                        model.filters = Filters()
                        model.persistFilters()
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Divider()

            ScrollView {
                filterBody(model: model)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .frame(maxHeight: 460)
            .scrollIndicators(.automatic)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "number").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                Text("\(TextFormat.number(model.currentSectionCount)) items in this view")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(width: 430)
    }

    private func filterBody(model: AppModel) -> some View {
        @Bindable var model = model
        // In the two catalogue tabs the panel edits that tab's own filters. The
        // news taxonomy has no meaning there — a font release is not a "Language
        // Model" — so showing it would offer controls that cannot do anything.
        if model.section == .tech {
            return AnyView(techBody(model: model))
        }
        if let surface = activeSurface {
            return AnyView(catalogueBody(model: model, surface: surface))
        }
        return AnyView(newsBody(model: model))
    }

    /// The filter set for the Tech News tab: its seven sections, its window,
    /// and its ten publishers.
    ///
    /// The news taxonomy is absent on purpose. A story about a graphics card is
    /// not a "Language Model", and offering a control that cannot match
    /// anything is worse than offering none.
    private func techBody(model: AppModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            group("Section") {
                VStack(alignment: .leading, spacing: 3) {
                    techSectionRow(nil, "All Tech", model: model)
                    ForEach(TechCategory.allCases) { cat in
                        techSectionRow(cat, cat.title, model: model)
                    }
                }
            }

            group("Date range") {
                Picker("", selection: Binding(
                    get: { model.techRange },
                    set: { model.techRange = $0 })) {
                    ForEach([DateRange.twelveHours, .day, .threeDays, .week, .month, .all]) { r in
                        Text(r.shortTitle).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            group("Sources") {
                VStack(alignment: .leading, spacing: 3) {
                    techSourceRow(nil, "All publishers", model: model, count: nil)
                    ForEach(TechCatalogue.sources, id: \.id) { s in
                        techSourceRow(s, s.title, model: model,
                                      count: model.availability(for: s.sourceID).last?.count ?? 0)
                    }
                }
            }
        }
    }

    private func techSectionRow(_ cat: TechCategory?, _ title: String,
                                model: AppModel) -> some View {
        let active = model.techSection == cat
        return Button {
            model.techSection = active ? nil : cat
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? AnyShapeStyle(.white.opacity(0.9))
                                 : AnyShapeStyle(cat.map { Color(hex: $0.accentHex) }
                                                 ?? Theme.accent))
                    .frame(width: 6, height: 6)
                Text(title).font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.textPrimary))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? AnyShapeStyle(Theme.accent)
                                 : AnyShapeStyle(Color.primary.opacity(0.11)))
            }
        }
        .buttonStyle(.plain)
    }

    private func techSourceRow(_ s: TechSource?, _ title: String,
                               model: AppModel, count: Int?) -> some View {
        let active = s == nil ? (model.techSource == nil) : (model.techSource == s!.id)
        return Button {
            model.techSource = s.map { $0.id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(active ? AnyShapeStyle(Theme.accent)
                                            : AnyShapeStyle(Theme.textTertiary))
                if let s {
                    Image(systemName: TechCatalogue.symbol(for: s))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(hex: TechCatalogue.accent(for: s)))
                }
                Text(title).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(TextFormat.number(count))
                        .font(.system(size: 9.5)).monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Which catalogue tab is on screen, if either.
    private var activeSurface: DesignSurface? {
        switch model.section {
        case .web: return .web
        case .design: return .design
        default: return nil
        }
    }

    /// The filter set for one catalogue tab: its sections and its publishers.
    private func catalogueBody(model: AppModel, surface: DesignSurface) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            group("Section") {
                VStack(alignment: .leading, spacing: 3) {
                    designSectionRow(nil, "All sections", model: model)
                    ForEach(DesignCategory.allCases.filter { $0.surface == surface }) { cat in
                        designSectionRow(cat, cat.title, model: model)
                    }
                }
            }

            group("Date range") {
                Picker("", selection: Binding(
                    get: { model.designRange },
                    set: { model.designRange = $0 })) {
                    ForEach([DateRange.twelveHours, .day, .week, .month, .all]) { r in
                        Text(r.shortTitle).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            group("Sources") {
                VStack(alignment: .leading, spacing: 3) {
                    designSourceRow(nil, "All sources", model: model,
                                    count: DesignCatalogue.sources(for: surface).count)
                    ForEach(DesignCatalogue.sources(for: surface), id: \.id) { s in
                        designSourceRow(s, s.title, model: model,
                                        count: model.availability(for: SourceID.design(s.id)).last?.count ?? 0)
                    }
                }
            }
        }
    }

    private func designSectionRow(_ cat: DesignCategory?, _ title: String,
                                  model: AppModel) -> some View {
        let active = model.designSection == cat
        return Button {
            model.designSection = active ? nil : cat
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? AnyShapeStyle(.white.opacity(0.9))
                                 : AnyShapeStyle(cat.map { Color(hex: $0.accentHex) }
                                                 ?? Theme.accent))
                    .frame(width: 6, height: 6)
                Text(title).font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.textPrimary))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? AnyShapeStyle(Theme.accent)
                                 : AnyShapeStyle(Color.primary.opacity(0.11)))
            }
        }
        .buttonStyle(.plain)
    }

    private func designSourceRow(_ s: DesignSource?, _ title: String,
                                 model: AppModel, count: Int) -> some View {
        let active = s == nil ? (model.designSource == nil) : (model.designSource == s!.id)
        return Button {
            model.designSource = s.map { $0.id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(active ? AnyShapeStyle(Theme.accent)
                                            : AnyShapeStyle(Theme.textTertiary))
                Text(title).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 4)
                Text(TextFormat.number(count))
                    .font(.system(size: 9.5)).monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func newsBody(model: AppModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            group("Category") {
                // 96pt clipped "Language M…" and "Tools & Plat…"; the longest name
                // is "Image, Video & Motion", which needs about 128pt at this size.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], spacing: 6) {
                    ForEach(Category.allCases) { cat in
                        categoryButton(cat)
                    }
                }
            }

            group("Date range") {
                Picker("", selection: Binding(
                    get: { model.filters.range },
                    set: { model.filters.range = $0; model.persistFilters() })) {
                    ForEach(DateRange.allCases) { r in
                        Text(r.shortTitle).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Twenty-five sources do not fit one flat list, so they are grouped
            // the way a reader thinks about them.
            group("Sources") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(sourceGroups.enumerated()), id: \.offset) { _, g in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(g.title.uppercased())
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                            ForEach(g.sources) { s in
                                sourceToggle(s)
                            }
                        }
                    }
                }
            }

            group("Features") {
                VStack(alignment: .leading, spacing: 4) {
                    checkbox("Open source only", isOn: Binding(
                        get: { model.filters.openSourceOnly },
                        set: { model.filters.openSourceOnly = $0; model.persistFilters() }))
                    checkbox("Free only", isOn: Binding(
                        get: { model.filters.freeOnly },
                        set: { model.filters.freeOnly = $0; model.persistFilters() }))
                    checkbox("Local execution only", isOn: Binding(
                        get: { model.filters.localOnly },
                        set: { model.filters.localOnly = $0; model.persistFilters() }))
                    checkbox("Prioritise Apple Silicon and local execution", isOn: Binding(
                        get: { model.filters.appleSiliconFirst },
                        set: { model.filters.appleSiliconFirst = $0; model.persistFilters() }))
                    checkbox("Unread only", isOn: Binding(
                        get: { model.filters.unreadOnly },
                        set: { model.filters.unreadOnly = $0; model.persistFilters() }))
                }
            }

        }
    }

    @ViewBuilder
    /// A category chip.
    ///
    /// The label was drawn in the category's own colour, which after the palette
    /// change meant a dark maroon label on a dark panel — legible in the design
    /// file, invisible on screen. Text is now always neutral; the category colour
    /// survives as a small dot, which carries the identity without carrying the
    /// contrast problem.
    private func categoryButton(_ cat: Category) -> some View {
        let active = model.filters.category == cat
        Button {
            model.filters.category = active ? nil : cat
            model.persistFilters()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? AnyShapeStyle(.white.opacity(0.9))
                                 : AnyShapeStyle(Color(hex: cat.accentHex)))
                    .frame(width: 6, height: 6)
                Text(cat.title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.textPrimary))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? AnyShapeStyle(Theme.accent)
                                 : AnyShapeStyle(Color.primary.opacity(0.11)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(active ? 0 : 0.18), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
    }

    private func checkbox(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
        }
        .toggleStyle(.checkbox)
    }

    /// Sources grouped for the filter panel, in reading order: mainstream
    /// publishers, then the labs, then practitioners and community, then design.
    private var sourceGroups: [(title: String, sources: [SourceID])] {
        [
            ("Publishers", SourceID.publishers),
            ("Labs & models", SourceID.labs),
            ("Community", SourceID.community),
            ("Design", SourceID.design),
            ("Code", SourceID.code)
        ].filter { !$0.1.isEmpty }
    }

    /// One source row. A blocked source stays listed but is dimmed and cannot be
    /// switched on, so the panel tells the truth instead of offering a source
    /// that can never return anything.
    private func sourceToggle(_ s: SourceID) -> some View {
        Toggle(isOn: Binding(
            get: { model.filters.sources.contains(s) },
            set: { on in
                if on { model.filters.sources.insert(s) }
                else { model.filters.sources.remove(s) }
                model.persistFilters()
            })) {
                HStack(spacing: 6) {
                    SourceLogo(source: s, size: 11)
                    Text(s.title).font(.system(size: 11.5))
                }
            }
            .toggleStyle(.checkbox)
            .help("\(s.host) — \(s.accessDescription)")
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
    }
}
