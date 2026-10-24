import FxEngine
import SwiftUI

/// The app's state: settings (shared with the extension and Shortcuts) and the counter.
@MainActor
final class AppModel: ObservableObject {
    let builtins: Rules
    private let store: SharedStore

    @Published var user: UserSettings {
        didSet {
            guard user != oldValue else { return }
            if (try? store.save(user)) != nil { settingsWereUnreadable = false }
        }
    }
    @Published private(set) var trackersRemoved: Int
    /// settings.json could not be read and was moved aside; cleared once settings are saved again.
    @Published private(set) var settingsWereUnreadable: Bool

    init(store: SharedStore = SharedStore()) {
        self.store = store
        // rules.json is part of the bundle: missing it is a build error, not a runtime case.
        builtins = try! LinkCleaner.bundledRules()
        user = store.load()
        settingsWereUnreadable = store.movedAside
        trackersRemoved = store.trackersRemoved
    }

    /// The share extension and the Shortcuts actions count too: reread when the app comes back.
    func refresh() {
        trackersRemoved = store.trackersRemoved
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

    func previewEnabled(_ p: Rules.Preview) -> Bool { user.previews[p.id]?.enabled ?? user.previewDefaultsEnabled }

    func setPreview(_ p: Rules.Preview, enabled: Bool) {
        var s = user.previews[p.id] ?? .init(enabled: user.previewDefaultsEnabled, apps: p.apps)
        s.enabled = enabled
        user.previews[p.id] = s
    }

    func previewTargetHost(_ p: Rules.Preview) -> String {
        user.previews[p.id]?.targetHost.flatMap(Rules.canonicalPreviewHost) ?? p.to
    }

    func setPreview(_ p: Rules.Preview, targetHost: String?) {
        var s = user.previews[p.id] ?? .init(enabled: user.previewDefaultsEnabled, apps: p.apps)
        s.targetHost = targetHost
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
