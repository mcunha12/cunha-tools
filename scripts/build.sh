#!/bin/zsh
# Builds apps into build/<CFBundleName>.app. Usage: build.sh [folder ...], e.g. build.sh tools/sound-manager. No argument builds every tool.
# ARCHS="arm64" skips the universal build. SCRATCH=<dir> gives a separate SwiftPM build folder, so parallel builds do not wait on each other.
set -euo pipefail

ROOT="${0:A:h:h}"
ARCH_LIST=(${=ARCHS:-arm64 x86_64})
SCRATCH_PATH="${SCRATCH:-$ROOT/.build}"
IDENTITY="Cunha Tools Local Signing"
cd "$ROOT"
KEYCHAIN="$("$ROOT/scripts/setup-signing.sh")"

plist_value() { /usr/libexec/PlistBuddy -c "Print $2" "$1" }

build_app() {
  local DIR="${1%/}"
  local PLIST="$ROOT/$DIR/Resources/Info.plist"
  local EXE="$(plist_value "$PLIST" CFBundleExecutable)"
  local NAME="$(plist_value "$PLIST" CFBundleName)"
  local BUNDLE_ID="$(plist_value "$PLIST" CFBundleIdentifier)"
  local APP="$ROOT/build/$NAME.app"
  local BINARIES=()
  for ARCH in $ARCH_LIST; do
    swift build -c release --scratch-path "$SCRATCH_PATH" --product "$EXE" --triple "$ARCH-apple-macosx15.0" >&2
    BINARIES+=("$(swift build -c release --scratch-path "$SCRATCH_PATH" --product "$EXE" --triple "$ARCH-apple-macosx15.0" --show-bin-path)/$EXE")
  done

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  lipo -create $BINARIES -output "$APP/Contents/MacOS/$EXE"
  cp "$PLIST" "$APP/Contents/Info.plist"
  for ITEM in "$ROOT/$DIR/Resources"/*(N); do
    [[ "${ITEM:t}" == "Info.plist" ]] || cp -R "$ITEM" "$APP/Contents/Resources/"
  done
  if [[ -x "$ROOT/$DIR/build-hook.sh" ]]; then
    "$ROOT/$DIR/build-hook.sh" "$APP" >&2
  fi
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --identifier "$BUNDLE_ID" "$APP" >&2
  echo "$APP"
}

mkdir -p "$ROOT/build"
DIRS=("$@")
if (( ${#DIRS} == 0 )); then
  DIRS=(tools/*(/N))
  DIRS=(${DIRS:#*/_*})
fi
for DIR in $DIRS; do
  build_app "$DIR"
done
