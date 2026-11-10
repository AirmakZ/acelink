#!/bin/bash
# Builds the acelinkui-engine helper (EngineHelper/, Apple's Containerization framework) and
# copies it, signed with the virtualization entitlement, into the given folder.
# Usage: scripts/build-engine-helper.sh "<App>.app/Contents/MacOS"
#
# The helper needs Apple silicon and the macOS 26 SDK. When it can't be built, the app is
# still fine: without the helper it runs the engine in Docker, as before.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?usage: $0 <destination folder>}"
# Outside the repo, which may live in iCloud Drive; SwiftPM's build folder is large.
SCRATCH="${ACELINKUI_ENGINE_BUILD_DIR:-$HOME/Library/Caches/AceLinkUI/engine-helper-build}"

if [ "$(uname -m)" != "arm64" ]; then
    echo "warning: acelinkui-engine needs Apple silicon; the app will use Docker."
    exit 0
fi

# Xcode's build phases set SDK and toolchain variables meant for the app target;
# SwiftPM must pick its own.
unset SDKROOT TOOLCHAINS MACOSX_DEPLOYMENT_TARGET

echo "Building acelinkui-engine…"
if ! swift build -c release --disable-sandbox \
    --package-path "$ROOT/EngineHelper" --scratch-path "$SCRATCH"; then
    echo "warning: Cannot build acelinkui-engine; the app will use Docker."
    exit 0
fi

mkdir -p "$DEST"
cp "$SCRATCH/release/acelinkui-engine" "$DEST/acelinkui-engine"
codesign --force --sign - --entitlements "$ROOT/EngineHelper/acelinkui-engine.entitlements" \
    "$DEST/acelinkui-engine"
echo "Copied acelinkui-engine to $DEST"
