#!/bin/zsh
# Builds every tool, the Android companion and the suite, then embeds them in build/Cunha Tools.app. ARCHS and SCRATCH work as in build.sh; SKIP_ANDROID=1 skips the APK.
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

APK=""
if [[ "${SKIP_ANDROID:-0}" == "1" ]]; then
  warn "SKIP_ANDROID=1, suíte sem o app companheiro"
elif [[ ! -f android/build.sh ]]; then
  warn "android/build.sh não existe, suíte sem o app companheiro"
elif [[ ! -x android/build.sh ]]; then
  warn "android/build.sh sem permissão de execução, suíte sem o app companheiro"
elif "$ROOT/android/build.sh" >&2 && [[ -f build/android/cunha-companion.apk ]]; then
  APK="$ROOT/build/android/cunha-companion.apk"
else
  warn "android/build.sh falhou, suíte sem o app companheiro"
fi

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
if [[ -n "$APK" ]]; then
  mkdir -p "$SUITE/Contents/Resources/Android"
  cp "$APK" "$SUITE/Contents/Resources/Android/cunha-companion.apk"
fi

COMMIT="${CUNHA_SOURCE_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)}"
if [[ -n "$COMMIT" ]]; then
  plutil -replace CunhaSourceCommit -string "$COMMIT" "$SUITE/Contents/Info.plist"
else
  warn "sem commit de origem, o Atualizar vai oferecer atualização"
fi

# No --deep: each embedded tool keeps its own signature and identifier.
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" \
  --identifier "$(plist_value "$ROOT/suite/Resources/Info.plist" CFBundleIdentifier)" "$SUITE" >&2

print -u2 "tools embutidas (${#EMBEDDED}): ${(j:, :)EMBEDDED}"
print -u2 "app companheiro: $([[ -n "$APK" ]] && echo sim || echo não)"
echo "$SUITE"
