#!/bin/bash
# Builds "News Radar.app" — a native macOS SwiftUI reader for news, GitHub
# projects and local-model tooling, with Persian summaries.
#
# Why swiftc instead of `swift build`?
#   This machine has Command Line Tools only (no Xcode). The SwiftPM build engine
#   fails to start on CLT-only installs, and the default SDK symlink can point at
#   a version that does not ship the SwiftUI macro plugin, so every @State fails
#   to compile. We therefore probe for an SDK whose SwiftUI macro plugin actually
#   typechecks and compile all sources in one swiftc invocation.
#
# Usage:
#   ./build.sh            build, self-test, live-test and launch
#   ./build.sh --no-run   build and test only
#   ./build.sh --fast     build and offline self-test only (no network)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="News Radar"
APP_BUNDLE="$APP_NAME.app"
BINARY_NAME="NewsRadar"
OUT_DIR="build/bin"
TARGET_MIN="14.0"

RUN_APP=1
LIVE_TEST=1
for arg in "$@"; do
  case "$arg" in
    --no-run) RUN_APP=0 ;;
    --fast)   RUN_APP=0; LIVE_TEST=0 ;;
  esac
done

# --- locate an SDK whose SwiftUI macro plugin actually works ---
SDK=""
for candidate in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -Vr); do
  probe=$(mktemp -d)
  printf 'import SwiftUI\nimport Observation\nimport AppKit\nstruct P: View { @State var v = 1; var body: some View { Text("\\(v)") } }\n@Observable final class O { var x = 1 }\n' > "$probe/p.swift"
  if swiftc -typecheck -target arm64-apple-macosx${TARGET_MIN} -sdk "$candidate" "$probe/p.swift" >/dev/null 2>&1; then
    SDK="$candidate"
    rm -rf "$probe"
    break
  fi
  rm -rf "$probe"
done

if [ -z "$SDK" ]; then
  echo "✗ No SDK with a working SwiftUI macro plugin was found." >&2
  echo "  Install Xcode and run: sudo xcode-select --switch /Applications/Xcode.app" >&2
  exit 1
fi

SDK_VERSION=$(basename "$SDK" .sdk | sed 's/MacOSX//')
LINK_TARGET="arm64-apple-macosx${SDK_VERSION}"
if [ "$(printf '%s\n' "$TARGET_MIN" "$SDK_VERSION" | sort -V | head -1)" = "$SDK_VERSION" ]; then
  LINK_TARGET="arm64-apple-macosx${TARGET_MIN}"
fi

echo "→ SDK: $(basename "$SDK")  (link target: ${LINK_TARGET#arm64-apple-})"
mkdir -p "$OUT_DIR"

# --- build stamp -------------------------------------------------------------
# The user needs to know which build is running after every edit. The stamp is a
# hash of the source tree plus its newest modification time, and the build number
# in Info.plist is bumped whenever that hash changes.
GEN_DIR="build/gen"
mkdir -p "$GEN_DIR" build

SRC_HASH=$({ find Sources -type f 2>/dev/null; echo build.sh; } \
  | sort | xargs cat 2>/dev/null | shasum -a 256 | cut -c1-8)
[ -z "$SRC_HASH" ] && SRC_HASH="unknown"

STAMP_FILE="build/stamp.txt"
PREV_HASH=""
[ -f "$STAMP_FILE" ] && PREV_HASH=$(cut -d' ' -f1 "$STAMP_FILE")

BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist 2>/dev/null || echo 1)
case "$BUILD_NUM" in ''|*[!0-9]*) BUILD_NUM=1 ;; esac

# The version is a release, not a counter: two components, read from
# Resources/Version.txt, and edited when a release is actually cut. It used to be
# bumped by this script on every source change, which is how "1.10" ended up on
# screen next to a notes list that stopped at 1.7 — the number moved, the release
# did not. Builds are numbered by CFBundleVersion; releases are named here.
#
# It is also two components only, and the minor rolls over at ten: 1.9 is followed
# by 2.0, never by 1.10. A two-digit minor reads as a third component and invites
# exactly the confusion this is meant to end.
CURRENT_SHORT=$(tr -d ' \n' < Resources/Version.txt 2>/dev/null || echo "2.0")
case "$CURRENT_SHORT" in
  [0-9]*.[0-9]|[0-9]*.[0-9][0-9])
    if [ "$(printf '%s' "$CURRENT_SHORT" | cut -d. -f2)" -ge 10 ]; then
      echo "✗ Version $CURRENT_SHORT has a two-digit minor. Use $(($(printf '%s' "$CURRENT_SHORT" | cut -d. -f1) + 1)).0." >&2
      exit 1
    fi ;;
  *) echo "✗ Resources/Version.txt must hold a version like 2.0 (got '$CURRENT_SHORT')." >&2; exit 1 ;;
esac

