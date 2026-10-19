#!/usr/bin/env bash
set -euo pipefail
binary=$(realpath "$1")
# Both the daemon and test clients use the release tools, never distro versions.
export PATH="$(dirname "$binary")/libexec:$PATH"
test "$(wl-paste --version | sed -n "1p")" = 'wl-clipboard 2.3.0'
work=$(mktemp -d)
export XDG_RUNTIME_DIR="$work/runtime"
export XDG_CONFIG_HOME="$work/config"
mkdir -m 700 "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_CONFIG_HOME/fxclip"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
export XDG_CURRENT_DESKTOP=sway
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
sway_pid='' daemon_pid=''
cleanup() {
    status=$?
    if (( status != 0 )); then
        cat "$work/sway.log" "$work/daemon.log" 2>/dev/null || true
        "$binary" check || true
        wl-paste --list-types || true
        swaymsg -t get_tree -r | jq '.. | objects | select(.focused? == true) | {type, app_id, window_properties}' || true
        if [[ -n "$daemon_pid" ]]; then ps -o pid,ppid,stat,comm --ppid "$daemon_pid" || true; fi
    fi
    [[ -z "$daemon_pid" ]] || kill "$daemon_pid" 2>/dev/null || true
    [[ -z "$sway_pid" ]] || kill "$sway_pid" 2>/dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
cat > "$work/sway.conf" <<'CONFIG'
output * mode 1280x720
seat seat0 fallback true
focus_follows_mouse no
CONFIG
env LD_PRELOAD="${FXCLIP_E2E_SWAY_PRELOAD:-}" sway --unsupported-gpu -c "$work/sway.conf" >"$work/sway.log" 2>&1 &
sway_pid=$!
for _ in {1..100}; do
    socket=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'sway-ipc.*.sock' -print -quit)
    display=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -print -quit)
    if [[ -n "$socket" && -n "$display" ]]; then
        export SWAYSOCK="$socket" WAYLAND_DISPLAY="$(basename "$display")"
        break
    fi
    sleep 0.1
done
: "${SWAYSOCK:?Sway did not start}"
if [[ "${FXCLIP_E2E_EXT_ONLY:-0}" == 1 ]]; then
    wayland-info >"$work/globals.log"
    grep -q "interface: 'ext_data_control_manager_v1'" "$work/globals.log"
    if grep -q "interface: 'zwlr_data_control_manager_v1'" "$work/globals.log"; then
        echo 'wlr-data-control must be hidden for the ext-only regression test' >&2
        exit 1
    fi
    legacy=${FXCLIP_E2E_LEGACY_WL_PASTE:?Legacy wl-paste required}
    test "$("$legacy" --version | sed -n "1p")" = 'wl-clipboard 2.2.1'
    status=0
    timeout 2 "$legacy" --watch true >"$work/legacy.log" 2>&1 || status=$?
    test "$status" -eq 1
    grep -q 'Watch mode requires.*data-control protocol' "$work/legacy.log"
    cp "$binary" "$work/legacy-fxclip"
    PATH="$(dirname "$legacy"):$PATH" "$work/legacy-fxclip" check >"$work/legacy-check.log"
    grep -q 'needs wl-clipboard 2.3.0 or later' "$work/legacy-check.log"
    printf '%s\n' 'Ext-only globals verified: ext advertised, wlr absent; wl-paste 2.2.1 watch rejected.'
fi
"$binary" check | tee "$work/check.log"
grep -q 'Data-control: available' "$work/check.log"
grep -q 'libexec/wl-paste (wl-clipboard 2.3.0)' "$work/check.log"
# A missing KDE adapter is actionable in check, including under systemd sessions.
env -u SWAYSOCK XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE "$binary" check >"$work/kde-check.log"
grep -q 'Focus adapter error: kdotool .*failed' "$work/kde-check.log"
"$binary" >"$work/daemon.log" 2>&1 &
daemon_pid=$!

assert_clipboard() {
    local expected="$1" actual=''
    for _ in {1..100}; do
        kill -0 "$daemon_pid"
        actual=$(timeout 2 wl-paste --no-newline 2>/dev/null || true)
        if [[ "$actual" == "$expected" ]]; then return; fi
        sleep 0.1
    done
    printf 'Clipboard mismatch: expected <%s>, got <%s>\n' "$expected" "$actual" >&2
    exit 1
}
assert_focus() {
    for _ in {1..100}; do
        if swaymsg -t get_tree -r | jq -e --arg app "$1" '.. | objects | select(.focused? == true and .app_id? == $app)' >/dev/null; then return; fi
        sleep 0.1
    done
    printf 'App never focused: %s\n' "$1" >&2
    exit 1
}

