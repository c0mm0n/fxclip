
### Install

**macOS** (13 Ventura or later): open `fxclip.dmg` and drag fxclip to Applications. The app isn't notarized by Apple, so the first launch is blocked: open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.

From 0.4.0, **Check for Updates…** is available in the app menu, menu bar and Settings. Install this DMG once if your current version has no updater. Automatic checks are off by default; GitHub is contacted only when you check or enable them. Downloads and installation always ask for confirmation. The cleaning itself stays offline.

**Windows** (10/11, x64): unzip `fxclip-windows-x64.zip` and run `fxclip.exe`. It isn't signed, so SmartScreen may warn: click **More info › Run anyway**. fxclip lives in the tray.

**Linux** (Wayland: Sway, Hyprland, KDE Plasma; GNOME isn't supported): wl-clipboard is bundled; on KDE install `kdotool` for previews, then
```shell
tar xzf fxclip-linux-x86_64.tar.gz && cd fxclip-linux-x86_64 && ./install.sh
```
`fxclip check` shows what it detected. Settings live in `~/.config/fxclip/settings.json`.


**Android** (8.0+): download `fxclip-android.apk`, open it and allow installation from your browser or file manager when Android asks. Share a link to **Clean link**, or use the text menu, tile or widget. No internet permission is requested.

If you installed an earlier development APK, export your settings and uninstall that build first: published APKs use a dedicated signing key. Uninstalling removes the development app's local data. Future published APKs use the same key and update in place.
