<div align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="160" height="160" />
  <h1>fxclip</h1>
  <p>Clean links, ready to share.</p>

  ![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-brightgreen)
  ![Swift](https://img.shields.io/badge/Swift-native-orange)
  ![Offline](https://img.shields.io/badge/works-100%25%20offline-blue)

  <a href="https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip.dmg"><img src="https://img.shields.io/badge/macOS-Download-blue?style=for-the-badge&logo=apple" alt="Download for macOS"/></a>
  <a href="https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-windows-x64.zip"><img src="https://img.shields.io/badge/Windows-Download-blue?style=for-the-badge&logo=windows" alt="Download for Windows"/></a>
  <a href="https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-linux-x86_64.tar.gz"><img src="https://img.shields.io/badge/Linux-Download-blue?style=for-the-badge&logo=linux" alt="Download for Linux"/></a>
</div>

---

fxclip cleans the links you copy, removing tracking parameters (`utm_*`, `fbclid`, YouTube's `si`, Amazon's `ref`…) while keeping useful details like timestamps, searches and product options. It sits in your menu bar or tray, ready whenever you copy a link.

As an optional extra, fxclip can adapt links for better previews in the destination apps you choose. For example, X and Instagram links can use preview-friendly mirrors in Telegram. Other apps get the clean original.

![fxclip](docs/images/overview.png)

## Features

- 🧹 **Clean every link you copy**: trackers removed on all websites, plus site rules for X, YouTube, Instagram, TikTok, Spotify, Amazon, AliExpress, Facebook, LinkedIn and Reddit
- 🎛️ **You decide what gets trimmed**: switch sites on and off, and keep a list of websites to never touch
- ⏸️ **Pause or skip**: pause cleaning, or leave just the next copy as is
- 🖥️ **Your choice of presence**: menu bar icon, Dock icon, open at login
- 🔗 **Optional app previews**: adapt X and Instagram links for better previews in the destination apps you choose, such as Telegram. Other apps get the clean original
- 🔒 **Private**: no network, no account, no analytics. Everything happens on your device
- 🙈 **Polite with clipboard managers**: the preview rewrites are marked transient, so they don't pile up in your clipboard history

<table>
  <tr>
    <td><img src="docs/images/trackers.png" alt="Link cleaning" /></td>
    <td><img src="docs/images/preview-links.png" alt="Optional app previews" /></td>
  </tr>
</table>

## Get Started

### macOS (13 Ventura or later)
Grab `fxclip.dmg` from the [latest release](https://github.com/c0mm0n/fxclip/releases/latest), open it and drag fxclip to Applications.

fxclip isn't notarized by Apple yet, so macOS blocks the first launch: open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. You only do this once.

### Windows (10/11, x64)
Unzip `fxclip-windows-x64.zip` and run `fxclip.exe`; it lives in the tray, with the same settings window as on the Mac. It isn't signed yet, so SmartScreen may warn: click **More info › Run anyway**. Rewritten preview links stay out of Win+V history. Details: [Windows/README.md](Windows/README.md).

### Android (8.0+)
Sideload the APK. Android forbids watching the clipboard in the background, so cleaning is one tap:
share a link to **Clean link**, pick it in the text selection menu, or use the quick-settings tile
or the home-screen widget. Telegram still receives the preview link. No permission is requested,
not even internet. Details: [android/README.md](android/README.md).

### Linux (Wayland)
Works on Sway, Hyprland and KDE Plasma (GNOME Wayland doesn't let background apps watch the clipboard). wl-clipboard comes bundled (2.3, with KDE's newer clipboard protocol); on KDE, install `kdotool` for previews. Then:
```shell
tar xzf fxclip-linux-x86_64.tar.gz && cd fxclip-linux-x86_64 && ./install.sh
fxclip check
```
It runs as a systemd user service with no window; settings live in `~/.config/fxclip/settings.json`, same format as the other platforms. Details: [Linux/dist/README.md](Linux/dist/README.md).

### Build from source
Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```shell
xcodegen generate
open FxClip.xcodeproj
```

To sign with your own Apple team, put `DEVELOPMENT_TEAM = <your team id>` in a `Local.xcconfig` at the root (it's git-ignored). `tools/make_dmg.sh <version>` builds the same ad-hoc signed DMG as the releases.

Engine tests: `swift test --package-path Engine`.

## How it works

- `Shared/rules.json` holds every rule: tracker parameters, site rules and preview mirrors. No code change is needed to add a site.
- `Engine/` is the cleaning engine (Foundation only), tested against `Shared/vectors.json`, a list of before/after links.
- `App/` is the macOS menu bar app: it watches the clipboard, applies the engine, and swaps the preview link in and out as you change apps.
- `Linux/` is the Wayland daemon; it reuses the same Swift engine.
- `android/` is the Android app in Kotlin/Compose, with its own port of the engine held to the same test files.
- `Windows/` is the tray app in C#, with its own port of the engine held to the same test files (`Shared/vectors.json`, `Shared/settings_vectors.json`).

## Releases

Push a tag and GitHub does the rest: tests on all three platforms, builds, and one release with the DMG, the Windows zip and the Linux tarball.

```shell
# write release-notes/v0.2.0.md, commit it, then
git tag v0.2.0 && git push origin v0.2.0
```

## Requirements

- macOS 13 Ventura or later
- Windows 10/11 x64
- Linux with a Wayland compositor that supports data-control (Sway, Hyprland, KDE Plasma) and `wl-clipboard`
