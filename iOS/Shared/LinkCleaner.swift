import Foundation
import FxEngine

/// The engine with the user's choices applied. Pure: no clipboard, no network.
struct LinkCleaner {
    /// What the Telegram app is called on iOS (`rules.json` apps › ios).
    static let telegram = "ph.telegra.Telegraph"

    let engine: Engine

    init(rules: Rules, user: UserSettings) {
        engine = Engine(rules: rules.applying(user))
    }

    /// The built-in rules shipped in the app or extension bundle.
    static func bundledRules(_ bundle: Bundle = .main) throws -> Rules {
        guard let url = bundle.url(forResource: "rules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Rules.load(Data(contentsOf: url))
    }

    func clean(_ text: String) -> (text: String, removed: Int) {
        engine.clean(text)
    }

    /// The link for one share destination: its preview mirror when that app has one, else the clean link.
    /// `destination` is an iOS bundle ID or a share-sheet activity type.
    func link(_ clean: String, for destination: String?) -> String {
        guard let destination else { return clean }
        return engine.preview(clean, forBundleID: destination)
    }

    func telegramPreview(_ clean: String) -> String {
        link(clean, for: Self.telegram)
    }
}
