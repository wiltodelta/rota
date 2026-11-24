#!/bin/bash
# Build Rota (100% Rust) and assemble its signed .app bundle.
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
MACOS_MIN="15.0"

# The latest release tag, as CI builds it, so a local build never reports an
# older version than the release (which Sparkle would then offer over it).
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
if [[ -z "$VERSION" ]]; then
    [[ -n "${GITHUB_ACTIONS:-}" ]] && { echo "error: no git tag to take the version from" >&2; exit 1; }
    VERSION="0.0.0"
fi
echo "Building $APP_NAME $VERSION (release, aarch64-apple-darwin)..."

cargo build --release --target aarch64-apple-darwin -p rota-app -p rota-cli
BIN_DIR="target/aarch64-apple-darwin/release"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" \
    "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Helpers"
cp "$BIN_DIR/$BIN" "$APP_DIR/Contents/MacOS/$BIN"
cp "$BIN_DIR/rota-cli" "$APP_DIR/Contents/Helpers/rota"
ditto "Resources/Fonts" "$APP_DIR/Contents/Resources/Fonts"

SDK_STAMP="$(vtool -show-build "$APP_DIR/Contents/MacOS/$BIN" | awk '/ sdk /{print $2}')"
if ! [[ "$SDK_STAMP" =~ ^[0-9]+ ]] || (( ${SDK_STAMP%%.*} < 26 )); then
    echo "error: binary is stamped sdk $SDK_STAMP; below 26 macOS runs the pre-Tahoe look" >&2
    exit 1
fi

# Sparkle 2.10.0 binary framework verified by SHA-256.
SPARKLE_VER="2.10.0"
SPARKLE_SHA256="17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VER/Sparkle-for-Swift-Package-Manager.zip"
SPARKLE_CACHE="target/sparkle-$SPARKLE_VER"
if [[ ! -d "$SPARKLE_CACHE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" ]]; then
    mkdir -p "$SPARKLE_CACHE"
    SPARKLE_ZIP="$SPARKLE_CACHE/Sparkle.zip"
    SWIFTPM_CACHED="$HOME/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_sparkle_project_Sparkle_releases_download_2_10_0_Sparkle_for_Swift_Package_Manager_zip"
    if [[ -f "$SWIFTPM_CACHED" ]] && [[ "$(shasum -a 256 "$SWIFTPM_CACHED" | awk '{print $1}')" == "$SPARKLE_SHA256" ]]; then
        cp "$SWIFTPM_CACHED" "$SPARKLE_ZIP"
    else
        curl -fLsS "$SPARKLE_URL" -o "$SPARKLE_ZIP"
    fi
    ACTUAL_SHA="$(shasum -a 256 "$SPARKLE_ZIP" | awk '{print $1}')"
    if [[ "$ACTUAL_SHA" != "$SPARKLE_SHA256" ]]; then
        echo "error: Sparkle archive SHA-256 mismatch ($ACTUAL_SHA != $SPARKLE_SHA256)" >&2
        rm -f "$SPARKLE_ZIP"
        exit 1
    fi
    unzip -q -o "$SPARKLE_ZIP" -d "$SPARKLE_CACHE"
fi

ditto "$SPARKLE_CACHE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$BIN" 2>/dev/null || true
cp "$SPARKLE_CACHE/LICENSE" "$APP_DIR/Contents/Resources/Sparkle LICENSE.txt"

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
