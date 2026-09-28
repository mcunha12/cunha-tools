#!/bin/zsh
# Packs build/Cunha Tools.app into build/CunhaTools-<version>.dmg with an Aplicativos shortcut and dist/Como instalar.txt. Run build-suite.sh first.
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/Cunha Tools.app"
if [[ ! -d "$APP" ]]; then
  print -u2 "erro: $APP não existe. Rode scripts/build-suite.sh antes."
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/CunhaTools-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/Cunha Tools.app"
ln -s /Applications "$STAGE/Aplicativos"
cp "$ROOT/dist/Como instalar.txt" "$STAGE/Como instalar.txt"

rm -f "$DMG"
hdiutil create -volname "Cunha Tools" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
echo "$DMG"
