#!/bin/bash
# Builds the styled install DMG: dark background, drag arrow, and the Applications drop link.
# Signing is left to the caller.
#
# Usage: scripts/make-dmg.sh <path/to/Prompter.app> <output.dmg>
# create-dmg lays the window out through Finder, so this needs a logged-in session; macOS
# asks once to let the calling app control Finder.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <path/to/Prompter.app> <output.dmg>" >&2; exit 64; }
APP="$1"
OUT="$2"
command -v create-dmg >/dev/null || { echo "error: create-dmg is missing. Run: brew install create-dmg" >&2; exit 1; }
[[ -d "$APP" ]] || { echo "error: no app at $APP" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Window layout in Finder points. The background art is drawn from the same numbers.
WIDTH=660
HEIGHT=400
APP_X=170
APPS_X=490
ICON_Y=200
TITLE_BAR=32 # Finder's window bounds include the title bar.

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/src"
cp -R "$APP" "$TMP/src/Prompter.app"

swift "$ROOT/scripts/generate-art.swift" dmg-background "$TMP/art" "$WIDTH" "$HEIGHT" "$APP_X" "$APPS_X" "$ICON_Y"
tiffutil -cathidpicheck "$TMP/art/background.png" "$TMP/art/background@2x.png" -out "$TMP/background.tiff"

# Build inside TMP so a failed run leaves nothing at OUT.
create-dmg \
    --volname "Prompter" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$TMP/background.tiff" \
    --window-pos 200 120 \
    --window-size "$WIDTH" "$((HEIGHT + TITLE_BAR))" \
    --icon-size 112 \
    --text-size 13 \
    --icon "Prompter.app" "$APP_X" "$ICON_Y" \
    --hide-extension "Prompter.app" \
    --app-drop-link "$APPS_X" "$ICON_Y" \
    --hdiutil-quiet \
    "$TMP/Prompter.dmg" "$TMP/src"

mkdir -p "$(dirname "$OUT")"
mv -f "$TMP/Prompter.dmg" "$OUT"
echo "Styled DMG: $OUT"
