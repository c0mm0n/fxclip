# Brief: turn fxclip into a real, publicly released macOS app

## What exists today (working, in daily use)
`fxclip.swift` (~190 lines, AppKit, no UI), run as a LaunchAgent (`KeepAlive`). Read it.
- Everywhere: strips tracking/affiliate params from copied links (global list: utm_*, fbclid, gclid, msclkid…; per-site lists: X s/t, YouTube si/pp, Instagram igsh/exln, TikTok, Spotify, Amazon tag + `/ref=` path, AliExpress, Facebook, LinkedIn, Reddit). Kept params stay byte-for-byte (raw-string filtering, no URLComponents rebuild). Punctuation/brackets around a URL in prose are preserved.
- Only while Telegram is frontmost: x.com/twitter.com → fxtwitter.com, instagram.com → zzinstagram.com (embed mirrors for link previews). On leaving Telegram, the clean original is restored unless the user copied something since (changeCount bookkeeping, `ourCount = clearContents()`).
- Skips images, files, and rich text unless the rich text is a single bare URL.
- Polls `NSPasteboard.changeCount` every 0.3 s + reacts instantly to `didActivateApplicationNotification`.
- Already went through 2 adversarial review rounds (races, re-encoding, nested URLs, quadratic trimming all fixed).

## What the user wants (their answers, verbatim intent)
- **Audience: public release.** Real distribution, strangers install it.
- **Rewrite targets: user-picked list of apps** (Telegram default; Discord, WhatsApp, Slack… addable).
- **Presence: the USER decides** — Dock icon / menu bar icon / "cleaned" flash / launch at login, all toggles.
- **"Full UI to decide what we trim, where we do the fx and kk etc."** — i.e. the user can see and edit: which tracking params are stripped (global + per site), which mirror rewrites exist (x→fxtwitter, instagram→zzinstagram, and future ones; mirrors die/change — kk was replaced by zz last week), and in which apps each rewrite applies.

## Owner's style constraints
- Simplicity in code, ambition in product. No gadgets. Small, readable Swift; one file per responsibility.
- The engine (pure functions: clean / embedify) must stay testable without UI; existing behaviour is the spec — port it, don't re-invent it.

## Your job (plan conference, you are one of two independent planners; a third model will synthesize and seek consensus)
Produce a plan covering:
1. **Product**: the screens (menu bar menu, Settings window tabs, onboarding/first run), what each shows, every user decision, defaults. Name concepts in the user's vocabulary (e.g. "Trackers", "Preview links"/"Rewrites", "Apps"). How rules are presented so a non-technical user gets it in 2 seconds (e.g. live "before → after" tester).
2. **Rules model**: how built-in rules vs user rules are stored (JSON? versioned built-in set? remote rule updates for dead mirrors — yes/no and why), import/export.
3. **Architecture**: SwiftUI vs AppKit split, targets/modules, persistence, login item (SMAppService), Dock/menu-bar toggle (activation policy), testing strategy (engine unit tests from today's behaviour).
4. **Distribution**: Mac App Store vs Developer ID + notarization + Sparkle (or both). Sandbox implications for reading/writing the pasteboard and reading the frontmost app. macOS pasteboard privacy prompts on recent macOS (programmatic pasteboard reads) — what is known, what must be PROVEN on a device. Name/branding risk (using "fx"/Twitter/Instagram trademarks in the name or App Store listing).
5. **Risks & open questions** for the owner (max 5, each with your recommended answer).
6. **Milestones** (ordered, each with a "done when").

Rules: ≤ 900 words. Be opinionated; give ONE recommendation per decision, alternatives in one line max. Mark anything you're unsure of about current Apple policy/APIs as UNVERIFIED rather than asserting it. Do NOT write code or modify any file except your output file.
