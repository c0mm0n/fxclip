# fxclip for Windows

Links that preview right, in the app you paste them into. Trackers gone everywhere.

## Install

1. Download and unzip `fxclip-windows-x64.zip` into a permanent folder.
2. Run `fxclip.exe`. No .NET installation or administrator access is needed.
3. The app is unsigned. If SmartScreen appears, select **More info → Run anyway**.
4. Choose your welcome preferences and select **Start**.

Windows 10/11, x64. The app stays in the system tray. Double-click its icon for Settings; opening the executable again also brings Settings forward. Keep the extracted folder in place when Open at login is enabled.

## Features

- Removes tracking parameters from every copied text link, keeping useful parameters, encoding, fragments, and surrounding prose intact.
- In Telegram by default, X links become fxtwitter.com and Instagram links become zzinstagram.com. The clean links return when you switch to another app. Pick different apps for each preview in Settings.
- Preview mirrors are third-party services. fxclip never contacts them; opening or sharing a mirror link lets that service handle the link.
- Preview writes are marked to stay out of Windows clipboard history and cloud clipboard. External clipboard managers may implement their own behaviour.
- Leaves files and images alone. Copies with HTML, RTF, URL formats, or browser metadata are touched only when their text is one bare URL. Sources that opt out of clipboard monitoring stay untouched; history and cloud opt-outs survive every derived copy.
- Pause/Resume, Skip next copy, per-site tracker switches, website exclusions with optional subdomains, a local counter, and Open at login.
- Follows the Windows light/dark setting. You can hide the tray icon and reopen the executable to return to Settings.
- Quitting or pausing retries restoration of a clean link if the clipboard still contains fxclip's preview. Pause stays responsive while the clipboard is busy; quitting waits up to ten seconds. A newer copy is never overwritten.

## Settings and privacy

Rule choices live in `%APPDATA%\fxclip\settings.json`, using the same camelCase `UserSettings` format as the Mac app. Missing keys use defaults. An unreadable file is moved to `settings.unreadable.json` and the welcome window returns.

`preferences.json` beside it contains only tray visibility and the tracker count. Open at login uses the current user's `Software\Microsoft\Windows\CurrentVersion\Run` registry key. Links, copied text, and app history are never saved. No network, no account, no analytics.

## Build and verification

With the .NET 8 SDK, from the repository root:

```shell
dotnet test Windows/Fxclip.Engine.Tests
dotnet publish Windows/Fxclip -c Release -r win-x64 --self-contained true -o Windows/publish -p:Version=0.0.0-dev -p:AssemblyVersion=0.0.0.0 -p:FileVersion=0.0.0.0
python3 Windows/tools/make_icon.py
```

The engine tests run on macOS and Windows and read **all** cases directly from `Shared/vectors.json` and `Shared/settings_vectors.json`. The WPF app needs the Windows Desktop build targets (included in the official Microsoft SDK); the Homebrew source-built SDK can run the engine tests but may omit the desktop build targets.

`build-windows.yml` builds on pushes to `windows` and can be called by the release workflow with a `version` input. It uploads `release-windows`, containing only `fxclip-windows-x64.zip` (the executable and this README as README.txt).

The CI clipboard smoke test launches the published executable with an isolated temporary APPDATA and `--no-welcome`. This flag only skips first-run setup; it doesn't enable login startup. It probes desktop/clipboard access and reports the exact result in the job summary. That step is best-effort because hosted runners may lack a usable desktop. It cannot replace checking foreground switching, tray interaction, all settings pages, first-run controls, login startup, and light/dark appearance on a real Windows desktop. CI also captures all five settings pages, the paused overview, the app picker, and the welcome screen in both light and dark themes in the separate `windows-ui-check` artifact.
