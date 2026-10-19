# fxclip for Android

The same link cleaning as the Mac, Windows and Linux apps, in Kotlin and Jetpack Compose
(Android 8.0+). Link cleaning stays local. Only update checks and downloads that the user authorizes contact GitHub; the update screen explains network access and Android’s install permission.

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

## Updates

From version 0.7.0, open **Updates** in the settings screen’s top bar. Check manually,
read the release notes, confirm the download, then choose **Install Update**. The
APK stays in private app storage. Its SHA-256, package, newer version code, Android
compatibility and signing certificate are checked before Android’s installer opens.

Automatic checks are off by default. If enabled, they run at most once a day when
the settings app opens; there is no background update service. Download and install
always require confirmation. Cleaning, settings, counters and history stay local.

On Android 8+, allow fxclip under **Install unknown apps** when asked, return to the
app, then tap **Install Update** again. Android asks before replacing the app. It
keeps the existing data; no silent install or automatic relaunch is requested. A
verified download survives reopening and is checked again before installation.

Install the new APK manually once if the installed version has no updater. Keep
the existing public signing key: an incompatible certificate cannot update that
installation, and uninstalling is never part of the public update flow.

## Build

The Android SDK is needed; `local.properties` points at it and is not in git.

```shell
./gradlew :engine:test          # the shared vectors, as on every platform
./gradlew :app:assembleRelease  # app/build/outputs/apk/release/
```

Published APKs keep the persistent release key held in GitHub Actions secrets and update in place. Local and PR builds use the debug key; the separate `.updatetest` application is used for update verification and preserves any public installation. A certificate mismatch is refused without removing the installed app or its data. A Play Store identity remains a separate decision.

The release workflow sets `-PfxclipVersion` from the tag and `-PfxclipVersionCode` from its run
number. Signing uses `FXCLIP_ANDROID_KEYSTORE` (path) and `FXCLIP_ANDROID_KEYSTORE_PASSWORD`;
never commit a keystore or its password.

## Update verification

The `updateTest` build type has a separate `.updatetest` package and a loopback-only
release fixture. Public APKs keep HTTPS-only release URLs and contain no fixture
endpoint. `UpdateReleaseTest` covers stable versions, immutable URLs, size limits
and digests in public and QA variants.

`tools/update-e2e.py` drives the real Compose controls and Android package installer
on an isolated headless emulator, using the pinned `agent-device` CLI. The emulator
must have no host clipboard bridge. The script touches only the QA app, with
known settings, counter and history and automatic clipboard cleaning disabled.
It checks default-off/daily consent, refusal, cancellation/retry, broken or stopped
downloads, corrupt files, invalid digest/size, package/version/certificate refusal,
reverification before install, permission guidance and native 1.0.0 → 1.0.1 install.
Data hashes and an enabled automatic-check preference must survive replacement;
the app is opened explicitly afterwards. Results and screenshots are kept as CI
artifacts. Android 8 and 15 native jobs gate release publication.

From the repository root, with an isolated emulator already running:

```sh
python3 android/tools/update-e2e.py emulator-5554 node_modules/.bin/agent-device android/update-proof android/app/build/outputs/apk/release/app-release.apk
```
