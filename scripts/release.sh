#!/bin/bash
# Publishes a release of Agent HUD for Homebrew. See docs/RELEASING.md.
#
#   scripts/release.sh 1.2.0            build, tag, GitHub Release, update the tap
#   scripts/release.sh 1.2.0 --dry-run  build the zip and the cask into build/, publish nothing
#
# Environment: REPO (default KylerHil/agent-hud), TAP (default KylerHil/homebrew-tap).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-}"
DRY="${2:-}"
REPO="${REPO:-KylerHil/agent-hud}"
TAP="${TAP:-KylerHil/homebrew-tap}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { sed -n '2,8p' "$0"; exit 1; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

if [[ "$DRY" != "--dry-run" ]]; then
    gh auth status >/dev/null 2>&1 || die "run 'gh auth login' first"
    [[ -z "$(git status --porcelain)" ]] || die "commit or stash your changes first"
    [[ "$(git branch --show-current)" == "main" ]] || die "release from main"
    git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "tag v$VERSION already exists"
    step "Running tests"
    swift test 2>&1 | tail -1
fi

PLIST=/usr/libexec/PlistBuddy
# Build numbers only need to increase; the commit count does.
BUILD_NUMBER="$(( $(git rev-list --count HEAD) + 1 ))"
if [[ "$DRY" != "--dry-run" && "$($PLIST -c 'Print :CFBundleShortVersionString' Resources/Info.plist)" != "$VERSION" ]]; then
    $PLIST -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
    $PLIST -c "Set :CFBundleVersion $BUILD_NUMBER" Resources/Info.plist
    git commit -qm "Release $VERSION" Resources/Info.plist
fi

step "Building universal release $VERSION"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|Compiling|Build complete" | tail -3
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
OUT="build/release"
APP="$OUT/AgentHUD.app"
rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
$PLIST -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PLIST -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$BIN/AgentHUD" "$BIN/agenthud-report" "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
# Ad-hoc signed: enough for Apple silicon to run it; the cask clears the download quarantine.
codesign --force --sign - --identifier com.xeratec.agenthud.reporter "$APP/Contents/MacOS/agenthud-report"
codesign --force --sign - "$APP"
codesign --verify --strict --deep "$APP"

ZIP="$OUT/AgentHUD-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" packaging/agent-hud.rb > "$OUT/agent-hud.rb"
echo "zip:  $ZIP"
echo "sha:  $SHA"

if [[ "$DRY" == "--dry-run" ]]; then
    step "Dry run: nothing published. Cask written to $OUT/agent-hud.rb"
    exit 0
fi

step "Tagging v$VERSION and publishing the GitHub Release"
git tag -a "v$VERSION" -m "Agent HUD $VERSION"
git push -q origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Agent HUD $VERSION" --generate-notes

step "Updating the Homebrew tap ($TAP)"
TAPDIR="build/homebrew-tap"
rm -rf "$TAPDIR"
gh repo clone "$TAP" "$TAPDIR" -- -q
mkdir -p "$TAPDIR/Casks"
cp "$OUT/agent-hud.rb" "$TAPDIR/Casks/agent-hud.rb"
git -C "$TAPDIR" add Casks/agent-hud.rb
git -C "$TAPDIR" commit -qm "agent-hud $VERSION"
git -C "$TAPDIR" push -q

step "Released. Install or update with:"
echo "  brew install --cask kylerhil/tap/agent-hud"
echo "  brew upgrade --cask agent-hud"
