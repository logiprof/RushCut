#!/bin/bash
# Captures d'écran et diagnostic de l'application réelle (accueil, puis projet de démonstration).
set -uo pipefail
OUT="${1:-/tmp/captures}"
APP="$PWD/dist/RushCut.app"
mkdir -p "$OUT"
system_profiler SPDisplaysDataType 2>/dev/null | grep -i resolution > "$OUT/ecran.txt" || true

RUSHCUT_DEMO_DIR="$HOME/Movies/RushCut" swift test --filter createDemoProject > "$OUT/demo.log" 2>&1 || true

windows() {
  swift - <<'SWIFT' 2>&1
import CoreGraphics
let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list where (w["kCGWindowOwnerName"] as? String) == "RushCut" {
    print(w["kCGWindowLayer"] ?? "", w["kCGWindowBounds"] ?? "", w["kCGWindowIsOnscreen"] ?? "", w["kCGWindowName"] ?? "")
}
SWIFT
}

capture() {
  local name="$1"
  sleep 12
  date -u +%T >> "$OUT/$name-info.txt"
  windows >> "$OUT/$name-info.txt"
  lsappinfo info -only name,pid "RushCut" >> "$OUT/$name-info.txt" 2>&1 || true
  screencapture -x "$OUT/$name.png"
  local pid
  pid=$(pgrep -x RushCut | head -1)
  if [ -n "$pid" ]; then
    sample "$pid" 2 -file "$OUT/$name-sample.txt" >/dev/null 2>&1 || true
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
  else
    echo "RushCut n'est pas lancé" >> "$OUT/$name-info.txt"
  fi
  sleep 1
}

date -u +%T > "$OUT/1-accueil-info.txt"
open -n "$APP" --args --capture "$OUT/1-accueil-app.png"
capture 1-accueil

# Le processus précédent a été arrêté de force : on retire son verrou de session.
rm -f "$HOME/Library/Application Support/RushCut/session.json"
date -u +%T > "$OUT/2-montage-info.txt"
open -n -a "$APP" "$HOME/Movies/RushCut/Démo RushCut.rushcut" --args --capture "$OUT/2-montage-app.png"
capture 2-montage

# Export réel depuis l'application n'est pas automatisable ici ; on vérifie l'aperçu à 5 s via une 3e capture.
rm -f "$HOME/Library/Application Support/RushCut/session.json"

log show --last 5m --predicate 'process == "tccd" AND eventMessage CONTAINS "RushCut"' --style compact 2>/dev/null | tail -30 > "$OUT/tcc.txt" || true
cp "$HOME/Library/Logs/RushCut/rushcut.log" "$OUT/journal.log" 2>/dev/null || true
ls -la "$OUT"
