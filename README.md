# News Radar

A native macOS reader for AI news, tech, GitHub projects and design work — built in SwiftUI, no
Electron, no web view. It reads 114 sources out of the box: 24 shipped feeds and pages (OpenAI,
Anthropic, DeepMind, Hacker News, r/LocalLLaMA, GitHub Trending), 80 design and web publishers
(Figma, Communication Arts, The Dieline, web.dev, Ahrefs and others) and 10 general tech publishers
(Ars Technica, The Verge, Wired, Tom's Hardware). It classifies every story into topic buckets and
folds the day into a briefing you can expand into the full article text. Summaries are written by a
language model you run yourself, or by an offline extractive digest when you have none configured.

<p align="left"><img src="Resources/AppIcon.png" width="96" height="96" alt="News Radar app icon"></p>

## What it does

- **Ten sections** — Daily Briefing, AI News, Tech News, Web & SEO, Design & Creative AI, GitHub &
  Code, Bookmarks, Reading History, Source Status and Settings, with a live source-health strip in
  the sidebar.
- **Automatic classification** of every item into 12 news topics (language models, agents, coding
  tools, image/video, audio, local models, hardware, research, business, policy, tools, other). The
  design surface has its own 13 sections and the tech surface 6, because a packaging story is not a
  language-model story.
- **Article reader** that extracts the real body text from the page, with its inline pictures and
  links in page order, instead of the teaser. A repository's sheet shows its whole README as text.
- **Summaries** from a local Ollama model or any OpenAI-compatible gateway (e.g. 9router), with a
  badge that always says which engine produced the text. A check sends at most twelve items to the
  model; the rest are rendered by the offline digest, and labelled as such.
- **Ranking you choose** — freshest first, most relevant, projects first, busiest source first, or
  your own order of publishers.
- **Search, filters and windows** — full-text search over titles and summaries, four quick windows
  in the toolbar (12h / 24h / 72h / 1w) and six in the filter panel up to all time, unread only,
  open source only, free only, Apple-Silicon-first, and a per-source picker.
- **Three layouts** — compact list, comfortable list, visual grid.
- **Custom sources** — add any RSS/Atom feed; the app explains how each source is collected, so a
  page scraped for headlines never passes itself off as a feed.
- **Pictures** loaded six at a time, decoded off the main thread at the size they are drawn, and
  kept in a disk cache with a ceiling.

## Requirements

- An Apple Silicon Mac, macOS 14 or newer. The build links `arm64` only.
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

The built binary runs the engine on its own, which is how a change gets proven rather than claimed:

```bash
build/bin/NewsRadar --selftest              # 475 offline checks, no network
build/bin/NewsRadar --livetest              # fetch and read every source, for real
build/bin/NewsRadar --probe                 # environment and local-data report
build/bin/NewsRadar --version               # running version, build and release notes
build/bin/NewsRadar --images 24             # time the app's own picture loader
build/bin/NewsRadar --checkfeed <url>       # validate a feed as the app does
build/bin/NewsRadar --readarticle <url>     # extract an article as the reader does
build/bin/NewsRadar --readme <owner/repo>   # a project README as the sheet shows it
```

`NEWSRADAR_DATA_DIR` points any of them at a throwaway store, and
`NEWSRADAR_IMAGE_CONCURRENCY` overrides how many pictures load at once.

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

The source lists are data, not hard-coded strings: `SourceSpecs.swift` holds the shipped feeds,
`DesignCatalogue.swift` and `TechCatalogue.swift` hold the publishers of the two catalogue tabs, and
every entry records the address that actually returned entries when it was verified.

## Data and privacy

Everything lives on this Mac, as plain JSON you can read, back up or delete:

```
~/Library/Application Support/NewsRadar/   stories, bookmarks, history, briefings,
                                           source health, READMEs, settings
~/Library/Caches/NewsRadar/Images          the picture cache, trimmed to 250 MB
```

The settings file holds, among other things, the summarizer endpoint and its API key, in clear text,
because the app writes what it uses and does not talk to a keychain. That key is never in this
repository, and the app has no server of its own.

The app asks the network only for what it shows: the feeds and listing pages of the publishers you
enable, GitHub's trending and explore pages plus its public API and raw file host, the article page
you open in the reader, the pictures those pages point at, and one site icon per publisher from
DuckDuckGo's icon service. With a summarizer configured, item text goes to the endpoint you typed
in and nowhere else. Every story keeps its link to the original.

## Prebuilt app

The GitHub Release carries a zipped `NewsRadar-<version>-macOS-arm64.app.zip`. It is ad-hoc signed
(no Apple developer account), so macOS will quarantine it on first launch. Either right-click →
Open the first time, or clear the attribute:

```bash
xattr -dr com.apple.quarantine "News Radar.app"
```

Building from source with `./build.sh` produces the same bundle without the fuss.
