#!/bin/bash
# Cuts a release: builds the universal Mac app + signed TV APK, publishes a GitHub release and
# (optionally) updates the Homebrew cask in your tap.
#
#   ./scripts/release.sh 1.0.1                 # build, zip, publish GitHub release
#   TAP_DIR=~/Projects/homebrew-tap ./scripts/release.sh 1.0.1 --tap   # also update + push the cask
#
# Requires: gh (logged in with write access), a clean `main` that is pushed, and that the version
# in build-mac-app.sh and android/app/build.gradle.kts already equals VERSION.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release.sh VERSION [--tap]}"
UPDATE_TAP=0; [ "${2:-}" = "--tap" ] && UPDATE_TAP=1
REPO="${REPO:-austial/AustialCast}"
TAG="v$VERSION"
cd "$ROOT"

echo "Checking…"
[ -z "$(git status --porcelain)" ] || { echo "working tree is not clean"; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "not on main"; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not pushed (HEAD != origin/main)"; exit 1; }
grep -q "^VERSION=\"$VERSION\"" scripts/build-mac-app.sh || { echo "scripts/build-mac-app.sh VERSION != $VERSION"; exit 1; }
grep -q "versionName = \"$VERSION\"" android/app/build.gradle.kts || { echo "android versionName != $VERSION"; exit 1; }
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && { echo "release $TAG already exists"; exit 1; }

./scripts/build-mac-app.sh
./scripts/build-tv-apk.sh

STAGE="$(mktemp -d)"
cp -R dist/AustialCast.app "$STAGE/"
cp dist/AustialCast-TV.apk "$STAGE/"
ZIP="$ROOT/dist/AustialCast.zip"
rm -f "$ZIP"
ditto -c -k --norsrc "$STAGE" "$ZIP"      # zip root: AustialCast.app + AustialCast-TV.apk (what the cask expects)
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$SHA  AustialCast.zip" > dist/SHA256SUMS
( cd dist && shasum -a 256 AustialCast-TV.apk >> SHA256SUMS )
unzip -l "$ZIP" | grep -E "AustialCast.app/Contents/MacOS/AustialCast$|AustialCast-TV.apk" >/dev/null || { echo "unexpected zip layout"; exit 1; }
echo "zip sha256: $SHA"

NOTES="$(mktemp)"
cat > "$NOTES" <<NOTES_EOF
## Install

**Mac (Homebrew):**
\`\`\`bash
brew install --cask aayushsolanki40/tap/austialcast
\`\`\`

**TV (Android TV / Google TV, via adb):**
\`\`\`bash
brew install --cask android-platform-tools
adb connect <tv-ip>:5555
adb install -r "\$(brew --prefix)/share/austialcast/AustialCast-TV.apk"
\`\`\`
Or download \`AustialCast-TV.apk\` below and sideload it. See the [README](https://github.com/$REPO#readme).

- \`AustialCast.zip\` — universal macOS app (Apple silicon + Intel, macOS 14+) and the TV APK
- \`AustialCast-TV.apk\` — signed Android TV app
- \`SHA256SUMS\` — checksums
NOTES_EOF

gh release create "$TAG" -R "$REPO" --target "$(git rev-parse HEAD)" --title "AustialCast $VERSION" --notes-file "$NOTES" \
  "$ZIP" dist/AustialCast-TV.apk dist/SHA256SUMS
echo "Released: https://github.com/$REPO/releases/tag/$TAG"

if [ $UPDATE_TAP -eq 1 ]; then
  : "${TAP_DIR:?set TAP_DIR to your homebrew tap checkout}"
  CASK="$TAP_DIR/Casks/austialcast.rb"
  [ -f "$CASK" ] || { echo "cask not found: $CASK (create it once by hand, then this script keeps it updated)"; exit 1; }
  sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  ( cd "$TAP_DIR" && git add Casks/austialcast.rb && git commit -q -m "austialcast $VERSION" && git push -q origin HEAD )
  echo "Cask updated and pushed: austialcast $VERSION"
fi
