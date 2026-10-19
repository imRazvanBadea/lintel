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

# Ad-hoc signatures are tied to the exact binary, so macOS forgets granted permissions
# (Device Control and Data Access) on every rebuild. Local installs sign with your
# Apple Development certificate when there is one, which keeps them. LINTEL_SIGN overrides.
SIGN="${LINTEL_SIGN:--}"
if [ "$1" = "--install" ] && [ -z "$LINTEL_SIGN" ]; then
  DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
  [ -n "$DEV_ID" ] && SIGN="$DEV_ID"
fi
codesign --force --sign "$SIGN" "$APP/Contents/Resources/libLintelNowPlaying.dylib"
codesign --force --sign "$SIGN" "$APP/Contents/MacOS/lintel-hook"
codesign --force --sign "$SIGN" --identifier com.razvanbadea.lintel "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$1" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x Lintel 2>/dev/null || true
  # Wait for it to quit, or `open` fails with -600 while the old instance is still going.
  for _ in $(seq 1 50); do pgrep -x Lintel >/dev/null || break; sleep 0.1; done
  rm -rf "$HOME/Applications/Lintel.app"
  cp -R "$APP" "$HOME/Applications/Lintel.app"
  open "$HOME/Applications/Lintel.app"
  echo "Installed to ~/Applications/Lintel.app and launched."
fi
