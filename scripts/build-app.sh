#!/bin/bash
# Construit RushCut.app (universelle : Apple Silicon + Intel) et l'archive RushCut.zip dans dist/.
# Usage : ./scripts/build-app.sh [version] [numéro de build]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
BUILD="${2:-1}"
APP="dist/RushCut.app"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RushCut" "$APP/Contents/MacOS/RushCut"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"

# Icône
ICONSET="dist/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Signature locale (sans compte développeur) : suffisante pour lancer l'application sur un Mac.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

ditto -c -k --keepParent "$APP" dist/RushCut.zip
lipo -info "$APP/Contents/MacOS/RushCut"
echo "Application prête : $APP ($(du -sh "$APP" | cut -f1))"
