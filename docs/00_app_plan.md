# 00 — fxclip as a public macOS app: consensus plan

Plan conference 2026-10-18: Codex GPT-6-Astra (high), Codex GPT-6.1-Sol (high), moderated by Claude Opus 5.5. Sources: `plan/00_brief.md`, `plan/r1_*.md`, `plan/r2_*.md`.

## Versions (2026-10-18: "keep it simple, layer the versions"; replaces the milestone order below)
Each version ships on its own. The sections below describe the full product; anything not listed in a version waits.

- **v1.0, ship what's useful:**
  - Today's engine and menu bar app (done), plus per-app preview links.
  - Settings window with a sidebar (replaced the 3 tabs, 2026-10-18), toggles only:
    - Overview: status, Pause / Skip next copy, counters, preview links in use.
    - Preview links: on/off and apps per rewrite.
    - Trackers: on/off per site. Never clean: websites left untouched.
    - Settings: menu bar, Dock, Open at login.
  - One first-run screen.
  - Distribution: ad-hoc signed DMG on GitHub Releases, built by CI from a tag (done). Notarization and Sparkle updates wait for the signing identity.
- **v1.1, copy extras:** remove "mailto:", force HTTPS, Songlink, "Copy without any parameters", "Expand short link".
- **v1.2, more coverage:** the ClearURLs catalog plus offline redirect unwrapping.
- **v1.3, power users:** the link tester, the "cleaned" flash, editing and adding rules, import/export.
- **v2:** Windows, maybe the Mac App Store.

## Product
**Lead with the per-app preview links** (market check 2026-10-18, `plan/r3_*.md`: no app does it; Unfurl, Clean Links and Pure Paste already clean links, so cleaning is table stakes). Tagline: "Links that preview right, in the app you paste them into. Trackers gone everywhere." Everything stays local: no history, no analytics, no network calls (except opt-in update checks).

### Screens
1. **First run** (one window, 3 steps)
   - What it does: a live example, "trackers removed" vs "preview link only in chosen apps, switched back after".
   - Preview links: opt-in, Telegram preselected. It warns that mirrors (fxtwitter, zzinstagram) are third-party services.
   - Start: checks clipboard access. If access is denied, a working Settings window opens instead of repeated prompts.
2. **Menu bar menu**
   - Status: Running / Paused / Access needed.
   - "Link cleaned · 2 min ago" and "1 284 trackers removed".
   - Pause/Resume, **Skip next clean** (the next copy is left untouched), Settings…, Check for Updates…, About, Quit.
   - It never shows clipboard contents or hostnames.
3. **Settings**, three tabs:
   - **General**: master switch; Dock icon, Menu bar icon, "Cleaned" flash and Open at login (independent toggles); automatic update checks; import/export/reset; privacy text; counter reset.
     - The flash is a brief panel that doesn't take focus and shows no URL.
     - Both icons can be hidden: reopening the app from Finder or Spotlight brings back Settings.
   - **Trackers**:
     - "All websites" plus one row per site, each with a switch and a readable description ("Remove utm_* everywhere") and parameter chips.
     - Built-in rules can be added, edited, disabled or reset, as an exact name or a prefix. No regex.
     - Amazon's "Remove referral path" is its own switch.
     - **Skip these websites**: exact host, with a subdomains option. It overrides all removals for that site.
   - **Preview links**: one row per rewrite, e.g. "X → fxtwitter.com", with app chips (Telegram…), a "Choose apps…" control, an Edit button and a switch.
     - This is the only place app assignments are edited; there is no separate Apps tab.
     - Telegram is one entry covering its 3 bundle IDs. Discord, WhatsApp and Slack are suggested, never auto-enabled.
4. **Tester**, inside Trackers and Preview links:
   - Paste a link and pick a target app to see Original → Cleaned → Preview link.
   - Removed parts are highlighted with the rule's name.
   - It never reads the clipboard by itself and makes no network calls.

Edits use Save/Cancel, and an invalid draft never affects monitoring. Keyboard navigation, VoiceOver and Reduce Motion are supported.

