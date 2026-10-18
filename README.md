<div align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="160" height="160" />
  <h1>fxclip</h1>
  <p>Copy a link, get it clean. Paste it in Telegram, get a real preview.</p>

  ![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-brightgreen)
  ![Swift](https://img.shields.io/badge/Swift-native-orange)
  ![Offline](https://img.shields.io/badge/works-100%25%20offline-blue)

  <a href="https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip.dmg">
    <img src="https://img.shields.io/badge/Download-Latest%20Version-blue?style=for-the-badge&logo=apple" alt="Download fxclip" width="250"/>
  </a>
</div>

---

fxclip sits in your menu bar and watches what you copy. Every link loses its trackers (`utm_*`, `fbclid`, YouTube's `si`, Amazon's `ref`…) the moment you copy it. In the apps you choose, x.com and instagram.com links become their preview-friendly mirrors, so the chat shows the post instead of a bare link. Switch to any other app and the clean original is back.

![fxclip](docs/images/overview.png)

## Features

- 🧹 **Clean every link you copy**: trackers removed on all websites, plus site rules for X, YouTube, Instagram, TikTok, Spotify, Amazon, AliExpress, Facebook, LinkedIn and Reddit
- 🔗 **Better previews where you want them**: x.com → fxtwitter.com and instagram.com → zzinstagram.com, only while an app you picked is in front (Telegram by default)
- ↩️ **Clean link everywhere else**: leave that app and the clipboard holds the original, tracker-free link again
- 🎛️ **You decide what gets trimmed**: switch sites on and off, and keep a list of websites to never touch
- ⏸️ **Pause or skip**: pause cleaning, or leave just the next copy as is
- 🖥️ **Your choice of presence**: menu bar icon, Dock icon, open at login
- 🔒 **Private**: no network, no account, no analytics. Everything happens on your Mac
- 🙈 **Polite with clipboard managers**: the preview rewrites are marked transient, so they don't pile up in your clipboard history

<table>
  <tr>
    <td><img src="docs/images/preview-links.png" alt="Preview links" /></td>
    <td><img src="docs/images/trackers.png" alt="Trackers" /></td>
  </tr>
</table>

## Get Started

### Download
Grab `fxclip.dmg` from the [latest release](https://github.com/c0mm0n/fxclip/releases/latest), open it and drag fxclip to Applications.

fxclip isn't notarized by Apple yet, so macOS blocks the first launch: open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. You only do this once.

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
- `App/` is the menu bar app: it watches the clipboard, applies the engine, and swaps the preview link in and out as you change apps.

## Releases

Push a tag and GitHub does the rest: tests, build, DMG, release.

```shell
# write release-notes/v0.2.0.md, commit it, then
git tag v0.2.0 && git push origin v0.2.0
```

## Requirements

- macOS 13 Ventura or later
