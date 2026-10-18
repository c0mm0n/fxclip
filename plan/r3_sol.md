# Round 3 — market check, 2026-10-18

Read against `docs/00_app_plan.md`. Searched GitHub, App Store, Product Hunt and Reddit. Documentation review, not installed-app testing. ✓ documented; partial = incomplete/manual/custom assembly; ✗ = outside documented scope; U = unverified. F1–F5 follow the brief; F4 requires **both** byte preservation and non-text/rich-text safety. Dates are latest verified releases; U is not evidence of abandonment. Prices USD unless stated.

| App | Platform | Price | F1/F2/F3/F4/F5 | Last release | Source URL |
|---|---|---|---|---|---|---|
| Unfurl | Mac/iOS | $5.99 | ✓/✓/✗/U/✓ | 2026-09, 2.3 | [Product](https://unfurl.software/), [features/releases](https://unfurl.software/features) |
| Clean Links | Mac/iOS | Free | ✓/U/✗/U/✓ | 2026-09-28 | [Clipboard](https://cleanlinks.app/en), [Store](https://apps.apple.com/us/app/clean-links-url-cleaner/id6747395062) |
| TrackerZapper | Mac | Free | ✓/✗/✗/partial/✗ | 2022-02-02 | [App](https://github.com/rknightuk/TrackerZapper), [releases](https://github.com/rknightuk/TrackerZapper/releases) |
| Pure Paste (Sorhus) | Mac | $4 | ✓/partial/✗/✗/✓ | 2026-09-14 | [Product](https://sindresorhus.com/pure-paste), [Store](https://apps.apple.com/app/id1611378436) |
| PurePaste (jayf0x) | Mac | Free | ✓/U/✗/U/partial | U | [GitHub](https://github.com/jayf0x/Pure-Paste) |
| AlterPaste | Mac | Free | ✓/✓/✗/U/✗ | 2024-12 | [Product](https://www.alterpaste.com/) |
| Notchy | Mac | Free | ✓/U/✗/U/partial | U; ≥1.0.172 | [Product](https://notchy.dev/mac-clean-links/) |
| Paste | Mac/iOS | $29.99/year | ✗/✗/✗/U/partial | U | [Plans/features](https://pasteapp.io/pricing) |
| Maccy | Mac | Free/GitHub | ✗/✗/✗/U/partial | Aug 10; year U | [App](https://maccy.app/), [2.7.1](https://github.com/p0deje/Maccy/releases/tag/2.7.1) |
| Raycast history | Mac/Windows | Free tier | ✗/✗/✗/U/partial | U | [Manual](https://manual.raycast.com/clipboard-history), [pricing](https://www.raycast.com/core-features/ai) |
| Raycast Link Cleaner | Mac | Free tier | partial/U/✗/U/partial | 2026-07-09 | [Store](https://www.raycast.com/MisakiCoca/link-cleaner) |
| Raycast Fix Link Embeds | Mac | Free tier | ✗/partial/partial/U/partial | 2026-07-16 | [Store](https://www.raycast.com/eggsy/fix-link-embeds) |
| Alfred Link Clean | Mac | Powerpack; price U | partial/U/✗/U/partial | U; v25.1 | [Gallery](https://alfred.app/workflows/vitor/link-clean/) |
| ClearURLs | Browser | Free | partial/partial/✗/U/✗ | 2025-02-05 | [Features](https://github.com/ClearURLs/Addon), [releases](https://github.com/ClearURLs/Addon/releases) |
| Link Cleaner + Shortcuts/CLI | Web/Mac/iOS | Free | partial/partial/✗/U/✗ | U | [Product/integrations](https://linkcleaner.app/) |
| Hammerspoon | Mac | Free | partial/✓/partial/U/✓ | 2026-02-26 | [Clipboard](https://www.hammerspoon.org/docs/hs.pasteboard.watcher.html), [app events](https://www.hammerspoon.org/docs/hs.application.watcher.html), [release](https://www.hammerspoon.org/releasenotes/1.1.1.html) |
| Keyboard Maestro recipes | Mac | $36 | partial/✓/partial/U/partial | U | [Product](https://www.keyboardmaestro.com/main/), [recipe](https://forum.keyboardmaestro.com/t/stripping-tracker-portions-from-a-url-clean-url-parameters/4005), [clipboard](https://wiki.keyboardmaestro.com/trigger/Clipboard_Changed), [app events](https://wiki.keyboardmaestro.com/trigger/Application) |
| Embed Fixer | Discord bot | U | ✗/partial/partial/✗/✗ | U | [GitHub](https://github.com/seriaati/embed-fixer) |
| Safari Link Tracking Protection | Mac/iOS | Bundled | partial/✗/✗/U/partial | U | [WebKit](https://webkit.org/blog/15697/) |

**Closest:** Unfurl already supplies automatic cleaning, editable per-site rules and exclusions, but documents no destination-app mirror switching with automatic restoration.

**Verdict: BUILD.** No verified ready-made solution covers F3 end-to-end; Hammerspoon/Keyboard Maestro provide primitives, requiring custom restoration/race handling. Forking TrackerZapper still leaves that core work.

**Plan changes:** Lead with per-app previews; prioritize milestone 3 earlier. Add “skip next clean” and clipboard-manager coexistence checks (Pure Paste documents conflicts). Keep no-history privacy and strict F4 tests. Unfurl advertises sandboxed clipboard access: investigate that precedent without relaxing the signed-install permission gate. Safari's verified feature cleans navigation, not every clipboard; its named “Copy Link without tracking” command remains unverified. “fxclip” already names a [Freelap accessory](https://www.freelap.com/wp-content/uploads/2024/06/catalog_running.pdf); trademark clearance remains open.
