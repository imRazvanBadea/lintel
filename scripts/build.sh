#!/bin/sh
# Builds Lintel.app (release) into ./build. Pass --install to copy it to ~/Applications and launch it.
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/Lintel.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Lintel"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lintel"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --identifier com.razvanbadea.lintel "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$1" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x Lintel 2>/dev/null || true
  rm -rf "$HOME/Applications/Lintel.app"
  cp -R "$APP" "$HOME/Applications/Lintel.app"
  open "$HOME/Applications/Lintel.app"
  echo "Installed to ~/Applications/Lintel.app and launched."
fi
