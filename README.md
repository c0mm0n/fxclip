<div align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="160" height="160" alt="fxclip app icon" />
  <h1>fxclip</h1>
  <p>Clean links, ready to share.</p>
  <p>macOS · Windows · Linux · Android · iOS · Telegram</p>

  <a href="https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip.dmg"><img src="https://img.shields.io/badge/macOS-Download-blue?style=for-the-badge&logo=apple" alt="Download for macOS"/></a>
  <a href="https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-windows-setup.exe"><img src="https://img.shields.io/badge/Windows-Download-blue?style=for-the-badge&logo=windows" alt="Download for Windows"/></a>
  <a href="https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-linux-x86_64.tar.gz"><img src="https://img.shields.io/badge/Linux-Download-blue?style=for-the-badge&logo=linux" alt="Download for Linux"/></a>
  <a href="https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-android.apk"><img src="https://img.shields.io/badge/Android-Download-blue?style=for-the-badge&logo=android" alt="Download for Android"/></a>
</div>

fxclip removes tracking from links while keeping useful details like video timestamps, searches and product options. Copy a link on desktop, share one on mobile, or let a self-hosted Telegram bot clean messages for your group.

It strips common trackers such as `utm_*` and `fbclid`, plus site-specific extras from X, YouTube, Instagram, TikTok, Spotify, Amazon, AliExpress, Facebook, LinkedIn and Reddit. Optional preview mirrors make X, Instagram and Reddit links easier to preview in chat.

![fxclip settings on macOS](docs/images/overview.png)

## Choose how to use it

