#!/bin/bash
# Builds "AceLinkUI.app" with only the Xcode Command Line Tools (no full Xcode needed).
# Usage: scripts/build-app.sh            -> build/AceLinkUI.app
#        scripts/build-app.sh --install  -> also copies it to /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/AceLinkUI"
OUT="$ROOT/build"
APP="$OUT/AceLinkUI.app"
VERSION="$(cat "$ROOT/VERSION")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
find "$SRC" -name '*.swift' -print0 | xargs -0 swiftc \
    -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -module-name AceLinkUI \
    -o "$APP/Contents/MacOS/AceLinkUI"

echo "Writing Info.plist…"
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' \
    -e 's/$(EXECUTABLE_NAME)/AceLinkUI/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/io.github.airmakz.acelinkui/' \
    -e 's/$(PRODUCT_NAME)/AceLinkUI/' \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$VERSION/" \
    -e 's/$(MACOSX_DEPLOYMENT_TARGET)/13.0/' \
    "$SRC/Info.plist" > "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleIconFile -string "AppIcon" "$APP/Contents/Info.plist"

echo "Copying images…"
# Without actool, ship each image set as a loose PNG so NSImage(named:) still finds it.
for set in "$SRC/Assets.xcassets"/StatusBarIcon*.imageset; do
    name="$(basename "$set" .imageset)"
    png="$(find "$set" -name '*.png' | head -1)"
    [ -n "$png" ] && cp "$png" "$APP/Contents/Resources/$name.png"
done

ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC/Assets.xcassets/AppIcon.appiconset/icon.png" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SRC/Assets.xcassets/AppIcon.appiconset/icon.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Runs the engine in a VM on macOS 26 instead of Docker (see EngineHelper/).
"$ROOT/scripts/build-engine-helper.sh" "$APP/Contents/MacOS"

echo "Signing (ad-hoc)…"
codesign --force --sign - --entitlements "$SRC/AceLinkUI.entitlements" "$APP"

echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/AceLinkUI.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/AceLinkUI.app"
fi
