# fxclip for Android

Clean links, ready to share. fxclip removes tracking from links on Android 8.0+, with optional X, Instagram and Reddit preview links for Telegram. Cleaning stays local; optional updates contact GitHub.

Open **App previews** to control each supported site and change its mirror domain. **Use Default** restores the built-in provider; turning a site off preserves its domain and app choices. Provider settings use the same format across platforms.

## Install

Download [fxclip-android.apk](https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip-android.apk) and open it. Allow installation from your browser or file manager when Android asks, then open fxclip for the first-launch tour.

Published APKs can update an existing installation without removing its settings or history. See [Updates](#updates) for in-app checks and installation.

## How to use it

Android does not allow background clipboard watching or detection of the app in front. Choose how to clean each link:

| Path | What happens |
|---|---|
| **Share → Clean link** | Cleans the link and opens a new share sheet. Telegram gets the optional preview link; other apps get the clean original. Frequent destinations are offered first. |
| **Text selection menu** | **Clean link** replaces the selection in place, with the optional preview link in Telegram. **Preview link** requests a preview in any app. |
| **Quick-settings tile / app shortcut** | Cleans the link already on the clipboard. fxclip briefly takes focus so Android allows clipboard access. |
| **Home-screen widget / opening the app** | Cleans the clipboard link. Automatic cleaning on app open can be turned off in Settings. |

## Layout

| Path | What |
|---|---|
| `engine/` | Kotlin port of the Swift engine, Android-free, so it runs on any JVM. Reads `Shared/rules.json` from this repo as a resource and is tested against `Shared/vectors.json` and `Shared/settings_vectors.json`. |
| `app/` | The app: `ShareActivity`, `ProcessTextActivity`, `CleanClipboardActivity`, `CleanTileService`, `CleanWidget`, the Material 3 settings screen (`MainActivity`) and the first-launch tour. |

Telegram's package names live in `rules.json` next to the macOS bundle IDs, the Linux app_ids
and the Windows exe names, under `android`.

## Settings

`settings.json` in the app's private files, the same format as the other platforms, so it can be
exported here and imported there. Custom rules use two additional keys: `addedTrackers`
(parameters and prefixes the user added) and `addedPreviews` (their own mirrors). Other platforms
ignore keys they do not support. Optional link history is stored only on the device and is off
until enabled.

## Updates

Open **Updates** in the settings screen’s top bar. Check manually,
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

The Android SDK is needed; `local.properties` points at it and is not in git. Run from `android/`:

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
artifacts. The Android 15 native job gates release publication.

From the repository root, with an isolated emulator already running:

```sh
python3 android/tools/update-e2e.py emulator-5554 node_modules/.bin/agent-device android/update-proof android/app/build/outputs/apk/release/app-release.apk
```
