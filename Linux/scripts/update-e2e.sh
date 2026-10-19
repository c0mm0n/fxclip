#!/usr/bin/env bash
# Real Qt / Swift / systemd replacements on a disposable Linux runner only.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'Requires a disposable GitHub Actions Linux user.' >&2; exit 1; }
package=$(realpath "$1")
fixtures=$(realpath "$2")
proof=$(realpath -m "$3")
for path in "$HOME/.local/bin/fxclip" "$HOME/.local/bin/fxclip-ui" "$HOME/.local/lib/fxclip" "$HOME/.config/fxclip" "$HOME/.config/systemd/user/fxclip.service"; do
    [[ ! -e "$path" ]] || { echo 'Refusing to alter an existing fxclip installation.' >&2; exit 1; }
done
work=$(mktemp -d)
server=''; sway_pid=''; installed=0
export XDG_CONFIG_HOME="$HOME/.config" XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export QT_QPA_PLATFORM=wayland QT_WAYLAND_DISABLE_WINDOWDECORATION=1
ui="$HOME/.local/bin/fxclip-ui"
stop_ui() {
    # This installation did not exist before the test. Never touch another app.
    local pid
    while read -r pid; do [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; done < <(pgrep -u "$(id -u)" -f "^$ui( |$)" || true)
    for _ in {1..30}; do pgrep -u "$(id -u)" -f "^$ui( |$)" >/dev/null || return 0; sleep .1; done
    return 1
}
cleanup() {
    status=$?
    trap - EXIT
    if ((status != 0)); then
        cat "$proof"/*.log "$HOME/.local/state/fxclip/update.log" 2>/dev/null || true
        systemctl --user status fxclip.service --no-pager || true
        journalctl --user -u fxclip.service --no-pager -n 30 || true
    fi
    stop_ui || true
    [[ -z "$server" ]] || kill "$server" 2>/dev/null || true
    if ((installed)); then sh "$package/install.sh" --uninstall || true; fi
    [[ -z "$sway_pid" ]] || kill "$sway_pid" 2>/dev/null || true
    rm -rf "$HOME/.config/fxclip" "$work"
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$proof" "$HOME/.config/fxclip"
sudo loginctl enable-linger "$USER"
sudo systemctl start "user@$(id -u).service"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman XDG_CURRENT_DESKTOP=sway
unset WAYLAND_DISPLAY SWAYSOCK DISPLAY
printf '%s\n' 'output * mode 1280x720' 'seat seat0 fallback true' > "$work/sway.conf"
sway --unsupported-gpu -c "$work/sway.conf" > "$proof/sway.log" 2>&1 & sway_pid=$!
for _ in {1..100}; do
    socket=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'sway-ipc.*.sock' -print -quit)
    display=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -print -quit)
    if [[ -n "$socket" && -n "$display" ]]; then export SWAYSOCK="$socket" WAYLAND_DISPLAY="$(basename "$display")"; break; fi
    sleep .1
done
: "${SWAYSOCK:?Sway did not start}"
for version in 1.0.0 1.0.1; do
    mkdir -p "$work/$version"
    cp -a "$package/." "$work/$version/"
    cp "$fixtures/$version/fxclip" "$fixtures/$version/fxclip-ui" "$work/$version/"
done
mkdir -p "$work/download/fxclip-linux-x86_64"
cp -a "$work/1.0.1/." "$work/download/fxclip-linux-x86_64/"
tar czf "$work/update.tar.gz" -C "$work/download" fxclip-linux-x86_64
python3 Linux/scripts/update-server.py "$work/update.tar.gz" "$proof/requests.log" "$work/port" & server=$!
for _ in {1..50}; do [[ -s "$work/port" ]] && break; sleep .1; done
base="http://127.0.0.1:$(cat "$work/port")"
touch "$proof/requests.log"
installed=1
sh "$work/1.0.0/install.sh"
printf '%s\n' '{"trackersEverywhere":true,"qaPreserve":"unchanged"}' > "$HOME/.config/fxclip/settings.json"
settings_hash=$(sha256sum "$HOME/.config/fxclip/settings.json")
old_hash=$(sha256sum "$ui" "$HOME/.local/bin/fxclip")
for mode in offline older equal draft prerelease decline-download cancel corrupt network automatic daily decline-install; do
    rm -f "$HOME/.config/fxclip/updates.ini"
    if [[ "$mode" == daily ]]; then printf '[General]\nautomaticChecks=true\nlastCheck=%s\n' "$(date +%s)" > "$HOME/.config/fxclip/updates.ini"; fi
    source_mode=normal
    case "$mode" in older|equal|draft|prerelease|corrupt|network) source_mode="$mode" ;; cancel) source_mode=slow ;; esac
    export FXCLIP_UPDATE_TEST_MODE="$mode" FXCLIP_UPDATE_TEST_OUTPUT="$proof/$mode.json" FXCLIP_UPDATE_TEST_API="$base/$source_mode/latest"
    before=$(wc -l < "$proof/requests.log" 2>/dev/null || echo 0)
    timeout 75 "$ui" --update-test > "$proof/$mode.log" 2>&1
    python3 - "$proof/$mode.json" "$proof/requests.log" "$before" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r['passed'],r
requests=open(sys.argv[2]).read().splitlines()[int(sys.argv[3]):]
mode=r['mode']
if mode in ('offline','daily'): assert not requests,(mode,requests)
elif mode in ('decline-download','automatic','older','equal','draft','prerelease','network'): assert len(requests)==1 and requests[0].endswith('/latest'),(mode,requests)
else: assert len(requests)==2 and requests[1].endswith('.tar.gz'),(mode,requests)
print(mode,'passed')
PY
    [[ "$settings_hash" == "$(sha256sum "$HOME/.config/fxclip/settings.json")" ]]
    [[ "$old_hash" == "$(sha256sum "$ui" "$HOME/.local/bin/fxclip")" ]]
    systemctl --user is-active --quiet fxclip.service
done
verify_cleaning() {
    printf '%s' 'https://example.com/?utm_source=qa' | "$HOME/.local/lib/fxclip/wl-copy"
    for _ in {1..50}; do
        text=$(timeout 2 "$HOME/.local/lib/fxclip/wl-paste" --no-newline 2>/dev/null || true)
        [[ "$text" == 'https://example.com/' ]] && return 0
        sleep .1
    done
    return 1
}
wait_version() {
    local expected=$1
    for _ in {1..45}; do
        if [[ "$("$ui" --probe 2>/dev/null || true)" == "$expected" ]]; then return 0; fi
        sleep .3
    done
    return 1
}
for scenario in install relaunch-failure install-failure; do
    stop_ui
    sh "$work/1.0.0/install.sh"
    # Updates must not turn login startup back on.
    systemctl --user disable fxclip.service
    old_pid=$(systemctl --user show fxclip.service --property=MainPID --value)
    export FXCLIP_UPDATE_TEST_MODE=install FXCLIP_UPDATE_TEST_API="$base/normal/latest"
    export FXCLIP_UPDATE_TEST_OUTPUT="$proof/$scenario.json" FXCLIP_UPDATE_TEST_RELAUNCH_CAPTURE="$proof/$scenario-relaunched.png"
    unset FXCLIP_UPDATE_TEST_FAIL_RELAUNCH
    if [[ "$scenario" == relaunch-failure ]]; then export FXCLIP_UPDATE_TEST_FAIL_RELAUNCH=1.0.1; fi
    if [[ "$scenario" == install-failure ]]; then
        # Inject one real file-install failure after the two executables were replaced.
        mkdir -p "$work/bin"
        export FXCLIP_QA_FAIL_ONCE="$work/failed-once"
        cat > "$work/bin/install" <<'SH'
#!/bin/sh
for arg do
    case "$arg" in */fxclip.rules.json.new) if test ! -e "$FXCLIP_QA_FAIL_ONCE"; then touch "$FXCLIP_QA_FAIL_ONCE"; exit 1; fi ;; esac
done
exec /usr/bin/install "$@"
SH
        chmod +x "$work/bin/install"
        export PATH="$work/bin:$PATH"
    fi
    timeout 75 "$ui" --update-test > "$proof/$scenario.log" 2>&1
    expected=1.0.0; [[ "$scenario" != install ]] || expected=1.0.1
    wait_version "$expected"
    # Wait until the installer has released its lock, including rollback cleanup.
    for _ in {1..50}; do flock -n "$HOME/.local/lib/fxclip/update.lock" true && break; sleep .2; done
    flock -n "$HOME/.local/lib/fxclip/update.lock" true
    [[ "$("$HOME/.local/bin/fxclip" --version)" == "fxclip $expected" ]]
    [[ "$settings_hash" == "$(sha256sum "$HOME/.config/fxclip/settings.json")" ]]
    [[ "$(systemctl --user is-enabled fxclip.service || true)" == disabled ]]
    systemctl --user is-active --quiet fxclip.service
    [[ "$old_pid" != "$(systemctl --user show fxclip.service --property=MainPID --value)" ]]
    "$ui" --updates
    [[ "$(pgrep -u "$(id -u)" -f "^$ui( |$)" | wc -l)" == 1 ]]
    if [[ "$scenario" != install ]]; then [[ "$old_hash" == "$(sha256sum "$ui" "$HOME/.local/bin/fxclip")" ]]; fi
    verify_cleaning
    sleep 1
    test -s "$proof/$scenario-relaunched.png"
    printf '%s\n' "$scenario: real GUI/service replacement, preferences, single instance and clipboard passed" | tee "$proof/$scenario-result.txt"
done
cp "$HOME/.local/state/fxclip/update.log" "$proof/installer.log"