### Defaults
- All of today's tracker rules are on.
- Previews (after opt-in): X → fxtwitter and Instagram → zzinstagram, in Telegram.
- Menu bar on. Dock, flash and Open at login off.

## Rules model
- Built-ins come as bundled, versioned JSON with stable rule IDs.
- The user's overrides, custom rules, exclusions and app assignments live in one versioned JSON file in Application Support. Writes are atomic, and the last valid config is kept.
- Simple preferences use UserDefaults.
- App updates never overwrite the user's overrides and never silently enable a new mirror.
- **Conflicts**: two rewrites with overlapping sources (aliases and subdomains included) can't be active **in the same app**. Example: X can go to fxtwitter in Telegram and to another mirror in Discord. There is no priority UI. The same check runs on import and on built-in upgrades.
- Built-in preview matching never widens to arbitrary subdomains.
- **No remote rule feed in v1.** Dead mirrors are fixed by the user right away, or by a signed app update.
- Import/export covers the rules and app assignments only, never clipboard data or machine-specific preferences. An import is validated, previewed, then applied all at once.
- Counter: only the total is stored, and it can be reset. It counts one per external copy that actually had trackers removed; tester runs, restores and app-switch recomputes don't count.

## Architecture
- macOS 13+, universal binary.
- **FxEngine**: a Swift package with no UI, holding today's clean/embedify ported **unchanged**, then parameterized by the rules model.
- **App target**:
  - SwiftUI for Settings and first run.
  - AppKit for the app lifecycle, menu bar icon, pasteboard, frontmost-app watching, and the Dock on/off switch.
  - One file per responsibility.
- The clipboard loop keeps today's logic:
  - 0.3 s poll plus instant reaction to app switches.
  - `clearContents()` generation bookkeeping and the change-count check just before writing.
  - The clean original is kept, and the preview link is recomputed from it on every app switch, never from an already rewritten link.
  - A cached clean original never overwrites a newer copy.
  - Pause and Quit restore the clean original only if the clipboard is still ours.
- Open at login uses SMAppService.mainApp and shows its real status. Migration removes the old LaunchAgent so the two never run together.
- **Tests**:
  - Engine: today's behaviour frozen, plus encoded/nested URLs, fragments, empty or duplicate params, host boundaries, bracket trimming, Amazon paths.
  - Controller: competing copies, app A → B → outside, pause/quit, rule edits.
  - On device: rich text, images and files are left alone; real previews in Telegram.

## Distribution
- Developer ID signing, hardened runtime, notarized and stapled DMG.
- Sparkle 2 for updates, signed and over HTTPS. Sparkle asks for automatic-check consent on second launch; install is never automatic.
- Coexistence with clipboard managers (Raycast, Maccy, Paste) is tested in milestone 1: no duplicate history entries or fights over the clipboard. Pure Paste documents such conflicts.
- **Mac App Store deferred**: Unfurl claims sandboxed clipboard access, a precedent worth checking in milestone 1. Until proven, it stays deferred: whether clipboard and frontmost-app access work under the sandbox is UNVERIFIED.
- **Release gate**: macOS's clipboard privacy behaviour (`NSPasteboard.accessBehavior`, prompts on background reads) is UNVERIFIED. It must be proven on fresh signed installs on the oldest and current macOS: allow, deny, revoke, relaunch, login, icons hidden. Release is blocked if monitoring keeps prompting.
- No Accessibility or Automation permissions.
- **Name**: neutral brand. "fxclip" is a working name. No X, Twitter or Instagram in the name or logo, and no implied affiliation. Trademark clearance is UNVERIFIED.
- **Price**: free for v1.

## Milestones (short vertical cycles, each tested)
1. **Signed working app**: done when copy → clean → paste and permission recovery pass on a real device with a signed build.
2. **Per-app previews** (the differentiator, so it comes first): done when Telegram → another app → outside restores safely, and the tester output matches real pastes.
3. **Editable Trackers and exclusions**: done when an edit saved in Settings changes a real copy, and export → import preserves behaviour.
4. **Presence and first run**: done when every icon combination, relaunch and Open at login work.
5. **Public beta**: done when a fresh-machine install and a signed update succeed, the permission, mirror and old-LaunchAgent checks pass, and the privacy, support and rollback pages are published.

