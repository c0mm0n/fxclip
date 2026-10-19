# fxclip for Android

The same link cleaning as the Mac, Windows and Linux apps, in Kotlin and Jetpack Compose
(Android 8.0+). No permission at all, not even internet.

## What Android changes

The desktop apps watch the clipboard and swap in the preview link while Telegram is in front.
Android forbids both: an app can only read the clipboard while it is the one in front, and it
cannot know which app is. Background watching was tried over ADB (`READ_LOGS` + a log watcher,
the KDE Connect trick) and dropped: on a Galaxy Z Fold7 under Android 16 the system logs no
clipboard line at all, so the signal it relied on does not exist. Cleaning is therefore
something the user asks for, by one of four paths:

| Path | What happens |
|---|---|
| **Share → Clean link** | The link is cleaned, then handed on. Telegram gets `fxtwitter` / `zzinstagram`, every other app the clean link (`EXTRA_REPLACEMENT_EXTRAS`). Apps you re-share to often are offered first. |
| **Text selection menu** | "Clean link" replaces the selection in place, with the preview link when the field belongs to Telegram. "Preview link" forces it anywhere. |
| **Quick-settings tile / app shortcut** | Cleans the link already on the clipboard. The invisible activity exists only to hold focus for the moment Android needs. |
| **Home-screen widget / opening the app** | The same, one tap away. |

## Layout

| Path | What |
|---|---|
| `engine/` | Kotlin port of the Swift engine, Android-free, so it runs on any JVM. Reads `Shared/rules.json` from this repo as a resource and is tested against `Shared/vectors.json` and `Shared/settings_vectors.json`. |
| `app/` | The app: `ShareActivity`, `ProcessTextActivity`, `CleanClipboardActivity`, `CleanTileService`, `CleanWidget`, the Material 3 settings screen (`MainActivity`) and the first-launch tour. |

Telegram's package names live in `rules.json` next to the macOS bundle IDs, the Linux app_ids
and the Windows exe names, under `android`.

## Settings

`settings.json` in the app's private files, the same format as the other platforms, so it can be
exported here and imported there. Two keys are written only by this app, and the others ignore
what they don't know: `addedTrackers` (parameters and prefixes the user added) and `addedPreviews`
(their own mirrors).

## Build

The Android SDK is needed; `local.properties` points at it and is not in git.

```shell
./gradlew :engine:test          # the shared vectors, as on every platform
./gradlew :app:assembleRelease  # app/build/outputs/apk/release/
```

Published APKs use a persistent release key held in GitHub Actions secrets. Local and PR builds
use the debug key. Switching from a development APK to a published APK requires exporting
settings and uninstalling the development build first; subsequent published versions update
in place. A Play Store identity remains a separate decision.

The release workflow sets `-PfxclipVersion` from the tag and `-PfxclipVersionCode` from its run
number. Signing uses `FXCLIP_ANDROID_KEYSTORE` (path) and `FXCLIP_ANDROID_KEYSTORE_PASSWORD`;
never commit a keystore or its password.
