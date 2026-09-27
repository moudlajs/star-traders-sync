#!/bin/bash
#
# Builds "Star Traders Sync Setup.app" and a .dmg around it, with the
# current bin/star-traders-sync bundled inside.
#
#   macos/build-app.sh            universal (arm64 + x86_64), needs Xcode
#   macos/build-app.sh --native   this Mac's architecture only, faster
#
# Output goes to macos/build/. The app is ad-hoc signed, not notarized
# (#61), so the first launch needs Privacy & Security > Open Anyway.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build"
NAME="Star Traders Sync Setup"
APP="$OUT/$NAME.app"
DMG="$OUT/Star-Traders-Sync-Setup.dmg"

ARCHS=(--arch arm64 --arch x86_64)
[ "${1:-}" = "--native" ] && ARCHS=()

VERSION="$(grep -oE '^readonly STS_VERSION="[^"]+"' "$REPO/bin/star-traders-sync" | cut -d'"' -f2)"
[ -n "$VERSION" ] || { echo "error: could not read STS_VERSION" >&2; exit 1; }

echo "building $NAME $VERSION"
swift build -c release --package-path "$HERE" ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release --package-path "$HERE" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/STSSetup" "$APP/Contents/MacOS/STSSetup"
cp "$REPO/bin/star-traders-sync" "$APP/Contents/Resources/star-traders-sync"
cp "$REPO/config.example" "$APP/Contents/Resources/config.example"
chmod 755 "$APP/Contents/Resources/star-traders-sync"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>STSSetup</string>
    <key>CFBundleIdentifier</key>          <string>com.github.moudlajs.star-traders-sync.setup</string>
    <key>CFBundleName</key>                <string>$NAME</string>
    <key>CFBundleDisplayName</key>         <string>$NAME</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc: required for arm64 to run at all, and seals the bundled script
# so a modified copy is refused rather than run.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "app: $APP"
echo "dmg: $DMG"
