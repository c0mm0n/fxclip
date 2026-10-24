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

    static func title(_ mode: Mode, language: BotLanguage = .en) -> String {
        switch mode {
        case .reply: return language.text("Reply to the message", "Répondre au message")
        case .replace: return language.text("Replace the message", "Remplacer le message")
        case .secretary: return language.text("Secretary · private chats", "Secrétaire · en privé")
        case .off: return language.text("Turn off fxclip", "Désactiver fxclip")
        }
    }

    static func outcome(_ mode: Mode, language: BotLanguage = .en) -> String {
        switch mode {
        case .reply:
            return language.text(
                "fxclip replies with a cleaned version and keeps the original message.",
                "fxclip répond avec une version nettoyée et garde le message original.")
        case .replace:
            return language.text(
                "fxclip reposts the cleaned text with the author's name, then deletes the original if its permissions allow it. Media and forwarded messages stay in place with a cleaned reply.",
                "fxclip republie le texte nettoyé avec le nom de l’auteur, puis supprime l’original si ses droits le permettent. Les médias et transferts restent en place avec une réponse nettoyée.")
        case .secretary:
            return language.text(
                "fxclip only edits your own outgoing messages in connected private chats. It never rewrites messages in groups.",
                "fxclip modifie uniquement vos propres messages sortants dans les conversations privées connectées. Aucune réécriture dans les groupes.")
        case .off:
            return language.text(
                "fxclip leaves messages as they are, without replying or editing.",
                "fxclip laisse les messages tels quels, sans réponse ni modification.")
        }
    }

    static func personal(mode: Mode?, defaultMode: Mode, owner: Bool,
                         preference: BotLanguage? = nil, language: BotLanguage = .en) -> SettingsUI {
        let current = mode.map { title($0, language: language) }
            ?? language.text("Follow the group's setting", "Suivre le réglage du groupe")
        let effect = mode.map { outcome($0, language: language) } ?? language.text(
            "Each group chooses its setting. If the group has no setting of its own, the general setting applies: \(title(defaultMode, language: language).lowercased()).",
            "Chaque groupe choisit son réglage. Sans réglage propre au groupe, le réglage général s’applique : \(title(defaultMode, language: language).lowercased()).")
        var text = language.text("<b>Your fxclip settings</b>", "<b>Vos réglages fxclip</b>")
        text += "\n\n<b>\(language.text("Current choice: ", "Choix actuel : "))\(current)</b>\n\(effect)"
        text += "\n\n" + language.text(
            "Your personal choice takes priority over group settings and only applies to your messages, in groups where cleaning is enabled.",
            "Votre choix personnel passe avant celui des groupes et ne concerne que vos messages, uniquement dans les groupes où le nettoyage est activé.")
        text += "\n\n" + language.text(
            "<b>Secretary: private chats only</b>\nThis mode requires connecting this bot in Telegram's automation settings, with reply and edit permissions. It never edits incoming messages.",
            "<b>Secrétaire : privé uniquement</b>\nCe mode nécessite une connexion à ce bot dans les réglages d’automatisation de Telegram, avec les droits de réponse et de modification. Il ne modifie jamais les messages reçus.")
        text += "\n\n" + language.text(
            "Links pass through Telegram and, for some previews, through mirror sites. With enhanced previews on, a plain YouTube link can receive a thumbnail and title fetched from YouTube, even when the link is already clean. Telegram does not report whether its own preview worked.\n\nChoose below 👇",
            "Les liens passent par Telegram et, pour certains aperçus, par des sites miroirs. Avec les aperçus améliorés, un lien YouTube seul peut recevoir une miniature et un titre récupérés sur YouTube, même s’il est déjà propre. Telegram n’indique pas si son propre aperçu a fonctionné.\n\nChoisissez ci-dessous 👇")
        var rows = modeRows(selected: mode, scope: "personal", language: language)
        rows.append([button("\(mode == nil ? "✓ " : "")\(language.text("Follow the group's setting", "Suivre le réglage du groupe"))", "personal:default")])
        if owner {
            rows.append([button(language.text("⚙️ General setting", "⚙️ Réglage général"), "default:show")])
            rows.append([button(language.text("👥 My groups", "👥 Mes groupes"), "groups:show")])
        }
        let choice = preference?.name ?? language.text("Automatic", "Automatique")
        rows.append([button("🌐 \(language.text("Language: ", "Langue : "))\(choice)", "language:show")])
        rows.append([closeButton(language: language)])
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    static func languages(selected: BotLanguage?, detected: BotLanguage) -> SettingsUI {
        let language = selected ?? detected
        let automatic = language.text("Automatic", "Automatique")
        let choice = selected?.name ?? "\(automatic) (\(detected.name))"
        let text = "<b>Language / Langue</b>\n\n<b>\(language.text("Current choice: ", "Choix actuel : "))\(choice)</b>\n\n" + language.text(
            "Automatic follows your Telegram interface language, with English as the fallback. This choice applies to your personal settings; each group's administrators choose its language separately.",
            "Le mode automatique suit la langue de votre interface Telegram, avec l’anglais par défaut. Ce choix s’applique à vos réglages personnels ; les administrateurs de chaque groupe choisissent sa langue séparément.")
        return SettingsUI(text: text, markup: ["inline_keyboard": [
            [button("\(selected == nil ? "✓ " : "")\(automatic) (\(detected.name))", "language:auto")],
            [button("\(selected == .en ? "✓ " : "")English", "language:en")],
            [button("\(selected == .fr ? "✓ " : "")Français", "language:fr")],
            [button(language.text("← Back to settings", "← Mes réglages"), "personal:show")],
            [closeButton(language: language)],
        ]])
    }

    static func defaults(mode: Mode, language: BotLanguage = .en) -> SettingsUI {
        var text = language.text("<b>fxclip general setting</b>", "<b>Réglage général fxclip</b>")
        text += "\n\n<b>\(language.text("Current choice: ", "Choix actuel : "))\(title(mode, language: language))</b>\n\(outcome(mode, language: language))"
        text += "\n\n" + language.text(
            "This setting applies when neither the person nor the group has chosen a mode. Personal choices take priority.\n\nSecretary requires connecting this bot with reply and edit permissions. It only acts on outgoing messages in connected private chats, never in groups.\n\nChoose the default setting 👇",
            "Ce réglage s’applique quand ni la personne ni le groupe n’a choisi de mode. Les choix personnels restent prioritaires.\n\nSecrétaire nécessite une connexion à ce bot avec les droits de réponse et de modification. Il agit uniquement sur les messages sortants des conversations privées connectées, jamais dans les groupes.\n\nChoisissez le réglage par défaut 👇")
        var rows = modeRows(selected: mode, scope: "default", language: language)
        rows.append([button(language.text("👥 My groups", "👥 Mes groupes"), "groups:show")])
        rows.append([button(language.text("← My settings", "← Mes réglages"), "personal:show")])
        rows.append([closeButton(language: language)])
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    static func groups(_ groups: [KnownGroup], enabled: (Int64) -> Bool, username: String,
                       language: BotLanguage = .en) -> SettingsUI {
        var text = language.text(
            "<b>My fxclip groups</b>\n\nChoose a group to enable cleaning and check the bot's permissions. This activation is independent of the mode chosen with /fxclip.",
            "<b>Mes groupes fxclip</b>\n\nChoisissez un groupe pour activer le nettoyage et vérifier les droits du bot. Cette activation est indépendante du mode choisi avec /fxclip.")
        text += "\n\n" + language.text(
            "Telegram does not let the bot list its groups: a group appears when the bot receives a message or a change to its status. If a group is missing, send /chatid@\(escaped(username)) in it.",
            "Telegram ne permet pas au bot de lister ses groupes : un groupe apparaît quand le bot reçoit un message ou un changement de son statut. Si un groupe manque, envoyez /chatid@\(escaped(username)) dedans.")
        if groups.isEmpty {
            text += "\n\n" + language.text("No groups discovered yet.", "Aucun groupe découvert pour le moment.")
        }
        var rows = groups.map { group in
            [button("\(enabled(group.chat.id) ? "✅" : "⏸") \(String((group.chat.title ?? String(group.chat.id)).prefix(60)))",
                    "group:\(group.chat.id):show")]
        }
        rows.append([button(language.text("🔄 Refresh list", "🔄 Actualiser la liste"), "groups:show")])
        rows.append([button(language.text("← General setting", "← Réglage général"), "default:show")])
        rows.append([closeButton(language: language)])
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    static func welcome(chatID: Int64, username: String, language: BotLanguage = .en) -> SettingsUI {
        SettingsUI(text: language.text(
            "Hello 👋 I clean links and improve their previews. Everyone can choose a mode in ‘My settings’; admins manage this group below.",
            "Bonjour 👋 Je nettoie les liens et améliore leurs aperçus. Chacun peut choisir son mode dans « Mes réglages », les admins règlent ce groupe ci-dessous."),
                   markup: ["inline_keyboard": [
                    [personalLink(username: username, language: language)],
                    [button(language.text("⚙️ Group settings", "⚙️ Réglage du groupe"), "chat:\(chatID):show")],
                   ]])
    }

    static func chat(_ chat: Chat, settings: ChatSettings, enabled: Bool, inherited: Bool,
                     username: String, language: BotLanguage = .en) -> SettingsUI {
        let key = "chat:\(chat.id):"
        var text = language.text("<b>This group's settings</b>", "<b>Réglage de ce groupe</b>")
        text += "\n\n<b>\(language.text("Cleaning: ", "Nettoyage : "))\(enabled ? language.text("on", "activé") : language.text("off", "désactivé"))</b>"
        let modeLabel = inherited ? language.text("General mode applied: ", "Mode général appliqué : ") : language.text("Mode: ", "Mode : ")
        text += "\n<b>\(modeLabel)\(title(settings.mode, language: language))</b>\n\(outcome(settings.mode, language: language))"
        text += "\n\n" + language.text(
            "Enhanced previews: \(settings.previews ? "on" : "off").\nAdministrators manage only this group. A personal choice takes priority when cleaning is enabled.",
            "Aperçus améliorés : \(settings.previews ? "activés" : "désactivés").\nLes administrateurs règlent uniquement ce groupe. Un choix personnel reste prioritaire lorsque le nettoyage est activé.")
        text += "\n\n" + language.text("Group language: ", "Langue du groupe : ") + language.name
        text += "\n\n" + language.text(
            "YouTube: enhanced previews fetch the title and thumbnail directly from YouTube, including for already-clean single links. A duplicate is possible if Telegram's own preview works.",
            "YouTube : les aperçus améliorés récupèrent le titre et la miniature directement sur YouTube, même pour un lien seul déjà propre. Un doublon est possible si l’aperçu Telegram fonctionne.")
        var rows = [[button(enabled ? language.text("⏸ Turn off cleaning", "⏸ Désactiver le nettoyage") : language.text("✅ Turn on cleaning", "✅ Activer le nettoyage"), key + (enabled ? "disable" : "enable"))]]
        rows += [Mode.reply, .replace, .off].map { mode in
            [button("\(settings.mode == mode ? "✓ " : "")\(title(mode, language: language))", key + mode.rawValue)]
        }
        rows.append([button(settings.previews ? language.text("Turn off enhanced previews", "Désactiver les aperçus améliorés") : language.text("Turn on enhanced previews", "Activer les aperçus améliorés"), key + (settings.previews ? "previews_off" : "previews_on"))])
        rows.append([personalLink(username: username, language: language)])
        rows.append([
            button("\(language == .en ? "✓ " : "")English", key + "lang_en"),
            button("\(language == .fr ? "✓ " : "")Français", key + "lang_fr"),
        ])
        rows.append([closeButton(language: language, action: key + "close")])
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    private static func personalLink(username: String, language: BotLanguage = .en) -> [String: String] {
        ["text": language.text("⚙️ My settings", "⚙️ Mes réglages"), "url": "https://t.me/\(username)?start=settings"]
    }

    static func group(_ group: KnownGroup, enabled: Bool, rights: ChatMember?,
                      language: BotLanguage = .en) -> SettingsUI {
        let chat = group.chat
        var text = "<b>\(escaped(chat.title ?? language.text("Group", "Groupe")))</b>\n\(language.text("ID: ", "Identifiant : "))\(chat.id)"
        text += "\n\n<b>\(language.text("Cleaning: ", "Nettoyage : "))\(enabled ? language.text("on", "activé") : language.text("off", "désactivé"))</b>\n"
        text += language.text(
            "When off, no messages are cleaned, even with a personal choice. The group's /fxclip mode stays unchanged.",
            "Désactivé, aucun message n’est nettoyé, même avec un choix personnel. Le mode /fxclip du groupe reste inchangé.")
        if let rights {
            text += "\n\n" + language.text("<b>Current bot permissions</b>", "<b>Droits actuels du bot</b>")
            text += "\n" + language.text("Administrator: ", "Administrateur : ") + (rights.isAdmin ? language.text("yes", "oui") : language.text("no", "non"))
            text += "\n" + language.text("Delete messages: ", "Suppression des messages : ") + (rights.canDelete(in: chat) ? language.text("allowed", "autorisée") : language.text("not allowed", "non autorisée"))
            if rights.isAdmin {
                text += "\n" + language.text("Send messages: allowed\nRead: all members' messages", "Envoi de messages : autorisé\nLecture : tous les messages des membres")
            } else if rights.status == "restricted" {
                text += "\n" + language.text("Send messages: ", "Envoi de messages : ") + permission(rights.can_send_messages, language: language)
                text += "\n" + language.text("Stickers and other messages: ", "Stickers et autres messages : ") + permission(rights.can_send_other_messages, language: language)
                text += "\n" + language.text("Link previews: ", "Aperçus de liens : ") + permission(rights.can_add_web_page_previews, language: language)
            } else {
                text += "\n" + language.text("Send messages: according to group permissions", "Envoi de messages : selon les permissions du groupe")
            }
            if !rights.isAdmin {
                text += "\n" + language.text(
                    "Read: may be limited by privacy mode. To receive all members' messages even with this mode, make the bot an administrator.",
                    "Lecture : peut être limitée par le mode confidentialité. Pour recevoir tous les messages des membres même avec ce mode, nommez le bot administrateur.")
            }
            if !rights.canDelete(in: chat) {
                text += "\n\n" + language.text(
                    "Cleaning can be enabled as a reply, without deleting the original. Replacement requires permission to delete messages.",
                    "Le nettoyage peut être activé en réponse, sans supprimer l’original. Le remplacement exige le droit de supprimer les messages.")
            }
            if rights.status == "restricted", rights.can_send_messages != true {
                text += "\n\n" + language.text(
                    "The bot cannot reply until sending messages is allowed.",
                    "Le bot ne peut pas répondre tant que l’envoi de messages n’est pas autorisé.")
            }
        } else {
            text += "\n\n" + language.text(
                "<b>Permissions not checked</b>\nCould not reach Telegram. Refresh permissions before enabling the group.",
                "<b>Droits non vérifiés</b>\nImpossible de joindre Telegram. Actualisez les droits avant d’activer le groupe.")
        }
        text += "\n\n" + language.text(
            "A group administrator must grant permissions in Telegram; the bot cannot grant them to itself.",
            "Un administrateur du groupe doit accorder les droits dans Telegram ; le bot ne peut pas se les donner.")
        let key = "group:\(chat.id):"
        return SettingsUI(text: text, markup: ["inline_keyboard": [
            [button(enabled ? language.text("⏸ Turn off cleaning", "⏸ Désactiver le nettoyage") : language.text("✅ Turn on cleaning", "✅ Activer le nettoyage"), key + (enabled ? "off" : "on"))],
            [button(language.text("🔄 Refresh permissions", "🔄 Actualiser les droits"), key + "refresh")],
            [button(language.text("← My groups", "← Mes groupes"), "groups:show")],
            [closeButton(language: language)],
        ]])
    }

    private static func permission(_ value: Bool?, language: BotLanguage = .en) -> String {
        value.map { $0 ? language.text("allowed", "autorisé") : language.text("not allowed", "non autorisé") }
            ?? language.text("not confirmed", "non confirmé")
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func modeRows(selected: Mode?, scope: String, language: BotLanguage = .en) -> [[[String: String]]] {
        [Mode.reply, .replace, .secretary, .off].map { mode in
            [button("\(selected == mode ? "✓ " : "")\(title(mode, language: language))", "\(scope):\(mode.rawValue)")]
        }
    }

    private static func closeButton(language: BotLanguage, action: String = "panel:close") -> [String: String] {
        button(language.text("✕ Close", "✕ Fermer"), action)
    }

    private static func button(_ text: String, _ action: String) -> [String: String] {
        ["text": text, "callback_data": "fxclip:\(action)"]
    }
}
