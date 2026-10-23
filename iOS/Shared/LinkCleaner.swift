import Foundation
import FxEngine

/// The engine with the user's choices applied. Pure: no clipboard, no network.
struct LinkCleaner {
    /// What the Telegram app is called on iOS (`rules.json` apps › ios).
    static let telegram = "ph.telegra.Telegraph"

    let engine: Engine
    /// Mirror host → original host ("fxtwitter.com" → "x.com"), from every built-in preview.
    private let mirrors: [(to: String, from: String)]

    init(rules: Rules, user: UserSettings) {
        engine = Engine(rules: rules.applying(user))
        mirrors = rules.previews.compactMap { p in p.from.first.map { (p.to.lowercased(), $0) } }
    }

    /// The built-in rules shipped in the app or extension bundle.
    static func bundledRules(_ bundle: Bundle = .main) throws -> Rules {
        guard let url = bundle.url(forResource: "rules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Rules.load(Data(contentsOf: url))
    }

    /// Also turns preview links back into the original: on iOS the clean link can't be remembered
    /// between Telegram opening and closing, as the Mac does, so "Clean link" undoes "Preview link".
    func clean(_ text: String) -> (text: String, removed: Int) {
        engine.clean(unmirror(text))
    }

    private func unmirror(_ text: String) -> String {
        mirrors.reduce(text) { text, m in
            text.replacingOccurrences(of: "https://\(m.to)/", with: "https://\(m.from)/", options: .caseInsensitive)
        }
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
