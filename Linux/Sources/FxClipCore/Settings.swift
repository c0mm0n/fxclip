import Foundation
import FxEngine

public func log(_ message: String) { FileHandle.standardError.write(Data(("fxclip: " + message + "\n").utf8)) }

public final class Settings {
    public let path: URL
    public private(set) var engine: Engine
    private let builtins: Rules
    private var previous: Data?
    private var wasPresent = false

    public static func configURL(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
        return URL(fileURLWithPath: base).appendingPathComponent("fxclip/settings.json")
    }

    public init(rules: Rules, path: URL = Settings.configURL()) {
        self.builtins = rules; self.path = path; self.engine = Engine(rules: rules)
        reload()
    }

    public func reload() {
        do {
            let data = try Data(contentsOf: path)
            guard data != previous || !wasPresent else { return }
            engine = Engine(rules: builtins.applying(try JSONDecoder().decode(UserSettings.self, from: data)))
            previous = data; wasPresent = true
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
                previous = nil; wasPresent = false; engine = Engine(rules: builtins); return
            }
            log("ERROR: settings.json is unreadable or invalid; moving it to settings.unreadable.json and using defaults.")
            let backup = path.deletingLastPathComponent().appendingPathComponent("settings.unreadable.json")
            do {
                if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
                try FileManager.default.moveItem(at: path, to: backup)
            } catch { log("ERROR: could not move settings.json; check the config directory permissions.") }
            previous = nil; wasPresent = false; engine = Engine(rules: builtins)
        }
    }
}
