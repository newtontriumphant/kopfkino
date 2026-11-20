#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/Kopfkino.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/macos/Info.plist" "$APP/Contents/Info.plist"
cp -R "$DIR/web" "$APP/Contents/Resources/web"

if [ -f "$DIR/macos/AppIcon.png" ]; then
  TMPSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$TMPSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$DIR/macos/AppIcon.png" --out "$TMPSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$DIR/macos/AppIcon.png" --out "$TMPSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMPSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$TMPSET")"
fi

echo "Compiling Kopfkino…"
swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -framework CoreMotion -framework AppKit -framework Network \
  "$DIR/macos/Kopfkino.swift" \
  -o "$APP/Contents/MacOS/Kopfkino"

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
