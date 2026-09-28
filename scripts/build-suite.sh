#!/bin/zsh
# Builds every tool and the suite, then embeds the tools in build/Cunha Tools.app. ARCHS and SCRATCH work as in build.sh.
# The suite's Info.plist gets CunhaSourceCommit from CUNHA_SOURCE_COMMIT, else from git; the update check compares it with GitHub.
set -euo pipefail

ROOT="${0:A:h:h}"
IDENTITY="Cunha Tools Local Signing"
cd "$ROOT"
KEYCHAIN="$("$ROOT/scripts/setup-signing.sh")"

warn() { print -u2 "aviso: $*" }
plist_value() { /usr/libexec/PlistBuddy -c "Print $2" "$1" }

# Each tool builds alone (CUNHA_ONLY), so one broken tool only skips itself.
BUILT_TOOLS=()
for DIR in tools/*(/N); do
  [[ "${DIR:t}" == _* ]] && continue
  if [[ ! -f "$DIR/Resources/Info.plist" ]]; then
    warn "$DIR sem Resources/Info.plist, pulada"
    continue
  fi
  if [[ -z "$(find "$DIR/Sources" -name '*.swift' -print -quit 2>/dev/null)" ]]; then
    warn "$DIR sem código Swift, pulada"
    continue
  fi
  if APP="$(CUNHA_ONLY="$DIR" "$ROOT/scripts/build.sh" "$DIR")"; then
    BUILT_TOOLS+=("$APP")
  else
    warn "$DIR não compilou, pulada"
  fi
done

SUITE="$(CUNHA_ONLY=suite "$ROOT/scripts/build.sh" suite)"
LIBRARY="$SUITE/Contents/Library/Tools"
mkdir -p "$LIBRARY"
EMBEDDED=()
for APP in $BUILT_TOOLS; do
  TARGET="$LIBRARY/${APP:t}"
  ditto "$APP" "$TARGET"
  # build/ is shared with other builds; a copy caught mid-rebuild fails here and is dropped.
  if codesign --verify --strict "$TARGET" 2>/dev/null; then
    EMBEDDED+=("${APP:t:r}")
  else
    warn "${APP:t} com assinatura inválida após a cópia, pulada"
    rm -rf "$TARGET"
  fi
done

COMMIT="${CUNHA_SOURCE_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)}"
if [[ -n "$COMMIT" ]]; then
  plutil -replace CunhaSourceCommit -string "$COMMIT" "$SUITE/Contents/Info.plist"
else
  warn "sem commit de origem, o Checar atualizações vai oferecer atualização"
fi

# No --deep: each embedded tool keeps its own signature and identifier.
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" \
  --identifier "$(plist_value "$ROOT/suite/Resources/Info.plist" CFBundleIdentifier)" "$SUITE" >&2

print -u2 "tools embutidas (${#EMBEDDED}): ${(j:, :)EMBEDDED}"
echo "$SUITE"