# A version without notes is a number with nothing behind it. That is the thing
# the changelog is supposed to prevent, so the build refuses to produce one.
if ! grep -q "(\"$CURRENT_SHORT\"," Sources/NewsRadar/Core/Version.swift; then
  echo "✗ No release notes for $CURRENT_SHORT." >&2
  echo "  Add an entry for \"$CURRENT_SHORT\" at the top of AppVersion.history in Sources/NewsRadar/Core/Version.swift." >&2
  exit 1
fi

if [ "$SRC_HASH" != "$PREV_HASH" ]; then
  BUILD_NUM=$((BUILD_NUM + 1))
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" Resources/Info.plist 2>/dev/null || true
  echo "$SRC_HASH $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STAMP_FILE"
  echo "→ Source changed: build $BUILD_NUM ($SRC_HASH)"
else
  echo "→ No source change since the last build ($SRC_HASH, build $BUILD_NUM)"
fi

SHORT_VERSION="$CURRENT_SHORT"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" Resources/Info.plist 2>/dev/null || true
echo "→ Version $SHORT_VERSION"

BUILT_AT=$(date "+%Y-%m-%d %H:%M")
cat > "$GEN_DIR/BuildStamp.swift" <<SWIFT
import Foundation

/// Generated by build.sh — do not edit. Reflects the exact source tree compiled.
enum BuildStamp {
    static let hash = "$SRC_HASH"
    static let date = "$BUILT_AT"
    static let build = "$BUILD_NUM"
    /// Written here as well as into Info.plist: the command-line binary has no
    /// bundle to read, so the version flag reported a fallback instead of the truth.
    /// (No backticks in this heredoc: it is unquoted, so they would be executed.)
    static let marketing = "$SHORT_VERSION"
}
SWIFT

SOURCES=$(find Sources "$GEN_DIR" -name '*.swift' | sort)
if [ -z "$SOURCES" ]; then
  echo "✗ No Swift sources found under Sources/." >&2
  exit 1
fi

echo "→ Compiling $(echo "$SOURCES" | wc -l | tr -d ' ') source files…"
# shellcheck disable=SC2086
swiftc \
  -target "$LINK_TARGET" -sdk "$SDK" \
  -O -whole-module-optimization \
  -o "$OUT_DIR/$BINARY_NAME" \
  $SOURCES \
  -framework SwiftUI -framework AppKit -framework Foundation \
  -framework UniformTypeIdentifiers

echo "→ Assembling bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$OUT_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
  echo "  ! Resources/AppIcon.icns missing; building without an icon."
fi
# The PNG as well as the .icns: a process started from the binary rather than by
# LaunchServices has to be able to find an image to put on its Dock tile, and
# reading a .icns back out of a bundle it just adopted is not reliable.
if [ -f Resources/AppIcon.png ]; then
  cp Resources/AppIcon.png "$APP_BUNDLE/Contents/Resources/AppIcon.png"
fi

# Ad-hoc signature so Gatekeeper opens it without ceremony.
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || echo "  (continued unsigned)"

echo "→ Running offline engine self-test…"
if "$OUT_DIR/$BINARY_NAME" --selftest > build/selftest.log 2>&1; then
  tail -2 build/selftest.log | sed 's/^/  /'
  echo "  ✓ self-test passed ($(grep -c '✓' build/selftest.log) checks)"
else
  echo "  ✗ self-test FAILED — see build/selftest.log" >&2
  grep '✗' build/selftest.log >&2 || true
  exit 1
fi

if [ "$LIVE_TEST" = "1" ]; then
  echo "→ Running live fetch test against every configured source…"
  if "$OUT_DIR/$BINARY_NAME" --livetest > build/livetest.log 2>&1; then
    grep -E '^[✓✗]' build/livetest.log | sed 's/^/  /' || true
    # A grep that finds nothing exits 1, and with `set -o pipefail` that would
    # abort the whole build even though the test just passed.
    grep -E '^Total items|^Result' build/livetest.log | sed 's/^/  /' || true
    echo "  ✓ live test passed (all sources answered)"
  else
    echo "  ! live test reported failures — see build/livetest.log" >&2
    grep -E '^✗' build/livetest.log | sed 's/^/  /' >&2 || true
    echo "  (the app handles unavailable sources, so the bundle is still usable)"
  fi
fi

echo
echo "✓ Ready: $(pwd)/$APP_BUNDLE"

if [ "$RUN_APP" = "1" ]; then
  echo "→ Launching…"
  open "$(pwd)/$APP_BUNDLE"
  sleep 2
  if pgrep -f "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" >/dev/null; then
    echo "✓ Running: $(pwd)/$APP_BUNDLE"
  else
    echo "! The process is not running; launch it manually to see the error:"
    echo "  \"$(pwd)/$APP_BUNDLE/Contents/MacOS/$BINARY_NAME\""
  fi
fi

echo
echo "  بازکردن دستی:  open \"$(pwd)/$APP_BUNDLE\""
echo "  خودآزمون:      \"$(pwd)/build/bin/$BINARY_NAME\" --selftest"
echo "  آزمون زنده:    \"$(pwd)/build/bin/$BINARY_NAME\" --livetest"
echo "  گزارش محیط:    \"$(pwd)/build/bin/$BINARY_NAME\" --probe"
