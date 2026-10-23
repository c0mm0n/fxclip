# fxclip for iOS

The same link cleaning as the other apps, for iPhone and iPad (iOS 16+). It ships as source only:
there is no App Store version and no download, so you build it and sign it with your own Apple
account (see [Build it yourself](#build-it-yourself)).

## How it's used

**Share › fxclip.** In X, Instagram or any app, tap Share on a post, then fxclip. The share sheet
opens again with the cleaned link: Telegram (`ph.telegra.Telegraph.Share`) gets the preview link
(`fxtwitter.com`, `zzinstagram.com`), every other app and Copy get the clean link
(`DestinationLink`, a `UIActivityItemSource` iOS asks once per destination). One tap more than a
normal share. Checked on an iPhone: the second sheet opens and Telegram shows the preview.

Why not like the Mac: iOS lets no app read the clipboard in the background or tell which app is in
front, so nothing can swap links on its own.

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
Nothing leaves the device: no network access at all.

## Build it yourself

You need a Mac with Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen), and an Apple
account. A free one works, but its apps stop opening after 7 days until you build them again.

1. Bundle IDs and App Groups belong to the first Apple account that registers them, so pick your
   own prefix. Create `Local.xcconfig` at the repository root (git-ignored):

   ```
   DEVELOPMENT_TEAM = <your team ID>
   FXCLIP_BUNDLE_PREFIX = com.yourname
   ```

   Your team ID is in Xcode › Settings › Accounts. The app becomes `com.yourname.fxclip`, the
   share extension `com.yourname.fxclip.share`, the App Group `group.com.yourname.fxclip`.
2. `xcodegen generate --spec iOS/project.yml`, open `iOS/FxClipiOS.xcodeproj`, pick your iPhone
   (Developer Mode on) and Run. Xcode registers the IDs and the App Group for you.

## Tests

```shell
xcodegen generate --spec iOS/project.yml
xcodebuild test -project iOS/FxClipiOS.xcodeproj -scheme FxClipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

CI (`.github/workflows/build-ios.yml`) does the same and keeps light and dark screenshots of the app.

## Checked on a real iPhone

- The share extension opens the second share sheet, Telegram is in it, and the link arrives as
  `fxtwitter.com` with the post's preview.
