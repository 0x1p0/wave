#!/bin/bash
# Builds a Developer ID–signed, notarized and stapled Wave.app, zipped (for when there is a Developer ID; scripts/release.sh is the current path).
#
# Needs a "Developer ID Application" certificate in your keychain and a notarytool keychain profile.
# One-time setup:
#   xcrun notarytool store-credentials wave-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#     (asks for an app-specific password from appleid.apple.com)
#
# Usage:
#   scripts/release.sh --team TEAMID [--identity "Developer ID Application: Name (TEAMID)"] [--profile wave-notary]
#   scripts/release.sh --team TEAMID --skip-notarize      # signed build only
#
# Environment equivalents: WAVE_TEAM_ID, WAVE_SIGN_IDENTITY, WAVE_NOTARY_PROFILE.
set -euo pipefail

TEAM="${WAVE_TEAM_ID:-}"
IDENTITY="${WAVE_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${WAVE_NOTARY_PROFILE:-wave-notary}"
NOTARIZE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --skip-notarize) NOTARIZE=0; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

cd "$(dirname "$0")/.."

if [ -z "$TEAM" ]; then
  echo "✗ Pass your Apple Developer Team ID with --team (or WAVE_TEAM_ID)." >&2
  exit 64
fi
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "✗ No \"Developer ID Application\" certificate in your keychain." >&2
  echo "  Create one at developer.apple.com → Certificates (needs a paid Apple Developer account)." >&2
  exit 1
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="build/release/$STAMP"
mkdir -p "$OUT"
EXPORT_OPTIONS="$OUT/ExportOptions.plist"
sed "s/__TEAM_ID__/$TEAM/" App/Support/ExportOptions.plist > "$EXPORT_OPTIONS"

echo "▶ Archiving (Release, universal, Developer ID, hardened runtime)…"
xcodebuild -project App/Wave.xcodeproj -scheme Wave -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/ReleaseDerivedData \
  -archivePath "$OUT/Wave.xcarchive" archive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" -quiet

echo "▶ Exporting…"
xcodebuild -exportArchive -archivePath "$OUT/Wave.xcarchive" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$OUT" -quiet

APP="$OUT/Wave.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow && {
  echo "✗ get-task-allow is still set; notarization would reject it." >&2; exit 1; }

if [ "$NOTARIZE" = 1 ]; then
  echo "▶ Notarizing (this usually takes a few minutes)…"
  ditto -c -k --keepParent "$APP" "$OUT/Wave-upload.zip"
  xcrun notarytool submit "$OUT/Wave-upload.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

ditto -c -k --keepParent "$APP" "$OUT/Wave.zip"
echo "✓ $OUT/Wave.zip"
