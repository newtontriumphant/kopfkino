#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/Kopfkino.app"
PORT="${PORT:-8723}"

if [ ! -x "$APP/Contents/MacOS/Kopfkino" ] || [ "$DIR/macos/Kopfkino.swift" -nt "$APP/Contents/MacOS/Kopfkino" ]; then
  "$DIR/build.sh"
fi

pkill -x Kopfkino 2>/dev/null || true
sleep 0.3
LOG="$DIR/build/kopfkino.log"
: > "$LOG"

ARGS=(--web "$DIR/web" --port "$PORT")
[ "${NO_BROWSER:-0}" = "1" ] && ARGS+=(--no-browser)

open -n "$APP" --stdout "$LOG" --stderr "$LOG" --args "${ARGS[@]}"

trap 'pkill -x Kopfkino 2>/dev/null; echo; echo "stopped."; exit 0' INT TERM
echo "Kopfkino running at http://127.0.0.1:$PORT/  (ctrl-c to stop)"
tail -n +1 -f "$LOG"
