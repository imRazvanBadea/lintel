#!/bin/sh
# Builds Lintel.app (release) into ./build. Pass --install to copy it to ~/Applications and launch it.
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/Lintel.app"

swift build -c release --arch arm64
BINDIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BINDIR/Lintel"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lintel"
cp "$BINDIR/lintel-hook" "$APP/Contents/MacOS/lintel-hook"   # hook helper agents run (see Sources/LintelHook)
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Now Playing bridge (loaded by /usr/bin/perl, see Bridge/LintelNowPlaying.m)
clang -dynamiclib -O2 -fobjc-arc -arch arm64 -framework AppKit Bridge/LintelNowPlaying.m \
  -o "$APP/Contents/Resources/libLintelNowPlaying.dylib"
cp "$APP/Contents/Resources/libLintelNowPlaying.dylib" build/libLintelNowPlaying.dylib

if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP/Contents/Resources/libLintelNowPlaying.dylib"
codesign --force --sign - "$APP/Contents/MacOS/lintel-hook"
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
