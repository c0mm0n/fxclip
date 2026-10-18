# fxclip — public macOS app plan

## Product

Ship a quiet native utility, macOS 13+, with four Settings tabs: General, Trackers, Preview links, Apps.

First run: explain “Trackers are removed everywhere; preview links change only in chosen apps, then switch back.” Show one example of each. Disclose automatic clipboard reading, no history/uploads, and that preview services receive links when shared. Offer sample testing before “Enable automatic cleaning”; request clipboard access only then. Defaults after consent: existing tracker rules enabled; existing X/Instagram mirrors enabled for Telegram’s three bundle IDs; menu bar on, Dock off, cleaned flash off, launch at login off. Other apps require explicit selection.

Menu: Active/Paused/Clipboard access needed; Pause/Resume; Settings; Check for Updates; About; Quit. Never display clipboard contents. Pause and Quit restore our clean original only if clipboard ownership still matches.

General: independent Dock, menu bar, launch-at-login and “Show ‘Cleaned’ flash” toggles; master cleaning switch; import/export. Flash is a brief nonactivating panel, never containing links. If both icons are hidden, explain once that reopening the app in Finder/Spotlight opens Settings; honor the choice. Closing Settings keeps the utility running.

Trackers: searchable “All websites” and website rows, toggles, readable examples (“Remove utm_* from every website”), and expandable parameter chips. Add/edit/remove exact names or prefixes and domains; per-rule Reset and Restore defaults. Amazon’s “Remove referral path suffix” is a separate switch. Preserve today’s exact-name case sensitivity and case-insensitive prefixes; explain this in editor help.

Preview links: rows like “X → fxtwitter.com · Telegram”; enabled switch, editable source domains/subdomain choices, HTTPS destination, app checkboxes, delete/reset. Built-ins retain today’s matching boundaries. No regex editor. Multiple matching rewrites require explicit priority; apply one rewrite only. New rules start disabled until saved and assigned apps.

Apps: add installed applications through a picker; store bundle IDs, show name/icon and enabled preview rules. Missing apps remain removable; Discord, WhatsApp and Slack are suggestions, never auto-enabled. A browser entry means the whole browser, not a web app/tab.

Every rule editor includes an offline tester: input, chosen destination app, “Original → Cleaned → Preview link”, highlighted changes and rule names. It never changes the clipboard or contacts mirrors. Draft edits require Save/Cancel; invalid domains and conflicting rules get inline explanations. Support keyboard navigation, VoiceOver and increased contrast.

## Rules and storage

Bundle versioned JSON defaults with stable rule IDs. Store a schema-versioned user JSON document in Application Support: overrides/disabled built-ins, added rules, priorities and per-rewrite bundle-ID sets. User overrides win across updates; Reset removes an override. Scalars use UserDefaults. Validate before atomic writes; retain the last valid configuration.

No remote rule feed in v1: mirror changes ship with signed app updates, avoiding a second trust/update mechanism. Users can immediately edit or disable dead mirrors. Import/export configuration JSON, excluding clipboard text and machine-specific presence/login preferences; preview differences, confirm replacement, reject unsupported schemas without changing settings. No accounts, sync, telemetry or clipboard logs.

## Architecture and behavior

One app target plus a Foundation-only Swift package for rules/clean/embed functions and tests. SwiftUI Settings/onboarding; AppKit owns NSPasteboard, NSWorkspace, NSStatusItem, window reopening and activation policy (.regular with Dock, .accessory otherwise). Separate small files by responsibility; no daemon or generic rule engine.

Keep the 0.3-second poll, activation notifications and generation bookkeeping. On every app switch, derive the selected app’s output from the retained clean original, never from a previous mirror. New copies cancel restoration; rule changes/disable/pause reconcile only owned content. Preserve raw kept bytes, punctuation, nested URLs, Amazon suffix behavior and rich-text/image/file exclusions.

Use [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice) for login registration, displaying actual status/errors. Replace the old LaunchAgent explicitly during migration; never run both.

Tests freeze existing behavior, encoding/case/domain boundaries and bracket trimming. Controller tests cover copies during processing/restoration and switches between differently configured apps. Real-app checks verify formatting preservation, reopening while hidden, login, permissions and actual previews.

## Distribution and release gates

Recommend Developer ID, Hardened Runtime, notarized/stapled DMG and [Sparkle 2](https://sparkle-project.org/documentation/) with HTTPS and EdDSA-signed updates. Defer Mac App Store: its [rules](https://developer.apple.com/app-store/review/guidelines/#software-requirements) require sandboxing and App Store updates; acceptance is UNVERIFIED.

Sandbox alone is not evidence that global clipboard access/frontmost-app observation is impossible. Test signed sandboxed and unsandboxed builds using NSPasteboard and [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication); exact restrictions are UNVERIFIED. Do not request Accessibility/Automation permissions speculatively.

Apple documents per-app [pasteboard access behavior](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-86972). Exact OS rollout, prompts and background-read behavior are UNVERIFIED. Prove fresh-install allow/deny/revoke, relaunch and login on minimum/current macOS devices; denial must stop repeated reads and expose recovery instructions.

Use a distinctive neutral brand; “fx”/fxclip trademark clearance is UNVERIFIED. Avoid Twitter/Instagram branding in name/icon and imply no affiliation; check listing wording against [metadata rules](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).

## Owner questions — recommended answers

1. Privacy prompts block automation? Gate release on device proof.
2. Mirrors die or redirect? Manual editing plus signed updates; no probes.
3. Broken links? Preserve baseline defaults; expose rule disable/test/reset.
4. Two hidden icons? Allow, with reopening recovery.
5. Store launch? Direct distribution first.

## Ordered milestones

Each milestone comprises sequential 60–90-minute vertical cycles, tested with a checkpoint.

1. Signed app slice: done when copy/clean/restore and permission outcomes work on devices.
2. Editable rules: done when both editors, tester and persistence drive real copies.
3. App/presence choices: done when per-app switching, hidden reopening, pause and login work.
4. Public release: done when import/export, migration, accessibility, notarization and Sparkle upgrade pass on a fresh account; download/support/privacy pages are ready.
