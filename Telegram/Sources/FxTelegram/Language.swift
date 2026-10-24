import Foundation

/// Bot presentation only. Link cleaning remains entirely in the shared FxEngine.
public enum BotLanguage: String, Codable, CaseIterable {
    case en, fr

    public var name: String { self == .fr ? "Français" : "English" }

    /// Telegram supplies the user's interface language, not the language of their messages.
    /// Unsupported nonempty tags use English; a missing tag can reuse the last observation.
    public static func telegram(_ tag: String?) -> BotLanguage? {
        guard let tag, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let base = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        return base == "fr" ? .fr : .en
    }

    func text(_ english: String, _ french: String) -> String { self == .fr ? french : english }
}
