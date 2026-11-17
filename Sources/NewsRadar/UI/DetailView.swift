import SwiftUI

/// Detail sheet: full summary, key points, GitHub statistics and the original
/// link.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    var item: RadarItem
    var onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    // For a project the README *is* the content, so it comes before
                    // the generated summary rather than below the frame.
                    if item.isGitHub { readmeBlock }
                    summaryBlock
                    if let repo = item.repo { repoBlock(repo) }
                    sourceBlock
                    originalBlock
                }
                .padding(18)
            }
        }
        .frame(width: 620, height: 620)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            SourceBadge(source: item.source)
            CategoryChip(item: item)
            if !item.isGitHub {
                // Says plainly where the reading happens: an article can be read in
                // this window, a project opens on GitHub.
                Text("Read here")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                    .background {
                        Capsule().fill(Theme.accent.opacity(0.13))
                    }
                    .help("This article can be read inside the app")
            }
            Spacer(minLength: 0)
            Button {
                model.toggleBookmark(item)
            } label: {
                Image(systemName: model.store.isBookmarked(item.id) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.store.isBookmarked(item.id) ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help("Bookmark")

            Button {
                copyToPasteboard("\(item.displayTitle)\n\n\(item.summary)\n\n\(item.link.absoluteString)")
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? Color(hex: "#4E8A6B") : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy summary")

            Button {
                // The primary action is reading it here; the browser is the
                // fallback for pages with no text to extract.
                if item.isGitHub || ArticleReader.isAppPage(item.link) {
                    model.open(item)
                } else {
                    model.readHere(item)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: item.isGitHub || ArticleReader.isAppPage(item.link)
                          ? "arrow.up.right.square" : "book")
                        .font(.system(size: 11, weight: .semibold))
                    Text(item.isGitHub || ArticleReader.isAppPage(item.link)
                         ? "Open project" : "Read here")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentGradient)
                }
            }
            .buttonStyle(.plain)
            .help(item.isGitHub || ArticleReader.isAppPage(item.link)
                  ? "Open in the browser"
                  : "Read the article inside the app")

            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Blocks

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.imageURL != nil {
                Thumb(item: item, width: .infinity, height: 210)
            }
            Text(item.displayTitle)
                .font(.system(size: 20, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                DateLine(date: item.published)
                if let author = item.author {
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Text(author).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                let engine = EngineLabel.describe(item.summaryEngine)
                if engine.isModel {
                    TagPill(text: "Summary by " + engine.title, symbol: engine.symbol,
                            tint: Theme.accent)
                }
            }
            FlagPills(item: item)
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "Summary", symbol: "text.alignleft",
                          subtitle: engineLabel)
            Text(item.summary.isEmpty ? "No summary has been recorded for this item." : item.summary)
                .font(.system(size: 13))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !item.keyPoints.isEmpty {
                Divider().padding(.vertical, 3)
                Text("Key points").font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(item.keyPoints.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(Theme.accentGradient)
                                .padding(.top, 6)
                            Text(point).font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    /// Says which engine produced the text, so nothing overclaims.
    private var engineLabel: String {
        if item.summaryEngine.hasPrefix("ollama") {
            return "written by a local model"
        }
        if item.summaryEngine == "digest" {
            return "composed from measured data (no feed description)"
        }
        return item.isGitHub ? "from the repository description" : "from the source's own summary"
    }

    private func repoBlock(_ repo: RepoStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "GitHub statistics", symbol: "chart.bar.doc.horizontal")
            VStack(spacing: 6) {
                statRow("Repository", repo.fullName, mono: true)
                statRow("Stars", TextFormat.number(repo.stars))
                if let forks = repo.forks { statRow("Forks", TextFormat.number(forks)) }
                if let today = repo.starsToday { statRow("Stars in last 24h", TextFormat.number(today)) }
                if let growth = repo.starGrowth7d {
                    statRow("Growth since last snapshot", (growth >= 0 ? "+" : "−") + TextFormat.number(abs(growth)))
                } else if let note = repo.starGrowthNote {
                    statRow("Star growth", note)
                }
                if let lang = repo.language { statRow("Language", lang) }
                statRow("Licence", repo.license ?? "not reported")
                if let created = repo.created {
                    statRow("Created", "\(TextFormat.date(created)) (\(TextFormat.age(created)))")
                }
                if let pushed = repo.pushed { statRow("Last pushed", TextFormat.relative(pushed)) }
                statRow("Open source", item.openSource ? "yes" : "not reported")
                statRow("Local execution", item.localExecution ? "yes" : "not reported")
                statRow("Apple Silicon", item.appleSilicon ? "yes" : "not reported")
            }
            HStack(spacing: 8) {
                Button("Open repository") { model.openURL(repo.htmlURL) }
                    .buttonStyle(.bordered).controlSize(.small)
                if let home = repo.homepage {
                    Button("Project website") { model.openURL(home) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if !repo.topics.isEmpty {
                    Text(repo.topics.prefix(5).joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    private var sourceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Source and link", symbol: "link")
            statRow("Source", item.source.title)
            statRow("Host", item.source.host, mono: true)
            statRow("Published", "\(TextFormat.date(item.published)) — \(TextFormat.time(item.published))")
            VStack(alignment: .leading, spacing: 3) {
                Text("Original link").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text(item.link.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { model.open(item) }
            }
            if !item.sourceCategories.isEmpty {
                Text("Source tags: " + item.sourceCategories.joined(separator: ", "))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    /// A project's README, in full. GitHub has no reading mode, and the card only
    /// carries one description line, so without this the original text would only
    /// be reachable by opening a browser tab.
    private var fullName: String? { item.repo?.fullName }

    private var readmeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Original text",
                          symbol: "doc.plaintext",
                          subtitle: item.isGitHub
                            ? "The repository's README, in full — a project has no reading mode."
                            : nil)
            if let readme = fullName.flatMap({ model.readme(for: $0) }), !readme.isEmpty {
                Text("\(TextFormat.number(readme.split(whereSeparator: \.isWhitespace).count)) words · the whole file, unedited")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                ScrollView {
                    Text(readme)
                        .font(.system(size: 11.5))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                Text("Reading the README…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
        .task(id: item.id) { await loadReadme() }
    }

    private func loadReadme() async {
        guard item.isGitHub, let full = item.repo?.fullName,
              model.readme(for: full) == nil else { return }
        let text = await Task.detached(priority: .userInitiated) {
            GitHubSource.readme(full)
        }.value
        guard let text, !text.isEmpty else { return }
        model.attachReadme(text, for: full)
    }

    /// The feed's own wording, kept verbatim for reference and quoting.
    @ViewBuilder
    private var originalBlock: some View {
        if !item.rawSummary.isEmpty || item.title != item.displayTitle {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: item.isGitHub ? "From the feed" : "Original text",
                              symbol: "text.quote")
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.rawSummary.isEmpty {
                    Text(item.rawSummary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 14)
        }
    }

    private func statRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
