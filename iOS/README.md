# fxclip for iOS

The same link cleaning as the other apps, for iPhone and iPad (iOS 16+). It ships as source only:
there is no App Store version and no download, so you build it and sign it with your own Apple
account (see [Build it yourself](#build-it-yourself)).

## What iOS changes

The desktop apps watch the clipboard and swap in the preview link while Telegram is in front.
iOS forbids both, like Android: no app may read the clipboard in the background, none can tell
which app is in front, and reading what another app copied shows a paste prompt. Cleaning is
therefore something the user asks for, by one of three paths:

| Path | What happens |
|---|---|
| **Share › Clean link** | The share extension cleans the link. **Copy** puts the clean link on the clipboard, **Copy for Telegram** the preview link, **Share…** hands it on: Telegram (`ph.telegra.Telegraph.Share`) gets `fxtwitter` / `zzinstagram`, every other app the clean link (`UIActivityItemSource`, asked per destination). |
| **Shortcuts** | "Clean link" and "Preview link" take text and return it cleaned. Shortcuts' own Get/Copy Clipboard actions do the clipboard, under Shortcuts' paste permission. |
| **Opening the app** | It checks for a link with `detectPatterns` (no prompt); the system Paste button (no prompt either) cleans it and puts it back. |

### Telegram previews without asking, via Shortcuts automations

This is the closest iOS gets to the Mac's swap. In Shortcuts › Automation:

1. **App › Telegram › Is Opened**, Run Immediately: Get Clipboard › Preview link › Copy to Clipboard.
2. **App › Telegram › Is Closed**, Run Immediately: Get Clipboard › Clean link › Copy to Clipboard.

Allow Shortcuts to paste once (Settings › Apps › Shortcuts › Paste from Other Apps › Allow).

## Layout

| Path | What |
|---|---|
| `project.yml` | xcodegen spec for `FxClipiOS.xcodeproj` (git-ignored), separate from the Mac project. Signing comes from `../Signing.xcconfig` (team ID in the ignored `Local.xcconfig`). |
| `Shared/` | Compiled into the app and the extension: `LinkCleaner` (the `FxEngine` from `../Engine` with the user's settings), `SharedStore` (settings.json and the counter in the App Group `group.<prefix>.fxclip`, read from Info.plist), `DestinationLink` (per-destination share item), `ShareSheet` (the share sheet's view, here so the tests can snapshot it). |
| `ShareExtension/` | Share › Clean link. |
| `App/` | The SwiftUI app (clipboard, link cleaning, app previews, how to use) and the Shortcuts actions. |
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

## Left to check on a real iPhone

- Presenting the second share sheet from the share extension, and Telegram's activity type there.
- The Shortcuts automations above.
- No paste prompt from `detectPatterns` and the Paste button.
