import Foundation

/// Presentation only: callback permissions and persistence stay in Bot.
struct SettingsUI {
    let text: String
    let markup: [String: Any]
    // Telegram returns message text without our bold tags in callback.message.
    var plainText: String {
        text.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
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
        var text = "<b>Vos réglages fxclip</b>\n\n<b>Choix actuel : \(current)</b>\n\(effect)\n\nVotre choix personnel passe avant celui des groupes et ne concerne que vos messages, uniquement dans les groupes où le nettoyage est activé."
        text += "\n\n<b>Secrétaire : privé uniquement</b>\nCe mode nécessite une connexion à ce bot dans les réglages d’automatisation de Telegram, avec les droits de réponse et de modification. Il ne modifie jamais les messages reçus."
        text += "\n\nLes liens passent par Telegram et, pour certains aperçus, par des sites miroirs.\n\nChoisissez ci-dessous 👇"
        var rows = modeRows(selected: mode, scope: "personal")
        rows.append([button("\(mode == nil ? "✓ " : "")Suivre le réglage du groupe", "personal:default")])
        if owner {
            rows.append([button("⚙️ Réglage général", "default:show")])
            rows.append([button("👥 Mes groupes", "groups:show")])
        }
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    static func defaults(mode: Mode) -> SettingsUI {
        let text = "<b>Réglage général fxclip</b>\n\n<b>Choix actuel : \(title(mode))</b>\n\(outcome(mode))\n\nCe réglage s’applique quand ni la personne ni le groupe n’a choisi de mode. Les choix personnels restent prioritaires.\n\nSecrétaire nécessite une connexion à ce bot avec les droits de réponse et de modification. Il agit uniquement sur les messages sortants des conversations privées connectées, jamais dans les groupes.\n\nChoisissez le réglage par défaut 👇"
        var rows = modeRows(selected: mode, scope: "default")
        rows.append([button("👥 Mes groupes", "groups:show")])
        rows.append([button("← Mes réglages", "personal:show")])
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    static func groups(_ groups: [KnownGroup], enabled: (Int64) -> Bool, username: String) -> SettingsUI {
        var text = "<b>Mes groupes fxclip</b>\n\nChoisissez un groupe pour activer le nettoyage et vérifier les droits du bot. Cette activation est indépendante du mode choisi avec /fxclip."
        text += "\n\nTelegram ne permet pas au bot de lister ses groupes : un groupe apparaît quand le bot reçoit un message ou un changement de son statut. Si un groupe manque, envoyez /chatid@\(escaped(username)) dedans."
        if groups.isEmpty { text += "\n\nAucun groupe découvert pour le moment." }
        var rows = groups.map { group in
            [button("\(enabled(group.chat.id) ? "✅" : "⏸") \(String((group.chat.title ?? String(group.chat.id)).prefix(60)))",
                    "group:\(group.chat.id):show")]
        }
        rows.append([button("🔄 Actualiser la liste", "groups:show")])
        rows.append([button("← Réglage général", "default:show")])
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    static func group(_ group: KnownGroup, enabled: Bool, rights: ChatMember?) -> SettingsUI {
        let chat = group.chat
        var text = "<b>\(escaped(chat.title ?? "Groupe"))</b>\nIdentifiant : \(chat.id)\n\n<b>Nettoyage : \(enabled ? "activé" : "désactivé")</b>\nDésactivé, aucun message n’est nettoyé, même avec un choix personnel. Le mode /fxclip du groupe reste inchangé."
        if let rights {
            text += "\n\n<b>Droits actuels du bot</b>\nAdministrateur : \(rights.isAdmin ? "oui" : "non")\nSuppression des messages : \(rights.canDelete(in: chat) ? "autorisée" : "non autorisée")"
            if rights.isAdmin {
                text += "\nEnvoi de messages : autorisé\nLecture : tous les messages des membres"
            } else if rights.status == "restricted" {
                text += "\nEnvoi de messages : \(permission(rights.can_send_messages))"
                text += "\nStickers et autres messages : \(permission(rights.can_send_other_messages))"
                text += "\nAperçus de liens : \(permission(rights.can_add_web_page_previews))"
            } else {
                text += "\nEnvoi de messages : selon les permissions du groupe"
            }
            if !rights.isAdmin {
                text += "\nLecture : peut être limitée par le mode confidentialité. Pour recevoir tous les messages des membres même avec ce mode, nommez le bot administrateur."
            }
            if !rights.canDelete(in: chat) {
                text += "\n\nLe nettoyage peut être activé en réponse, sans supprimer l’original. Le remplacement exige le droit de supprimer les messages."
            }
            if rights.status == "restricted", rights.can_send_messages != true {
                text += "\n\nLe bot ne peut pas répondre tant que l’envoi de messages n’est pas autorisé."
            }
        } else {
            text += "\n\n<b>Droits non vérifiés</b>\nImpossible de joindre Telegram. Actualisez les droits avant d’activer le groupe."
        }
        text += "\n\nUn administrateur du groupe doit accorder les droits dans Telegram ; le bot ne peut pas se les donner."
        let key = "group:\(chat.id):"
        return SettingsUI(text: text, markup: ["inline_keyboard": [
            [button(enabled ? "⏸ Désactiver le nettoyage" : "✅ Activer le nettoyage", key + (enabled ? "off" : "on"))],
            [button("🔄 Actualiser les droits", key + "refresh")],
            [button("← Mes groupes", "groups:show")],
        ]])
    }

    private static func permission(_ value: Bool?) -> String {
        value.map { $0 ? "autorisé" : "non autorisé" } ?? "non confirmé"
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
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
