# fxclip — public macOS release plan

## Product

Ship a quiet utility: “Remove trackers everywhere. Improve previews in apps you choose.” Keep clipboard contents local, with no history, analytics, or URL fetching.

First run shows an editable example, explains permanent tracker removal versus temporary preview links, and discloses that recipients/preview services contact third-party mirrors. Telegram is preselected; previews require explicit acceptance. “Start” enables monitoring after an access check; denial leaves a useful Settings window, not repeated prompts.

Defaults: all existing tracker rules enabled; accepted previews use X→fxtwitter and Instagram→zzinstagram in Telegram only. Menu bar on; Dock, cleaned flash, login launch off.

Menu: Running/Paused/Access needed, Pause/Resume, Settings…, Check for Updates…, About, Quit. Show no clipboard excerpt. Pause and Quit restore the clean original only while we still own that clipboard generation.

Settings tabs:
- **General:** monitoring, independent Dock/menu-bar/“Link cleaned” flash/login toggles, update-check consent (off initially), version and privacy explanation. Flash is a brief nonactivating panel without URL content. Allow both icons off; explain reopening from Finder/Spotlight and always reopen Settings.
- **Trackers:** “All websites” plus site groups; switches, readable descriptions, exact parameter names, prefix badges, and Amazon’s separate “Remove referral path” switch. Add/edit/delete custom rules; edit/disable/reset built-ins. Editor chooses website scope, exact name or prefix, and enabled state; no regex.
- **Preview links:** source domains → replacement domain, enabled switch, and app chips. Add/edit/delete/reset; require a valid HTTPS destination host, forbid credentials/paths and overlapping source rules. Expose explicit source aliases; preserve today’s matching boundaries.
- **Apps:** installed-app picker, selected apps with icons and per-rewrite switches; remove an app without deleting rules. Store bundle identifiers; retain missing apps as “Not installed.” Telegram’s three existing identifiers share one entry. Discord/WhatsApp/Slack are opt-in; browser tabs are outside scope.

Trackers and Preview links share a live tester: typed/pasted example + target app → Cleaned → Preview link, with removed parts highlighted and named reasons. Never automatically read the clipboard for examples; no network requests. Edits use Save/Cancel; invalid drafts never affect monitoring. Support keyboard navigation, VoiceOver labels and Reduce Motion. Import/export/reset sit in Settings; replacement/reset requires confirmation.

## Rules and persistence

Bundle versioned JSON with stable rule IDs, exact names/prefixes, domain scope, explicit preview aliases, and the dedicated Amazon path operation. Store custom rules, built-in overrides, disable flags and app assignments in one versioned Codable JSON file under Application Support; atomic writes, migration and last-good recovery. UserDefaults holds presentation preferences.

Built-ins remain inspectable; updates never overwrite overrides or silently enable new mirrors. Export effective rules and assignments, excluding clipboard data and machine preferences. Import validates schema, hosts and conflicts, previews replacement, then applies atomically.

No remote rules feed in v1: ship reviewed defaults through app updates; users can repair dead mirrors immediately. One update mechanism keeps trust and maintenance simple.

## Architecture and correctness

Target macOS 13+, universal binary. One app target, one small Foundation-only engine target, test targets; one file per responsibility. SwiftUI owns settings/editors/onboarding; AppKit owns lifecycle, status item, pasteboard and workspace observation. No daemon, generic rule interpreter or simulated product engine.

Port clean/embedify unchanged before parameterizing. Preserve raw retained bytes, decoded-name matching, exact-name case sensitivity, case-insensitive prefixes, punctuation and anchored rewrites.

Keep the 0.3-second poll and activation notifications. Store the clean baseline plus our generation; recompute from that baseline when switching app-specific rules, never rewrite an already mirrored URL. External copies supersede it. Preserve clearContents() generation bookkeeping and pre-write checks; cross-process writes are not transactional.

Use regular/accessory activation policies for Dock presence. Use [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp) for login; display actual approval status. Retire the existing KeepAlive agent during owner migration before running both.

Tests cover current examples, encoded/nested URLs, fragments, duplicate/empty parameters, host boundaries, bracket trimming and Amazon paths; integration cases cover rich-text/image/file skips, competing copies, app A→B→outside, pause, quit and rule edits.

## Distribution and release gates

Release Developer ID + hardened runtime + notarized, stapled DMG; [Apple requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Use [Sparkle 2](https://sparkle-project.org/documentation/) with signed updates over HTTPS; automatic installation off.

Defer Mac App Store. It [requires sandboxing](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution); recommend unsandboxed v1. Sandbox compatibility of pasteboard reads/writes and frontmost-app observation is **UNVERIFIED**: prove with a signed sandboxed build before promising store support. Do not add Accessibility or automation permissions speculatively.

Apple documents per-app [pasteboard access behavior](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum), including ask/allow/deny. OS-specific rollout, background prompts and metadata-read behavior are **UNVERIFIED**. Test fresh signed installs on minimum/current macOS, denial/revocation, login and hidden-icon operation; block release if monitoring repeatedly prompts.

## Owner questions — recommended answers

1. Mirror reliability/privacy? Explicit opt-in; no availability guarantees.
2. Public name? Neutral brand; keep fxclip provisional. Trademark clearance, including “fx,” is **UNVERIFIED**; avoid X/Twitter/Instagram in the product name and platform logos/implied affiliation ([Apple policy](https://developer.apple.com/app-store/review/guidelines/#intellectual-property)).
3. Monetization? Free first release; validate usefulness before licensing infrastructure.

## Ordered milestones

Use 60–90-minute vertical cycles, each tested and checkpointed.
1. Signed working app: done when copy→clean→paste and permission recovery pass on-device.
2. Editable Trackers: done when save→real clipboard and export→import preserve behavior.
3. App-specific previews: done when A→B→outside restores safely and examples match actual pastes.
4. Presence/onboarding: done when all icon combinations, relaunch and login work.
5. Public beta: done when fresh-machine installation and signed update succeed; permission, mirror and legacy-agent checks pass; privacy/support pages and rollback instructions are published.
