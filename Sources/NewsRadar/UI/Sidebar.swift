import SwiftUI

/// Translucent sidebar: navigation, live counts and a source-health strip.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand block. Top padding clears the window's traffic lights, which
            // float over the content because the title bar is hidden.
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.accentGradient)
                        .frame(width: 28, height: 28)
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("News Radar")
                        .font(.system(size: 13.5, weight: .bold))
                    Text("News, projects and tools")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 42)   // clears the window's traffic lights
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    navItem(.digest)
                    navItem(.all)
                    navItem(.tech)
                    navItem(.web)
                    navItem(.design)
                    navItem(.github)
                    navItem(.bookmarks)
                    navItem(.history)

                    Divider().padding(.horizontal, 10).padding(.vertical, 7)

                    navItem(.sources)
                    navItem(.settings)
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 8)

            sourceStrip
        }
        .frame(width: Theme.sidebarWidth)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            // `Color.black` at 7% is invisible on a dark window, so the sidebar
            // looked like a slab butted against the content with no edge at all.
            Theme.separator.frame(width: 0.6)
        }
    }

    // MARK: - Nav

    @ViewBuilder
    private func navItem(_ section: NavSection) -> some View {
        let selected = model.section == section
        Button {
            withAnimation(.smooth(duration: 0.2)) { model.go(to: section) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.accentGradient))
                Text(section.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
                if let count = badgeCount(for: section), count > 0 {
                    Text(TextFormat.number(count))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background {
                            Capsule().fill(selected ? AnyShapeStyle(.white.opacity(0.22))
                                                    : AnyShapeStyle(Color.secondary.opacity(0.14)))
                        }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accentGradient)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.0001))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func badgeCount(for section: NavSection) -> Int? {
        let c = model.counts
        switch section {
        case .all: return c.all
        case .tech: return model.techCount
        case .web: return model.designCount(for: .web)
        case .design: return model.designCount(for: .design)
        case .bookmarks: return c.bookmarks
        case .history: return model.store.history.count
        case .github: return c.github
        default: return nil
        }
    }

    // MARK: - Source strip

    private var sourceStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Sources")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("\(okCount)/\(model.sourceStatuses.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(okCount == model.sourceStatuses.count
                                     ? AnyShapeStyle(.tertiary)
                                     : AnyShapeStyle(Color(hex: "#A8792F")))
                Spacer(minLength: 0)
                if let last = model.store.state.lastRefresh {
                    Text(TextFormat.relative(last))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Bounded box with its own scroll: twenty-four sources must never
            // take over the whole sidebar.
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.sourceStatuses) { status in
                        Button {
                            withAnimation(.smooth(duration: 0.2)) { model.section = .sources }
                        } label: {
                            HStack(spacing: 7) {
                                StatusDot(ok: status.ok, fromCache: status.fromCache)
                                Text(status.source.title)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                // The count keeps its own column. "OpenAI News
                                // 1,308" used to squeeze the name to "OpenA…",
                                // because the number was allowed to grow into the
                                // label's width.
                                Text(TextFormat.number(status.itemCount))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.textTertiary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(minWidth: 26, alignment: .trailing)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(status.message.isEmpty ? status.source.host : status.message)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 240)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.90),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }

            Divider().padding(.horizontal, 10)

            Button {
                withAnimation(.smooth(duration: 0.2)) { model.section = .sources }
            } label: {
                HStack(spacing: 5) {
                    Text("All sources")
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Version " + AppVersion.line)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
                .help("Version \(AppVersion.marketing) · build \(AppVersion.build) · source \(AppVersion.sourceHash) · built \(AppVersion.builtAt)")
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Theme.separator.frame(height: 0.6)
        }
    }

    private var okCount: Int { model.sourceStatuses.filter { $0.ok }.count }
}

/// Transparent view that lets the user drag the window by the toolbar area.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil } // let clicks through
    }
}
