#!/bin/bash
# Builds a signed release of Agent HUD. See docs/DISTRIBUTION.md for the one-time setup.
#
#   scripts/release.sh direct              Developer ID: sign, notarize, staple, DMG → build/dist/
#   scripts/release.sh appstore            Sandboxed Mac App Store build → build/dist/*.pkg
#   scripts/release.sh appstore --upload   …and upload it to App Store Connect (it lands in TestFlight)
#
# Environment: VERSION (default: Info.plist), BUILD_NUMBER (default: yyMMddHHmm, always increasing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FLAVOR="${1:-}"
UPLOAD="${2:-}"
[[ "$FLAVOR" == "direct" || "$FLAVOR" == "appstore" ]] || { sed -n '2,8p' "$0"; exit 1; }

CONFIG="Distribution/config.env"
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG: copy Distribution/config.env.example and fill it in." >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
[[ "${TEAM_ID:-XXXXXXXXXX}" != "XXXXXXXXXX" ]] || { echo "Set TEAM_ID in $CONFIG." >&2; exit 1; }

PLIST=/usr/libexec/PlistBuddy
VERSION="${VERSION:-$($PLIST -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%y%m%d%H%M)}"
OUT="build/$FLAVOR"
APP="$OUT/AgentHUD.app"
DIST="build/dist"
mkdir -p "$DIST"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Building universal release ($VERSION, build $BUILD_NUMBER)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

step "Assembling $APP"
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/AgentHUD" "$BIN/agenthud-report" "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
$PLIST -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
$PLIST -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PLIST -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

entitlements() { # template → filled-in copy
    local out="$OUT/$(basename "$1")"
    sed -e "s/__TEAM_ID__/$TEAM_ID/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" "$1" > "$out"
    echo "$out"
}

if [[ "$FLAVOR" == "direct" ]]; then
    ENT="$(entitlements Distribution/entitlements/direct.entitlements)"
    step "Signing with $DEVELOPER_ID_APP (hardened runtime)"
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APP" \
        --identifier "$BUNDLE_ID.reporter" "$APP/Contents/MacOS/agenthud-report"
    codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID_APP" --entitlements "$ENT" "$APP"
    codesign --verify --strict --deep "$APP"

    step "Building the DMG"
    DMG="$DIST/AgentHUD-$VERSION.dmg"
    STAGE="$OUT/dmg" && rm -rf "$STAGE" && mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Agent HUD" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG"

    step "Notarizing (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" || true
    step "Done: $DMG"
    exit 0
fi

# --- App Store ---------------------------------------------------------------------
[[ -f "$APPSTORE_PROFILE" ]] || { echo "Missing provisioning profile at $APPSTORE_PROFILE." >&2; exit 1; }
$PLIST -c "Add :AgentHUDAppGroup string $TEAM_ID.$BUNDLE_ID" "$APP/Contents/Info.plist"
cp "$APPSTORE_PROFILE" "$APP/Contents/embedded.provisionprofile"
APP_ENT="$(entitlements Distribution/entitlements/appstore-app.entitlements)"
REP_ENT="$(entitlements Distribution/entitlements/appstore-reporter.entitlements)"

step "Signing with $APPSTORE_APP_IDENTITY (App Sandbox)"
codesign --force --timestamp --sign "$APPSTORE_APP_IDENTITY" --identifier "$BUNDLE_ID.reporter" \
    --entitlements "$REP_ENT" "$APP/Contents/MacOS/agenthud-report"
codesign --force --timestamp --sign "$APPSTORE_APP_IDENTITY" --entitlements "$APP_ENT" "$APP"
codesign --verify --strict --deep "$APP"
codesign -d --entitlements - "$APP" >/dev/null

step "Packaging"
PKG="$DIST/AgentHUD-$VERSION-$BUILD_NUMBER.pkg"
productbuild --component "$APP" /Applications --sign "$APPSTORE_INSTALLER_IDENTITY" "$PKG"

if [[ "$UPLOAD" == "--upload" ]]; then
    step "Validating with App Store Connect"
    xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    step "Uploading (it appears in TestFlight after processing, usually 10–30 min)"
    xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
fi
step "Done: $PKG"
