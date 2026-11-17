import AppKit
import SwiftUI

/// The window contents: translucent sidebar, frosted toolbar, current section.
struct RootView: View {
    @Environment(AppModel.self) private var model

    /// How far a row dissolves as it reaches the top of the page.
    private static let fadeBand: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            // The toolbar is a band, not a floating panel: it sits in the flow, so
            // nothing — no card, no row — can ever appear above it. Making it float
            // was a mistake: rows sailed over the top edge and the bar read as a hole
            // in the window.
            VStack(spacing: 0) {
                TopBar()
                sectionContent
                    // A row that reaches the top of the page dissolves into the
                    // bar rather than being sheared at a hard line. The fade is a
                    // mask on the page, not paint on top of it: a wash drawn over
                    // cards reads as a smudge, a mask reads as depth.
                    .mask(alignment: .top) {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.fadeBand)
                            Color.black
                        }
                    }
            }
        }
        .background(AppBackground())
        .background(WindowConfigurator())
        .sheet(isPresented: Binding(get: { model.showAddSource },
                                    set: { model.showAddSource = $0 })) {
            AddSourceSheet(onClose: { model.showAddSource = false })
                .environment(model)
        }
        .sheet(item: Binding(get: { model.readerItem },
                             set: { model.readerItem = $0 })) { item in
            ReaderView(item: item, onClose: { model.readerItem = nil })
        }
        .sheet(item: Binding(get: { model.detailItem },
                             set: { model.detailItem = $0 })) { item in
            DetailView(item: item, onClose: { model.detailItem = nil })
        }
        .overlay(alignment: .bottom) { toastView }
        .onAppear {
            model.bootstrap()
            applyTestWindowSize()
        }
        .onChange(of: model.toast) { _, newValue in
            guard newValue != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                if model.toast == newValue { model.toast = nil }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var sectionContent: some View {
        switch model.section {
        case .digest:
            DigestTab()
        case .all:
            ItemList(items: model.visibleItems,
                     emptySymbol: model.store.items.isEmpty ? "dot.radiowaves.up.forward" : "magnifyingglass",
                     emptyTitle: emptyTitle,
                     emptyMessage: emptyMessage,
                     emptyActionTitle: emptyActionTitle,
                     emptyAction: emptyAction,
                     header: AnyView(allHeader))
        case .bookmarks:
            ItemList(items: model.visibleItems,
                     emptySymbol: "bookmark",
                     emptyTitle: "No bookmarks yet",
                     emptyMessage: "Use the bookmark icon on any card and the item stays here, available offline.",
                     emptyActionTitle: "Show all news",
                     emptyAction: { model.section = .all })
        case .history:
            ItemList(items: model.visibleItems,
                     emptySymbol: "clock.arrow.circlepath",
                     emptyTitle: "No reading history yet",
                     emptyMessage: "Every story you open is recorded locally so you can find it again.",
                     emptyActionTitle: nil,
                     emptyAction: nil,
                     header: AnyView(historyHeader))
        case .github:
            ItemList(items: model.visibleItems,
                     emptySymbol: "chevron.left.forwardslash.chevron.right",
                     emptyTitle: "No projects in this window",
                     emptyMessage: "This section is fed by the GitHub Trending and Explore pages. Widen the time window or refresh; Source Status explains any source that failed.",
                     emptyActionTitle: "Refresh",
                     emptyAction: { model.refresh(userInitiated: true) })
        case .tech:
            TechTab()
        case .web:
            DesignTab(surface: .web)
        case .design:
            DesignTab(surface: .design)
        case .sources:
            SourcesTab()
        case .settings:
            SettingsTab()
        }
    }

    /// Empty-state copy for the news list.
    ///
    /// When one source is filtered in and the page is blank, the reason is almost
    /// always the window, not the source: a publisher that posts twice a day has
    /// nothing in twelve hours. Saying that, and offering the one click that fixes
    /// it, is better than "no matches".
    private var emptyTitle: String {
        if model.store.items.isEmpty { return "Nothing saved yet" }
        if let only = soleSelectedSource {
            return "\(only.title): nothing in the \(model.filters.range.shortTitle) window"
        }
        return "No matches for these filters"
    }

    private var emptyMessage: String {
        if model.store.items.isEmpty {
            return "Press Refresh in the toolbar to pull AI news from every configured source."
        }
        if let only = soleSelectedSource {
            // Name the window it does have, in the same shorthand as the toolbar,
            // so the fix ("widen to 24h") is legible from the sentence alone.
            let measured = model.availability(for: only).filter { $0.range != .all }
            let populated = measured.filter { $0.count > 0 }
            if let widest = populated.max(by: { $0.count < $1.count }) {
                return "This source last posted within the \(widest.range.shortTitle) window: "
                    + "\(widest.count) "
                    + (widest.count == 1 ? "story, which falls" : "stories, which fall")
                    + " outside the \(model.filters.range.shortTitle) you are looking at."
            }
            return "Nothing from this source is in the local archive. Its feed may publish "
                + "rarely, or it may have started failing — Source Status says which."
        }
        return "Try a wider time window (12h → 24h → 72h → 1w) or clear the filters. "
            + "GitHub projects live in the GitHub & Code section."
    }

    private var emptyActionTitle: String? {
        if model.store.items.isEmpty { return "Refresh sources" }
        // Widening the window is the smaller, truer fix; clearing the filter is
        // the fallback when no window holds anything.
        if let wider = model.widestWindowWithContent() {
            return "Show the \(wider.shortTitle) window"
        }
        if soleSelectedSource != nil { return "Show everything" }
        return "Clear filters"
    }

    private var emptyAction: (() -> Void)? {
        if model.store.items.isEmpty {
            return { model.refresh(userInitiated: true) }
        }
        return {
            // Widen first, clear only if widening does not help: dropping the
            // filter the reader just set is a worse answer than showing the same
            // source a week back.
            if let wider = model.widestWindowWithContent() {
                model.filters.range = wider
            } else {
                model.filters = Filters()
            }
            model.persistFilters()
        }
    }

    /// The single source whose filter is active, if exactly one is.
    private var soleSelectedSource: SourceID? {
        model.filters.sources.count == 1 ? model.filters.sources.first : nil
    }

    // MARK: - Headers

    private var allHeader: some View {
        HStack(spacing: 8) {
            SectionHeader(title: model.section.title, symbol: "newspaper",
                          subtitle: model.filters.range.title,
                          count: model.visibleItems.count)
            // Say when the list cap is hiding rows, and offer the way out, rather
            // than letting the count silently disagree with the sidebar badge.
            if model.isListCapped {
                Button("Show all \(TextFormat.number(model.unfilteredCount))") {
                    model.showAllRows()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("Draw every matching row. The stored archive is unchanged.")
            }
            Spacer(minLength: 0)
            if model.filters.unreadOnly {
                Button("Mark all as read") { model.markAllVisibleRead() }
                    .buttonStyle(.link).font(.system(size: 11))
            } else {
                Button("Unread only") {
                    model.filters.unreadOnly = true
                    model.persistFilters()
                }
                .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(.top, 2)
    }

    /// UI-testing hook: `NEWSRADAR_WINDOW_SIZE=1000x620` resizes the window before
    /// it is captured, so the layout can be checked at the narrowest size the app
    /// allows without synthesising a drag (which needs Accessibility permission).
    private func applyTestWindowSize() {
        guard let raw = ProcessInfo.processInfo.environment["NEWSRADAR_WINDOW_SIZE"] else { return }
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible })
            else { return }
            window.setContentSize(NSSize(width: parts[0], height: parts[1]))
        }
    }

    private var historyHeader: some View {
        HStack(spacing: 8) {
            SectionHeader(title: "Reading History", symbol: "clock.arrow.circlepath",
                          count: model.visibleItems.count)
            Spacer(minLength: 0)
            Button("Clear history") { model.clearHistory() }
                .buttonStyle(.link).font(.system(size: 11))
        }
        .padding(.top, 2)
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "#10B981"))
                Text(toast).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassCard(radius: 13)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }
}

