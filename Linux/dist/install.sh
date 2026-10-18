#!/bin/sh
set -eu

bin_dir="$HOME/.local/bin"
lib_dir="$HOME/.local/lib/fxclip"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

case "${1:-}" in
    --uninstall)
        systemctl --user disable --now fxclip.service || true
        rm -f "$bin_dir/fxclip" "$bin_dir/fxclip.rules.json" "$unit_dir/fxclip.service"
        rm -f "$lib_dir/wl-copy" "$lib_dir/wl-paste" "$lib_dir/LICENSE.wl-clipboard" "$lib_dir/wl-clipboard-source.tar.gz"
        rmdir "$lib_dir" 2>/dev/null || true
        systemctl --user daemon-reload
        printf '%s\n' 'fxclip uninstalled. Your settings have been kept.'
        exit 0
        ;;
    '') ;;
    *) printf '%s\n' 'Usage: ./install.sh [--uninstall]' >&2; exit 1 ;;
esac

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for command in systemctl; do
    command -v "$command" >/dev/null 2>&1 || { printf 'Missing dependency: %s\n' "$command" >&2; exit 1; }
done
for file in fxclip fxclip.rules.json fxclip.service libexec/wl-copy libexec/wl-paste libexec/LICENSE.wl-clipboard libexec/wl-clipboard-source.tar.gz; do
    test -f "$source_dir/$file" || { printf 'Missing tarball file: %s\n' "$file" >&2; exit 1; }
done
mkdir -p "$bin_dir" "$unit_dir" "$lib_dir"
for tool in wl-copy wl-paste; do
    install -m 755 "$source_dir/libexec/$tool" "$lib_dir/$tool.new"
    mv -f "$lib_dir/$tool.new" "$lib_dir/$tool"
done
for file in LICENSE.wl-clipboard wl-clipboard-source.tar.gz; do
    install -m 644 "$source_dir/libexec/$file" "$lib_dir/$file"
done
# Atomic replacement also allows upgrading a running executable.
install -m 755 "$source_dir/fxclip" "$bin_dir/fxclip.new"
mv -f "$bin_dir/fxclip.new" "$bin_dir/fxclip"
install -m 644 "$source_dir/fxclip.rules.json" "$bin_dir/fxclip.rules.json"
install -m 644 "$source_dir/fxclip.service" "$unit_dir/fxclip.service"
systemctl --user daemon-reload
# Run from a terminal in the graphical session, whose focus sockets the daemon needs.
for variable in WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK KDE_SESSION_VERSION KDE_FULL_SESSION DISPLAY XDG_RUNTIME_DIR PATH XDG_CONFIG_HOME; do
    if printenv "$variable" >/dev/null 2>&1; then
        systemctl --user import-environment "$variable"
    fi
done
systemctl --user enable fxclip.service
systemctl --user restart fxclip.service
printf '%s\n' 'fxclip installed. Run ~/.local/bin/fxclip check to inspect your session.'
