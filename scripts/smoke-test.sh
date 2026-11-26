#!/bin/bash
# Lance l'application quelques secondes et vérifie qu'elle ne plante pas au démarrage.
set -uo pipefail
APP="${1:-dist/RushCut.app}"
LOG="smoke.log"

"$APP/Contents/MacOS/RushCut" > "$LOG" 2>&1 &
PID=$!
sleep 8
if kill -0 "$PID" 2>/dev/null; then
  echo "RushCut tourne depuis 8 secondes : démarrage correct."
  kill "$PID" 2>/dev/null || true
  sleep 1
  kill -9 "$PID" 2>/dev/null || true
  exit 0
fi
wait "$PID"
CODE=$?
echo "RushCut s'est arrêté au démarrage (code $CODE)."
cat "$LOG"
exit 1
