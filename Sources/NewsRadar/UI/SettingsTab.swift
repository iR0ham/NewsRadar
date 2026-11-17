import SwiftUI

/// Settings tab: Ollama endpoint, data management and per-source control.
struct SettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Order follows what the user actually changes: how new stories
                // arrive, how they are ranked, how long they are kept, how many
                // are shown, then the optional model and the engine details.
                refreshSettings(model: model)
                rankingSettings(model: model)
                dataSettings
                displaySettings(model: model)
                ollamaSettings(model: model)
                engineSettings
                aboutSettings
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Delete all local data?",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                model.resetAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bookmarks, reading history and the story archive are deleted. This cannot be undone.")
        }
    }

    // MARK: - Refresh

    private func refreshSettings(model: AppModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "New stories", symbol: "bolt.horizontal",
                          subtitle: "checking is cheap")

            Text("A check asks each source whether anything was published since the last one. A source that has not changed answers immediately, and only genuinely new stories are summarised, so reopening the app does not re-do the whole archive.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Check every").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.autoCheckMinutes },
                    set: { model.autoCheckMinutes = $0; model.persistRefreshSettings() })) {
                    ForEach(model.autoCheckOptions, id: \.self) { m in
                        Text(AppModel.autoCheckLabel(m)).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                Text("while the app is open").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 9) {
                PillSwitch(
                    isOn: model.checkOnLaunch,
                    onToggle: {
                        model.checkOnLaunch.toggle()
                        model.persistRefreshSettings()
                    },
                    help: "Check for new stories once each time the app opens.")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check once when the app opens").font(.system(size: 12, weight: .medium))
                    Text("Picks up what was published while the app was closed.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            if let last = model.store.state.lastRefresh {
                Text("Last check: " + TextFormat.date(last))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Ranking

    /// How the lists are ordered, and — when the reader asks for their own
    /// order — which publisher comes first.
    ///
    /// This is the app's answer to "what should I see first". The toolbar's sort
    /// menu is a per-look override of one list; this applies everywhere,
    /// including the Daily Briefing, which is why it lives in Settings.
    private func rankingSettings(model: AppModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Ranked by", symbol: "arrow.up.arrow.down",
                          subtitle: "applies to every list")

            Picker("", selection: Binding(
                get: { model.rank },
                set: { model.rank = $0; model.persistRank() })) {
                ForEach(RankMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.rank.detail)
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.rank.needsManualOrder {
                manualOrderEditor(model: model)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// The reader's own order of publishers, for the "My order" ranking.
    ///
    /// Every publisher the app collects is listed, with the ones the reader has
    /// placed at the top first. Moving one up or down writes the whole order,
    /// so it survives a relaunch.
    private func manualOrderEditor(model: AppModel) -> some View {
        let all = model.manualOrderCandidates
        return VStack(alignment: .leading, spacing: 7) {
            Text("Your order")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
            if model.manualOrder.isEmpty {
                Text("No publisher is placed yet — use the arrows to move one to the top.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.manualOrder) { id in
                HStack(spacing: 8) {
                    SourceBadge(source: id, compact: true)
                    Text(id.title).font(.system(size: 11.5))
                    Spacer(minLength: 0)
                    Button {
                        model.moveManualOrder(id, by: -1)
                    } label: { Image(systemName: "chevron.up").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .help("Move up")
                    Button {
                        model.moveManualOrder(id, by: 1)
                    } label: { Image(systemName: "chevron.down").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .help("Move down")
                    Button {
                        model.removeManualOrder(id)
                    } label: { Image(systemName: "xmark.circle").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Remove from your order")
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
            }
            if !all.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Add a publisher")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.4)
                    .foregroundStyle(Theme.textTertiary)
                Menu {
                    ForEach(all) { id in
                        Button(id.title) { model.addManualOrder(id) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        Text("Choose a publisher").font(.system(size: 11.5))
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Display

    private func displaySettings(model: AppModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "How much is shown", symbol: "list.number")

            HStack(spacing: 8) {
                Text("Briefing highlights").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 150, alignment: .leading)
                Stepper(value: Binding(
                    get: { model.briefingNewsCount },
                    set: { model.briefingNewsCount = $0; model.persistRefreshSettings() }),
                        in: 3...20) {
                    Text("\(model.briefingNewsCount) stories")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 76, alignment: .leading)
                }
            }

            HStack(spacing: 8) {
                Text("GitHub picks").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 150, alignment: .leading)
                Stepper(value: Binding(
                    get: { model.briefingRepoCount },
                    set: { model.briefingRepoCount = $0; model.persistRefreshSettings() }),
                        in: 0...12) {
                    Text(model.briefingRepoCount == 0 ? "hidden"
                                                      : "\(model.briefingRepoCount) projects")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 76, alignment: .leading)
                }
            }

            HStack(spacing: 8) {
                Text("Rows per list").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 150, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.listLimit },
                    set: { model.listLimit = $0; model.persistRefreshSettings() })) {
                    Text("100").tag(100)
                    Text("300").tag(300)
                    Text("600").tag(600)
                    Text("Everything").tag(0)
                }
                .labelsHidden()
                .frame(width: 150)
                Text("the archive keeps everything either way")
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }

            Text("These numbers apply to the Daily Briefing and the AI News and GitHub lists. They do not change how much is stored.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Summary service

    private func ollamaSettings(model: AppModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Summarise with a model", symbol: "cpu", subtitle: "optional")

            // Engine choice first: everything below is labelled for the service
            // that is actually selected.
            Picker("", selection: Binding(
                get: { model.ollama.engine },
                set: { switchEngine($0, model: model) })) {
                ForEach(SummaryEngine.allCases, id: \.self) { e in
                    Text(e.title).tag(e)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            Text(model.ollama.engine.detail)
                .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { model.ollama.enabled },
                set: { model.ollama.enabled = $0; model.persistOllama() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use \(model.ollama.engine.title) for summaries")
                        .font(.system(size: 12, weight: .medium))
                    Text("When off, summaries come from the app's own offline digest.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 8) {
                Text("Server").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 90, alignment: .leading)
                TextField(model.ollama.engine.defaultBaseURL, text: Binding(
                    get: { model.ollama.baseURL },
                    set: { model.ollama.baseURL = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: 260)
                Button(model.checkingOllama ? "Checking…" : "Check connection") { model.checkOllama() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.checkingOllama)
                StatusDot(ok: model.ollamaReachable)
            }

            // 9router authenticates every request, so the key is part of the setup
            // rather than an advanced option.
            if model.ollama.engine.needsAPIKey {
                HStack(spacing: 8) {
                    Text("API key").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    SecureField("sk-…", text: Binding(
                        get: { model.ollama.apiKey },
                        set: { model.ollama.apiKey = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: 260)
                    .onSubmit { model.persistOllama() }
                }
                Text("Stored only in this app's data folder on this Mac, and sent only to the server above.")
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 98)
            }

            HStack(spacing: 8) {
                Text("Model").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 90, alignment: .leading)
                if model.ollamaModels.isEmpty {
                    TextField(model.ollama.engine == .ollama ? "model name, e.g. qwen2.5:7b"
                                                             : "model id, e.g. openrouter/…",
                              text: Binding(get: { model.ollama.model },
                                            set: { model.ollama.model = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: 260)
                } else {
                    Picker("", selection: Binding(
                        get: { model.ollama.model },
                        set: { model.ollama.model = $0 })) {
                        ForEach(model.ollamaModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                }
                Text(model.ollamaModels.isEmpty
                     ? "Check the connection to list models"
                     : "\(TextFormat.number(model.ollamaModels.count)) models available")
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }

            if let err = model.ollama.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Color(hex: "#A8792F"))
                    Text(err).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Save and re-render summaries") {
                    model.persistOllama()
                    model.reRenderAll()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.isRefreshing)

                Button("Use the offline digest") {
                    model.ollama.enabled = false
                    model.persistOllama()
                    model.reRenderAll()
                }
                .buttonStyle(.bordered)
                .disabled(model.isRefreshing)
            }

            Text("Note: a refresh sends at most 12 items to the model so cost and resource use stay bounded. Everything else is rendered by the offline digest, and each card states which engine was used.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// Switching engine resets the address to that service's default and clears
    /// the discovered models, so a 9router id can never be sent to Ollama.
    private func switchEngine(_ engine: SummaryEngine, model: AppModel) {
        guard engine != model.ollama.engine else { return }
        model.ollama.engine = engine
        model.ollama.baseURL = engine.defaultBaseURL
        model.ollama.model = ""
        model.ollamaModels = []
        model.ollamaReachable = false
        model.ollama.lastError = nil
        model.persistOllama()
        model.checkOllama()
    }

    // MARK: - Engine

    private var engineSettings: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Offline digest engine", symbol: "text.alignleft")
            Text("Summaries come from the feed's own description when it is long enough; otherwise the app composes one from measured data (stars, language, licence, flags). It never invents text and needs no network.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                statChip("Category signals", TextFormat.number(Signals.category.values.reduce(0) { $0 + $1.count }))
                statChip("Feature signals", TextFormat.number(Signals.local.count + Signals.openSource.count + Signals.appleSilicon.count))
                statChip("Stored items", TextFormat.number(model.store.items.count))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func statChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }

    // MARK: - Data

    private var dataSettings: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Data", symbol: "internaldrive")
            Text("Bookmarks, reading history, the story archive and star snapshots are stored on this Mac only.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)

            // Retention is explicit: nothing is ever deleted silently, and the
            // user chooses the window.
            HStack(spacing: 8) {
                Text("Keep stories for").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 150, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.retentionDays },
                    set: { model.retentionDays = $0; model.persistRefreshSettings() })) {
                    Text("3 days").tag(3)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                .labelsHidden()
                .frame(width: 150)
                Text(model.retentionDays == 0
                     ? "nothing is removed automatically"
                     : "older stories are removed on the next check")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 8) {
                Button("Delete older stories now") {
                    let removed = model.store.pruneOlderThanRetention()
                    model.revision &+= 1
                    model.toast = removed == 0
                        ? "Nothing was older than \(model.retentionDays) days."
                        : "\(TextFormat.number(removed)) stories removed."
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.retentionDays == 0)

                Text("\(TextFormat.number(model.store.items.count)) stories stored")
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 16) {
                labeled("Path", model.store.directory.path)
                labeled("Size", ByteCountFormatter.string(fromByteCount: model.store.sizeOnDisk, countStyle: .file))
            }
            HStack(spacing: 8) {
                Button("Clear image cache") {
                    ImageLoader.shared.clearDiskCache()
                    model.toast = "Image cache cleared"
                }
                .buttonStyle(.bordered).controlSize(.small)

                Button("Clear network cache") {
                    HTTP.clearFetchedCache()
                    model.toast = "Network response cache cleared"
                }
                .buttonStyle(.bordered).controlSize(.small)

                Button("Delete all data", role: .destructive) {
                    confirmReset = true
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                .textSelection(.enabled)
        }
    }

    // MARK: - About

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "About", symbol: "info.circle")
            HStack(spacing: 22) {
                labeled("Version", AppVersion.marketing)
                labeled("Build", AppVersion.build)
                labeled("Source hash", AppVersion.sourceHash)
                labeled("Built", AppVersion.builtAt)
                labeled("Minimum macOS", Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String ?? "14.0")
            }
            Text("Sources: \(SourceID.all.map { $0.host }.joined(separator: ", "))")
                .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The app reads public RSS feeds and the public GitHub API only. It never republishes article content and always shows the link to the original.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 3)

            Text("What changed").font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(AppVersion.changelog, id: \.0) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.0).font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        ForEach(entry.1, id: \.self) { line in
                            Text("· " + line)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
