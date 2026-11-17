import AppKit
import Foundation

// Entry point. Headless modes are handled before any UI or store is created, so
// the build script and CI can exercise the engine directly:
//
//   NewsRadar --selftest   offline engine checks, no network     (exit 0 = pass)
//   NewsRadar --livetest   real fetch, every configured source    (exit 0 = all ok)
//   NewsRadar --probe      environment + local data report
//   NewsRadar              normal GUI launch

let arguments = CommandLine.arguments

/// Returns true when this process is the only copy of the app running.
///
/// A named lock in the system's application-support lock directory. If it can be
/// taken, this process is the only one; if it cannot, another copy holds it and
/// this one activates that copy instead of opening a second window over the same
/// archive.
///
/// The lock is released by the kernel when the process dies, so a crash cannot
/// leave it held, and it is never a file on disk that has to be cleaned up.
private func becomeSingleInstance() -> Bool {
    let name = "NewsRadar.single-instance"
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first!
    let dir = base.appendingPathComponent("NewsRadar", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(name).path

    // `flock` with LOCK_EX|LOCK_NB: non-blocking, advisory, per-open-file. The
    // descriptor is deliberately never closed — it must outlive this function for
    // the lock to last as long as the process.
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }   // cannot tell; do not block the app
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }

    // Lost the race: another copy owns the app. Bring it forward rather than
    // starting a second one, then exit.
    let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.newsradar.reader")
    running.first(where: { $0.processIdentifier != getpid() })?
        .activate(options: [.activateAllWindows])
    return false
}

/// Makes this process a real application even when it was not started by
/// LaunchServices.
///
/// A GUI launch from `build/bin/NewsRadar`, or from the executable inside `.app`
/// run by a script, reaches AppKit with no bundle identity. AppKit then treats
/// it as a background daemon: `lsappinfo` reports `bundleID=[NULL]`, so it gets
/// no Dock tile and no icon.
///
/// The tempting fix is to hand over to `open News Radar.app` and quit — but that
/// makes the app visibly close and reopen on every launch, which is worse than
/// the missing icon. So nobody restarts. The bundle is adopted in-process, the
/// activation policy is set to regular, and the icon is assigned directly from
/// the PNG in the bundle. `llsappinfo` may still show no bundle id in this mode,
/// but the window, the Dock tile and the icon are all correct, and the process
/// is the same one that started.
private func adoptBundledIdentity() {
    let alreadyBundled = Bundle.main.bundleIdentifier != nil

    if !alreadyBundled {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var app: URL?
        var candidate = exe.deletingLastPathComponent()
        for _ in 0..<4 {
            candidate = candidate.deletingLastPathComponent()
            if candidate.pathExtension == "app" { app = candidate; break }
        }
        if app == nil {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let packaged = cwd.appendingPathComponent("News Radar.app")
            if FileManager.default.fileExists(atPath: packaged.path) { app = packaged }
        }
        if let app { _ = Bundle(path: app.path) }
    }

    NSApplication.shared.setActivationPolicy(.regular)

    // The icon, taken straight from whichever bundle this process can see. When
    // the bundle was adopted above its resources are reachable; when it was not,
    // the packaged file is, and it is the same image the .icns was made from.
    if NSApplication.shared.applicationIconImage == nil {
        var candidates: [URL] = []
        for name in ["AppIcon", "AppIcon@2x"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png") {
                candidates.append(url)
            }
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<5 {
            let png = dir.appendingPathComponent("Resources/AppIcon.png")
            if FileManager.default.fileExists(atPath: png.path) { candidates.append(png) }
            dir = dir.deletingLastPathComponent()
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/AppIcon.png"))
        for url in candidates {
            if let image = NSImage(contentsOf: url) {
                NSApplication.shared.applicationIconImage = image
                break
            }
        }
    }
}

if arguments.contains("--selftest") {
    exit(SelfCheck.runSelfTest())
} else if arguments.contains("--livetest") {
    exit(SelfCheck.runLiveTest())
} else if arguments.contains("--images") {
    //   NewsRadar --images [n]   time the picture loader on the live archive
    let args = arguments.dropFirst().filter { $0 != "--images" }
    let n = args.first.flatMap { Int($0) } ?? 12
    exit(SelfCheck.runImageBenchmark(count: max(1, min(40, n))))
} else if arguments.contains("--checkfeed") {
    //   NewsRadar --checkfeed <url>    validate a feed exactly as the sheet does
    let args = arguments.dropFirst().filter { $0 != "--checkfeed" }
    guard let raw = args.first else {
        print("usage: NewsRadar --checkfeed <url>")
        exit(2)
    }
    exit(SelfCheck.runFeedCheck(raw))
} else if arguments.contains("--readarticle") {
    //   NewsRadar --readarticle <url>  extract an article exactly as the sheet does
    let args = arguments.dropFirst().filter { $0 != "--readarticle" }
    guard let raw = args.first, let url = URL(string: raw) else {
        print("usage: NewsRadar --readarticle <url>")
        exit(2)
    }
    exit(SelfCheck.runArticleRead(url))
} else if arguments.contains("--readme") {
    //   NewsRadar --readme <owner/repo>   the README as the detail sheet shows it
    let args = arguments.dropFirst().filter { $0 != "--readme" }
    guard let full = args.first else {
        print("usage: NewsRadar --readme <owner/repo>")
        exit(2)
    }
    guard let text = GitHubSource.readme(full), !text.isEmpty else {
        print("no README could be read for \(full)")
        exit(1)
    }
    print(text)
    exit(0)
} else if arguments.contains("--version") {
    //   NewsRadar --version    what the window's footer shows, plus the changelog
    print("Version " + AppVersion.line)
    print("Built " + AppVersion.builtAt)
    // The current release is printed in full — its notes are the whole point of
    // asking. Earlier releases are summarized, or the answer is a wall of text.
    for (index, entry) in AppVersion.changelog.prefix(3).enumerated() {
        print("\n\(entry.0)")
        let notes = index == 0 ? entry.1[...] : entry.1.prefix(3)
        for line in notes { print("  · \(line)") }
        if index > 0, entry.1.count > 3 {
            print("  … \(entry.1.count - 3) more in Settings")
        }
    }
    exit(0)
} else if arguments.contains("--probe") {
    exit(SelfCheck.runProbe())
} else if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    News Radar — news, GitHub projects and local-model tooling


    Usage:
      NewsRadar               launch the app
      NewsRadar --selftest    offline engine self-test (no network)
      NewsRadar --livetest    live fetch against every configured source
      NewsRadar --probe       environment and local-data report
    """)
    exit(0)
} else {
    // Same process, same window: no relaunch, no close-and-reopen.
    adoptBundledIdentity()
    // One instance only.
    //
    // Opening the app twice used to start two full copies, each loading the whole
    // archive and its own image cache into memory, and leaving both running after
    // the first window was closed. A few launches and the Mac was swapping. The
    // second copy now hands focus to the one already running and exits.
    //
    // Skipped when a data directory is given: the QA runs launch several
    // instances against throwaway stores on purpose, and they must not collide.
    if ProcessInfo.processInfo.environment["NEWSRADAR_DATA_DIR"]?.isEmpty ?? true,
       !becomeSingleInstance() {
        exit(0)
    }
    NewsRadarApp.main()
}