/// Soft, light/dark adaptive backdrop. Sidebar and toolbar use `.ultraThinMaterial`
/// over this, which is what produces the Liquid Glass translucency.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ramp = Theme.backdrop(isDark: scheme == .dark)
        ZStack {
            ramp.base
            RadialGradient(colors: [ramp.topTint, .clear],
                           center: .topLeading, startRadius: 10, endRadius: 620)
            RadialGradient(colors: [ramp.bottomTint, .clear],
                           center: .bottomTrailing, startRadius: 10, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

/// Configures the hosting NSWindow so the frosted glass has the desktop behind
/// it: transparent title bar, hidden title, full-size content view.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.insert([.closable, .miniaturizable, .resizable])
            window.isMovableByWindowBackground = false
            // Matched to `Theme.backdrop`: the window used to paint its own grey
            // behind everything, which showed through the materials as a second
            // tone and made the sidebar look pasted on.
            window.backgroundColor = NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return dark ? NSColor(srgbRed: 0.071, green: 0.075, blue: 0.090, alpha: 1)
                            : NSColor(srgbRed: 0.965, green: 0.957, blue: 0.953, alpha: 1)
            }
            window.minSize = NSSize(width: 1000, height: 640)
            // A borderless / full-size title bar keeps the glass look but can drop
            // the traffic lights. They are standard macOS window controls and must
            // always be available, so they are re-enabled explicitly here.
            for kind in [NSWindow.ButtonType.closeButton,
                         .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(kind) {
                    button.isHidden = false
                    button.alphaValue = 1
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            for kind in [NSWindow.ButtonType.closeButton,
                         .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(kind), button.isHidden {
                    button.isHidden = false
                    button.alphaValue = 1
                }
            }
        }
    }
}
