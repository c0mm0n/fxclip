#!/usr/bin/env bash
# Build on Ubuntu 22.04: only libwayland-client and glibc are linked dynamically.
set -euo pipefail
output=$(realpath -m "$1")
mkdir -p "$output"
sources=${2:-$(mktemp -d)}
sources=$(realpath "$sources")
if [[ ! -d "$sources/wl-clipboard" ]]; then
    git clone --depth 1 --branch v2.3.0 https://github.com/bugaevc/wl-clipboard "$sources/wl-clipboard"
    test "$(git -C "$sources/wl-clipboard" rev-parse HEAD)" = 67a7b937895bceec1ae5ccebb10216f63f70ca1b
fi
if [[ ! -d "$sources/wayland-protocols" ]]; then
    curl --fail --location --retry 3 https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.39/downloads/wayland-protocols-1.39.tar.xz -o "$sources/wayland-protocols-1.39.tar.xz"
    echo "e1dcdcbbf08e2e0a8a02ee5d9a0be3a6aafc39a4b51fa7e0d2f1a16411cb72fa  $sources/wayland-protocols-1.39.tar.xz" | sha256sum --check
    mkdir -p "$sources/wayland-protocols"
    tar -xJf "$sources/wayland-protocols-1.39.tar.xz" --strip-components=1 -C "$sources/wayland-protocols"
fi
# Jammy's wayland-protocols is too old: 2.3.0 needs >=1.39 to compile ext support.
meson setup "$sources/protocols-build" "$sources/wayland-protocols" --prefix="$sources/protocols-install" -Dtests=false
meson install -C "$sources/protocols-build"
export PKG_CONFIG_PATH="$sources/protocols-install/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
meson setup "$sources/clipboard-build" "$sources/wl-clipboard" --buildtype=release -Db_lto=true
ninja -C "$sources/clipboard-build"
grep -q '^#define HAVE_EXT_DATA_CONTROL$' "$sources/clipboard-build/src/config.h"
for tool in wl-copy wl-paste; do
    install -m 755 "$sources/clipboard-build/src/$tool" "$output/$tool"
    strip "$output/$tool"
    test "$("$output/$tool" --version | sed -n "1p")" = "wl-clipboard 2.3.0"
    strings "$output/$tool" | grep 'ext_data_control_manager_v1'
    readelf -d "$output/$tool"
    ldd "$output/$tool"
    python3 - "$output/$tool" <<'PY'
import re, subprocess, sys
needed = set(re.findall(r'\(NEEDED\).*\[(.*?)\]', subprocess.check_output(['readelf', '-d', sys.argv[1]], text=True)))
allowed = {'libwayland-client.so.0', 'libc.so.6', 'libpthread.so.0', 'librt.so.1', 'libm.so.6', 'libdl.so.2', 'ld-linux-x86-64.so.2', 'ld-linux-aarch64.so.1'}
assert {'libwayland-client.so.0', 'libc.so.6'} <= needed, needed
assert needed <= allowed, needed
print(sys.argv[1] + ' NEEDED: ' + ', '.join(sorted(needed)))
PY
done
install -m 644 "$sources/wl-clipboard/COPYING" "$output/LICENSE.wl-clipboard"
# Include corresponding source and the build recipe with the GPL binaries.
recipe=$(realpath "${BASH_SOURCE[0]}")
if [[ "$recipe" != "$sources/build-wl-clipboard.sh" ]]; then
    cp "$recipe" "$sources/build-wl-clipboard.sh"
fi
tar --exclude=.git -czf "$output/wl-clipboard-source.tar.gz" -C "$sources" wl-clipboard wayland-protocols build-wl-clipboard.sh
