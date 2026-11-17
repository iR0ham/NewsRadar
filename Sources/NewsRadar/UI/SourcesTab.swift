import SwiftUI

/// Source status: the health of every configured source, in a compact table.
///
/// The list grew to eighty-odd publishers, and one card per publisher turned
/// the page into a wall that nobody could scan. It is now a table: one line per
/// source, grouped by where the source belongs, with the columns that answer
/// the only questions that matter — did it answer, how much did it give, when
/// was it last read, and how is it read. A source that failed is pulled to the
/// top and its reason is spelled out.
struct SourcesTab: View {
    @Environment(AppModel.self) private var model

    /// Show only the sources that need attention.
    @State private var onlyProblems = false
    /// The group being shown, or nil for all of them.
    @State private var group: SourceGroup?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !failedStatuses.isEmpty { failureBanner }
                groupPicker
                table
                ollamaCard
                cacheCard
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            SectionHeader(title: "Source status",
                          symbol: "antenna.radiowaves.left.and.right",
                          subtitle: subtitle)
            Spacer(minLength: 0)
            Toggle(isOn: $onlyProblems) {
                Text("Only problems").font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Show only the sources that could not be read")
            Button {
                model.showAddSource = true
            } label: {
                Label("Add source", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Add an RSS or Atom feed of your own")
        }
    }

    private var subtitle: String {
        let failed = failedStatuses.count
        let total = model.sourceStatuses.count
        if failed == 0 { return "all \(total) sources answered" }
        return "\(total - failed) of \(total) sources answered · \(failed) "
            + (failed == 1 ? "needs attention" : "need attention")
    }

    // MARK: - Groups

    /// The groups a source can belong to.
    ///
    /// The grouping follows where the source is read, not the order the
    /// publishers happen to be listed in, so the table reads the way the app
    /// is organised: news, then the two catalogue tabs, then code.
    enum SourceGroup: String, CaseIterable, Identifiable {
        case news
        case tech
        case web
        case design
        case code
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .news: return "AI News"
            case .tech: return "Tech News"
            case .web: return "Web & SEO"
            case .design: return "Design & Creative AI"
            case .code: return "GitHub & Code"
            case .custom: return "Added by you"
            }
        }

        var symbol: String {
            switch self {
            case .news: return "newspaper"
            case .tech: return "cpu"
            case .web: return "globe"
            case .design: return "paintpalette.fill"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .custom: return "plus.circle"
            }
        }

