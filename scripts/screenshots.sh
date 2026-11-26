#!/bin/bash
# Captures d'écran de l'application réelle (accueil, puis projet de démonstration ouvert).
# Utilisé par la compilation automatique pour vérifier l'interface.
set -uo pipefail
OUT="${1:-/tmp/captures}"
APP="$PWD/dist/RushCut.app"
mkdir -p "$OUT"
system_profiler SPDisplaysDataType 2>/dev/null | grep -i resolution > "$OUT/ecran.txt" || true

RUSHCUT_DEMO_DIR="$HOME/Movies/RushCut" swift test --filter createDemoProject > "$OUT/demo.log" 2>&1 || true

open -n "$APP"
sleep 10
screencapture -x "$OUT/1-accueil.png"
osascript -e 'tell application "RushCut" to quit' || true
sleep 3

open -a "$APP" "$HOME/Movies/RushCut/Démo RushCut.rushcut"
sleep 14
screencapture -x "$OUT/2-montage.png"
osascript -e 'tell application "RushCut" to quit' || true
sleep 2
cp "$HOME/Library/Logs/RushCut/rushcut.log" "$OUT/journal.log" 2>/dev/null || true
ls -la "$OUT"
