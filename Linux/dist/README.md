# fxclip for Linux (Wayland)

fxclip removes tracking parameters from copied links. While Telegram is focused,
X and Instagram links become fxtwitter and zzinstagram preview links; switching
away restores the clean link. No network requests, account, analytics, clipboard
history, or clipboard logging. Only the current text is held in memory.

Supported desktops: Sway/wlroots and Hyprland; KDE Plasma with data-control enabled.
GNOME Wayland is unsupported and exits with an explanation. Other compositors with
data-control can clean links, with previews disabled. X11 is not supported.

Install `wl-clipboard` using your distribution's package manager. Sway needs
`swaymsg`, Hyprland needs `hyprctl` (normally included with the compositor).
KDE previews additionally need `kdotool`; without it, cleaning still works.
The x86_64 binary includes the Swift runtime; Swift does not need to be installed.
It is built on Ubuntu 22.04 and requires glibc 2.35 or newer (not Alpine/musl).

Extract `fxclip-linux-x86_64.tar.gz`, then run `./install.sh` from a terminal in
your Wayland session. This installs into `~/.local/bin` and enables a systemd user
service linked to `graphical-session.target`. Keep `fxclip.rules.json` next to
`fxclip`, including when running directly from the extracted tarball.

Use `~/.local/bin/fxclip check` to see the compositor, data-control availability,
focused application identifier, and config path. Stop the service before running
a second instance manually: `systemctl --user stop fxclip`.
`journalctl --user -u fxclip` shows diagnostics; `fxclip --version` shows the build.
`fxclip clean 'https://x.com/example/status/123?utm_source=test' --app org.telegram.desktop`
runs the engine without accessing the clipboard.

## Settings

Edit `$XDG_CONFIG_HOME/fxclip/settings.json` (default `~/.config/fxclip/settings.json`).
The file is optional and reloads automatically. Invalid or unreadable settings
produce an error and are moved to `settings.unreadable.json`; defaults then apply.
There is no separate Linux settings schema: it is the shared `UserSettings` JSON.

For example, if `fxclip check` reports `Focused app: com.example.Chat`, add it to
both preview lists while keeping Telegram enabled:

```json
{
  "addedApps": [
    {
      "id": "my-chat",
      "name": "My chat",
      "bundleIDs": [],
      "linux": ["com.example.Chat"]
    }
  ],
  "previews": {
    "x": {"enabled": true, "apps": ["telegram", "my-chat"]},
    "instagram": {"enabled": true, "apps": ["telegram", "my-chat"]}
  }
}
```

Use the exact identifier reported by `check`; matching ignores case. The arrays
replace each preview's app list, so retain `telegram` if you want its previews.

Images, files (`text/uri-list`), and unknown non-text offers are left alone. Rich
text is only flattened when its plain text is a single bare HTTP(S) URL. The
selection is polled every 0.3 seconds; Sway focus events also trigger immediate
checks. Each write rechecks types and text first. Wayland/wl-clipboard has no
atomic compare-and-set: an identical fresh copy cannot be distinguished from the
same selection, and a copy in the tiny interval after the final read can race.
Clipboard managers may record temporary preview rewrites; Wayland has no portable
macOS transient-selection marker. Avoid running multiple clipboard cleaners.

The desktop session must import its Wayland/focus environment into the systemd
user manager on each login (especially `SWAYSOCK` or
`HYPRLAND_INSTANCE_SIGNATURE`). The installer imports the current environment.
If your compositor does not manage `graphical-session.target`, use a session
manager such as uwsm, or add a compositor startup command that imports those
variables with `systemctl --user import-environment` and then runs
`systemctl --user restart fxclip.service`.

Uninstall using `./install.sh --uninstall`. Settings are preserved.

## Build and verify

From the repository root:

```sh
swift test --package-path Engine
swift test --package-path Linux
swift build --package-path Linux -c release --static-swift-stdlib
cp Shared/rules.json Linux/.build/release/fxclip.rules.json
Linux/.build/release/fxclip --version
```

The Linux workflow also exercises cleaning, real app focus previews, restoration,
non-text copies, settings reload, and shutdown under headless Sway with foot.
Hyprland and KDE still need verification in real desktop sessions.