printf '%s' 'https://x.com/example/status/123?utm_source=test' | wl-copy
assert_clipboard 'https://x.com/example/status/123'
foot --app-id=org.telegram.desktop sh -c 'sleep 120' >"$work/telegram.log" 2>&1 &
assert_focus org.telegram.desktop
"$binary" check
assert_clipboard 'https://fxtwitter.com/example/status/123'
"$binary" check | grep -q 'Focused app: org.telegram.desktop'
foot --app-id=com.example.Other sh -c 'sleep 120' >"$work/other.log" 2>&1 &
assert_focus com.example.Other
assert_clipboard 'https://x.com/example/status/123'
# No double-processing of our own mirror; re-entering Telegram still works.
swaymsg '[app_id="org.telegram.desktop"] focus' >/dev/null
assert_focus org.telegram.desktop
assert_clipboard 'https://fxtwitter.com/example/status/123'

# A file offer replaces the preview and must survive focus changes.
printf '%s' 'file:///tmp/fxclip-test?utm_source=keep' | wl-copy --type text/uri-list
sleep 0.7
swaymsg '[app_id="com.example.Other"] focus' >/dev/null
sleep 0.7
[[ "$(wl-paste --no-newline --type text/uri-list)" == 'file:///tmp/fxclip-test?utm_source=keep' ]]
printf '%s' 'synthetic-image-data' | wl-copy --type image/png
sleep 0.7
[[ "$(wl-paste --no-newline --type image/png)" == 'synthetic-image-data' ]]

# Settings apply without restarting, including replacing a preview with clean text.
printf '%s' 'https://instagram.com/p/123/?utm_source=test' | wl-copy
assert_clipboard 'https://instagram.com/p/123/'
swaymsg '[app_id="org.telegram.desktop"] focus' >/dev/null
assert_focus org.telegram.desktop
assert_clipboard 'https://zzinstagram.com/p/123/'
printf '%s' '{"previews":{"instagram":{"enabled":false,"apps":[]}}}' >"$XDG_CONFIG_HOME/fxclip/settings.json"
assert_clipboard 'https://instagram.com/p/123/'
printf '%s' 'invalid JSON' >"$XDG_CONFIG_HOME/fxclip/settings.json"
sleep 0.7
assert_clipboard 'https://instagram.com/p/123/'
test "$(cat "$XDG_CONFIG_HOME/fxclip/settings.json")" = 'invalid JSON'
test ! -e "$XDG_CONFIG_HOME/fxclip/settings.unreadable.json"
printf '%s' '{}' >"$XDG_CONFIG_HOME/fxclip/settings.json"
assert_clipboard 'https://zzinstagram.com/p/123/'
# SIGTERM restores the clean selection, whose wl-copy owner must outlive fxclip.
kill -TERM "$daemon_pid"
wait "$daemon_pid"
daemon_pid=''
[[ "$(timeout 2 wl-paste --no-newline)" == 'https://instagram.com/p/123/' ]]
printf '%s\n' 'Headless Sway e2e passed: clean, preview, restore, own writes, files/images, settings, shutdown.'

# Run the actual Qt helper against the actual compositor/fxclip check, with no fake focus command.
if [[ "${FXCLIP_E2E_UI:-0}" == 1 ]]; then
    ui="$(dirname "$binary")/fxclip-ui"
    proof=${FXCLIP_UI_HELPER_CAPTURE_DIR:?UI proof directory required}
    mkdir -p "$proof"
    before=$(sha256sum "$XDG_CONFIG_HOME/fxclip/settings.json" | cut -d' ' -f1)
    QT_QPA_PLATFORM=wayland QT_WAYLAND_DISABLE_WINDOWDECORATION=1 timeout 20 "$ui" --helper-shot >"$proof/helper.log" 2>&1 &
    ui_pid=$!
    sleep 2
    foot --app-id=org.fxclip.QaChat sh -c 'sleep 30' >"$work/qa-chat.log" 2>&1 &
    assert_focus org.fxclip.QaChat
    wait "$ui_pid"
    test "$(cat "$proof/detected-id.txt")" = org.fxclip.QaChat
    test "$before" = "$(sha256sum "$XDG_CONFIG_HOME/fxclip/settings.json" | cut -d' ' -f1)"
    for shot in initial countdown detected; do test -s "$proof/$shot.png"; done
    printf '%s\n' 'Qt helper real-focus detection and cancel passed; settings unchanged.'
fi
