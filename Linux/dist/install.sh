#!/bin/sh
set -eu

bin_dir="$HOME/.local/bin"
lib_dir="$HOME/.local/lib/fxclip"
config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
case "$config_root" in /*) ;; *) config_root="$HOME/.config" ;; esac
unit_dir="$config_root/systemd/user"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
case "$data_dir" in /*) ;; *) data_dir="$HOME/.local/share" ;; esac
desktop_file="$data_dir/applications/io.github.fxclip.Fxclip.desktop"
icon_file="$data_dir/icons/hicolor/512x512/apps/io.github.fxclip.png"
legacy_icon_file="$data_dir/icons/hicolor/scalable/apps/io.github.fxclip.svg"
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

case "${1:-}" in
    --uninstall)
        systemctl --user disable --now fxclip.service || true
        rm -f "$bin_dir/fxclip" "$bin_dir/fxclip-ui" "$bin_dir/fxclip.rules.json" "$bin_dir/fxclip-icon.png" "$bin_dir/fxclip-tray.png" "$unit_dir/fxclip.service"
        rm -f "$desktop_file" "$icon_file" "$legacy_icon_file"
        rmdir "$(dirname -- "$legacy_icon_file")" 2>/dev/null || true
        rm -f "$lib_dir/wl-copy" "$lib_dir/wl-paste" "$lib_dir/LICENSE.wl-clipboard" "$lib_dir/wl-clipboard-source.tar.gz" "$lib_dir/update.lock"
        rmdir "$lib_dir" 2>/dev/null || true
        systemctl --user daemon-reload
        printf '%s\n' 'fxclip uninstalled. Your settings have been kept.'
        exit 0
        ;;
    ''|--update) ;;
    *) printf '%s\n' 'Usage: ./install.sh [--uninstall]' >&2; exit 1 ;;
esac

validate_package() {
    for file in fxclip fxclip-ui fxclip.rules.json fxclip.service install.sh README.md fxclip-icon.png fxclip-tray.png libexec/wl-copy libexec/wl-paste libexec/LICENSE.wl-clipboard libexec/wl-clipboard-source.tar.gz; do
        test -f "$source_dir/$file" && test ! -L "$source_dir/$file" || { printf 'Missing or invalid tarball file: %s\n' "$file" >&2; return 1; }
    done
    for file in fxclip fxclip-ui libexec/wl-copy libexec/wl-paste; do test -x "$source_dir/$file" || return 1; done
    command -v systemctl >/dev/null 2>&1 || { printf '%s\n' 'Missing dependency: systemctl' >&2; return 1; }
}

install_files() {
    mkdir -p "$bin_dir" "$unit_dir" "$lib_dir"
    for tool in wl-copy wl-paste; do
        install -m 755 "$source_dir/libexec/$tool" "$lib_dir/$tool.new"
        mv -f "$lib_dir/$tool.new" "$lib_dir/$tool"
    done
    for file in LICENSE.wl-clipboard wl-clipboard-source.tar.gz; do
        install -m 644 "$source_dir/libexec/$file" "$lib_dir/$file.new"
        mv -f "$lib_dir/$file.new" "$lib_dir/$file"
    done
    for file in fxclip fxclip-ui; do
        install -m 755 "$source_dir/$file" "$bin_dir/$file.new"
        mv -f "$bin_dir/$file.new" "$bin_dir/$file"
    done
    for file in fxclip.rules.json fxclip-icon.png fxclip-tray.png; do
        install -m 644 "$source_dir/$file" "$bin_dir/$file.new"
        mv -f "$bin_dir/$file.new" "$bin_dir/$file"
    done
    mkdir -p "$(dirname -- "$icon_file")" "$(dirname -- "$desktop_file")"
    install -m 644 "$source_dir/fxclip-icon.png" "$icon_file.new"
    mv -f "$icon_file.new" "$icon_file"
    rm -f "$legacy_icon_file"
    desktop_exec_path=$(printf '%s' "$bin_dir/fxclip-ui" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g')
    printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=fxclip' 'Comment=Manage clipboard link cleaning' \
        "Exec=\"$desktop_exec_path\"" 'Icon=io.github.fxclip' 'Terminal=false' 'Categories=Utility;' 'StartupNotify=true' > "$desktop_file.new"
    chmod 644 "$desktop_file.new"
    mv -f "$desktop_file.new" "$desktop_file"
    install -m 644 "$source_dir/fxclip.service" "$unit_dir/fxclip.service.new"
    mv -f "$unit_dir/fxclip.service.new" "$unit_dir/fxclip.service"
}

if test "${1:-}" = --update; then
    test "$#" = 4 || exit 2
    old_pid=$2
    version=$3
    work=$4
    case "$old_pid" in ''|*[!0-9]*) exit 2 ;; esac
    case "$version" in ''|*[!0-9.]*) exit 2 ;; esac
    case "$(basename -- "$work")" in fxclip-update-*) ;; *) exit 2 ;; esac
    test -d "$work" && test ! -L "$work" && test "$(stat -c %u "$work")" = "$(id -u)" || exit 2
    test "$source_dir" = "$work/payload/fxclip-linux-x86_64" || exit 2
    state_root="${XDG_STATE_HOME:-$HOME/.local/state}"
    case "$state_root" in /*) ;; *) state_root="$HOME/.local/state" ;; esac
    mkdir -p "$state_root/fxclip" "$config_root/fxclip" "$lib_dir"
    exec >> "$state_root/fxclip/update.log" 2>&1
    printf '\n%s fxclip update to %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$version"
    result_file="$config_root/fxclip/update-result.txt"
    backup="$work/previous"
    files_changed=0
    new_ui_pid=''
    was_active=0
    systemctl --user is-active --quiet fxclip.service && was_active=1
    result() { printf '%s\n' "$1" > "$result_file.tmp"; mv -f "$result_file.tmp" "$result_file"; }
    start_ui() { nohup "$bin_dir/fxclip-ui" --updates 9>&- </dev/null & new_ui_pid=$!; }
    snapshot() {
        mkdir -p "$(dirname -- "$backup/$1")"
        if test -e "$2" || test -L "$2"; then cp -pP "$2" "$backup/$1"; fi
    }
    restore() {
        mkdir -p "$(dirname -- "$2")"
        rm -f "$2.new"
        if test -e "$backup/$1" || test -L "$backup/$1"; then
            cp -pP "$backup/$1" "$2.restore" && mv -f "$2.restore" "$2"
        else rm -f "$2"; fi
    }
    managed_files() {
        operation=$1
        managed_failed=0
        for file in fxclip fxclip-ui fxclip.rules.json fxclip-icon.png fxclip-tray.png; do "$operation" "bin/$file" "$bin_dir/$file" || managed_failed=1; done
        for file in wl-copy wl-paste LICENSE.wl-clipboard wl-clipboard-source.tar.gz; do "$operation" "lib/$file" "$lib_dir/$file" || managed_failed=1; done
        "$operation" unit "$unit_dir/fxclip.service" || managed_failed=1
        "$operation" desktop "$desktop_file" || managed_failed=1
        "$operation" icon "$icon_file" || managed_failed=1
        "$operation" legacy-icon "$legacy_icon_file" || managed_failed=1
        return "$managed_failed"
    }
    rollback() {
        code=$1
        trap - 0 HUP INT TERM
        set +e
        printf '%s\n' 'Update failed; restoring the previous version.'
        if test -n "$new_ui_pid"; then
            kill -TERM "$new_ui_pid" 2>/dev/null
            for attempt in 1 2 3 4 5; do kill -0 "$new_ui_pid" 2>/dev/null || break; sleep 1; done
            kill -KILL "$new_ui_pid" 2>/dev/null || true
            wait "$new_ui_pid" 2>/dev/null || true
        fi
        restored=1
        if test "$files_changed" = 1; then
            systemctl --user stop fxclip.service || true
            managed_files restore || restored=0
            systemctl --user daemon-reload || restored=0
        fi
        if test "$was_active" = 1; then systemctl --user start fxclip.service || restored=0; fi
        if test "$restored" = 1; then
            result 'Couldn’t install the update. The previous version was restored; try again later.'
            start_ui
            rm -rf "$work"
        else
            result "Couldn’t finish restoring the previous version. Its backup is in $backup. See the local update log."
            start_ui
        fi
        exit "$code"
    }
    # The GUI exits only after the user confirms. Never kill a pre-existing process.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$old_pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$old_pid" 2>/dev/null; then result 'The interface did not close. Your installed version is unchanged.'; exit 1; fi
    exec 9> "$lib_dir/update.lock"
    if ! flock -n 9; then result 'Another update is already in progress.'; exit 1; fi
    trap 'rollback $?' 0
    trap 'rollback 1' HUP INT TERM
    validate_package
    test -x "$bin_dir/fxclip-ui" && test -x "$bin_dir/fxclip" && test -f "$unit_dir/fxclip.service"
    test "$("$source_dir/fxclip" --version)" = "fxclip $version"
    test "$("$source_dir/fxclip-ui" --version)" = "fxclip-ui $version"
    managed_files snapshot
    systemctl --user stop fxclip.service
    files_changed=1
    install_files
    systemctl --user daemon-reload
    # Keep the existing enabled/disabled startup preference; never enable it implicitly.
    systemctl --user restart fxclip.service
    service_pid=$(systemctl --user show fxclip.service --property=MainPID --value)
    sleep 2
    systemctl --user is-active --quiet fxclip.service
    test "$service_pid" != 0 && test "$service_pid" = "$(systemctl --user show fxclip.service --property=MainPID --value)"
    result "Updated to version $version."
    start_ui
    ready=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if test "$("$bin_dir/fxclip-ui" --probe 2>/dev/null)" = "$version"; then ready=1; break; fi
        sleep 1
    done
    test "$ready" = 1
    trap - 0 HUP INT TERM
    printf '%s\n' 'Update installed; service and interface restarted successfully.'
    rm -rf "$work"
    exit 0
fi

validate_package
install_files
systemctl --user daemon-reload
for variable in WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK KDE_SESSION_VERSION KDE_FULL_SESSION DISPLAY XDG_RUNTIME_DIR PATH XDG_CONFIG_HOME; do
    if printenv "$variable" >/dev/null 2>&1; then systemctl --user import-environment "$variable"; fi
done
systemctl --user enable fxclip.service
systemctl --user restart fxclip.service
printf '%s\n' 'fxclip installed. Run ~/.local/bin/fxclip check to inspect your session.'
