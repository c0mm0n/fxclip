import Foundation
import FxEngine

/// Presentation only: callback permissions and persistence stay in Bot.
struct SettingsUI {
    let text: String
    let markup: [String: Any]
    // Telegram returns message text without our formatting tags in callback.message.
    var plainText: String {
        text.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
            .replacingOccurrences(of: "<code>", with: "").replacingOccurrences(of: "</code>", with: "")
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
            "Links pass through Telegram and, for some previews, through mirror sites. With enhanced previews on, a plain YouTube link can receive a thumbnail and title fetched from YouTube, even when the link is already clean. Telegram does not report whether its own preview worked.",
            "Les liens passent par Telegram et, pour certains aperçus, par des sites miroirs. Avec les aperçus améliorés, un lien YouTube seul peut recevoir une miniature et un titre récupérés sur YouTube, même s’il est déjà propre. Telegram n’indique pas si son propre aperçu a fonctionné.")
        text += "\n\n" + facebookDisclosure(language: language)
        text += "\n\n" + language.text("Choose below 👇", "Choisissez ci-dessous 👇")
        text += "\n\n" + removalDisclosure(language: language)
        var rows = modeRows(selected: mode, scope: "personal", language: language)
        rows.append([button("\(mode == nil ? "✓ " : "")\(language.text("Follow the group's setting", "Suivre le réglage du groupe"))", "personal:default")])
        rows.append([button(language.text("🔗 Link settings", "🔗 Réglages des liens"), "rules:p:show")])
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
        text += "\n\n" + facebookDisclosure(language: language)
        text += "\n\n" + removalDisclosure(language: language)
        var rows = modeRows(selected: mode, scope: "default", language: language)
        rows.append([button(language.text("🔗 Link settings", "🔗 Réglages des liens"), "rules:d:show")])
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
        text += "\n\n" + facebookDisclosure(language: language)
        text += "\n\n" + removalDisclosure(language: language)
        var rows = [[button(enabled ? language.text("⏸ Turn off cleaning", "⏸ Désactiver le nettoyage") : language.text("✅ Turn on cleaning", "✅ Activer le nettoyage"), key + (enabled ? "disable" : "enable"))]]
        rows += [Mode.reply, .replace, .off].map { mode in
            [button("\(settings.mode == mode ? "✓ " : "")\(title(mode, language: language))", key + mode.rawValue)]
        }
        rows.append([button(settings.previews ? language.text("Turn off enhanced previews", "Désactiver les aperçus améliorés") : language.text("Turn on enhanced previews", "Activer les aperçus améliorés"), key + (settings.previews ? "previews_off" : "previews_on"))])
        rows.append([button(language.text("🔗 Link settings", "🔗 Réglages des liens"), "rules:c:\(chat.id):show")])
        rows.append([personalLink(username: username, language: language)])
        rows.append([
            button("\(language == .en ? "✓ " : "")English", key + "lang_en"),
            button("\(language == .fr ? "✓ " : "")Français", key + "lang_fr"),
        ])
        rows.append([closeButton(language: language, action: key + "close")])
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    static func rules(_ settings: UserSettings, builtins: Rules, scope: String,
                      section: String = "show", inherited: Bool, previewsEnabled: Bool = true,
                      youTubeCards: Bool = true, facebookReels: Bool = false,
                      language: BotLanguage = .en) -> SettingsUI {
        let groupID = scope.hasPrefix("c:") ? String(scope.dropFirst(2)) : nil
        let key = "rules:\(scope):"
        let command = groupID != nil ? "/fxclip " : scope == "d" ? "/default " : "/"
        let parent = groupID.map { "chat:\($0):show" } ?? (scope == "d" ? "default:show" : "personal:show")
        let close = groupID.map { "chat:\($0):close" } ?? "panel:close"
        let scopeTitle = groupID != nil
            ? language.text("Group link settings", "Réglages des liens du groupe")
            : scope == "d" ? language.text("Default link settings", "Réglages généraux des liens")
            : language.text("Your link settings", "Vos réglages des liens")
        var text = "<b>\(scopeTitle)</b>"
        var rows: [[[String: String]]] = []

        func state(_ enabled: Bool) -> String {
            enabled ? language.text("on", "activé") : language.text("off", "désactivé")
        }
        // Keep catalog IDs intact. An oversized callback must never be truncated
        // into another rule's action or sent beyond Telegram's 64-byte limit.
        func add(_ label: String, _ action: String) {
            guard ("fxclip:" + key + action).utf8.count <= 64 else { return }
            rows.append([button(label, key + action)])
        }
        func toggle(_ label: String, enabled: Bool, action: String) {
            add("\(enabled ? "✓" : "○") \(label) · \(state(enabled))", action + (enabled ? ":off" : ":on"))
        }

        if scope == "d" {
            text += "\n" + language.text(
                "Applies when no group or personal link configuration is set.",
                "S’applique sans configuration de liens propre au groupe ou à la personne.")
        } else if groupID != nil {
            text += "\n" + (inherited ? language.text("Following all default link settings.", "Tous les réglages généraux des liens sont suivis.")
                : language.text("This group's complete custom link configuration replaces the defaults.", "La configuration personnalisée complète de ce groupe remplace les réglages généraux."))
            text += "\n" + language.text("Personal link configurations take priority.", "Les configurations personnelles des liens restent prioritaires.")
        } else {
            text += "\n" + (inherited ? language.text("Following each group's complete link configuration.", "La configuration complète des liens de chaque groupe est suivie.")
                : language.text("Your complete custom link configuration replaces group settings in every group where cleaning is enabled.", "Votre configuration personnalisée complète des liens remplace celle de chaque groupe où le nettoyage est activé."))
            text += "\n" + language.text(
                "Custom settings start from the bot’s defaults. Reset to follow each group again.",
                "La personnalisation part des réglages généraux du bot. Réinitialisez pour suivre à nouveau chaque groupe.")
        }
        if groupID != nil && !previewsEnabled {
            text += "\n\n" + language.text(
                "⏸ Enhanced previews are paused for this group, including YouTube cards and Facebook videos. Enable them in the group settings to apply the choices below.",
                "⏸ Les aperçus améliorés sont en pause pour ce groupe, y compris les fiches YouTube et les vidéos Facebook. Activez-les dans les réglages du groupe pour appliquer les choix ci-dessous.")
        }

        switch section {
        case "clean":
            text += "\n\n" + language.text("<b>Tracker cleaning</b>\nEach switch controls its own cleaning rules.", "<b>Nettoyage des traceurs</b>\nChaque interrupteur contrôle ses propres règles de nettoyage.")
            toggle(language.text("All websites", "Tous les sites"), enabled: settings.trackersEverywhere, action: "trackers")
            for site in builtins.trackers.sites {
                let enabled = !settings.disabledSites.contains(site.id)
                toggle(site.name, enabled: enabled, action: "site:\(site.id)")
            }
        case "previews":
            text += "\n\n" + language.text(
                "<b>Preview mirrors</b>\nEnabled mirrors replace the link's domain. Links pass through Telegram and the selected mirror.",
                "<b>Miroirs d’aperçu</b>\nLes miroirs activés remplacent le domaine du lien. Les liens passent par Telegram et le miroir choisi.")
            for preview in builtins.previews {
                let enabled = (settings.previews[preview.id]?.enabled ?? settings.previewDefaultsEnabled)
                    && (settings.previews[preview.id]?.apps ?? preview.apps).contains("telegram")
                let host = settings.previews[preview.id]?.targetHost.flatMap(Rules.canonicalPreviewHost) ?? preview.to
                text += "\n\n\(enabled ? "✓" : "○") <b>\(escaped(preview.name))</b> · \(state(enabled))\n\(escaped(host))"
                toggle(preview.name, enabled: enabled, action: "preview:\(preview.id)")
                add(language.text("Change provider", "Changer de fournisseur") + " · " + preview.name, "provider:\(preview.id)")
            }
            text += "\n\n" + language.text(
                "<b>YouTube cards</b> · \(state(youTubeCards))\nBot-only option: fetches the title and thumbnail directly from YouTube, even for an already-clean single link. A duplicate is possible if Telegram also displays its own preview.",
                "<b>Fiches YouTube</b> · \(state(youTubeCards))\nOption propre au bot : récupère le titre et la miniature directement sur YouTube, même pour un lien seul déjà propre. Un doublon est possible si Telegram affiche aussi son aperçu.")
            toggle(language.text("YouTube cards", "Fiches YouTube"), enabled: youTubeCards, action: "youtube")
            text += "\n\n" + language.text(
                "<b>Facebook videos</b> · \(state(facebookReels))\nBot-only option, off by default: private Facebed code on the bot server fetches metadata from Facebook; the bot downloads validated Facebook CDN video and uploads a copy to Telegram. No calls or fallback to the public facebed.com service. Requires enhanced previews and a single plain public Facebook or Facebed link, including /reel/id and /share/r/token, even if already clean. Resolution depends on Meta allowing logged-out access; image/text-only posts are not converted. A duplicate is possible if Telegram also shows its preview. Limit: 20 MiB. Larger videos receive a title and Open Facebook reply; the original stays even in Replace mode. No Facebook login or access to private content. Full videos show only the video and Remove preview for 5 minutes: no heading, author, description, link or Open button. Replacement attempts add a small poster credit; the original stays if deletion fails.",
                "<b>Vidéos Facebook</b> · \(state(facebookReels))\nOption propre au bot, désactivée par défaut : le code Facebed privé sur le serveur du bot récupère les métadonnées sur Facebook ; le bot télécharge la vidéo validée du CDN Facebook et en envoie une copie à Telegram. Aucun appel ni repli vers le service public facebed.com. Nécessite les aperçus améliorés et un lien public Facebook ou Facebed seul et sans mise en forme, dont /reel/id et /share/r/token, même déjà propre. La résolution dépend de l’accès sans connexion autorisé par Meta ; les publications image/texte seules ne sont pas converties. Un doublon est possible si Telegram affiche aussi son aperçu. Limite : 20 Mio. Au-delà, une réponse affiche le titre et Ouvrir Facebook ; l’original reste même en mode Remplacer. Aucune connexion Facebook ni accès au contenu privé. Vidéos complètes : vidéo seule et Retirer l’aperçu pendant 5 minutes, sans titre, auteur, description, lien ni bouton Ouvrir. Une tentative de remplacement ajoute un petit crédit d’auteur ; l’original reste si sa suppression échoue.")
            toggle(language.text("Facebook videos", "Vidéos Facebook"), enabled: facebookReels, action: "facebook")
            text += "\n\n" + removalDisclosure(language: language)
        case "excluded":
            text += "\n\n" + language.text(
                "<b>Cleaning exclusions</b>\nTracker cleaning is skipped for these domains. Preview switches apply separately and can still change their links.",
                "<b>Exclusions du nettoyage</b>\nLes traceurs de ces domaines ne sont pas nettoyés. Les réglages des aperçus s’appliquent séparément et peuvent encore modifier leurs liens.")
            if settings.neverClean.isEmpty {
                text += "\n\n" + language.text("No cleaning exclusions.", "Aucune exclusion du nettoyage.")
            } else {
                for host in settings.neverClean.prefix(8) {
                    text += "\n• \(escaped(host.host))" + (host.subdomains ? language.text(" (including subdomains)", " (sous-domaines inclus)") : language.text(" (exact domain)", " (domaine exact)"))
                }
            }
            if settings.neverClean.count > 8 {
                text += "\n" + language.text("… and \(settings.neverClean.count - 8) more.", "… et \(settings.neverClean.count - 8) autres.")
            }
            text += "\n\n" + language.text("Send a command with the domain to add or remove:", "Envoyez une commande avec le domaine à ajouter ou retirer :")
            text += "\n<code>\(escaped(command))exclude add &lt;domain&gt;</code>\n<code>\(escaped(command))exclude remove &lt;domain&gt;</code>"
        case let provider where provider.hasPrefix("provider:"):
            let id = String(provider.dropFirst("provider:".count))
            if let preview = builtins.previews.first(where: { $0.id == id }) {
                let host = settings.previews[id]?.targetHost.flatMap(Rules.canonicalPreviewHost) ?? preview.to
                text += "\n\n<b>\(escaped(preview.name))</b>\n" + language.text("Current provider: ", "Fournisseur actuel : ") + escaped(host)
                text += "\n" + language.text("Built-in provider: ", "Fournisseur d’origine : ") + escaped(preview.to)
                text += "\n\n" + language.text("To change it, send this command with the mirror's domain:", "Pour le changer, envoyez cette commande avec le domaine du miroir :")
                text += "\n<code>\(escaped(command))provider \(escaped(id)) &lt;domain&gt;</code>"
                text += "\n\n" + language.text("Enabled preview links will use that provider, which receives the links.", "Les liens d’aperçu activés utiliseront ce fournisseur, qui recevra les liens.")
                add(language.text("Restore built-in provider", "Rétablir le fournisseur d’origine"), "providerreset:\(id)")
            } else {
                text += "\n\n" + language.text("This preview is no longer available.", "Cet aperçu n’est plus disponible.")
            }
        default:
            add(language.text("🧹 Tracker cleaning", "🧹 Nettoyage des traceurs"), "clean")
            add(language.text("🖼 Previews and providers", "🖼 Aperçus et fournisseurs"), "previews")
            add(language.text("🚫 Cleaning exclusions", "🚫 Exclusions du nettoyage"), "excluded")
            text += "\n\n" + language.text("Choose a category below.", "Choisissez une catégorie ci-dessous.")
            text += "\n" + (scope == "d" ? language.text("Reset restores the complete built-in link configuration.", "Réinitialiser rétablit la configuration complète des liens d’origine.")
                : groupID != nil ? language.text("Reset removes this group's complete custom link configuration and follows the defaults again.", "Réinitialiser retire toute la configuration personnalisée des liens du groupe et rétablit les réglages généraux.")
                : language.text("Reset removes your complete custom link configuration and follows each group again.", "Réinitialiser retire toute votre configuration personnalisée des liens pour suivre à nouveau chaque groupe."))
            add(scope == "d" ? language.text("↺ Restore built-in settings", "↺ Rétablir les réglages d’origine")
                : language.text("↺ Follow inherited settings", "↺ Suivre les réglages hérités"), "reset")
        }
        if section.hasPrefix("provider:") {
            add(language.text("← Previews", "← Aperçus"), "previews")
        } else if section != "show" {
            add(language.text("← Link settings", "← Réglages des liens"), "show")
        }
        rows.append([button(language.text("← Settings", "← Réglages"), parent)])
        rows.append([closeButton(language: language, action: close)])
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
        text += "\n\n" + facebookDisclosure(language: language)
        text += "\n\n" + removalDisclosure(language: language)
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

    private static func removalDisclosure(language: BotLanguage) -> String {
        language.text(
            "Remove preview disappears after 5 minutes. Open-button links stay locally only until cleanup succeeds (YouTube and size notices; retry limit: 48 h). Full-video replies retain no Open URL. Message text and media are not saved.",
            "Retirer l’aperçu disparaît après 5 minutes. Les liens des boutons d’ouverture restent localement jusqu’au nettoyage (YouTube et avis de taille ; réessais : 48 h maximum). Aucun lien d’ouverture conservé pour les vidéos complètes. Aucun texte de message ni média n’est enregistré.")
    }

    private static func facebookDisclosure(language: BotLanguage) -> String {
        language.text(
            "Facebook videos are off by default. If enabled separately in Link settings, a single plain public Facebook or Facebed link (including /reel/id and /share/r/token) uses private Facebed code on the bot server to fetch metadata from Facebook. The bot downloads validated Facebook CDN video and uploads a copy to Telegram. No calls or fallback to the public facebed.com service. Resolution depends on Meta allowing logged-out access. No Facebook login or access to private content. Full videos show only the video and Remove preview for 5 minutes: no heading, author, description, link or Open button. Replacement attempts add a small poster credit; the original stays if deletion fails. Pausing enhanced previews also pauses Facebook videos.",
            "Les vidéos Facebook sont désactivées par défaut. Si l’option est activée séparément dans les réglages des liens, un lien public Facebook ou Facebed seul et sans mise en forme (dont /reel/id et /share/r/token) utilise le code Facebed privé sur le serveur du bot pour récupérer les métadonnées sur Facebook. Le bot télécharge la vidéo validée du CDN Facebook et en envoie une copie à Telegram. Aucun appel ni repli vers le service public facebed.com. La résolution dépend de l’accès sans connexion autorisé par Meta. Aucune connexion Facebook ni accès au contenu privé. Vidéos complètes : vidéo seule et Retirer l’aperçu pendant 5 minutes, sans titre, auteur, description, lien ni bouton Ouvrir. Une tentative de remplacement ajoute un petit crédit d’auteur ; l’original reste si sa suppression échoue. Mettre les aperçus améliorés en pause suspend aussi les vidéos Facebook.")
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
