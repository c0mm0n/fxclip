
### Install

**macOS** (13 Ventura or later): open `fxclip.dmg` and drag fxclip to Applications. The app isn't notarized by Apple, so the first launch is blocked: open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.

From 0.4.0, **Check for Updates…** is available in the app menu, menu bar and Settings. Install this DMG once if your current version has no updater. Automatic checks are off by default; GitHub is contacted only when you check or enable them. Downloads and installation always ask for confirmation. The cleaning itself stays offline.

**Windows** (10/11, x64): unzip `fxclip-windows-x64.zip` and run `fxclip.exe`. It isn't signed, so SmartScreen may warn: click **More info › Run anyway**. fxclip lives in the tray.

From 0.5.0, you can also use `fxclip-windows-setup.exe` for a per-user installation. Settings and the tray menu offer **Check for Updates…**, download and **Restart to Update**. Automatic checks are optional and off by default. Install the complete new Windows download once if the installed app has no updater.

**Linux** (Wayland: Sway, Hyprland, KDE Plasma; GNOME isn't supported): wl-clipboard is bundled; on KDE install `kdotool` for previews, then
```shell
tar xzf fxclip-linux-x86_64.tar.gz && cd fxclip-linux-x86_64 && ./install.sh
```
`fxclip check` shows what it detected. Settings live in `~/.config/fxclip/settings.json`.

From 0.6.0, the Qt tray and Settings offer **Check for Updates…** and **Install and Restart**. The window needs Qt 6 Widgets, Network and a Qt Wayland plugin. Optional daily checks run only while the interface is open; the cleaning service stays offline. Install the new Linux download manually once to get the updater.


**Android** (8.0+): download `fxclip-android.apk`, open it and allow installation from your browser or file manager when Android asks. Share a link to **Clean link**, or use the text menu, tile or widget. Cleaning stays local; only authorized updates contact GitHub.

From 0.7.0, **Updates** in the settings toolbar offers checks, downloads and **Install Update**. Daily checks are optional and off by default. Android asks for permission to install from fxclip, then confirms the update. Published APKs keep the existing signing key and data; uninstalling is never part of this update flow. Install this APK manually once if the current version has no updater. A certificate mismatch is refused without removing the installed app.
