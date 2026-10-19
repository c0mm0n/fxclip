#!/usr/bin/env bash
# Exercise the packaged installer without touching the user's service or home.
set -euo pipefail
package=$(realpath "$1")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home with space" XDG_CONFIG_HOME="$work/config"
export XDG_DATA_HOME="$work/data"
mkdir -p "$work/bin" "$HOME" "$XDG_CONFIG_HOME/fxclip"
if test -x "$package/fxclip-ui"; then
    mkdir -p "$XDG_DATA_HOME/icons/hicolor/scalable/apps"
    cp "$package/fxclip-icon.png" "$XDG_DATA_HOME/icons/hicolor/scalable/apps/io.github.fxclip.svg"
fi
printf '%s\n' '{"keep":"settings"}' >"$XDG_CONFIG_HOME/fxclip/settings.json"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/systemctl"
chmod +x "$work/bin/systemctl"
export PATH="$work/bin:$PATH"
sh "$package/install.sh"
if test -x "$package/fxclip-ui"; then
    cmp "$package/fxclip-ui" "$HOME/.local/bin/fxclip-ui"
    cmp "$package/fxclip-icon.png" "$HOME/.local/bin/fxclip-icon.png"
    cmp "$package/fxclip-tray.png" "$HOME/.local/bin/fxclip-tray.png"
    cmp "$package/fxclip-icon.png" "$XDG_DATA_HOME/icons/hicolor/512x512/apps/io.github.fxclip.png"
    QT_QPA_PLATFORM=offscreen "$HOME/.local/bin/fxclip-ui" --icon-check
    test ! -e "$XDG_DATA_HOME/icons/hicolor/scalable/apps/io.github.fxclip.svg"
    test -f "$XDG_DATA_HOME/applications/io.github.fxclip.Fxclip.desktop"
    grep -Fq "Exec=\"$HOME/.local/bin/fxclip-ui\"" "$XDG_DATA_HOME/applications/io.github.fxclip.Fxclip.desktop"
    grep -Fq 'Icon=io.github.fxclip' "$XDG_DATA_HOME/applications/io.github.fxclip.Fxclip.desktop"
    desktop-file-validate "$XDG_DATA_HOME/applications/io.github.fxclip.Fxclip.desktop"
    python3 - "$package/fxclip-icon.png" "$package/fxclip-tray.png" <<'PY'
import struct, sys
expected = ((512, 512), (64, 64))
for path, size in zip(sys.argv[1:], expected):
    with open(path, "rb") as image:
        assert image.read(8) == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack(">I", image.read(4))[0] == 13
        assert image.read(4) == b"IHDR"
        dimensions = struct.unpack(">II", image.read(8))
        assert dimensions == size, (path, dimensions, size)
PY
fi
for tool in wl-copy wl-paste; do
    cmp "$package/libexec/$tool" "$HOME/.local/lib/fxclip/$tool"
    test "$("$HOME/.local/lib/fxclip/$tool" --version | sed -n "1p")" = "wl-clipboard 2.3.0"
done
cmp "$package/libexec/LICENSE.wl-clipboard" "$HOME/.local/lib/fxclip/LICENSE.wl-clipboard"
cmp "$package/libexec/wl-clipboard-source.tar.gz" "$HOME/.local/lib/fxclip/wl-clipboard-source.tar.gz"
# No Wayland access: check still identifies the installed tools and versions.
env -u WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=Unknown "$HOME/.local/bin/fxclip" check >"$work/check.log"
grep -Fq "$HOME/.local/lib/fxclip/wl-paste (wl-clipboard 2.3.0)" "$work/check.log"
grep -Fq "$HOME/.local/lib/fxclip/wl-copy (wl-clipboard 2.3.0)" "$work/check.log"
sh "$package/install.sh" --uninstall
test ! -e "$HOME/.local/bin/fxclip"
test ! -e "$HOME/.local/bin/fxclip-ui"
test ! -e "$HOME/.local/bin/fxclip-icon.png"
test ! -e "$HOME/.local/bin/fxclip-tray.png"
test ! -e "$XDG_DATA_HOME/applications/io.github.fxclip.Fxclip.desktop"
test ! -e "$XDG_DATA_HOME/icons/hicolor/512x512/apps/io.github.fxclip.png"
test ! -e "$XDG_DATA_HOME/icons/hicolor/scalable/apps/io.github.fxclip.svg"
test ! -e "$HOME/.local/lib/fxclip"
test ! -e "$XDG_CONFIG_HOME/systemd/user/fxclip.service"
test "$(cat "$XDG_CONFIG_HOME/fxclip/settings.json")" = '{"keep":"settings"}'
printf '%s\n' 'Packaged install, tool resolution and uninstall passed; settings preserved.'
