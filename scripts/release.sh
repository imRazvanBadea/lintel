#!/bin/bash
# Builds Lintel and packages build/Lintel-<version>.dmg (the app + an Applications shortcut).
# Pass --publish to create the GitHub release v<version> with the DMG attached (needs `gh`).
# The version comes from Resources/Info.plist (CFBundleShortVersionString): bump it first.
set -e
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/Lintel-$VERSION.dmg"

./scripts/build.sh

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/Lintel.app "$STAGE/Lintel.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Lintel" -srcfolder "$STAGE" -format UDZO -fs HFS+ -quiet "$DMG"
echo "Packaged $DMG ($(du -h "$DMG" | cut -f1)), sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"

if [ "$1" = "--publish" ]; then
  command -v gh >/dev/null || { echo "Install the GitHub CLI (brew install gh) to publish." >&2; exit 1; }
  gh release create "v$VERSION" "$DMG" --title "Lintel $VERSION" --generate-notes
fi
