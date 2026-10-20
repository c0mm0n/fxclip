import Foundation
import FxEngine

/// Settings and the counter, shared by the app, the share extension and the Shortcuts actions
/// through the App Group. Only a total is counted, never a link or a site.
final class SharedStore {
    static let appGroup = "group.io.github.c0mm0n.fxclip"
    private static let counterKey = "trackersRemoved"

    let file: URL
    private let defaults: UserDefaults
    /// The settings file existed but could not be read: it was moved aside, not overwritten.
    private(set) var movedAside = false

    /// `directory`/`defaults` are for tests; otherwise the App Group, or the app's own
    /// Application Support when the group is unavailable (unsigned simulator builds).
    init(directory: URL? = nil, defaults: UserDefaults? = nil) {
        let fm = FileManager.default
        let dir = directory
            ?? fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("fxclip", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("settings.json")
        self.defaults = defaults ?? UserDefaults(suiteName: Self.appGroup) ?? .standard
    }

    /// Same format as every other platform, so settings.json moves between them.
    func load() -> UserSettings {
        guard let data = try? Data(contentsOf: file) else { return UserSettings() }
        if let saved = try? JSONDecoder().decode(UserSettings.self, from: data) { return saved }
        let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: file, to: aside)
        movedAside = true
        return UserSettings()
    }

    func save(_ user: UserSettings) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(user).write(to: file, options: .atomic)
    }

    var trackersRemoved: Int { defaults.integer(forKey: Self.counterKey) }

    func record(_ removed: Int) {
        guard removed > 0 else { return }
        defaults.set(trackersRemoved + removed, forKey: Self.counterKey)
    }

    func resetCounter() {
        defaults.set(0, forKey: Self.counterKey)
    }

    /// The cleaner for the settings currently on disk.
    func cleaner(rules: Rules) -> LinkCleaner {
        LinkCleaner(rules: rules, user: load())
    }
}
