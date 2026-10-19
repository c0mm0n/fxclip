# fxclip for Linux (Wayland)

fxclip cleans copied links by removing tracking parameters while keeping useful
details. Optionally, it adapts X and Instagram links for better previews in chosen
destination apps (Telegram by default); switching away restores the clean original.
Link cleaning stays local, with no account, analytics, clipboard history or clipboard
logging. Only the current text is held in memory. Authorized updates contact GitHub
from the desktop interface; the cleaning service never makes network requests.

Supported desktops: Sway/wlroots and Hyprland; KDE Plasma with data-control enabled.
GNOME Wayland is unsupported and exits with an explanation. Other compositors with
data-control can clean links, with previews disabled. X11 is not supported.

The release bundles **wl-clipboard 2.3.0** (`wl-copy` and `wl-paste`), including
support for both `ext_data_control_manager_v1` (recent KDE Plasma) and
`zwlr_data_control_manager_v1`. No distribution wl-clipboard package is needed.
Sway needs `swaymsg`, Hyprland needs `hyprctl` (normally included with the compositor).
**KDE previews need `kdotool`**; without it, cleaning still works.
The x86_64 binary includes the Swift runtime; Swift does not need to be installed.
All release binaries are built on Ubuntu 22.04 and require glibc 2.35 or newer
(not Alpine/musl). The bundled tools link dynamically to the system
`libwayland-client.so.0` and glibc; the Wayland library and its distribution-managed
dependencies must be present (as they normally are in a Wayland desktop session).

From a terminal in your Wayland session, run:

```sh
tar xzf fxclip-linux-x86_64.tar.gz
cd fxclip-linux-x86_64
./install.sh
```

This installs fxclip into `~/.local/bin`, the clipboard tools into
`~/.local/lib/fxclip/`, and enables a systemd user service linked to
`graphical-session.target`. Keep `fxclip.rules.json` and the `libexec/` directory
next to `fxclip` when running directly from the extracted tarball. fxclip looks
first in that adjacent `libexec/`, then in `~/.local/lib/fxclip/`, then on `PATH`.

The package also installs the optional KDE-friendly Qt 6 desktop window as
`~/.local/bin/fxclip-ui`. Open it from a terminal or your application launcher.
It provides Overview, Link cleaning, App previews, Never clean and Settings
pages, including app selection, Wayland diagnostics and controls for the
existing user service. Qt 6 Widgets, Qt 6 Network and a Qt Wayland platform plugin are runtime
requirements for the window; the headless `fxclip` service does not depend on
Qt. If a system tray is available, closing the window keeps it in the tray;
otherwise it exits. The service continues running when the window closes.
Start/stop and login startup are separate controls.

The installer adds an application launcher and icon under your XDG data
directory. Its `Exec` entry contains the absolute path to `~/.local/bin/fxclip-ui`,
so launching it does not depend on that directory being in `PATH`. The window,
tray and launcher use the original app icon artwork; the launcher icon is installed
at 512×512 and the tray uses the 64×64 variant.

The window edits the same `settings.json` used by the daemon and atomically saves
changes. Unknown JSON fields are preserved. Invalid settings stay untouched and
the controls remain read-only until the file is fixed.

Use `~/.local/bin/fxclip check` to see the compositor, data-control availability,
the selected clipboard tool paths and versions, focused application identifier,
and config path. If a data-control probe fails, `check` also inspects advertised
globals when `wayland-info` is installed. An older PATH fallback may need upgrading
to wl-clipboard 2.3.0 for an ext-only desktop; reinstalling this release supplies it.
To add a Linux app in App previews, choose **Add Linux app…**, select **Detect app**,
then switch to the target app within five seconds. The detected identifier fills
editable fields; review them and choose **Add** to save. You can also enter the
identifier manually, and canceling the dialog does not change settings.
Stop the service before running a second instance manually: `systemctl --user stop fxclip`.
`journalctl --user -u fxclip` shows diagnostics; `fxclip --version` shows the build.
`fxclip clean 'https://x.com/example/status/123?utm_source=test' --app org.telegram.desktop`
runs the engine without accessing the clipboard.

## Updates

From version 0.6.0, choose **Check for Updates…** in the tray menu or **Settings →
Updates**. Install this download manually once if your current version has no
updater. The updater manages the standard user installation created by `install.sh`.

Checks contact GitHub Releases for the latest stable Linux x86_64 download and
release notes. Automatic checks are off until enabled, run at most once a day,
and only run while the interface is open. Downloading and **Install and Restart**
each require confirmation; you can cancel a download and keep cleaning. Links and
clipboard contents are never sent. The headless service has no network activity.

The download is verified against GitHub's SHA-256 digest before extraction. The
installer keeps the previous files while replacing the interface and service,
preserves settings and the existing login-startup preference, then relaunches both.
If installation or relaunch fails, it restores the previous version and shows the
result in Updates. The local installer log is at
`$XDG_STATE_HOME/fxclip/update.log` (default `~/.local/state/fxclip/update.log`).
If restoring files also fails, the message identifies the retained backup.

## Settings

