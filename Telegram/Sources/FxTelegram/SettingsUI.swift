import Foundation

/// Presentation only: callback permissions and persistence stay in Bot.
struct SettingsUI {
    let text: String
    let markup: [String: Any]
    // Telegram returns message text without our bold tags in callback.message.
    var plainText: String {
        text.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
    }

    static func title(_ mode: Mode) -> String {
        switch mode {
        case .reply: return "Répondre au message"
        case .replace: return "Remplacer le message"
        case .secretary: return "Secrétaire · en privé"
        case .off: return "Désactiver fxclip"
        }
    }

    static func outcome(_ mode: Mode) -> String {
        switch mode {
        case .reply:
            return "fxclip répond avec une version nettoyée et garde le message original."
        case .replace:
            return "fxclip republie le texte nettoyé avec le nom de l’auteur, puis supprime l’original si ses droits le permettent. Les médias et transferts restent en place avec une réponse nettoyée."
        case .secretary:
            return "fxclip modifie uniquement vos propres messages sortants dans les conversations privées connectées. Aucune réécriture dans les groupes."
        case .off:
            return "fxclip laisse les messages tels quels, sans réponse ni modification."
        }
    }

    static func personal(mode: Mode?, defaultMode: Mode, owner: Bool) -> SettingsUI {
        let current = mode.map(title) ?? "Suivre le réglage du groupe"
        let effect = mode.map(outcome) ?? "Chaque groupe choisit son réglage. Sans réglage propre au groupe, le réglage général s’applique : \(title(defaultMode).lowercased())."
        var text = "<b>Vos réglages fxclip</b>\n\n<b>Choix actuel : \(current)</b>\n\(effect)\n\nVotre choix personnel passe avant celui des groupes et ne concerne que vos messages."
        text += "\n\n<b>Secrétaire : privé uniquement</b>\nCe mode nécessite une connexion à ce bot dans les réglages d’automatisation de Telegram, avec les droits de réponse et de modification. Il ne modifie jamais les messages reçus."
        text += "\n\nLes liens passent par Telegram et, pour certains aperçus, par des sites miroirs.\n\nChoisissez ci-dessous 👇"
        var rows = modeRows(selected: mode, scope: "personal")
        rows.append([button("\(mode == nil ? "✓ " : "")Suivre le réglage du groupe", "personal:default")])
        if owner { rows.append([button("⚙️ Réglage général", "default:show")]) }
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    static func defaults(mode: Mode) -> SettingsUI {
        let text = "<b>Réglage général fxclip</b>\n\n<b>Choix actuel : \(title(mode))</b>\n\(outcome(mode))\n\nCe réglage s’applique quand ni la personne ni le groupe n’a choisi de mode. Les choix personnels restent prioritaires.\n\nSecrétaire nécessite une connexion à ce bot avec les droits de réponse et de modification. Il agit uniquement sur les messages sortants des conversations privées connectées, jamais dans les groupes.\n\nChoisissez le réglage par défaut 👇"
        var rows = modeRows(selected: mode, scope: "default")
        rows.append([button("← Mes réglages", "personal:show")])
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    private static func modeRows(selected: Mode?, scope: String) -> [[[String: String]]] {
        [Mode.reply, .replace, .secretary, .off].map { mode in
            [button("\(selected == mode ? "✓ " : "")\(title(mode))", "\(scope):\(mode.rawValue)")]
        }
    }

    private static func button(_ text: String, _ action: String) -> [String: String] {
        ["text": text, "callback_data": "fxclip:\(action)"]
    }
}
