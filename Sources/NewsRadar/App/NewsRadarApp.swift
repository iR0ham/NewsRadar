import SwiftUI

/// News Radar — a native macOS reader for news, GitHub projects and local
/// model tooling.
///
/// The SwiftUI `App` type has no `@main` attribute on purpose: `main.swift` runs
/// first so the headless modes (`--selftest`, `--livetest`, `--probe`) can exit
/// before any window or store is created.
struct NewsRadarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("News Radar", id: "newsradar.main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 620)
                .tint(Theme.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        // `.contentMinSize`, not the default: the window must never resize itself
        // to fit what it is drawing. The toolbar's progress text changes on every
        // source during a load, and with the default resizability that made the
        // whole window pump wider and narrower and push its content off the edge.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .toolbar) {
                Button("Check for new stories") {
                    model.refresh(userInitiated: true, kind: .check)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing)
                Button("Refresh everything") {
                    model.refresh(userInitiated: true, kind: .full)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isRefreshing)
                Button("Search") { model.focusSearchTick &+= 1 }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Bookmark the first item") { model.toggleBookmarkOfFirstVisible() }
                    .keyboardShortcut("b", modifiers: .command)
                Divider()
                Button("Mark all as read") { model.markAllVisibleRead() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            CommandMenu("Layout") {
                ForEach(Array(LayoutMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button(mode.title) {
                        model.layout = mode
                        model.persistLayout()
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
                ForEach(Array(NavSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.go(to: section) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                }
            }
        }
    }
}
