#!/bin/zsh
# Dev loop: builds one app folder, replaces its copy in /Applications and relaunches it. Usage: install.sh tools/sound-manager
set -euo pipefail

ROOT="${0:A:h:h}"
DIR="${1:?usage: install.sh <folder>}"
BUILT="$("$ROOT/scripts/build.sh" "$DIR")"
TARGET="/Applications/${BUILT:t}"
EXE="$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$BUILT/Contents/Info.plist")"

pkill -f "${BUILT:t}/Contents/MacOS/$EXE" || true
sleep 1
rm -rf "$TARGET"
cp -R "$BUILT" "$TARGET"
open "$TARGET"
echo "$TARGET"
