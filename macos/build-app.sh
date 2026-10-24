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

VERSION="${VERSION:-2.6.0}"
ARCHS="${ARCHS:-arm64 x86_64}"
SCRATCH="${SCRATCH:-.build}"
DIST="${DIST:-dist}"
APP="$DIST/Multicam Studio.app"

arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done

echo "Building $VERSION for: $ARCHS"
swift build -c release --scratch-path "$SCRATCH" "${arch_flags[@]}" --product MulticamStudio
swift build -c release --scratch-path "$SCRATCH" "${arch_flags[@]}" --product mcstudio
BIN="$(swift build -c release --scratch-path "$SCRATCH" "${arch_flags[@]}" --show-bin-path)"

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
