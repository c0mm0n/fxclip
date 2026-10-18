# Round 3: does an existing app already cover this need? (market check before mockups)

Read `docs/00_app_plan.md` (the consensus plan) for what we intend to build.

## Question
Is there already a macOS app (or a combination: clipboard manager feature, Raycast/Alfred extension, Shortcuts automation, browser extension + something, open-source tool) that covers this need, well enough that building ours is pointless, or that we should fork or contribute to instead?

The need, as features to check one by one:
- F1. Automatically strips tracking/affiliate params from links **on the clipboard**, system-wide, with no gesture.
- F2. Rules can be edited by the user (per-site parameters, exclusions).
- F3. **Per-destination-app** rewriting: rewrite x.com → fxtwitter.com / instagram.com → zzinstagram.com (or any mirror) **only when pasting into chosen apps** (Telegram, Discord…), and restore the clean original elsewhere.
- F4. Preserves the rest of the link byte-for-byte, skips images/files/rich text.
- F5. Public, maintained (release within the last ~12 months), native macOS.

Candidates to check at least (verify they exist; don't trust this list): TrackerZapper, Clean Links (iOS/macOS), Pure Paste, Paste / Maccy / Raycast clipboard history, Raycast or Alfred extensions for link cleaning or fxtwitter, ClearURLs (browser), Link Cleaner, Apple Shortcuts automations, Hammerspoon/Keyboard Maestro recipes, Telegram/Discord bots or clients that fix embeds on their own (e.g. Discord embed-fix bots), Safari's "Copy Link without tracking" / Link Tracking Protection. Search for others too (GitHub, Mac App Store, Product Hunt, Reddit).

## Output
Write ≤ 500 words to your output file:
1. A table: app | platform | price | F1–F5 (✓ / partial / ✗) | last release date | source URL. Only list what you actually verified on a live page; mark anything unverified.
2. The closest competitor, and the exact gap left (in one sentence).
3. Verdict: BUILD / DON'T BUILD / FORK-OR-CONTRIBUTE (name the project), with one reason.
4. Anything that should change in our plan (e.g. positioning, a feature that's table stakes we missed, a name already taken: check "fxclip").

Use web search. Modify no file other than your output file. No code.