Edit `$XDG_CONFIG_HOME/fxclip/settings.json` (default `~/.config/fxclip/settings.json`).
The file is optional and reloads automatically. At startup, invalid or unreadable
settings are moved to `settings.unreadable.json` and defaults apply; an existing
backup is preserved by using a timestamped name. During live reload, invalid or
truncated saves produce a warning and keep the last valid settings until a valid
save is available.
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

## Limitations

Images, files (`text/uri-list`), and unknown non-text offers are left alone. Rich
text is only flattened when its plain text is a single bare HTTP(S) URL. The
selection is polled every 0.3 seconds; Sway focus events also trigger immediate
checks. Each write rechecks types and text first. Wayland/wl-clipboard has no
atomic compare-and-set: an identical fresh copy cannot be distinguished from the
same selection, and a copy in the tiny interval after the final read can race.
The type-list/read and `wl-paste --watch true` probes are not atomic with secret
selection changes; any content read is held only in memory and discarded, since
wl-clipboard provides no atomic offer API.
Clipboard managers may record temporary preview rewrites; Wayland has no portable
macOS transient-selection marker. Avoid running multiple clipboard cleaners.

The desktop session must import its Wayland/focus environment into the systemd
user manager on each login (especially `SWAYSOCK` or
`HYPRLAND_INSTANCE_SIGNATURE`, and `KDE_SESSION_VERSION` / `KDE_FULL_SESSION`
plus `DISPLAY` when set for KDE). The installer imports the current environment.
If your compositor does not manage `graphical-session.target`, use a session
manager such as uwsm, or add a compositor startup command that imports those
variables with `systemctl --user import-environment` and then runs
`systemctl --user restart fxclip.service`.

Uninstall using `./install.sh --uninstall`. The bundled tools are removed; settings
are preserved.

## Bundled software

[wl-clipboard 2.3.0](https://github.com/bugaevc/wl-clipboard/tree/v2.3.0) is licensed
under **GPL-3.0-or-later**. Its license is shipped beside the tools as
`libexec/LICENSE.wl-clipboard`. `libexec/wl-clipboard-source.tar.gz` contains the
unmodified wl-clipboard and Wayland protocol sources plus the build recipe.
The installer keeps these files in `~/.local/lib/fxclip/` as well.

## Build and verify

From the repository root:

```sh
swift test --package-path Engine
swift test --package-path Linux
swift build --package-path Linux -c release --static-swift-stdlib
cp Shared/rules.json Linux/.build/release/fxclip.rules.json
Linux/.build/release/fxclip --version
cmake -S Linux/ui -B Linux/ui/build -DCMAKE_BUILD_TYPE=Release
cmake --build Linux/ui/build --parallel
ctest --test-dir Linux/ui/build --output-on-failure
```

Building the optional Qt window on Ubuntu 22.04 requires `cmake`, `g++`,
`libgl-dev`, `qt6-base-dev`, `qt6-qpa-plugins` and `qt6-wayland`. The package
needs the Qt 6 Widgets and Network runtimes and Qt Wayland platform plugin to run the window;
the headless daemon does not require Qt.

To build the bundled tools on Ubuntu 22.04, install `meson`, `ninja-build`,
`libwayland-dev`, `pkg-config`, `gcc`, `git`, `curl`, `xz-utils` and `python3`, then run
`bash Linux/scripts/build-wl-clipboard.sh package/libexec`. The recipe fetches
wl-clipboard v2.3.0 and the freedesktop release tarball for wayland-protocols 1.39.
**Building wl-clipboard 2.3.0 yourself requires wayland-protocols >= 1.39 at build
time**: with older definitions it silently builds without ext-data-control,
despite reporting version 2.3.0. The recipe checks that ext support was compiled,
asserts the ELF dependency list and checks the ext protocol name in both binaries.
To rebuild from the shipped sources, extract the source archive and run
`bash build-wl-clipboard.sh /tmp/fxclip-tools "$PWD"` from it; this uses the extracted sources without fetching them again.

The Linux workflow exercises cleaning, real app focus previews, restoration,
non-text copies, settings reload, and shutdown under headless Sway with foot,
using the bundled tools. It repeats the full e2e against Fedora 43's Sway 1.11 /
wlroots 0.19, with a test-only compositor global filter hiding wlr-data-control.
`wayland-info` must confirm ext is advertised and wlr absent; wl-paste 2.2.1 must
fail to watch while the bundled 2.3.0 and fxclip pass. The filter preserves Sway's
security filter and is never shipped in the release. Ubuntu 22.04's Sway 1.7
continues to cover the older wlr protocol. Hyprland and KDE still need verification
in real desktop sessions.

The updater workflow separately builds unpublished 1.0.0 and 1.0.1 fixtures, drives
the real Qt controls and HTTP downloads, and replaces the actual Swift daemon and
Qt interface under systemd/headless Sway. It checks default-off/daily networking,
refusals, interruption, corruption, offline errors, older/non-stable releases,
settings and startup preservation, single-instance relaunch, and rollbacks after
a partial install failure or failed interface relaunch. Clipboard checks use only
the isolated compositor. Test endpoints and failure hooks are absent from releases.
