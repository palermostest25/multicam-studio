#!/bin/bash
# Build "Multicam Studio.app" (native, universal) and a DMG.
#
#   ./build-app.sh                  # ad-hoc signed app + DMG in macos/dist
#   SIGN_IDENTITY="Developer ID Application: …" ./build-app.sh
#   ARCHS=arm64 ./build-app.sh      # Apple silicon only (faster build)
#
# Needs Xcode (or the Command Line Tools with a macOS 14+ SDK).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-2.8.0}"
ARCHS="${ARCHS:-arm64 x86_64}"
SCRATCH="${SCRATCH:-.build}"
DIST="${DIST:-dist}"
APP="$DIST/Multicam Studio.app"

echo "Building $VERSION for: $ARCHS"
arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done
if swift build -c release --scratch-path "$SCRATCH" "${arch_flags[@]}" --product MulticamStudio \
   && swift build -c release --scratch-path "$SCRATCH" "${arch_flags[@]}" --product mcstudio; then
    BIN="$(swift build -c release --scratch-path "$SCRATCH" "${arch_flags[@]}" --show-bin-path)"
else
    # Command Line Tools only: one build per architecture, joined with lipo. Record SDK 14 like the
    # Xcode build does: linking against a newer SDK turns on SwiftUI split-view behaviour that
    # aborted the app at launch (update-constraints loop).
    BIN="$SCRATCH/universal"
    mkdir -p "$BIN"
    for product in MulticamStudio mcstudio; do
        slices=()
        for a in $ARCHS; do
            swift build -c release --scratch-path "$SCRATCH/$a" --arch "$a" --product "$product" \
                -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker 14.0
            slices+=("$(swift build -c release --scratch-path "$SCRATCH/$a" --arch "$a" --show-bin-path)/$product")
        done
        lipo -create "${slices[@]}" -output "$BIN/$product"
    done
fi
# Never ship a build that links a newer SDK (see above).
otool -arch arm64 -l "$BIN/MulticamStudio" | grep -A4 LC_BUILD_VERSION | grep -q "sdk 14.0" || { echo "error: app links a newer SDK"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/MulticamStudio" "$APP/Contents/MacOS/Multicam Studio"
cp "$BIN/mcstudio" "$APP/Contents/Helpers/mcstudio"
cp ../packaging/MulticamStudio.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${SIGN_IDENTITY:--}"
echo "Signing with: $IDENTITY"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP/Contents/Helpers/mcstudio"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

DMG="$DIST/Multicam-Studio-$VERSION-macOS.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Multicam Studio $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Done: $APP"
echo "      $DMG"
