#!/bin/zsh
# Publishes the GitHub release v<suite version> with one asset, CunhaTools.dmg: universal build, DMG, draft release, upload, then publish.
# DRY_RUN=1 builds the DMG and prints the API requests without sending them. SCRATCH works as in build.sh.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
PLIST="$ROOT/suite/Resources/Info.plist"
REPO="$(/usr/libexec/PlistBuddy -c "Print CunhaUpdateRepository" "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$PLIST")"
TAG="v$VERSION"
ASSET="CunhaTools.dmg"
DMG="$ROOT/build/$ASSET"
API="https://api.github.com/repos/$REPO"
DRY="${DRY_RUN:-0}"
TOKEN=""
RELEASE_ID=""
PUBLISHED=0

# A real run stops at the first refusal; DRY_RUN reports it and goes on.
refuse() {
  if [[ "$DRY" == "1" ]]; then
    print -u2 "DRY_RUN: um release real pararia aqui: $*"
  else
    print -u2 "erro: $*"
    exit 1
  fi
}

# The token goes to curl through stdin (-H @-), so it never shows in ps, in the history or in the output.
api() {
  local method="$1" url="$2" out
  shift 2
  if [[ "$DRY" == "1" ]]; then
    print -u2 "DRY_RUN: $method $url"
    print -u2 "  cabeçalhos: Authorization: Bearer ***, Accept: application/vnd.github+json, X-GitHub-Api-Version: 2022-11-28"
    if (( $# )); then print -u2 "  curl: ${(j: :)@}"; fi
    return 0
  fi
  if ! out="$(print -r -- "Authorization: Bearer $TOKEN
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28" | curl -sS --fail-with-body -X "$method" -H @- "$@" "$url")"; then
    print -u2 "erro: $method $url falhou: $out"
    return 1
  fi
  print -r -- "$out"
}

# A draft that never got its DMG is deleted, so releases/latest keeps pointing at the previous release.
drop_draft() {
  if [[ -n "$RELEASE_ID" && "$PUBLISHED" == "0" && "$DRY" != "1" ]]; then
    api DELETE "$API/releases/$RELEASE_ID" >/dev/null || print -u2 "aviso: apague o rascunho $RELEASE_ID em github.com/$REPO/releases"
  fi
}
trap drop_draft EXIT

[[ -z "$(git status --porcelain)" ]] || refuse "a árvore git tem mudanças fora de commit"
git fetch --quiet origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || refuse "HEAD não é o origin/main"
[[ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ]] || refuse "a tag $TAG já existe no GitHub. Suba CFBundleShortVersionString em suite/Resources/Info.plist"
COMMIT="$(git rev-parse HEAD)"
if [[ "$DRY" != "1" ]]; then
  TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n 's/^password=//p')"
  [[ -n "$TOKEN" ]] || refuse "sem credencial do GitHub no git. Um git push grava a credencial no Keychain"
fi

SUITE="$(ARCHS="arm64 x86_64" "$ROOT/scripts/build-suite.sh")"
# build-suite.sh leaves out a tool that does not build; a release needs every tool, the APK and both architectures.
for TOOL_PLIST in tools/*/Resources/Info.plist(N); do
  [[ "${TOOL_PLIST:h:h:t}" == _* ]] && continue
  NAME="$(/usr/libexec/PlistBuddy -c "Print CFBundleName" "$TOOL_PLIST")"
  [[ -d "$SUITE/Contents/Library/Tools/$NAME.app" ]] || refuse "a suíte saiu sem o $NAME"
done
[[ -f "$SUITE/Contents/Resources/Android/cunha-companion.apk" ]] || refuse "a suíte saiu sem o app companheiro Android"
ARCHS_BUILT="$(lipo -archs "$SUITE/Contents/MacOS/$EXECUTABLE")"
[[ "$ARCHS_BUILT" == *arm64* && "$ARCHS_BUILT" == *x86_64* ]] || refuse "a suíte saiu só com $ARCHS_BUILT"

BUILT="$("$ROOT/scripts/make-dmg.sh")"
mv -f "$BUILT" "$DMG"
printf 'DMG: %s, %.1f MB, commit %s\n' "$DMG" $(( $(stat -f %z "$DMG") / 1048576.0 )) "${COMMIT:0:7}" >&2

NOTES="Baixe o $ASSET, arraste o Cunha Tools para Aplicativos e siga o Como instalar.txt do DMG."
BODY="{\"tag_name\":\"$TAG\",\"target_commitish\":\"$COMMIT\",\"name\":\"Cunha Tools $VERSION\",\"body\":\"$NOTES\",\"draft\":true,\"generate_release_notes\":true}"
RESPONSE="$(api POST "$API/releases" --data "$BODY")"
if [[ "$DRY" == "1" ]]; then
  RELEASE_ID="<id>"
else
  RELEASE_ID="$(print -r -- "$RESPONSE" | plutil -extract id raw -o - -)"
fi
api POST "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$ASSET" \
  -H "Content-Type: application/x-apple-diskimage" --data-binary "@$DMG" >/dev/null
api PATCH "$API/releases/$RELEASE_ID" --data '{"draft":false,"make_latest":"true"}' >/dev/null
PUBLISHED=1

if [[ "$DRY" == "1" ]]; then
  print -u2 "DRY_RUN: nada foi enviado ao GitHub."
else
  print -u2 "publicado: https://github.com/$REPO/releases/tag/$TAG"
fi
echo "https://github.com/$REPO/releases/latest/download/$ASSET"
