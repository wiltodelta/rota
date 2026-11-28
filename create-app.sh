#!/bin/bash
# Build Rota (native SwiftUI/AppKit Tahoe UI + Rust engine) and assemble its signed .app bundle.
#   ./create-app.sh              everyday build (Developer ID when available, no timestamp)
#   RELEASE=1 ./create-app.sh    release build: Developer ID with a secure timestamp
# Only a release build is com.wiltodelta.rota. Every other build is
# com.wiltodelta.rota.dev, a separate app with its own data ("Rota Dev"),
# defaults and notifications that runs beside the installed Rota, so building
# and checking never touch the copy someone relies on.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

APP_NAME="Rota"
if [[ "${RELEASE:-}" == 1 ]]; then
    BUNDLE_ID="com.wiltodelta.rota"; DISPLAY_NAME="Rota"; UPDATE_CHECKS="true"
else
    BUNDLE_ID="com.wiltodelta.rota.dev"; DISPLAY_NAME="Rota Dev"; UPDATE_CHECKS="false"
fi
APP_DIR="$APP_NAME.app"
BIN="Rota"

VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
if [[ -z "$VERSION" ]]; then
    [[ -n "${GITHUB_ACTIONS:-}" ]] && { echo "error: no git tag to take the version from" >&2; exit 1; }
    VERSION="0.0.0"
fi
echo "Building $APP_NAME $VERSION (release, arm64)..."

cargo build --release --target aarch64-apple-darwin -p rota-ffi -p rota-cli
RUST_BIN_DIR="target/aarch64-apple-darwin/release"
mkdir -p target/swift-ffi
cp "$RUST_BIN_DIR/librota_ffi.a" target/swift-ffi/librota_ffi.a

MACOS_MIN="$(sed -n 's/^let deploymentTarget = "\(.*\)"$/\1/p' Package.swift)"
swift build -c release --arch arm64 --disable-automatic-resolution --product Rota
SWIFT_BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" \
    "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Helpers"
cp "$SWIFT_BIN_DIR/$BIN" "$APP_DIR/Contents/MacOS/$BIN"
cp "$RUST_BIN_DIR/rota-cli" "$APP_DIR/Contents/Helpers/rota"
ditto "$SWIFT_BIN_DIR/Rota_Rota.bundle" "$APP_DIR/Contents/Resources/Rota_Rota.bundle"

SDK_STAMP="$(vtool -show-build "$APP_DIR/Contents/MacOS/$BIN" | awk '/ sdk /{print $2}')"
if ! [[ "$SDK_STAMP" =~ ^[0-9]+ ]] || (( ${SDK_STAMP%%.*} < 26 )); then
    echo "error: binary is stamped sdk $SDK_STAMP; below 26 macOS runs the pre-Tahoe look" >&2
    exit 1
fi

ditto "$SWIFT_BIN_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$BIN" 2>/dev/null || true
cp ".build/artifacts/sparkle/Sparkle/LICENSE" "$APP_DIR/Contents/Resources/Sparkle LICENSE.txt"

PARTIAL_PLIST="$(mktemp -t rota-icon)"
trap 'rm -f "$PARTIAL_PLIST"' EXIT
xcrun actool "$PWD/App Icon.icon" "$PWD/MenuIcons.xcassets" "$PWD/HarnessLogos.xcassets" \
    --compile "$PWD/$APP_DIR/Contents/Resources" \
    --platform macosx --minimum-deployment-target "$MACOS_MIN" --app-icon "App Icon" \
    --output-partial-info-plist "$PARTIAL_PLIST" >/dev/null
ICON_PLIST="	<key>CFBundleIconFile</key>
	<string>App Icon</string>
	<key>CFBundleIconName</key>
	<string>App Icon</string>"

cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$BIN</string>
${ICON_PLIST:+$ICON_PLIST
}	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$DISPLAY_NAME</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright 2026 Victor Kuznetsov. Licensed under Apache-2.0.</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MACOS_MIN</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>SUFeedURL</key>
	<string>https://github.com/wiltodelta/rota/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>hqKKidqlpRpssnvj1i6i1qY+jYdPjjDKIZHFyOxyGhc=</string>
	<key>SUEnableAutomaticChecks</key>
	<$UPDATE_CHECKS/>
	<key>SURequireSignedFeed</key>
	<true/>
	<key>SUVerifyUpdateBeforeExtraction</key>
	<true/>
</dict>
</plist>
EOF
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

TEAM_ID="K2GT9Q4S6U"
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v team="($TEAM_ID)" '/Developer ID Application:/ && index($2, team) {print $2; exit}')"
if [[ -n "$SIGN_IDENTITY" ]]; then
    TIMESTAMP="--timestamp=none"
    [[ "${RELEASE:-}" == 1 ]] && TIMESTAMP="--timestamp"
    SIGN=(codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY")
elif [[ "${RELEASE:-}" == 1 ]]; then
    echo "error: RELEASE=1 but no Developer ID Application identity for team $TEAM_ID" >&2
    exit 1
else
    echo "warning: no Developer ID Application identity, signing ad hoc"
    SIGN=(codesign --force --sign -)
fi

SPARKLE="$APP_DIR/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" --identifier com.wiltodelta.rota.cli "$APP_DIR/Contents/Helpers/rota"
"${SIGN[@]}" "$APP_DIR"

echo "Done: $PWD/$APP_DIR"
echo "Launch with: open \"$PWD/$APP_DIR\""
