import SwiftUI

/// The "add a source" sheet.
///
/// The paste-and-hope version of this dialog is what turns a news reader into a
/// list of dead rows, so nothing is added until the URL has been fetched, parsed
/// and counted. The verdict is shown in words, and a refusal says what to try
/// instead: a page that advertises its feed has that feed offered directly.
struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    var onClose: () -> Void

    @State private var urlText = ""
    @State private var titleText = ""
    @State private var checking = false
    @State private var result: Result?
    @FocusState private var urlFocused: Bool

    private enum Result {
        case added(title: String, note: String)
        case refused(String, suggestion: String?)
        case duplicate(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .onAppear { urlFocused = true }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a source").font(.system(size: 13, weight: .semibold))
                Text("Paste a feed or a blog address. Nothing is added until it has answered.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Feed or site address").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("https://example.com/feed.xml", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($urlFocused)
                    .onSubmit { check() }
                    .disabled(checking)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text("Name").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("optional — taken from the feed when left empty")
                        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                }
                TextField("Publisher name", text: $titleText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(checking)
            }

            if let result { verdict(result) }

            Text("The app asks the address for its feed. If it answers with a web page, the feed that page advertises is used instead. Only RSS and Atom are supported: a site that draws its list with JavaScript cannot be read this way.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    @ViewBuilder
    private func verdict(_ result: Result) -> some View {
        switch result {
        case .added(let title, let note):
            notice(symbol: "checkmark.seal.fill", tint: Color(hex: "#4E8A6B"),
                   title: "Added \(title)", detail: note)
        case .duplicate(let title):
            notice(symbol: "equal.circle.fill", tint: Color(hex: "#A8792F"),
                   title: "Already configured",
                   detail: "\(title) is already in the source list, so nothing was added twice.")
        case .refused(let reason, let suggestion):
            VStack(alignment: .leading, spacing: 6) {
                notice(symbol: "exclamationmark.triangle.fill",
                       tint: Color(hex: "#A8792F"), title: "Not added", detail: reason)
                if let suggestion {
                    Button("Try \(suggestion)") {
                        urlText = suggestion
                        check()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        }
    }

    private func notice(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.10))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if checking {
                ProgressView().controlSize(.small)
                Text("Checking the address…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(checking ? "Checking…" : "Check and add") { check() }
                .keyboardShortcut(.defaultAction)
                .disabled(checking || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Action

    private func check() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !checking else { return }
        checking = true
        result = nil
        let name = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            // The validation blocks on the network, so it cannot run on the main
            // actor; the sheet stays responsive because `checking` is the only
            // state it touches.
            let verdict = await Task.detached(priority: .userInitiated) {
                SourceValidator.validate(urlString: url, title: name.isEmpty ? nil : name)
            }.value
            checking = false
            switch verdict {
            case .valid(let source):
                let added = model.addCustomSource(source)
                if added {
                    result = .added(title: source.title, note: source.note)
                    urlText = ""
                    titleText = ""
                    // The new source is fetched straight away, so it appears with
                    // real stories instead of an empty row.
                    model.refresh(userInitiated: true, kind: .check)
                } else {
                    result = .duplicate(source.title)
                }
            case .duplicate(let title):
                result = .duplicate(title)
            case .notAFeed(let reason, let suggestion):
                result = .refused(reason, suggestion: suggestion)
            case .unreachable(let reason):
                result = .refused(reason, suggestion: nil)
            }
        }
    }
}
