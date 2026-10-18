
### Install

**macOS** (13 Ventura or later): open `fxclip.dmg` and drag fxclip to Applications. The app isn't notarized by Apple, so the first launch is blocked: open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.

**Windows** (10/11, x64): unzip `fxclip-windows-x64.zip` and run `fxclip.exe`. It isn't signed, so SmartScreen may warn: click **More info › Run anyway**. fxclip lives in the tray.

**Linux** (Wayland: Sway, Hyprland, KDE Plasma; GNOME isn't supported): install `wl-clipboard` (and `kdotool` on KDE for previews), then
```shell
tar xzf fxclip-linux-x86_64.tar.gz && cd fxclip-linux-x86_64 && ./install.sh
```
`fxclip check` shows what it detected. Settings live in `~/.config/fxclip/settings.json`.
