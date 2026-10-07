#!/bin/bash
#
# Builds "Star Traders Sync.app" and a .dmg around it, with the
# current bin/star-traders-sync and the Go build bundled inside, behind
# the engine shim (#175).
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
NAME="Star Traders Sync"
APP="$OUT/$NAME.app"
DMG="$OUT/Star-Traders-Sync.dmg"

ARCHS=(--arch arm64 --arch x86_64)
[ "${1:-}" = "--native" ] && ARCHS=()

# Say what is missing before a toolchain says it less clearly (#180).
# Nobody needs to build to use the app: the release has the dmg.
need() {
    printf 'error: %s\n' "$1" >&2
    printf 'To just install the app, no build is needed: download Star-Traders-Sync.dmg from\n' >&2
    printf '  https://github.com/moudlajs/star-traders-sync/releases/latest\n' >&2
    exit 1
}
# A universal build goes through xcbuild, which ships only with Xcode.
case "${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}" in
    *CommandLineTools*)
        [ ${#ARCHS[@]} -eq 0 ] || need "a universal build needs Xcode, and this Mac has only the Command Line Tools.
Build for this Mac only instead:  $0 --native" ;;
esac
command -v go >/dev/null 2>&1 || need "Go is needed to build the Go engine (brew install go)."

# `|| true`: under pipefail a failed grep would abort here, before the
# friendlier message below could say what went wrong.
VERSION="$(grep -oE '^readonly STS_VERSION="[^"]+"' "$REPO/bin/star-traders-sync" | cut -d'"' -f2 || true)"
[ -n "$VERSION" ] || { echo "error: could not read STS_VERSION" >&2; exit 1; }

echo "building $NAME $VERSION"
swift build -c release --package-path "$HERE" ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release --package-path "$HERE" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The icon is drawn by code (macos/icon/make-icon.swift) on every build,
# so there is no binary design file to drift from the source.
swift "$HERE/icon/make-icon.swift" "$OUT/icon" >/dev/null
cp "$OUT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/STSSetup" "$APP/Contents/MacOS/STSSetup"
# The tool is three files (#175): the engine shim every caller runs by its
# old name, the script, and the Go build. The shim picks one.
RES="$APP/Contents/Resources"
sed "s/@STS_VERSION@/$VERSION/" "$HERE/engine-shim.sh" > "$RES/star-traders-sync"
cp "$REPO/bin/star-traders-sync" "$RES/star-traders-sync.bash"
GOARCHS=(arm64 amd64)
[ "${1:-}" = "--native" ] && GOARCHS=("$(go env GOARCH)")
thin=()
for a in "${GOARCHS[@]}"; do
    (cd "$REPO" && CGO_ENABLED=0 GOOS=darwin GOARCH="$a" go build -trimpath -o "$OUT/sts-go-$a" ./cmd/sts)
    thin+=("$OUT/sts-go-$a")
done
lipo -create -output "$RES/star-traders-sync-go" "${thin[@]}"
rm -f "${thin[@]}"
codesign --force --sign - "$RES/star-traders-sync-go"
cp "$REPO/config.example" "$RES/config.example"
chmod 755 "$RES/star-traders-sync" "$RES/star-traders-sync.bash" "$RES/star-traders-sync-go"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>STSSetup</string>
    <key>CFBundleIdentifier</key>          <string>com.github.moudlajs.star-traders-sync</string>
    <key>CFBundleName</key>                <string>$NAME</string>
    <key>CFBundleDisplayName</key>         <string>$NAME</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundleIconName</key>            <string>AppIcon</string>
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
