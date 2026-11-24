#!/bin/zsh
# Builds the public downloads into release/:
#   Wave-<version>-macos-universal.dmg   the installer (drag Wave into Applications)
#   Wave-<version>-macos-universal.zip   the same app, zipped
#   Wave.dmg                             the same installer by a name that never changes, so
#                                        …/releases/latest/download/Wave.dmg is always the newest
#   SHA256SUMS.txt                       checksums
# The version is MARKETING_VERSION in the Xcode project. The app is universal (Apple silicon and Intel) and signed
# with the release identity ("Wave Release Signing", which names no one), so installed copies keep their microphone
# and Accessibility permissions across updates. It isn't notarized (no Developer ID yet): the first launch of a fresh
# download needs System Settings → Privacy & Security → Open Anyway. scripts/release-notarized.sh is the Developer ID
# path for when there is one.
#
# usage: scripts/release.sh
#   WAVE_P12 / WAVE_P12_PASSWORD: the release identity (default: ~/.wave-signing/)
#   DMGBUILD: the dmgbuild command (default: dmgbuild; `pip install dmgbuild`)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
V=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' App/Wave.xcodeproj/project.pbxproj | head -1)
ID="Wave Release Signing"

DMGBUILD="${DMGBUILD:-dmgbuild}"
if ! command -v "$DMGBUILD" > /dev/null; then
  echo "dmgbuild is missing (it lays out the installer window): pip install dmgbuild"
  exit 1
fi

# The release identity, from a throwaway keychain.
P12="${WAVE_P12:-$HOME/.wave-signing/wave-mac-signing.p12}"
P12_PW="${WAVE_P12_PASSWORD:-$(cat "$HOME/.wave-signing/p12-password.txt" 2>/dev/null || true)}"
if [[ ! -f "$P12" || -z "$P12_PW" ]]; then
  echo "The release identity is missing ($P12)."
  exit 1
fi
KC="$(mktemp -d)/release.keychain-db"
KC_PW=$(uuidgen)
# codesign only finds identities in keychains on the search list: add this one for the build, then put the list back.
KEYCHAINS=("${(@f)$(security list-keychains -d user | tr -d '" ')}")
security create-keychain -p "$KC_PW" "$KC"
trap 'security list-keychains -d user -s "${KEYCHAINS[@]}"; security delete-keychain "$KC" 2>/dev/null || true' EXIT
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KC_PW" "$KC"
security list-keychains -d user -s "$KC" "${KEYCHAINS[@]}"
security import "$P12" -k "$KC" -P "$P12_PW" -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC" > /dev/null
security find-identity -p codesigning "$KC" | grep -q "$ID" || { echo "The release identity didn't import."; exit 1; }

echo "▶ Building Wave $V (Release, universal)…"
DERIVED=build/ReleaseDerivedData
rm -rf "$DERIVED/Build/Products/Release/Wave.app"
xcodebuild -project App/Wave.xcodeproj -scheme Wave -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" build ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  -quiet 2>&1 | { grep -v 'IDERunDestination: Supported platforms' || true; }
APP="$DERIVED/Build/Products/Release/Wave.app"

echo "▶ Signing with $ID…"
# Inside out: anything nested first, then the app with its entitlements and the hardened runtime.
find "$APP/Contents" -depth \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" -o -name "*.xpc" \) -print0 2>/dev/null |
  while IFS= read -r -d '' nested; do
    codesign --force --options runtime --timestamp=none --keychain "$KC" --sign "$ID" "$nested"
  done
codesign --force --options runtime --timestamp=none --keychain "$KC" --sign "$ID" \
  --entitlements App/Support/Wave.entitlements "$APP"
codesign --verify --deep --strict "$APP"
codesign -dr - "$APP" 2>&1 | grep -q "identifier \"local.wave.Wave\"" || { echo "Unexpected signature."; exit 1; }
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow && { echo "get-task-allow is set."; exit 1; }
ARCHS=$(lipo -archs "$APP/Contents/MacOS/Wave")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "Not universal: $ARCHS"; exit 1; }

OUT=release
rm -rf "$OUT"
mkdir -p "$OUT"
NAME="Wave-$V-macos-universal"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"

echo "▶ Building the installer…"
BG="$(mktemp -d)/background.tiff"
tiffutil -cathidpicheck App/Support/dmg/background.png App/Support/dmg/background@2x.png -out "$BG" > /dev/null
"$DMGBUILD" -s App/Support/dmg/settings.py -D app="$APP" -D background="$BG" Wave "$OUT/$NAME.dmg" > /dev/null
codesign --force --timestamp=none --keychain "$KC" --sign "$ID" "$OUT/$NAME.dmg"
cp "$OUT/$NAME.dmg" "$OUT/Wave.dmg"
(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" Wave.dmg > SHA256SUMS.txt)

echo
ls -lh "$OUT"
echo
echo "Publish:  gh release create v$V $OUT/$NAME.dmg $OUT/$NAME.zip $OUT/Wave.dmg $OUT/SHA256SUMS.txt --title \"Wave $V\" --notes-file NOTES.md"
