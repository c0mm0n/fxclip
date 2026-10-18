import AppKit
import FxEngine
import os

/// The user's settings: rule choices in a JSON file (Application Support), presence in UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    let builtins: Rules
    /// Called with the rules in force after every change.
    var onRulesChange: (Rules) -> Void = { _ in }
    /// Called when an icon setting changes.
    var onPresenceChange: () -> Void = {}

    @Published var user: UserSettings {
        didSet {
            guard user != oldValue else { return }
            save()
            onRulesChange(effective)
        }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon"); onPresenceChange() }
    }
    @Published var showDock: Bool {
        didSet { defaults.set(showDock, forKey: "showDock"); onPresenceChange() }
    }
    /// No settings file yet: the welcome screen hasn't been completed.
    private(set) var isFirstRun: Bool

    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "io.github.c0mm0n.fxclip", category: "settings")
    private let file: URL

    init(builtins: Rules) {
        self.builtins = builtins
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fxclip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("settings.json")
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        showDock = defaults.bool(forKey: "showDock")

        isFirstRun = !FileManager.default.fileExists(atPath: file.path)
        if let data = try? Data(contentsOf: file) {
            if let saved = try? JSONDecoder().decode(UserSettings.self, from: data) {
                user = saved
                return
            }
            // Unreadable: keep it aside for inspection rather than overwrite it.
            let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            log.error("settings.json unreadable, moved aside; asking again")
            isFirstRun = true
        }
        user = UserSettings()
    }

    var effective: Rules { builtins.applying(user) }

    func save() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(user).write(to: file, options: .atomic)
            isFirstRun = false
        } catch {
            log.error("saving settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: preview links

    func setting(for p: Rules.Preview) -> UserSettings.PreviewSetting {
        user.previews[p.id] ?? .init(enabled: true, apps: p.apps)
    }

    func setPreview(_ p: Rules.Preview, enabled: Bool) {
        var s = setting(for: p)
        s.enabled = enabled
        user.previews[p.id] = s
    }

    func setPreview(_ p: Rules.Preview, apps: [String]) {
        var s = setting(for: p)
        s.apps = apps
        user.previews[p.id] = s
    }

    /// Every app a preview link can be assigned to: built-ins plus the ones the user added.
    var knownApps: [Rules.App] { builtins.apps + user.addedApps }

    func app(_ id: String) -> Rules.App? { knownApps.first { $0.id == id } }

    /// Makes an app assignable (suggested or picked from disk).
    func addApp(_ app: Rules.App) {
        guard self.app(app.id) == nil else { return }
        user.addedApps.append(app)
    }
}