## Owner decisions still open
- **Public name**: a neutral brand is needed before milestone 5. "FxClip" is already the name of a Freelap sports accessory.
- **Apple Developer account** ($99/yr): needed from milestone 1, for signing and notarization.

## Windows (after the v1 Mac release)
- The Swift toolchain runs on Windows, and Arc for Windows ships in Swift. The only part that carries over is the engine; the UI layer (SwiftUI/AppKit) does not exist on Windows.
- **Recommended**: a native C# + WinUI 3 app with its own engine (~200 lines). It reads the **same rules JSON** and must pass the **same before/after test links**, so any difference in behaviour fails the tests.
  - Alternatives: Swift + swift-winrt (the Arc approach, tooling still young), or C# calling the Swift engine as a DLL (means shipping the Swift runtime and bridging two languages).
- Windows-specific work:
  - `AddClipboardFormatListener` tells the app when the clipboard changes, so no polling. `GetClipboardSequenceNumber` plays the role of `changeCount`.
  - `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` gives the app in front, matched by its exe name.
  - Our rewrites are kept out of clipboard history (Win+V) and cloud clipboard with the `ExcludeClipboardContentFromMonitorProcessing` / `CanIncludeInClipboardHistory` formats.
  - The app lives in the system tray (the Windows equivalent of the menu bar icon) and starts at login with a startup task.
  - Distribution: MSIX, winget, then maybe the Microsoft Store. Code signing through Azure Trusted Signing to avoid the SmartScreen warning.
- **What it changes in the Mac plan now**: from milestone 1, the rules and the before/after test links are language-neutral JSON files in `Shared/`, and FxEngine stays free of AppKit.

## Additions 2026-10-18 (ideas from Velja + URLCheck, owner's calls)
- **ClearURLs catalog as the base layer** (206 sites, 742 rules, LGPL-3.0, github.com/ClearURLs/Rules).
  - It ships as a separate, credited data file (`Shared/clearurls.json`), updated with app releases.
  - Our rules sit on top and win on conflicts. Sites get a "keep" list so useful params survive the catalog (Amazon `keywords`/`th`, YouTube `t`/`list`).
  - Every change it makes to the legacy test links is reviewed one by one before it ships.
  - LGPL compliance for a closed app is UNVERIFIED.
- **Offline redirect unwrapping** from the same catalog (61 sites): `google.com/url?q=`, `l.facebook.com/l.php?u=`, `out.reddit.com`, `youtube.com/redirect`… The wrapped link replaces the wrapper, then gets cleaned.
- **When copying** (General › "When you copy a link", each a toggle, off by default like Velja):
  - **Remove leading "mailto:"** from copied email addresses.
  - **Force HTTPS**: `http://` becomes `https://`. Off by default because sites without HTTPS would break; the tester shows the effect.
- **Songlink** (song.link) for Apple Music, Spotify, TIDAL and Deezer, as a built-in Preview links row with its own app chips (plus an "All apps" chip). Off by default.
  - This is a new rewrite type that wraps the link (`https://song.link/<link>`) instead of swapping its host.
- **Expand short link** (bit.ly, t.co, lnkd.in…), **on demand only**: from the menu ("Expand short link") and in the tester.
  - fxclip asks the shortener directly (follows redirects, never loads the page). No third party. Never automatic.
  - The menu and the privacy text say the shortener sees the request.
- **Copy without any parameters**: a one-shot menu action, for when a site's parameters are all noise.
- **Link parts in the tester**: scheme, host, path and each query parameter, decoded.
- **Not taken**: cleaning links when *opening* them (needs fxclip to be the default browser; Velja's job); suspicious-link warnings; VirusTotal; webhooks; link history (contradicts "nothing stored").
- **Where they land**: ClearURLs and unwrapping in milestone 3 (Trackers). mailto, HTTPS, Songlink, expand and strip-all form a new **milestone 3b, "Copy extras"**: done when each toggle is seen working on a real copy and in the tester.
