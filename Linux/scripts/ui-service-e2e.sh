#!/usr/bin/env bash
# Only the disposable GitHub Linux runner user is touched. Never run on a user's desktop.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'Requires a disposable GitHub Actions Linux user.' >&2; exit 1; }
package=$(realpath "$1")
driver=$(realpath "$2")
proof=$(realpath -m "$3")
for path in "$HOME/.local/bin/fxclip" "$HOME/.local/bin/fxclip-ui" "$HOME/.local/lib/fxclip" "$HOME/.config/fxclip" "$HOME/.config/systemd/user/fxclip.service"; do
    [[ ! -e "$path" ]] || { echo 'Refusing to alter an existing fxclip installation.' >&2; exit 1; }
done
work=$(mktemp -d)
sway_pid=''
installed=0
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
cleanup() {
    status=$?
    if ((status != 0)); then
        cat "$work/sway.log" 2>/dev/null || true
        systemctl --user status fxclip.service --no-pager || true
        journalctl --user -u fxclip.service --no-pager -n 30 || true
    fi
    if ((installed)); then sh "$package/install.sh" --uninstall || true; fi
    [[ -z "$sway_pid" ]] || kill "$sway_pid" 2>/dev/null || true
    rm -f "$HOME/.local/bin/fxclip-ui-service-test"
    rm -rf "$HOME/.config/fxclip" "$work"
    exit "$status"
}
trap cleanup EXIT
sudo loginctl enable-linger "$USER"
sudo systemctl start "user@$(id -u).service"
mkdir -p "$proof" "$HOME/.config/fxclip"
printf '%s\n' '{"trackersEverywhere":true,"qaPreserve":"unchanged"}' > "$HOME/.config/fxclip/settings.json"
settings_hash=$(sha256sum "$HOME/.config/fxclip/settings.json")
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman XDG_CURRENT_DESKTOP=sway
unset WAYLAND_DISPLAY SWAYSOCK DISPLAY
printf '%s\n' 'output * mode 1280x720' 'seat seat0 fallback true' > "$work/sway.conf"
sway --unsupported-gpu -c "$work/sway.conf" > "$work/sway.log" 2>&1 &
sway_pid=$!
for _ in {1..100}; do
    socket=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'sway-ipc.*.sock' -print -quit)
    display=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -print -quit)
    if [[ -n "$socket" && -n "$display" ]]; then export SWAYSOCK="$socket" WAYLAND_DISPLAY="$(basename "$display")"; break; fi
    sleep 0.1
done
: "${SWAYSOCK:?Sway did not start}"
installed=1
sh "$package/install.sh"
install -m 755 "$driver" "$HOME/.local/bin/fxclip-ui-service-test"
QT_QPA_PLATFORM=wayland QT_WAYLAND_DISABLE_WINDOWDECORATION=1 FXCLIP_UI_SERVICE_CAPTURE="$proof/real-service-settings.png" timeout 75 "$HOME/.local/bin/fxclip-ui-service-test"
[[ "$settings_hash" == "$(sha256sum "$HOME/.config/fxclip/settings.json")" ]]
# Confirm the restarted real service still cleans the controlled Wayland clipboard.
printf '%s' 'https://example.com/?utm_source=qa' | "$HOME/.local/lib/fxclip/wl-copy"
for _ in {1..50}; do
    text=$(timeout 2 "$HOME/.local/lib/fxclip/wl-paste" --no-newline 2>/dev/null || true)
    [[ "$text" == 'https://example.com/' ]] && break
    sleep 0.1
done
[[ "$text" == 'https://example.com/' ]]
printf '%s\n' 'Native systemd UI controls, settings preservation and clipboard cleaning passed.'
