#!/usr/bin/env bash
set -euo pipefail
binary=$(realpath "$1")
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
sway --unsupported-gpu -c "$work/sway.conf" >"$work/sway.log" 2>&1 &
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
"$binary" check | tee "$work/check.log"
grep -q 'Data-control: available' "$work/check.log"
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
assert_clipboard 'https://zzinstagram.com/p/123/'
test -f "$XDG_CONFIG_HOME/fxclip/settings.unreadable.json"
# SIGTERM restores the clean selection, whose wl-copy owner must outlive fxclip.
kill -TERM "$daemon_pid"
wait "$daemon_pid"
daemon_pid=''
[[ "$(timeout 2 wl-paste --no-newline)" == 'https://instagram.com/p/123/' ]]
printf '%s\n' 'Headless Sway e2e passed: clean, preview, restore, own writes, files/images, settings, shutdown.'
