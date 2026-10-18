#!/bin/bash
# Builds fxclip ad-hoc signed (no certificate: no name or team ID in the signature)
# and packs build/fxclip.dmg with an Applications shortcut.
# Usage: tools/make_dmg.sh <version> [build number]
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?version, e.g. 0.2.0}
build=${2:-1}

mkdir -p build
xcodegen generate >/dev/null
xcodebuild -project FxClip.xcodeproj -scheme FxClip -configuration Release \
  -derivedDataPath build/dmg \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  build >build/dmg.log 2>&1 || { tail -40 build/dmg.log; exit 1; }

app=build/dmg/Build/Products/Release/fxclip.app
codesign --verify --strict "$app"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ]

stage=$(mktemp -d)
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f build/fxclip.dmg
hdiutil create -volname "fxclip $version" -srcfolder "$stage" -format UDZO build/fxclip.dmg >/dev/null
rm -rf "$stage"
echo build/fxclip.dmg
