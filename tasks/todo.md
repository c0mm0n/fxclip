# v1.0 (docs/00_app_plan.md › Versions)

Done when: every v1 toggle, seen in Settings, changes a real copy on this Mac; the app reopens from Spotlight with both icons hidden; Open at login works through SMAppService (LaunchAgent removed).

- [x] Engine: UserSettings model (pure Codable) + Rules.applying(settings) + "never clean" hosts; tests
- [x] SettingsStore: JSON in Application Support, atomic save, live engine update
- [x] Settings window (toolbar tabs): Preview links (on/off, apps per rewrite, Choose apps sheet), Trackers (site toggles, never-clean list), General (menu bar, Dock, Open at login, counter, privacy)
- [x] Menu: Settings… ⌘,
- [x] Presence: menu bar icon / Dock toggles, reopen → Settings
- [x] Open at login: SMAppService.mainApp; remove the legacy LaunchAgent
- [x] First-run screen (one screen, previews opt-in, Telegram preselected)
- [x] Live verification on this Mac (only after the owner's go for clipboard tests)
- Later in v1, blocked on the signing identity: Developer ID, notarized DMG, Sparkle

## Review (2026-10-18)
- Engine: 11 tests (legacy vectors + settings layer). Screens checked on screenshots: welcome, General, Trackers, Preview links, Choose apps.
- On the owner's Mac: Discord added on the X row → fxtwitter in Discord ✓; example.com in "Never clean" → link kept ✓; menu bar icon off → reopen from Spotlight shows Settings ✓.
- Left in v1: Developer ID signing, notarized DMG, Sparkle — blocked on the signing identity (not decided yet).
