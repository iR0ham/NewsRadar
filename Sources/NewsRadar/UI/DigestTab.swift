import SwiftUI

/// Daily briefing tab: the written digest, the day's highlights and the
/// repository picks, each of which can be opened in place.
struct DigestTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ItemList(items: [],
                 emptySymbol: "sun.max",
                 emptyTitle: "",
                 emptyMessage: "",
                 header: AnyView(header))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            briefingCard
            // One block per reading surface. The briefing is the app's home
            // page, so it has to speak about everything the app collects: a
            // reader who follows the web and SEO side should not have to scroll
            // past forty AI headlines to reach it.
            ForEach(model.briefingSections) { section in
                sectionBlock(section)
            }
            allCategories
        }
    }

    /// One surface's picks, with its own heading and its own count.
    @ViewBuilder
    private func sectionBlock(_ section: BriefingSection) -> some View {
        let picks = model.briefingPicks(for: section)
        if !picks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SectionHeader(title: section.title, symbol: section.symbol,
                                  subtitle: model.briefingIsFiltered
                                      ? "filtered by the toolbar" : "ranked by \(model.rank.title.lowercased())",
                                  count: picks.count)
                    Spacer(minLength: 0)
                    // The count the surface contributed in the window, so an
                    // empty block is a measurement, not a mystery.
                    Text("\(TextFormat.number(model.briefingCount(for: section))) in the window")
                        .font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
                    Button("Open \(section.title)") { model.go(to: section.navSection) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
                switch model.layout {
                case .compact:
                    VStack(spacing: 6) {
                        ForEach(picks) { item in
                            CompactRow(item: item,
                                       isBookmarked: model.store.isBookmarked(item.id),
                                       isRead: model.store.isRead(item.id),
                                       onBookmark: { model.toggleBookmark(item) },
                                       onOpen: { model.open(item) },
                                       onDetail: { model.detailItem = item })
                        }
                    }
                case .comfortable:
                    VStack(spacing: 10) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { idx, item in
                            BriefingPick(item: item, rank: idx + 1,
                                         onDetail: { model.detailItem = item },
                                         onOpen: { model.open(item) })
                        }
                    }
                case .grid:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMin), spacing: 12)],
                              spacing: 12) {
                        ForEach(picks) { item in
                            GridTile(item: item,
                                     isBookmarked: model.store.isBookmarked(item.id),
                                     isRead: model.store.isRead(item.id),
                                     onBookmark: { model.toggleBookmark(item) },
                                     onOpen: { model.open(item) },
                                     onDetail: { model.detailItem = item })
                        }
                    }
                }
            }
        }
    }

    // MARK: - Briefing card

    /// The briefing, in three bands: what happened (figures), what matters
    /// (prose), and how it splits (one bar).
    ///
    /// It used to be one undifferentiated stack — a title, a settings strip, eight
    /// paragraphs and twelve labelled bar-chart rows — with the same three story
    /// titles repeated in three consecutive sentences. Everything in it carried the
    /// same weight, so nothing led. The figures come first because they are the
    /// claim; the prose supports them; the chart is reference, not headline.
    @ViewBuilder
    private var briefingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            briefingHeader
            if let b = model.briefing {
                if let news = b.newsCount, let sources = b.sourceCount {
                    figures(news: news, sources: sources, categories: b.categoryCounts)
                }
                prose(b.paragraphs)
                if !b.categoryCounts.isEmpty { distribution(b.categoryCounts) }
            } else {
                emptyBriefing
            }
            Theme.separatorSoft.frame(height: 0.5).padding(.top, 12)
            autoCheckBar.padding(.top, 9)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var briefingHeader: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(Theme.accentGradient).frame(width: 28, height: 28)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Daily Briefing")
                    .font(.system(size: 14, weight: .bold))
                Text(model.briefing?.headline ?? TextFormat.longDate(Date()))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if let b = model.briefing {
                let info = EngineLabel.describe(b.engine)
                TagPill(text: info.title, symbol: info.symbol, tint: Theme.accent)
                Text(TextFormat.relative(b.generatedAt))
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            Button {
                copyToPasteboard(model.briefingText())
                model.toast = "Briefing text copied"
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            .help("Copy the briefing text")
            .disabled(model.briefing == nil)

            Button {
                model.refresh(userInitiated: true, kind: .check)
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            .help("Check for new stories and rebuild the briefing")
        }
    }

    /// Two figures and the window they cover. Big enough to be the first thing
    /// read, which is what a briefing's opening sentence was trying to do in prose.
    private func figures(news: Int, sources: Int, categories: [String: Int]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            figure(TextFormat.number(news), "stories",
                   detail: "in \(Int(Summarizer.hourWindow)) hours")
            rule
            figure(TextFormat.number(sources), sources == 1 ? "source" : "sources",
                   detail: "reporting")
            rule
            figure(TextFormat.number(categories.count), categories.count == 1 ? "topic" : "topics",
                   detail: topTopic(categories) ?? "no topic")
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private var rule: some View {
        Theme.separator.frame(width: 0.5, height: 30).padding(.horizontal, 18)
    }

    private func figure(_ value: String, _ label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }

    /// The biggest topic that is actually a topic. "Other" is the classifier's
    /// remainder, so naming it as the day's leading subject said nothing.
    private func topTopic(_ counts: [String: Int]) -> String? {
        Category.allCases
            .compactMap { c -> (String, Int)? in
                guard c != .other, let n = counts[c.rawValue], n > 0 else { return nil }
                return (c.title, n)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// The prose. The first paragraph is the lead and is set larger; the rest are
    /// quieter, and their leading label ("Top story:", "Trending on GitHub:") is
    /// made a label rather than left buried in a run-on sentence.
    private func prose(_ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { idx, p in
                let parts = Self.splitLabel(p)
                Group {
                    if idx == 0 {
                        Text(p)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineSpacing(4)
                    } else if let label = parts.label {
                        // On its own line: prefixed inline, "Top story" ran
                        // straight into the headline and read as one sentence.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(Theme.textTertiary)
                            Text(parts.body).font(.system(size: 12))
                                .lineSpacing(3.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(p).font(.system(size: 12)).lineSpacing(3.5)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
        }
        .padding(.top, 12)
    }

    /// "Top story: X — TechCrunch." → ("Top story", "X — TechCrunch.")
    ///
    /// Only a short opening clause counts as a label: a paragraph is not split at
    /// just any colon, or a sentence with a colon in the middle would lose its
    /// first half to a bold heading.
    static func splitLabel(_ s: String) -> (label: String?, body: String) {
        guard let range = s.range(of: ": "), s.distance(from: s.startIndex, to: range.lowerBound) <= 24
        else { return (nil, s) }
        let label = String(s[..<range.lowerBound])
        let body = String(s[range.upperBound...])
        guard body.count > 12 else { return (nil, s) }
        return (label, body)
    }

    /// One stacked bar instead of a twelve-row chart.
    ///
    /// The rows were readable one at a time and useless together: twelve labels,
    /// twelve numbers, and no sense of proportion at a glance, which is the only
    /// thing a category chart is for. A single bar shows the split; the four
    /// largest keep their names.
    private func distribution(_ counts: [String: Int]) -> some View {
        let ordered = Category.allCases
            .compactMap { c -> (Category, Int)? in
                guard let n = counts[c.rawValue], n > 0 else { return nil }
                return (c, n)
            }
            .sorted { $0.1 > $1.1 }
        let total = max(1, ordered.reduce(0) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("By topic").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Text("\(ordered.count) topics").font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(Array(ordered.enumerated()), id: \.offset) { _, entry in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color(hex: entry.0.accentHex))
                            .frame(width: max(2, (geo.size.width - CGFloat(ordered.count) * 1.5)
                                              * CGFloat(entry.1) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 7)
            // The four that matter, with their counts, as a legend.
            HStack(spacing: 12) {
                ForEach(Array(ordered.prefix(4).enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: entry.0.accentHex)).frame(width: 5, height: 5)
                        Text(entry.0.title).font(.system(size: 9.5))
                            .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Text(TextFormat.number(entry.1)).font(.system(size: 9.5, weight: .medium))
                            .monospacedDigit()
                    }
                }
                if ordered.count > 4 {
                    Text("+\(ordered.count - 4) more")
                        .font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 12)
    }

    private var emptyBriefing: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 16)).foregroundStyle(Theme.accentGradient)
            Text("Refresh once to build today's briefing.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 14)
    }

    // MARK: - Auto-check bar

    @ViewBuilder
    private var autoCheckBar: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Image(systemName: model.autoCheckMinutes > 0 ? "bolt.horizontal.fill" : "bolt.slash")
                .font(.system(size: 10))
                .foregroundStyle(model.autoCheckMinutes > 0 ? Theme.accent : .secondary)

            Text("Auto-check").font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(model.autoCheckMinutes > 0 ? .primary : .secondary)

            PillSwitch(
                isOn: model.autoCheckMinutes > 0,
                onToggle: {
                    model.autoCheckMinutes = model.autoCheckMinutes > 0
                        ? 0 : max(5, model.lastAutoCheckMinutes)
                    model.persistRefreshSettings()
                },
                help: model.autoCheckMinutes > 0
                    ? "Auto-check is on. Click to stop checking."
                    : "Auto-check is off. Click to check for new stories automatically.")

            if model.autoCheckMinutes > 0 {
                Picker("", selection: Binding(
                    get: { model.autoCheckMinutes },
                    set: { model.autoCheckMinutes = $0; model.persistRefreshSettings() })) {
                    ForEach(model.autoCheckOptions.filter { $0 > 0 }, id: \.self) { m in
                        Text(AppModel.autoCheckLabel(m)).tag(m)
                    }
                }
                .labelsHidden().fixedSize()
            } else {
                Text("off").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }

            if let last = model.store.state.lastRefresh {
                Text("Last check: " + TextFormat.relative(last))
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            if model.isRefreshing {
                Text(model.statusMessage ?? "").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
            // "No new stories" is already stated in the toolbar; repeating it here
            // put the same sentence twice on one screen.
        }
    }

    // MARK: - Highlights

    /// News highlights, in the layout the toolbar is set to.
    ///
    /// The compact / comfortable / grid picker applies here too: the briefing used
    /// to ignore it and always drew the same rows, so choosing a layout on this
    /// tab appeared to do nothing.
    @ViewBuilder
    private var highlights: some View {
        // Highlights are stories. Repositories have their own section below, so a
        // trending repo cannot crowd the news out of the briefing.
        let highlights = model.briefingNews
        if !highlights.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Today's highlights", symbol: "sparkles",
                              subtitle: model.briefingIsFiltered
                                  ? "filtered by the toolbar" : "ranked by relevance",
                              count: highlights.count)
                switch model.layout {
                case .compact:
                    VStack(spacing: 6) {
                        ForEach(highlights) { item in
                            CompactRow(item: item,
                                       isBookmarked: model.store.isBookmarked(item.id),
                                       isRead: model.store.isRead(item.id),
                                       onBookmark: { model.toggleBookmark(item) },
                                       onOpen: { model.open(item) },
                                       onDetail: { model.detailItem = item })
                        }
                    }
                case .comfortable:
                    VStack(spacing: 10) {
                        ForEach(Array(highlights.enumerated()), id: \.element.id) { idx, item in
                            BriefingPick(item: item, rank: idx + 1,
                                         onDetail: { model.detailItem = item },
                                         onOpen: { model.open(item) })
                        }
                    }
                case .grid:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMin), spacing: 12)],
                              spacing: 12) {
                        ForEach(highlights) { item in
                            GridTile(item: item,
                                     isBookmarked: model.store.isBookmarked(item.id),
                                     isRead: model.store.isRead(item.id),
                                     onBookmark: { model.toggleBookmark(item) },
                                     onOpen: { model.open(item) },
                                     onDetail: { model.detailItem = item })
                        }
                    }
                }
            }
        }
    }

    /// Repository picks get a divider and their own tinted block, so on a page of
    /// news cards they read as a separate section rather than a continuation of
    /// the highlights.
    @ViewBuilder
    private var repoPicks: some View {
        let picks = model.briefingRepos
        if !picks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider().padding(.vertical, 2)
                SectionHeader(title: "Trending on GitHub",
                              symbol: "chevron.left.forwardslash.chevron.right",
                              subtitle: "by stars today", count: picks.count)
                switch model.layout {
                case .compact:
                    VStack(spacing: 6) {
                        ForEach(picks) { item in
                            CompactRow(item: item,
                                       isBookmarked: model.store.isBookmarked(item.id),
                                       isRead: model.store.isRead(item.id),
                                       onBookmark: { model.toggleBookmark(item) },
                                       onOpen: { model.open(item) },
                                       onDetail: { model.detailItem = item })
                        }
                    }
                case .comfortable:
                    VStack(spacing: 10) {
                        ForEach(picks) { item in
                            BriefingPick(item: item, rank: nil,
                                         onDetail: { model.detailItem = item },
                                         onOpen: { model.open(item) })
                        }
                    }
                case .grid:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridMin), spacing: 12)],
                              spacing: 12) {
                        ForEach(picks) { item in
                            GridTile(item: item,
                                     isBookmarked: model.store.isBookmarked(item.id),
                                     isRead: model.store.isRead(item.id),
                                     onBookmark: { model.toggleBookmark(item) },
                                     onOpen: { model.open(item) },
                                     onDetail: { model.detailItem = item })
                        }
                    }
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.20), lineWidth: 0.7)
            }
        }
    }

    @ViewBuilder
    private var allCategories: some View {
        if model.briefing == nil && model.store.items.isEmpty {
            EmptyState(symbol: "dot.radiowaves.up.forward",
                       title: "The radar is empty",
                       message: "Press Refresh to pull AI news from every configured source. If a source is unreachable the app shows the rest and reports its status under Source Status.",
                       actionTitle: "Refresh sources",
                       action: { model.refresh(userInitiated: true) })
        }
    }
}
