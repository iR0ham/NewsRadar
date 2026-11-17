import SwiftUI

/// The article, read inside the app.
///
/// The point is to follow a story without a browser tab: title, byline, the text
/// itself in a measure that is comfortable to read, and the original always one
/// click away. The provenance line matters — a reader should know whether it is
/// looking at the article or at the feed's summary.
struct ReaderView: View {
    let item: RadarItem
    let onClose: () -> Void

    @State private var state: LoadState = .loading
    @State private var copied = false
    @State private var fontSize: CGFloat = 14.5

    private enum LoadState {
        case loading
        case loaded(ArticleReader.Article)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 700)
        .background(.regularMaterial)
        .task(id: item.id) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Read here").font(.system(size: 13, weight: .semibold))
            // Says the thing the badge in the list promises: the text below is
            // the story itself, so there is no reason to open a browser tab.
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 8.5))
                Text("Full text inside the app").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background {
                Capsule().fill(Theme.accent.opacity(0.12))
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.5))
            }
            .help("No new page needed — the article text is here")
            if case .loaded(let article) = state {
                Text("· \(article.wordCount) words")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)

            Button {
                fontSize = max(12, fontSize - 1)
            } label: { Image(systemName: "textformat.size.smaller") }
                .buttonStyle(.plain)
                .help("Smaller text")

            Button {
                fontSize = min(21, fontSize + 1)
            } label: { Image(systemName: "textformat.size.larger") }
                .buttonStyle(.plain)
                .help("Larger text")

            Button {
                copy()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy the article text")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the page…").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                Text("This page could not be read here")
                    .font(.system(size: 13, weight: .semibold))
                Text(reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open the original page") { open(item.link) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let article):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(article.title)
                        .font(.system(size: fontSize + 7, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        SourceBadge(source: item.source)
                        if let byline = article.byline {
                            Text(byline).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                        // `Text(date, format:)` follows the system locale, which
                        // rendered the date in Persian script ("مهر 28") on this Mac.
                        // Every string in this app is English, so the date is too.
                        Text("\(TextFormat.shortDate(item.published)) · \(TextFormat.time(item.published))")
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }

                    if let imageURL = article.imageURL {
                        AsyncImage(url: imageURL) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else { Color.clear }
                        }
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    // The body in page order, so an inline diagram stays where the
                    // author put it and an inline link stays clickable instead of
                    // being flattened into unlinked text.
                    ForEach(Array(renderBlocks(article).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let text):
                            Text(text)
                                .font(.system(size: fontSize))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)

                        case .image(let url, let caption):
                            VStack(alignment: .leading, spacing: 5) {
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image {
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    } else if phase.error != nil {
                                        EmptyView()
                                    } else {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.primary.opacity(0.06))
                                            .overlay(ProgressView().controlSize(.small))
                                            .frame(height: 120)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                if let caption {
                                    Text(caption)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 2)

                        case .linked(let plain, let links, _):
                            linkedText(plain: plain, links: links)
                                .font(.system(size: fontSize))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider().padding(.vertical, 4)

                    HStack(spacing: 6) {
                        Image(systemName: article.possiblyTruncated
                              ? "exclamationmark.circle" : "checkmark.seal")
                            .font(.system(size: 10))
                            .foregroundStyle(article.possiblyTruncated
                                             ? Color(hex: "#A8792F") : Color(hex: "#4E8A6B"))
                        Text(article.source)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(22)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// The blocks to draw. Falls back to the plain paragraphs when the extractor
    /// found no richer structure (an older stored article, or a page with no <p>).
    private func renderBlocks(_ article: ArticleReader.Article) -> [ArticleReader.Block] {
        if !article.blocks.isEmpty {
            // The hero at the top of the sheet is usually the first image in the
            // body too; drawing it twice looks like a bug.
            guard let hero = article.imageURL?.absoluteString else { return article.blocks }
            return article.blocks.filter { block in
                if case .image(let url, _) = block { return url.absoluteString != hero }
                return true
            }
        }
        return article.paragraphs.map { .paragraph($0) }
    }

    /// A paragraph with its links live: the sentence reads as one run of text, and
    /// the words that were links in the original open that page.
    private func linkedText(plain: String, links: [ArticleReader.Block.LinkRun]) -> Text {
        var result = AttributedString()
        var rest = plain[plain.startIndex...]
        while !rest.isEmpty {
            // The next link that still appears in the remaining text.
            let next = links.compactMap { run -> (Range<String.Index>, ArticleReader.Block.LinkRun)? in
                guard let r = rest.range(of: run.text) else { return nil }
                return (r, run)
            }.min { $0.0.lowerBound < $1.0.lowerBound }

            guard let (range, run) = next else {
                result.append(AttributedString(String(rest)))
                break
            }
            if range.lowerBound > rest.startIndex {
                result.append(AttributedString(String(rest[rest.startIndex..<range.lowerBound])))
            }
            result.append(AttributedString(run.text).settingAttributes(
                AttributeContainer([.link: run.url, .underlineStyle: 1])
                    .merging(AttributeContainer([.foregroundColor: Theme.accent]))))
            rest = rest[range.upperBound...]
        }
        return Text(result)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(item.link.host ?? item.link.absoluteString)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Open original") { open(item.link) }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: - Actions

    private func load() async {
        state = .loading
        let url = item.link
        let title = item.displayTitle
        let summary = item.rawSummary
        let result = await Task.detached(priority: .userInitiated) {
            ArticleReader.read(url: url, fallbackTitle: title, feedSummary: summary)
        }.value
        switch result {
        case .success(let article): state = .loaded(article)
        case .failure(let error): state = .failed(error.localizedDescription)
        }
    }

    private func copy() {
        guard case .loaded(let article) = state else { return }
        let text = ([article.title, ""] + article.paragraphs + ["", item.link.absoluteString])
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
