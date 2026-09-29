#!/bin/zsh
# Puts the official scrcpy-server (pinned version and SHA-256) into the app bundle. Usage: build-hook.sh <app>
set -euo pipefail

VERSION="4.1"
SHA256="deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae"
URL="https://github.com/Genymobile/scrcpy/releases/download/v$VERSION/scrcpy-server-v$VERSION"

ROOT="${0:A:h:h:h}"
APP="${1:?usage: build-hook.sh <app>}"
CACHE="$ROOT/.build/downloads"
FILE="$CACHE/scrcpy-server-v$VERSION"

checksum() { shasum -a 256 "$1" | cut -d' ' -f1 }

mkdir -p "$CACHE"
if [[ ! -f "$FILE" || "$(checksum "$FILE")" != "$SHA256" ]]; then
  curl -fsSL --retry 3 -o "$FILE.part" "$URL"
  if [[ "$(checksum "$FILE.part")" != "$SHA256" ]]; then
    rm -f "$FILE.part"
    echo "scrcpy-server v$VERSION: SHA-256 não confere" >&2
    exit 1
  fi
  mv "$FILE.part" "$FILE"
fi
cp "$FILE" "$APP/Contents/Resources/scrcpy-server"
