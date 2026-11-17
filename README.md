# News Radar

A native macOS reader for AI news, GitHub projects and design work — built in SwiftUI, no
Electron, no web view. It reads from 31 curated sources (OpenAI, Anthropic, DeepMind, Hacker News,
GitHub Trending, r/LocalLLaMA, Creative Bloq and more), classifies every story into topic buckets,
and folds the day into a briefing you can expand into the full article text. Summaries are
written by a language model you run yourself, or by an offline extractive digest when you have
none configured.

<p align="left"><img src="Resources/AppIcon.png" width="96" height="96" alt="News Radar app icon"></p>

## What it does

- **Eight reading sections** — daily briefing, AI news, tech, web & SEO, design & creative AI,
  GitHub, bookmarks and history — plus a live source-health strip in the sidebar.
- **Automatic classification** of every item into 12 topics (language models, agents, coding
  tools, image/video, audio, local models, hardware, research, business, policy, tools, other).
- **Article reader** that extracts the real body text from the page, not the teaser.
- **Summaries** from a local Ollama model or any OpenAI-compatible gateway (e.g. 9router), with a
  badge that always says which engine produced the text. Without a model configured, a plain
  extractive digest is used and labelled as such.
- **Custom sources** — add any RSS/Atom feed; the app explains how each source is collected.
- **Pictures** loaded concurrently and decoded off the main thread.

## Requirements

- macOS 14 or newer
- A Swift toolchain (Command Line Tools are enough — `xcode-select --install`)

## Build and run

```bash
./build.sh            # build, run self-tests and live tests, then launch
./build.sh --no-run   # build and test, do not launch
./build.sh --fast     # build and offline self-tests only (no network)
```

The script compiles the whole tree with a single `swiftc` invocation instead of `swift build`,
because the SwiftPM driver misbehaves on Command-Line-Tools-only installs. It probes the installed
SDKs for one whose SwiftUI macro plugin actually typechecks before compiling, generates
`build/gen/BuildStamp.swift` (source hash + build number) and ad-hoc signs the bundle.

The version shown by the app comes from `Resources/Version.txt`, and every version there must have
a matching entry in the release history in `Sources/NewsRadar/Core/Version.swift` — `build.sh`
refuses to build one without the other.

## Layout

```
Sources/NewsRadar/App     app entry, root view, the @Observable view-model
Sources/NewsRadar/Core    feeds, parsing, classification, GitHub, images, storage, self-check
Sources/NewsRadar/UI      sidebar, tabs, cards, reader, sheets, design kit
Resources/                Info.plist, app icon, version file
scripts/make_icon.py      regenerates the .icns from a source PNG
build.sh                  the whole build + test pipeline
```

## Data and privacy

Everything the app stores lives in `~/Library/Application Support/NewsRadar/state.json` as plain
JSON — bookmarks, read history, custom sources and, if you configure one, the summarizer endpoint
and its API key. Nothing is uploaded anywhere by the app: it only contacts the feeds you enable,
GitHub's public API, and the summarizer endpoint you point it at. That key is never in this
repository.

## Prebuilt app

The GitHub Release carries a zipped `News Radar.app`. It is ad-hoc signed (no Apple developer
account), so macOS will quarantine it on first launch. Either right-click → Open the first time,
or clear the attribute:

```bash
xattr -dr com.apple.quarantine "News Radar.app"
```

Building from source with `./build.sh` produces the same bundle without the fuss.
