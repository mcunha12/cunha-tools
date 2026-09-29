#!/bin/zsh
# Pipeline test without a phone: ffmpeg streams → fake scrcpy server → real client. Usage: pipeline_test.sh <app> [h265|h264] [rounds] [--fail-first]
# MEASURE=1 skips captures and simulated input, for a clean CPU/RAM reading.
set -euo pipefail

APP="${1:?usage: pipeline_test.sh <app> [h265|h264] [rounds]}"
CODEC="${2:-h265}"
ROUNDS="${3:-1}"
EXTRA=("${@:4}")
HERE="${0:A:h}"
ROOT="${0:A:h:h:h:h}"
WORK="$ROOT/.build/pair-screen-test"
BIN="$APP/Contents/MacOS/PairScreen"
CLIPBOARD="texto copiado no celular ✓"
mkdir -p "$WORK/$CODEC"

generate() {
  local out="$1" size="$2" seconds="$3"
  [[ -f "$out" ]] && return
  if [[ "$CODEC" == h265 ]]; then
    ffmpeg -loglevel error -f lavfi -i "testsrc2=size=${size}:rate=60" -t "$seconds" -pix_fmt yuv420p \
      -c:v libx265 -preset ultrafast -x265-params "keyint=60:min-keyint=60:bframes=0:log-level=error" -f hevc "$out"
  else
    ffmpeg -loglevel error -f lavfi -i "testsrc2=size=${size}:rate=60" -t "$seconds" -pix_fmt yuv420p \
      -c:v libx264 -preset ultrafast -tune zerolatency -bf 0 -g 60 -f h264 "$out"
  fi
}

generate "$WORK/portrait.$CODEC" 1080x2340 3
generate "$WORK/landscape.$CODEC" 2340x1080 1.5
generate "$WORK/small.$CODEC" 720x1560 1.5

PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 "$HERE/fake_scrcpy_server.py" --port "$PORT" --codec "$CODEC" --rounds "$ROUNDS" --clipboard "$CLIPBOARD" $EXTRA \
  --stream "$WORK/portrait.${CODEC}:1080x2340" --stream "$WORK/landscape.${CODEC}:2340x1080" --stream "$WORK/small.${CODEC}:720x1560" \
  > "$WORK/$CODEC/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
until grep -q "ouvindo" "$WORK/$CODEC/server.log" 2>/dev/null; do sleep 0.1; done

SECONDS_TO_RUN=$(( ROUNDS == 1 ? 7 : 14 ))
"$BIN" --selftest-pipeline --port "$PORT" --seconds "$SECONDS_TO_RUN" --out "$WORK/$CODEC" --expect-clipboard "$CLIPBOARD" ${MEASURE:+--no-capture} > "$WORK/$CODEC/client.log" 2>&1 &
CLIENT=$!
: > "$WORK/$CODEC/ps.txt"
while kill -0 $CLIENT 2>/dev/null; do
  ps -o %cpu=,rss= -p $CLIENT >> "$WORK/$CODEC/ps.txt" 2>/dev/null || true
  sleep 0.5
done
STATUS=0
wait $CLIENT || STATUS=$?
sleep 0.3

cat "$WORK/$CODEC/server.log" "$WORK/$CODEC/client.log"
awk 'NF == 2 { n++; cpu += $1; if ($1 > maxcpu) maxcpu = $1; if ($2 > maxrss) maxrss = $2 }
  END { if (n) printf "[medida] amostras=%d cpu média=%.1f%% cpu máx=%.1f%% rss máx=%.1f MB\n", n, cpu / n, maxcpu, maxrss / 1024 }' "$WORK/$CODEC/ps.txt"
echo "[medida] saída do cliente=$STATUS"
exit $STATUS
