#!/bin/bash
# Builds a Developer ID–signed release, notarizes it, and produces a stapled, styled DMG at build/Prompter.dmg.
#
# Requires:
#   NOTARY_PROFILE     a keychain profile created with:
#                      xcrun notarytool store-credentials <profile> --apple-id … --team-id …
# Optional:
#   DEVELOPMENT_TEAM   Apple Developer team ID (default: 728M4WMSGG)
set -euo pipefail

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-728M4WMSGG}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"

# Sign by certificate hash: the bare name "Developer ID Application" matches any team's certificate.
IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' -v team="($DEVELOPMENT_TEAM)" '$2 ~ /^Developer ID Application: / && index($2, team) { split($1, f, " "); print f[2] }' \
    | sort -u)"
if [[ -z "$IDENTITY" || "$IDENTITY" == *$'\n'* ]]; then
    echo "error: need exactly one valid 'Developer ID Application: … ($DEVELOPMENT_TEAM)' identity in the keychain" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/Prompter.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Prompter.app"
DMG="$ROOT/build/Prompter.dmg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$ROOT"
xcodegen generate --quiet

rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project Prompter.xcodeproj -scheme Prompter -configuration Release \
    -derivedDataPath "$BUILD" \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    archive

cat > "$TMP/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$TMP/ExportOptions.plist"

codesign --verify --deep --strict --verbose=2 "$APP"

scripts/make-dmg.sh "$APP" "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
spctl --assess --type exec --verbose "$APP"
echo "Notarized DMG: $DMG"
