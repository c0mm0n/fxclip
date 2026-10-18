# fxclip

Clipboard link cleaner for macOS (menu bar app, Swift/AppKit + SwiftUI, macOS 13+), Windows (C# WPF tray app) and Linux (Wayland daemon in Swift). It watches the clipboard and:
- strips trackers from every copied link (`utm_*`, `fbclid`, YouTube `si`, Amazon `/ref=`…);
- while a user-picked app is in front (Telegram by default), rewrites x.com → fxtwitter.com and instagram.com → zzinstagram.com so chats show a real preview, then puts the clean link back as soon as another app comes to the front.

Plan and decisions: `docs/00_app_plan.md` (the "Versions" section at the top wins over the older milestones below it). `plan/` holds the planning conference (r1–r3) and the HTML mockups; history, not instructions.

## Layout

| Path | What |
|---|---|
| `Shared/rules.json` | All rules, language-neutral: trackers everywhere, per-site params, preview mirrors, apps (several bundle IDs per app). Explicit host lists, no regex. |
| `Shared/vectors.json` | Before/after test links (from the legacy CLI). Any engine, in any language, must pass them. |
| `Engine/` | SwiftPM `FxEngine`, **Foundation only** (no AppKit) so it can be reused on Linux/Windows. `Engine.swift` cleans and rewrites, `UserSettings.swift` layers the user's choices over the built-ins (`Rules.applying`). |
| `App/Sources/` | The app: `ClipboardWatcher` (the loop), `SettingsStore` (settings.json + UserDefaults), `StatusMenu`, `MainWindow` + `Pages` + `Components` (sidebar window), `Windows.swift` (welcome), `ChooseAppsSheet`, `AppIcons`. |
| `Linux/` | Wayland daemon (SwiftPM, reuses `Engine/`): wl-clipboard for the clipboard, focus adapters for Sway/Hyprland/KDE (kdotool), `fxclip check`, systemd user unit + `install.sh` in `Linux/dist/`, headless-Sway e2e in `Linux/scripts/e2e.sh`. |
| `Windows/` | .NET 8: `Fxclip.Engine` (C# port of the engine, byte-exact), `Fxclip.Engine.Tests` (runs both shared vector files), `Fxclip` WPF tray app with the same five pages; `tools/clipboard-smoke.ps1` is the real-clipboard check run in CI. |
| `tools/` | `make_dmg.sh` (release DMG), `make_icon.swift` (redraws the app icon), `vectors_from_legacy.py`. |
| `release-notes/` | One `vX.Y.Z.md` per release + `install.md` appended to every release. |
| `fxclip.swift` | The original ~190-line CLI the app grew from. Reference only. |

## Commands

```shell
swift test --package-path Engine          # engine + settings tests (must stay green)
xcodegen generate                         # FxClip.xcodeproj and App/Info.plist come from project.yml
xcodebuild -project FxClip.xcodeproj -scheme FxClip -configuration Release -derivedDataPath build build
tools/make_dmg.sh 0.2.0                   # ad-hoc signed DMG in build/fxclip.dmg
```

`FxClip.xcodeproj` is generated and git-ignored: edit `project.yml`, never the project. The version lives in `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`; releases override both from the tag.

## Releases

1. Write `release-notes/v0.2.0.md` ("## What's New in fxclip 0.2.0" + emoji bullets), commit, push.
2. `git tag v0.2.0 && git push origin v0.2.0`.
3. `.github/workflows/release.yml` runs three platform jobs: `mac` (notes file check, engine tests, DMG), `linux` (`build-linux.yml`: engine tests on Linux Foundation, static binary, headless Sway e2e, tarball) and `windows` (`build-windows.yml`: all vectors, single-file exe, clipboard smoke test, zip). `publish` waits for all three and creates one release with `fxclip.dmg`, `fxclip-windows-x64.zip`, `fxclip-linux-x86_64.tar.gz`. GitHub adds the source archives itself.
4. `build-linux.yml` / `build-windows.yml` also run on pushes to the `linux` / `windows` branches: work on a port there, push the branch, read the run.

The DMG is **ad-hoc signed and not notarized** (owner's choice for now): users click System Settings › Privacy & Security › Open Anyway once. Developer ID, notarization and Sparkle wait for the signing-identity decision.

## Privacy: nothing personal in the repo

The owner's name, e-mail, company and Apple team ID must never reach git (history included). The public history was started fresh for this reason; the pre-publish history stays local only.
- Commits use the GitHub noreply identity (set in this repo's local git config). Check `git log -1 --format=%ae` before pushing from a new clone.
- The Apple team ID lives in `Local.xcconfig` (git-ignored), pulled in by `Signing.xcconfig` through `#include?`. Never put `DEVELOPMENT_TEAM` back in `project.yml`.
- Releases are signed ad-hoc (`CODE_SIGN_IDENTITY=-`, empty team): an Apple Development certificate would print the owner's legal name in the signature.
- Bundle ID is `io.github.c0mm0n.fxclip` (it used to carry the owner's initials). Logger subsystem matches it.
- No absolute home paths in docs or plans; refer to repo-relative paths.
- Before any push: `git grep -i -E '<name>|<email>|<team id>|/Users/'` on what's about to leave, and `strings` on a release binary.

Product privacy promise (README, Settings): no network, no account, no analytics; settings and the counter stay on the Mac. Anything that would break it (short-link expansion in v1.1) must say so in the UI where it's switched on.

## Clipboard: what we learned

- **Generations.** `NSPasteboard.changeCount` identifies a copy; `clearContents()` returns the generation we create, so our own writes are recognised and never re-processed. Recheck `changeCount` right before writing: the user may have copied again while we computed.
- **Poll + activation.** 0.3 s poll plus `didActivateApplicationNotification` (the preview/restore swap must happen the moment the front app changes).
- **macOS 15.4+ paste privacy.** Use `detectedPatterns(for: [\.links, \.probableWebURL])` before reading, so the app only reads when a link is there; no privacy alert was observed in practice. `accessBehavior` is logged at launch.
- **Leave non-text alone.** Images, files and rich text are never touched; rich text only when it's a bare URL.
- **Transient marker.** Preview rewrites carry `org.nspasteboard.TransientType`, so clipboard managers (Raycast…) skip them.
- **Launch clipboard.** `seen = -1` so the link already on the clipboard at launch gets cleaned.
- **Pause** is honoured after the async detection too, and restores the clean link if a preview was on the clipboard. Quitting restores it as well.
- **Velja** (and similar apps) also cleans copied links ~0.17 s after a copy. Both racing is harmless (first writer wins, the other sees nothing to do), but tell users to keep only one cleaner on.

### Testing on the owner's Mac
- Clipboard tests touch the owner's real clipboard: run them **only after their explicit go**.
- Snapshot the whole clipboard first (every type, not just text) and restore it only if they haven't copied anything since. A text-only backup once wiped a copied image and file.

## App details that bit us

- A main menu with an **Edit** menu is required, even without a Dock icon, or ⌘C/⌘V/⌘A don't work in text fields.
- Swift's synthesized `Codable` **ignores property defaults**: a missing key fails the whole decode. `UserSettings` has a hand-written `init(from:)` with `decodeIfPresent`; keep it in sync when adding a field (test: `testPartialFileDecodes`).
- Unreadable `settings.json` is moved to `settings.unreadable.json` and the welcome screen shows again; never silently fall back to defaults.
- The welcome window has no close button: cleaning starts from Start, never from a dismissed window.
- Hosts are compared through `SkipHost.canonical` (lowercase, no trailing DNS dot).
- An app picked from disk that's already known (Telegram.app) reuses the known entry instead of creating a duplicate.
- Login: `SMAppService.mainApp`. Changing the bundle ID orphans the old registration; toggle "Open at login" off/on.
- Presence: Dock = `.regular`/`.accessory` activation policy; opening the app again (Spotlight, Finder) always shows the window, the way back when both icons are hidden.

## UI conventions

The window copies VoiceInk's layout from **measurements only** (VoiceInk is GPL-3.0; none of its code is in here): 950×700 window, 220 pt `.sidebar` material sidebar, 38 pt rows with radius 10 and 24 pt colored icon tiles, 30 pt bold page titles with an ⓘ popover (280 wide), cards `secondary.opacity(0.10)` with a hairline stroke.
- Lists are cards of rows (`Card`/`CardRow`); explanations go behind ⓘ, not in paragraphs.
- No focus ring on open: the window clears its first responder after showing; sidebar rows are `.focusable(false)`.
- Before calling a UI change done, screenshot every page it touches (`screencapture -l <window id>`) and look at it. README screenshots live in `docs/images/` (1400 px wide).

## Versions (from the plan)

- **v1.0** (now): engine, per-app preview links, sidebar settings, welcome, GitHub releases. Left: signing identity → notarization + Sparkle updates.
- **v1.1 copy extras:** strip `mailto:`, force HTTPS, Songlink, "Copy without any parameters", on-demand short-link expansion (direct request, said in the UI).
- **v1.2 coverage:** ClearURLs catalog as a base under our rules, offline redirect unwrapping.
- **v1.3 power users:** link tester, "cleaned" flash, rule editing, import/export.
- **Windows (shipped 0.2.0):** C# WPF tray app, unsigned single-file exe. Left: test foreground switching, tray and settings on a real Windows desktop; code signing (Azure Trusted Signing) when the identity is decided.
- **Linux (shipped 0.2.0):** Wayland daemon for Sway/Hyprland/KDE, no window (settings.json). GNOME Wayland can't work (no data-control; would need a Shell extension). Left: first real Hyprland/KDE session.
- Not taken: cleaning on *open* (Velja's job), link warnings, link history (contradicts "nothing stored").

## Ports: rules that keep them honest

- Every app identity lives in `rules.json` apps: `bundleIDs` (macOS, exact), `linux` (app_id / WM class) and `windows` (exe name), both matched ignoring case.
- `Shared/vectors.json` and `Shared/settings_vectors.json` are the contract. A behaviour change starts as a new vector, checked against the Swift engine (the reference), then every port must pass it.
- Clipboard policy is the same everywhere: refuse files and images, act on rich content only when the text is one bare URL, never re-process our own writes, never overwrite a newer copy, respect clipboard privacy markers (Windows `ExcludeClipboardContentFromMonitorProcessing`, history/cloud opt-outs; KDE password-manager hint).

## Working rules

- Keep it simple; layer features into versions rather than growing v1.
- Engine changes come with vectors/tests; behaviour differences between platforms must fail tests.
- A change is done when tests pass, the app is built and installed, and the affected screens were looked at.
- Commit messages: plain, no Co-Authored-By lines.
