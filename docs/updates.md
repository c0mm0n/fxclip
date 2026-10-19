# Integrated updates

Delivery order: **Mac → Windows → Linux with Qt UI → Android**. Each platform ships in its own PR, passes a real old-to-new update test and is released before the next platform starts. No website, paid certificate, account or telemetry is required.

Manual checking is always available. Automatic checks are opt-in, at most daily. Download and installation need explicit confirmation; never silently restart. Cleaning stays offline, and copied links never enter update requests. Current architectures and minimum OS versions stay unchanged.

## Mac: first delivery (0.4.0)

Sparkle 2.10.0 is pinned in XcodeGen. AppUpdater owns the controller for the app lifetime, shares it with the app menu, status menu and Settings, and leaves preferences to Sparkle. Automatic checks and downloads default off. System-profile keys are excluded. The existing termination handler restores a clean clipboard link before the updater relaunches the app.

The ad-hoc signed app keeps Hardened Runtime with the approved library-validation exception for the embedded framework. No Apple identity is used. The public Ed25519 key is embedded; the private key belongs in the release secret `FXCLIP_SPARKLE_PRIVATE_KEY` and a protected off-repository backup. Preserve that key for future updates.

After building the exact DMG, `tools/make_appcast.sh` uses Sparkle's official tools to sign the archive and feed, embed release notes and validate the immutable versioned URL, size and versions. Publication requires all four platform downloads plus `appcast.xml` before making the draft latest. Every future release must continue producing this feed, even while another OS updater is being added.

### Reproduce the real update test

1. Run `tools/prepare_mac_update_test.sh /absolute/unused/test-directory`. It makes builds 100 and 101 with a dedicated bundle ID, an ephemeral signing key and a signed DMG feed pointing at `http://localhost:8769`.
2. Serve its `downloads` directory on localhost port 8769, then open `installed/fxclip-update-qa.app`. The real Settings page opens with automatic checks off. No request should reach the server until explicitly checking.
3. Close the offer first: no DMG download or replacement. Check again, accept the download, confirm **Install and Relaunch**, then verify build 101, one process, unchanged test settings and the preserved update preference.
4. Use fresh download URLs for failure fixtures to avoid cache reuse. An altered archive with the original signature must be refused before extraction; a cancelled slow download and an unavailable feed must leave the old app working. Rechecking the installed version must say it is up to date.

`UPDATE_TESTING` is only set by this test build command, never by release or PR packaging. These builds never start the clipboard watcher, skip login setup and keep JSON settings next to the installed test app; UserDefaults uses the dedicated QA bundle ID. `--welcome-test` displays the welcome window for screenshots only: do not click Start. Production builds have no test launch mode or HTTP feed override.

## Windows: second delivery (0.5.0)

Velopack 1.2.161 runs before the mutex/WPF startup, with a per-user installer, a Velopack portable ZIP retaining the existing download filename, and native release packages/feed on public GitHub Releases. Keep AppData settings/counter and migrate an enabled login entry to the new location. Add checking, notes, progress and **Restart to Update** to the tray menu and Settings. Disable automatic application on exit. No paid signing certificate in this work.

## Linux: after Windows

First review/integrate Qt UI PR #8. Add the same update controls to its Settings and tray, using Qt Network, the latest stable public GitHub release and its asset SHA-256 digest. Stage and verify the complete archive before closing the UI/service or replacing files. Extend the per-user installer with a previous-version backup and rollback on failed installation/restart. Restart both service and UI after confirmation. Automatic checks run only while the UI is open; the cleaner daemon stays offline.

## Android: last

Add update controls and an opt-in daily check at foreground entry. Add internet/install permissions with clear explanation. Download privately and verify digest, package ID, increasing versionCode and installed signing-certificate compatibility before handing over to Android's installer. Explain the unknown-source setting when needed and handle cancellation. Keep the existing APK signing key and all data; never uninstall a public build to update it. Do not promise silent installation or automatic relaunch.

Windows verification: `Windows/tools/update-e2e.ps1` builds isolated 1.0.0 and 1.0.1 fixtures with `UPDATE_TESTING`, packages real Velopack portable and per-user setup installs, serves a local HTTP feed, then verifies replacement/relaunch and AppData preservation with the native updater. It covers default-off network behavior, declining, cancellation, digest failure, older/equal versions and leaving a downloaded update pending across a restart, and migrating the login entry from a legacy ZIP. This flag is absent from published builds. UI screenshots are rendered by the real WPF Settings/welcome windows on the Windows runner; a user desktop remains useful for SmartScreen and installer appearance.
