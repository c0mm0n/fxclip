import FxEngine
import SwiftUI
import UIKit

/// The app's state: settings (shared with the extension and Shortcuts), the counter and the last result.
@MainActor
final class AppModel: ObservableObject {
    let builtins: Rules
    private let store: SharedStore

    @Published var user: UserSettings {
        didSet {
            guard user != oldValue else { return }
            try? store.save(user)
        }
    }
    @Published private(set) var trackersRemoved: Int
    /// The clipboard holds something that looks like a link (asked without reading it).
    @Published private(set) var clipboardHasLink = false
    @Published private(set) var result: CleanResult?
    /// settings.json could not be read and was moved aside.
    let settingsWereUnreadable: Bool

    struct CleanResult: Equatable {
        let clean: String
        let telegram: String
        let removed: Int
        let removedNames: [String]
    }

    init(store: SharedStore = SharedStore()) {
        self.store = store
        // rules.json is part of the bundle: missing it is a build error, not a runtime case.
        builtins = try! LinkCleaner.bundledRules()
        user = store.load()
        settingsWereUnreadable = store.movedAside
        trackersRemoved = store.trackersRemoved
    }

    var cleaner: LinkCleaner { LinkCleaner(rules: builtins, user: user) }

    /// Detection only: iOS answers without showing the paste prompt.
    func checkClipboard() {
        trackersRemoved = store.trackersRemoved
        guard UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs else {
            clipboardHasLink = false
            return
        }
        Task {
            let found = (try? await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL]))?
                .contains(\UIPasteboard.DetectedValues.probableWebURL) ?? false
            clipboardHasLink = found
        }
    }

    /// Text the user pasted with the system Paste button (no prompt): clean it and put it back.
    func cleanPasted(_ text: String) {
        let cleaner = cleaner
        let out = cleaner.clean(text)
        store.record(out.removed)
        trackersRemoved = store.trackersRemoved
        result = CleanResult(clean: out.text, telegram: cleaner.telegramPreview(out.text), removed: out.removed,
                             removedNames: removedParameters(original: text, clean: out.text))
        UIPasteboard.general.string = out.text
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    func resetCounter() {
        store.resetCounter()
        trackersRemoved = 0
    }

    // MARK: settings

    func siteEnabled(_ site: Rules.Site) -> Bool { !user.disabledSites.contains(site.id) }

    func setSite(_ site: Rules.Site, enabled: Bool) {
        if enabled { user.disabledSites.remove(site.id) } else { user.disabledSites.insert(site.id) }
    }

    func previewEnabled(_ p: Rules.Preview) -> Bool { user.previews[p.id]?.enabled ?? true }

    func setPreview(_ p: Rules.Preview, enabled: Bool) {
        var s = user.previews[p.id] ?? .init(enabled: true, apps: p.apps)
        s.enabled = enabled
        user.previews[p.id] = s
    }

    /// "On", "Off" or "5 of 7 sites", for the home row.
    var cleaningSummary: String {
        let sites = builtins.trackers.sites
        let on = sites.filter(siteEnabled).count
        if on == sites.count { return user.trackersEverywhere ? "On" : "Sites only" }
        if on == 0 && !user.trackersEverywhere { return "Off" }
        return "\(on) of \(sites.count) sites"
    }

    var previewsSummary: String {
        let on = builtins.previews.filter(previewEnabled).count
        return on == 0 ? "Off" : on == builtins.previews.count ? "On" : "\(on) of \(builtins.previews.count)"
    }

    /// The app names a preview is used in, from the built-in and added apps.
    func appNames(_ p: Rules.Preview) -> String {
        let ids = user.previews[p.id]?.apps ?? p.apps
        let apps = builtins.apps + user.addedApps
        return ids.compactMap { id in apps.first { $0.id == id }?.name }.joined(separator: ", ")
    }
}