| Use fxclip on | How it works | Get started |
|---|---|---|
| **macOS 13+** | Menu bar app: cleans copied links and adapts previews as you switch apps. | [Download DMG](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip.dmg) · [Install](#macos) |
| **Windows 10/11, x64** | Tray app with clipboard cleaning, app previews and settings. | [Download installer](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-windows-setup.exe) · [Guide](Windows/README.md) |
| **Linux, Wayland, x86_64** | Clipboard service for Sway, Hyprland and KDE Plasma, with an optional Qt settings window. | [Download archive](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-linux-x86_64.tar.gz) · [Guide](Linux/dist/README.md) |
| **Android 8+** | Clean from Share, text selection, a quick-settings tile or a widget. | [Download APK](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-android.apk) · [Guide](android/README.md) |
| **iOS 16+** | Share → fxclip opens a new share sheet with the cleaned link. Source only; build and sign it yourself. | [Build guide](iOS/README.md) |
| **Telegram** | Self-hosted bot: reply with clean links, replace messages with author credit, or edit your outgoing messages in connected private chats. | [Setup guide](Telegram/README.md) |

## Clean links, with previews when you want them

On desktop, fxclip cleans the clipboard automatically. Choose which sites to clean and exclude websites. On macOS and Windows, you can also pause cleaning or skip the next copy. Files and images are left alone; rich content is only changed when its text is a single bare link.

App previews are optional. By default, X links can use `fxtwitter.com` and Instagram links can use `zzinstagram.com`, and Reddit links can use `vxreddit.com` in Telegram. On desktop, switching to another app restores the clean original. Mobile sharing sends the appropriate link to the destination you choose.

Each App previews screen lets you switch a site on or off, edit its mirror domain, or restore the built-in provider. These choices use the same settings format across platforms. A previous choice to decline preview mirrors is preserved when new sites are added.

The Telegram bot uses the same cleaning rules. It stays silent when the final link is unchanged, including matching preview links already prepared by a fxclip client, with one optional exception: enhanced previews can add a thumbnail, title and clean link for a plain YouTube URL, even when it is already clean. This fetches metadata directly from YouTube and can duplicate a working Telegram preview. A tracker-free original can also become a mirror link when previews are enabled. Members choose their own behavior; admins control group activation and defaults. Its menus support English and French.

<table>
  <tr>
    <td><img src="docs/images/trackers.png" alt="Choose which tracking parameters to remove" /></td>
    <td><img src="docs/images/preview-links.png" alt="Choose apps for optional preview links" /></td>
  </tr>
</table>

## Install

### macOS

Download [fxclip.dmg](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip.dmg), open it and drag fxclip to Applications. Open the app, choose your preferences and select **Start**.

The app is ad-hoc signed and not notarized. If macOS blocks the first launch, open **System Settings → Privacy & Security → Open Anyway**. Install in a writable Applications folder so in-app updates can replace it; running from the DMG cannot update the app.

### Windows

Run [fxclip-windows-setup.exe](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-windows-setup.exe) for a per-user installation. A [portable ZIP](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-windows-x64.zip) is also available; keep its files together. No administrator access or separate .NET installation is needed. The app is unsigned, so SmartScreen may show **More info → Run anyway**. See the [Windows guide](Windows/README.md).

### Linux

Download the [Linux archive](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-linux-x86_64.tar.gz), then run these commands in your Wayland session:

```shell
tar xzf fxclip-linux-x86_64.tar.gz
cd fxclip-linux-x86_64
./install.sh
~/.local/bin/fxclip check
```

The installer sets up a systemd user service and the optional `fxclip-ui` settings window. Clipboard tools are bundled; KDE previews also need `kdotool`. GNOME Wayland and X11 are unsupported. See the [Linux guide](Linux/dist/README.md) for runtime dependencies and session setup.

### Android

Install [fxclip-android.apk](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-android.apk), allowing installation from your browser or file manager when Android asks. Share a link to **Clean link**, or use the text-selection menu, quick-settings tile or home-screen widget. Android does not allow background clipboard watching. See the [Android guide](android/README.md).

### iOS and Telegram

iOS is **source only**, with no App Store release or signed download: follow the [iOS build guide](iOS/README.md) using your own Apple account. The Telegram bot is **self-hosted**, with no public bot configured by this project: follow the [Docker setup guide](Telegram/README.md) to run your own instance.

## Privacy and updates

**Native apps clean locally.** Links are not sent to a cleaning service, and there is no account or analytics. Settings and counters stay on the device; Android's optional history is local too. Preview mirrors are third-party services: native apps only rewrite the URL, but sharing or opening it can send the link to the mirror.

**The Telegram bot communicates with Telegram.** Cleaning runs on your server, but the bot receives messages and sends cleaned results through Telegram; preview generation can also involve mirror services. Message text and URLs are never persisted or logged by the bot. See [privacy and limits](Telegram/README.md#privacy-and-limits) before enabling it in a group.

**Updates are your choice.** macOS, Windows, Linux's desktop interface and Android can check GitHub on request. Automatic checks are off by default and run at most daily when enabled; Linux checks require its interface to be open, and Android checks when its settings app opens. Downloads and installation require confirmation. If an older installation has no updater, install the latest download manually once. Update requests never include copied links. iOS builds and Telegram container updates are managed manually.

## Development

The public name is **fxclip**. All platforms use the same white link mark on blue;
see the [identity and artwork guide](docs/branding.md) for the canonical exports.

[Shared/rules.json](Shared/rules.json) is the single source of truth for tracker rules, preview mirrors and app identities across all six delivery modes. The Swift engine in `Engine/` is reused by macOS, Linux, iOS and Telegram. Windows has a C# port; Android has a Kotlin port. All engines are checked against [shared link vectors](Shared/vectors.json) and [settings vectors](Shared/settings_vectors.json).

To build the macOS app, install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), then run from the repository root:

```shell
swift test --package-path Engine
xcodegen generate
open FxClip.xcodeproj
```

For personal signing, put `DEVELOPMENT_TEAM = <your team ID>` in the ignored `Local.xcconfig`. `tools/make_dmg.sh <version>` produces the ad-hoc signed release DMG. Other build and verification commands live in the platform guides above.

Merging to `main` runs the release workflow, which tests and builds macOS, Windows, Linux and Android before publishing their downloads together. iOS stays source only; Telegram has its own Docker build instructions. Release history is in [GitHub Releases](https://github.com/c0mm0n/fxclip/releases).
