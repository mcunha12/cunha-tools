#!/bin/zsh
# Interop: Java core (plays the phone) x Mac binary, both directions, one big file and 1,000 small files, SHA-256 check, wrong-key check.
# Usage: interop-test.sh <work folder>. BIG_MB=1536 sets the big file size; KEEP=1 keeps the test data.
set -euo pipefail

ROOT="${0:A:h:h:h:h}"
WORK="${1:?uso: interop-test.sh <pasta de trabalho>}"
BIG_MB="${BIG_MB:-1536}"
SCRATCH="${SCRATCH:-$ROOT/.build/pfs}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
JAVA="$JAVA_HOME/bin/java"
FAILED=0

cd "$ROOT"
CUNHA_ONLY=tools/pair-file-sharing swift build -c release --scratch-path "$SCRATCH" --product PairFileSharing >&2
BIN="$(CUNHA_ONLY=tools/pair-file-sharing swift build -c release --scratch-path "$SCRATCH" --product PairFileSharing --show-bin-path)/PairFileSharing"
mkdir -p "$WORK/jvm" "$WORK/src"
"$JAVA_HOME/bin/javac" --release 8 -d "$WORK/jvm" $(find android/core/src android/jvm/src -name '*.java')
CLI=("$JAVA" -cp "$WORK/jvm" com.marcelocunha.cunhatools.pfs.jvm.Cli)
KEY="$(python3 -c 'import os,base64;print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))')"

limit() { perl -e 'alarm shift; exec @ARGV' "$@" }

if [[ ! -f "$WORK/src/big.bin" ]]; then
  echo "gerando big.bin ($BIG_MB MB) e 1.000 arquivos pequenos" >&2
  head -c $((BIG_MB * 1024 * 1024)) /dev/urandom > "$WORK/src/big.bin"
  python3 - "$WORK/src/many" <<'EOF'
import os, random, sys
root = sys.argv[1]
random.seed(7)
for i in range(1000):
    folder = os.path.join(root, f"pasta{i % 20:02d}")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, f"arquivo{i:04d}.bin"), "wb") as f:
        f.write(os.urandom(random.randint(1, 64 * 1024)))
os.makedirs(os.path.join(root, "vazia"), exist_ok=True)
open(os.path.join(root, "zero.txt"), "wb").close()
EOF
fi

# SHA-256 of every file plus the list of empty folders under <base>/<item>, with paths relative to <base>.
manifest() {
  (cd "$1" && { find "$2" -type f | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256; find "$2" -type d -empty | sed 's|^\./||' | LC_ALL=C sort; })
}

run_case() {
  local label="$1" direction="$2" item="$3" port="$4"
  local dest="$WORK/dest"
  rm -rf "${dest:?}"; mkdir -p "$dest"
  local out
  if [[ "$direction" == "java-to-mac" ]]; then
    limit 900 "$BIN" --selftest-receive "$port" "$KEY" "$dest" > "$WORK/recv.log" 2>&1 &
    sleep 0.5
    out="$(limit 900 "${CLI[@]}" send 127.0.0.1 "$port" "$KEY" 4 "$WORK/src/$item")"
  elif [[ "$direction" == "mac-to-java" ]]; then
    limit 900 "${CLI[@]}" receive "$port" "$KEY" "$dest" > "$WORK/recv.log" 2>&1 &
    sleep 1
    out="$(limit 900 "$BIN" --selftest-send 127.0.0.1 "$port" "$KEY" 4 "$WORK/src/$item")"
  else
    limit 900 "$BIN" --selftest-receive "$port" "$KEY" "$dest" > "$WORK/recv.log" 2>&1 &
    sleep 0.5
    out="$(limit 900 "$BIN" --selftest-send 127.0.0.1 "$port" "$KEY" 4 "$WORK/src/$item")"
  fi
  wait
  manifest "$WORK/src" "$item" > "$WORK/expected.txt"
  manifest "$dest" . > "$WORK/actual.txt"
  if diff -q "$WORK/expected.txt" "$WORK/actual.txt" > /dev/null; then
    echo "ok   $label ($(wc -l < "$WORK/actual.txt" | tr -d ' ') itens, SHA-256 iguais): $out | $(grep -h recebido "$WORK/recv.log" | head -1)"
  else
    echo "FAIL $label: $out"
    diff "$WORK/expected.txt" "$WORK/actual.txt" | head -5
    cat "$WORK/recv.log"
    FAILED=1
  fi
  rm -rf "${dest:?}"
}

run_case "Java->Mac big.bin" java-to-mac big.bin 48101
run_case "Java->Mac 1.000 arquivos" java-to-mac many 48102
run_case "Mac->Java big.bin" mac-to-java big.bin 48103
run_case "Mac->Java 1.000 arquivos" mac-to-java many 48104
run_case "Mac->Mac big.bin" mac-to-mac big.bin 48105
run_case "Mac->Mac 1.000 arquivos" mac-to-mac many 48106

"$BIN" --selftest-receive 48107 "$KEY" "$WORK/dest" > /dev/null 2>&1 &
RECV=$!
sleep 0.5
if "${CLI[@]}" wrongkey 127.0.0.1 48107 "$KEY"; then echo "ok   chave errada (Java contra Mac) rejeitada"; else echo "FAIL chave errada (Java contra Mac)"; FAILED=1; fi
kill $RECV 2>/dev/null || true
"${CLI[@]}" receive 48108 "$KEY" "$WORK/dest" > /dev/null 2>&1 &
RECV=$!
sleep 1
if "$BIN" --selftest-wrongkey 127.0.0.1 48108 "$KEY"; then echo "ok   chave errada (Mac contra Java) rejeitada"; else echo "FAIL chave errada (Mac contra Java)"; FAILED=1; fi
kill $RECV 2>/dev/null || true
wait 2>/dev/null || true

[[ "${KEEP:-0}" == 1 ]] || rm -rf "${WORK:?}/src" "${WORK:?}/dest" "${WORK:?}/jvm" "${WORK:?}"/*.txt "${WORK:?}"/*.log
exit $FAILED
