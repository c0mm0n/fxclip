Checked 2026-10-18; live documentation, not installation tests. ✓=documented; partial=incomplete/DIY; ✗=not supplied by documented workflow; U=unverified. F1–F5 follow the brief’s order. Dates are latest located releases, not crawl dates; U is not evidence of abandonment.

| App | Platform | Price | F1/F2/F3/F4/F5 | Last release | Source |
|---|---|---|---|---|---|---|
| Unfurl | Mac/iOS | $5.99 | ✓/✓/✗/U/partial | 2026-09, claimed | [Features](https://unfurl.software/features), [price](https://unfurl.software/) |
| Clean Links | Mac/iOS | Free | ✓/U/✗/U/✓ | 2026-09-15 | [Store](https://apps.apple.com/us/app/clean-links-url-cleaner/id6747395062?platform=mac) |
| Pure Paste | Mac | $4 | ✓/partial/✗/✗/✓ | 2026-09-14 | [FAQ](https://sindresorhus.com/pure-paste), [release](https://apps.apple.com/us/app/pure-paste/id1611378436?mt=12) |
| TrackerZapper | Mac | Free | ✓/✗/✗/partial/✗ | 2022-02-02 | [Releases](https://github.com/rknightuk/TrackerZapper/releases) |
| LinkCleaner (Lynch) | Mac | U | ✓/U/✗/U/partial | U | [Developer](https://davidlynch.org/apps/linkcleaner/) |
| Link Cleaner (Davenport)/Shortcuts | Web/Mac/iOS | Free | ✗/U/✗/U/✗ | U | [Project](https://linkcleaner.app/) |
| ClearURLs | Browsers | Free | ✗/partial/✗/U/✗ | U | [Repository](https://github.com/ClearURLs/Addon) |
| Paste | Mac/iOS | Paid; amount U | ✗/✗/✗/U/partial | U | [Product](https://pasteapp.io/) |
| Maccy | Mac | Free | ✗/✗/✗/U/partial | U | [Product](https://maccy.app/) |
| Raycast history | Mac/Windows | Free/Pro | ✗/✗/✗/U/partial | U | [Manual](https://manual.raycast.com/clipboard-history) |
| Raycast Fix Link Embeds | Mac | U | U/U/partial/U/partial | U | [Listing](https://www.raycast.com/store/recent/129/feed.json/feed.json/feed.atom) |
| Alfred Link Clean | Mac | Powerpack; amount U | ✗/U/✗/✗/partial | 25.1; date U | [Gallery](https://alfred.app/workflows/vitor/link-clean/) |
| Hammerspoon | Mac | Free | partial/partial/partial/U/partial | U | [Clipboard](https://www.hammerspoon.org/docs/hs.pasteboard.watcher.html), [apps](https://www.hammerspoon.org/docs/hs.application.watcher.html) |
| Keyboard Maestro Decrufter | Mac | Paid host; amount U | ✓/partial/✗/U/✗ | 2024-05-27 recipe | [Recipe](https://forum.keyboardmaestro.com/t/macro-an-automatic-url-decrufter-for-defined-hosts/23830) |
| FixTweetBot | Discord | Free/Premium | ✗/partial/partial/U/✗ | U | [Repository](https://github.com/Kyrela/FixTweetBot) |
| Safari/Apple LTP | Mac/iOS | Included | ✗/✗/✗/U/partial | U | [Apple](https://www.apple.com/privacy/features/) |
| Notchy | Mac | Free | ✓/U/✗/U/partial | 1.0.172; date U | [Developer](https://notchy.dev/mac-clean-links/) |
| PasteMemo | Mac | Free | ✓/partial/✗/U/✓ | 2026-09-21 | [Features](https://www.lifedever.com/PasteMemo/), [release](https://github.com/lifedever/PasteMemo-app/releases) |
| AlterPaste | Mac | Free | ✓/partial/✗/U/✗ | 2024-12 | [Developer](https://www.alterpaste.com/) |

**Closest competitor:** Unfurl advertises automatic cleaning, editable per-site rules and exclusions, but no destination-app mirror rewriting with automatic clean-original restoration; its App Store listing could not be verified.

**Verdict: BUILD**, narrowly for F3: no verified ready-made combination satisfies it. Hammerspoon/Keyboard Maestro can implement it, but require bespoke restoration/race logic. A cleaner plus Discord bot covers participating chats, not arbitrary apps or clipboard restoration. No maintained fork target removes that work without adding clipboard-history scope.

**Plan changes:** Lead with destination-specific previews; cleaning and rule editing are table stakes. Bring F3 into the first working slice. Add “skip next cleaning” and clipboard-manager coexistence checks ([Pure Paste documents conflicts](https://sindresorhus.com/pure-paste)). Preserve no-history positioning. Do not claim competitors preserve bytes: none proved full F4. Unfurl’s feature/changelog and FAQ disagree about rule editing; verify hands-on before treating claims as shipped. Apple LTP is scoped browsing/sharing, not a system clipboard watcher; Safari’s exact “Copy Link without tracking” command remains unverified.

Name check: [FxClip already names a Freelap accessory](https://freelap-adria.com/proizvod/fxclip/); no same-purpose app surfaced. This is not trademark clearance.