        func contains(_ source: SourceID) -> Bool {
            if source.isCustom { return self == .custom }
            if source.kind == .github { return self == .code }
            // A Tech News publisher is listed under its own tab. A publisher
            // read in two scopes of the same publication — MIT Technology
            // Review's AI feed and its general feed — appears in both, because
            // both are being read and both have a health of their own.
            if source.isTech { return self == .tech }
            switch DesignCatalogue.surface(of: source) {
            case .some(.web): return self == .web
            case .some(.design): return self == .design
            case .none: return self == .news
            }
        }
    }

    private var groups: [SourceGroup] {
        SourceGroup.allCases.filter { g in
            model.sourceStatuses.contains { g.contains($0.source) }
        }
    }

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All", symbol: "square.grid.3x3",
                     count: shownStatuses.count, selected: group == nil) { group = nil }
                ForEach(groups) { g in
                    chip(title: g.title, symbol: g.symbol,
                         count: statuses(in: g).count, selected: group == g) {
                        group = (group == g) ? nil : g
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
        .help("\(title) — \(count) sources")
    }

    // MARK: - The table

    private var table: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(shownGroups, id: \.self) { g in
                groupSection(g)
            }
        }
    }

    /// The groups that are shown, after the "only problems" switch and the
    /// group picker have had their say.
    private var shownGroups: [SourceGroup] {
        var out: [SourceGroup] = []
        for g in groups {
            let list = statuses(in: g)
            if onlyProblems && list.allSatisfy({ $0.ok }) { continue }
            out.append(g)
        }
        return out
    }

    @ViewBuilder
    private func groupSection(_ g: SourceGroup) -> some View {
        let list = statuses(in: g)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: g.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(g.title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(TextFormat.number(list.count))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, status in
                        sourceRow(status)
                        if index < list.count - 1 {
                            Divider().opacity(0.5).padding(.leading, 12)
                        }
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 0.7)
                }
            }
        }
    }

    /// One source, one line.
    @ViewBuilder
    private func sourceRow(_ status: SourceStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                StatusDot(ok: status.ok, fromCache: status.fromCache)
                Image(systemName: status.source.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: status.source.accentHex))
                    .frame(width: 13)
                Text(status.source.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(status.source.host)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                countCell("In feed", status.itemCount)
                countCell("Stored", storedCount(for: status.source))
                HStack(spacing: 4) {
                    Text(status.lastSuccess.map { TextFormat.relative($0) } ?? "—")
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(minWidth: 46, alignment: .trailing)
                    Text("Last read")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(accessLabel(for: status.source))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 92, alignment: .trailing)
                    .lineLimit(1)
            }
            if !status.message.isEmpty {
                Text(status.message)
                    .font(.system(size: 10))
                    .foregroundStyle(status.ok ? Theme.textTertiary : Color(hex: "#B3323F"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { selected = (selected == status.source) ? nil : status.source }

        // The actions of the opened row, in place, so no second window is
        // needed to look at one source.
        if selected == status.source {
            HStack(spacing: 8) {
                Button {
                    model.openURL(status.source.homeURL)
                } label: { Label("Source page", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.bordered).controlSize(.small)

                Button {
                    model.filters.sources = [status.source]
                    // A publisher that posts twice a day has nothing in a
                    // twelve-hour window; opening its page there made a working
                    // source look empty. Widen to the narrowest window that
                    // actually holds something from it.
                    model.filters.range = model.narrowestPopulatedRange(
                        for: status.source, fallback: model.filters.range)
                    model.persistFilters()
                    model.section = .all
                } label: { Label("This source only", systemImage: "line.3.horizontal.decrease.circle") }
                    .buttonStyle(.bordered).controlSize(.small)

                if let custom = model.customSources.first(where: { $0.sourceID == status.source }) {
                    Button(role: .destructive) {
                        model.removeCustomSource(custom)
                    } label: { Label("Remove", systemImage: "trash") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Remove this source and its stored stories")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
        }
    }

    /// The source whose row was opened.
    @State private var selected: SourceID?

    private func countCell(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(TextFormat.number(value))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// How the source is read, in three words.
    private func accessLabel(for source: SourceID) -> String {
        if let entry = DesignCatalogue.entry(for: source) {
            if entry.usesSitemap { return "Sitemap" }
            if entry.usesListing { return "Listing page" }
            return "Feed"
        }
        switch source.spec.access {
        case .rss: return "Feed"
        case .githubPage: return "Page"
        case .api: return "API"
        case .sitemap: return "Sitemap"
        case .communityAPI: return "API"
        }
    }

    // MARK: - Failure banner

    /// One-line summary of what failed and why, above the table.
    private var failureBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#A8792F"))
                Text("\(failedStatuses.count) source"
                     + (failedStatuses.count == 1 ? "" : "s") + " could not be read")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            ForEach(failedStatuses) { s in
                Text("· \(s.source.title) — \(s.message.isEmpty ? "no reason reported" : s.message)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: "#A8792F").opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(hex: "#A8792F").opacity(0.28), lineWidth: 0.7)
        }
    }

    // MARK: - Status lists

    private var failedStatuses: [SourceStatus] {
        model.sourceStatuses.filter { !$0.ok }
    }

    private var shownStatuses: [SourceStatus] {
        model.sourceStatuses
    }

    private func statuses(in g: SourceGroup) -> [SourceStatus] {
        model.sourceStatuses
            .filter { g.contains($0.source) }
            .sorted { a, b in
                if a.ok != b.ok { return !a.ok }
                return a.source.title < b.source.title
            }
    }

    // MARK: - Local cards

    private var ollamaCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "Local summarisation (optional)", symbol: "cpu")
            HStack(spacing: 8) {
                StatusDot(ok: model.ollamaReachable)
                Text(model.ollamaReachable
                     ? "Ollama server reachable — \(TextFormat.number(model.ollamaModels.count)) models"
                     : "Ollama server unreachable — summaries use the built-in offline digest")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                if !model.ollamaReachable {
                    Button("Check again") { model.checkOllama() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if !model.ollamaModels.isEmpty {
                Text("Installed models: " + model.ollamaModels.prefix(6).joined(separator: ", "))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
            Text("To enable: run Ollama and pull a model, for example `ollama pull qwen2.5:7b`. Then switch local summarisation on in Settings.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "Local cache", symbol: "internaldrive")
            HStack(spacing: 16) {
                labeled("App data", ByteCountFormatter.string(fromByteCount: model.store.sizeOnDisk, countStyle: .file))
                labeled("Images", ByteCountFormatter.string(fromByteCount: ImageLoader.shared.diskUsage, countStyle: .file))
                labeled("Data path", model.store.directory.path)
            }
            Text(model.store.directory.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    /// How many stories from this source survive in the local archive.
    private func storedCount(for source: SourceID) -> Int {
        model.availability(for: source).last?.count ?? 0
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        }
    }
}
