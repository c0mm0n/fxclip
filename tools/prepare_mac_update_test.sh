#!/bin/bash
# Builds two isolated copies of the real app, a signed local feed and an ephemeral key.
# Does not launch anything or read/write the real clipboard. Serve the printed directory
# on port 8769, then open the installed app and use its normal Check for Updates button.
set -euo pipefail
cd "$(dirname "$0")/.."
root=${1:?absolute empty test directory}
[[ "$root" = /* ]] && [ ! -e "$root" ] || { echo 'Choose an unused absolute test directory' >&2; exit 1; }
mkdir -p "$root/installed" "$root/downloads"
chmod 700 "$root"
qa_bundle_id="io.github.c0mm0n.fxclip.update-qa.$(uuidgen | tr '[:upper:]' '[:lower:]')"
printf '%s\n' "$qa_bundle_id" > "$root/bundle-id"
swift - "$root" <<'SWIFT'
import CryptoKit
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: dir.appendingPathComponent("key"), atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("key").path)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: dir.appendingPathComponent("public-key"), atomically: true, encoding: .utf8)
SWIFT
xcodegen generate >/dev/null
for build in 100 101; do
    version="0.4.$((build - 100))"
    xcodebuild -project FxClip.xcodeproj -scheme FxClip -configuration Release \
        -derivedDataPath build/update-test \
        "PRODUCT_BUNDLE_IDENTIFIER=$qa_bundle_id" PRODUCT_NAME=fxclip-update-qa \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS=UPDATE_TESTING \
        MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
        build > "$root/build-$build.log" 2>&1 || { tail -40 "$root/build-$build.log"; exit 1; }
    app="$root/app-$build/fxclip-update-qa.app"
    mkdir -p "$(dirname "$app")"
    ditto build/update-test/Build/Products/Release/fxclip-update-qa.app "$app"
    plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName fxclip Update QA' "$plist"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $(cat "$root/public-key")" "$plist"
    /usr/libexec/PlistBuddy -c 'Set :SUFeedURL http://localhost:8769/appcast.xml' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$plist"
    codesign --force --sign - --options runtime --entitlements App/FxClip.entitlements "$app"
    codesign --verify --deep --strict "$app"
done
ditto "$root/app-100/fxclip-update-qa.app" "$root/installed/fxclip-update-qa.app"
mkdir "$root/dmg-stage"
ditto "$root/app-101/fxclip-update-qa.app" "$root/dmg-stage/fxclip-update-qa.app"
ln -s /Applications "$root/dmg-stage/Applications"
hdiutil create -volname 'fxclip Update QA' -srcfolder "$root/dmg-stage" -format UDZO "$root/downloads/fxclip.dmg" >/dev/null
printf 'Update test: build 100 → 101. Settings and clipboard watcher stay isolated.\n' > "$root/downloads/fxclip.txt"
tools=build/update-test/SourcePackages/artifacts/sparkle/Sparkle/bin
"$tools/generate_appcast" --ed-key-file "$root/key" --maximum-deltas 0 \
    --embed-release-notes --download-url-prefix http://localhost:8769/ "$root/downloads"
"$tools/sign_update" --verify --ed-key-file "$root/key" "$root/downloads/appcast.xml"
cp "$root/downloads/appcast.xml" "$root/appcast-valid.xml"
printf 'Serve: %s/downloads\nOpen: %s/installed/fxclip-update-qa.app\n' "$root" "$root"
