# fxclip for iOS

Clean links, ready to share. fxclip removes tracking from links on iPhone and iPad (iOS 16+), with optional X, Instagram and Reddit previews for Telegram. It is **source only**: there is no App Store release or signed download. Build and sign it with your own Apple account using the [build guide below](#build-it-yourself).

Open **App previews** to control each supported site and change its mirror domain. **Use Default** restores the built-in provider; turning a site off preserves its domain and app choices. Provider settings use the same format across platforms.

## How to use it

**Share › fxclip.** In X, Instagram, Reddit or any app, tap Share on a post, then fxclip. The share sheet
opens again with the cleaned link. With app previews enabled, Telegram gets the preview link
(`fxtwitter.com`, `zzinstagram.com`); every other app and Copy get the clean original. Choose
your destination as usual.

iOS does not allow background clipboard watching or detection of the app in front. Cleaning
starts when you share a link or run a Shortcuts action.

The **Shortcuts actions** "Clean link" and "Preview link" take text and return it; "Clean link"
also turns a preview link back into the original. They're there for whoever builds their own
shortcuts; the app doesn't ask anyone to.

## Layout

| Path | What |
|---|---|
| `project.yml` | xcodegen spec for `FxClipiOS.xcodeproj` (git-ignored), separate from the Mac project. Signing comes from `../Signing.xcconfig` (team ID in the ignored `Local.xcconfig`). |
| `Shared/` | Compiled into the app and the extension: `LinkCleaner` (the `FxEngine` from `../Engine` with the user's settings), `SharedStore` (settings.json and the counter in the App Group `group.<prefix>.fxclip`, read from Info.plist), `DestinationLink` (per-destination share item), `ShareSheet` (the extension's model, and the screen shown when nothing was shared). |
| `ShareExtension/` | Share › fxclip: cleans, then opens the share sheet straight away. |
| `App/` | The SwiftUI app (how to use Share › fxclip, the counter, link cleaning, app previews) and the Shortcuts actions. |
| `Tests/` | Unit tests hosted in the app. The engine itself is held to `Shared/vectors.json` by `swift test --package-path Engine`. |

Telegram's iOS bundle ID and share activity type live in `Shared/rules.json` under `ios`, next to the
other platforms' identifiers, and are matched exactly.

## Settings

`settings.json` in the App Group container, the same format as the other platforms. An unreadable
file is moved to `settings.unreadable.json`, never silently replaced. The counter is a total only.
Cleaning stays on the device; fxclip makes no network requests and has no account or analytics.
Preview mirrors are third-party services: sharing or opening a mirror link can send it to that service.

## Build it yourself

You need a Mac with Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen), and an Apple
account. A free one works, but its apps stop opening after 7 days until you build them again.

1. Bundle IDs and App Groups belong to the first Apple account that registers them, so pick your
   own prefix. Create `Local.xcconfig` at the repository root (git-ignored):

   ```
   DEVELOPMENT_TEAM = <your team ID>
   FXCLIP_BUNDLE_PREFIX = com.example
   ```

   Replace `com.example` with your own unique prefix. Your team ID is in Xcode › Settings ›
   Accounts. With this example, the app becomes `com.example.fxclip`, the share extension
   `com.example.fxclip.share`, and the App Group `group.com.example.fxclip`.
2. `xcodegen generate --spec iOS/project.yml`, open `iOS/FxClipiOS.xcodeproj`, pick your iPhone
   (Developer Mode on) and Run. Xcode registers the IDs and the App Group for you.

## Tests

From the repository root:

```shell
xcodegen generate --spec iOS/project.yml
xcodebuild test -project iOS/FxClipiOS.xcodeproj -scheme FxClipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

CI (`.github/workflows/build-ios.yml`) does the same and keeps light and dark screenshots of the app.

## Checked on a real iPhone

- The share extension opens the second share sheet, Telegram is in it, and the link arrives as
  `fxtwitter.com` with the post's preview.
