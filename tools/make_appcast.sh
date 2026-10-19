#!/bin/bash
# Generate and sign the Mac feed from the exact DMG built for this release.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?version, e.g. 0.4.0}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid stable version' >&2; exit 1; }
: "${FXCLIP_SPARKLE_PRIVATE_KEY:?Sparkle signing secret is required}"
sparkle_tools=build/dmg/SourcePackages/artifacts/sparkle/Sparkle/bin
test -x "$sparkle_tools/generate_appcast"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp build/fxclip.dmg "$stage/"
if [ -f "release-notes/v$version.md" ]; then
    cp "release-notes/v$version.md" "$stage/fxclip.md"
else
    printf 'fxclip %s\n\nRelease notes: https://github.com/c0mm0n/fxclip/releases/tag/v%s\n' "$version" "$version" > "$stage/fxclip.md"
fi
printf '%s' "$FXCLIP_SPARKLE_PRIVATE_KEY" | "$sparkle_tools/generate_appcast" \
    --ed-key-file - --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/c0mm0n/fxclip/releases/download/v$version/" \
    --link "https://github.com/c0mm0n/fxclip/releases/tag/v$version" "$stage"
printf '%s' "$FXCLIP_SPARKLE_PRIVATE_KEY" | "$sparkle_tools/sign_update" --verify --ed-key-file - "$stage/appcast.xml"
cp "$stage/appcast.xml" build/appcast.xml
python3 tools/check_appcast.py build/appcast.xml build/fxclip.dmg "$version"
