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
        case .reply: return language.text("Reply with a clean link", "Répondre avec le lien propre")
        case .replace: return language.text("Replace the original", "Remplacer l’original")
        case .secretary: return language.text("Secretary · private chats", "Secrétaire · en privé")
        case .off: return language.text("Leave messages unchanged", "Laisser les messages tels quels")
        }
    }

    static func outcome(_ mode: Mode, language: BotLanguage = .en) -> String {
        switch mode {
        case .reply:
            return language.text("Replies with the clean link; keeps the original message.",
                                 "Répond avec le lien propre ; garde le message original.")
        case .replace:
            return language.text(
                "Reposts clean text with the author’s name, then deletes the original if allowed. Media and forwarded messages get a reply instead.",
                "Republie le texte propre avec le nom de l’auteur, puis supprime l’original si autorisé. Les médias et transferts reçoivent une réponse.")
        case .secretary:
            return language.text("Edits only your outgoing messages in connected private chats. Your group messages get no fxclip replies.",
                                 "Modifie uniquement vos messages sortants dans les conversations privées connectées. Vos messages de groupe ne reçoivent aucune réponse fxclip.")
        case .off:
            return language.text("No replies or edits for these messages.", "Aucune réponse ni modification pour ces messages.")
        }
    }

    static func personal(mode: Mode?, defaultMode: Mode, owner: Bool,
                         preference: BotLanguage? = nil, language: BotLanguage = .en,
                         section: String = "show") -> SettingsUI {
        let current = mode.map { title($0, language: language) } ?? follow(scope: "p", language: language)
        var text = scopeHeader("p", language: language)
        var rows: [[[String: String]]] = []
        switch section {
        case "mode":
            text += "\n\n<b>\(language.text("Behavior", "Comportement"))</b>\n\(current)\n\n"
            text += language.text("Your choice takes priority for your messages only. It never resumes a paused group.",
                                  "Votre choix est prioritaire pour vos messages uniquement. Il ne réactive jamais un groupe en pause.")
            rows = modeRows(selected: mode, scope: "personal", language: language)
            rows.append([button("\(mode == nil ? "✓ " : "")\(follow(scope: "p", language: language))", "personal:default")])
            text += "\n\n" + (mode.map { outcome($0, language: language) } ?? language.text(
                "Without a group choice, the bot default applies: \(title(defaultMode, language: language)).",
                "Sans choix du groupe, le réglage par défaut du bot s’applique : \(title(defaultMode, language: language))."))
            text += "\n\n" + modeDisclosure(language: language)
            rows.append([button(language.text("Secretary · private chats →", "Secrétaire · en privé →"), "personal:secretary_setup")])
            rows.append([back("p", language: language), closeButton(language: language)])
        case "secretary_setup":
            text = language.text("<b>My preferences · Secretary</b>\nConnected private chats · my outgoing messages",
                                 "<b>Mes préférences · Secrétaire</b>\nConversations privées connectées · mes messages sortants")
            text += "\n\n" + language.text(
                "Connect this bot in Telegram’s automation settings and allow replies and edits. fxclip edits only your outgoing messages, never incoming ones.\n\nSecretary replaces your personal group behavior: your group messages will get no fxclip replies. Choose a group behavior again to leave this mode.",
                "Connectez ce bot dans les réglages d’automatisation de Telegram et autorisez les réponses et modifications. fxclip modifie uniquement vos messages sortants, jamais les messages reçus.\n\nSecrétaire remplace votre comportement personnel en groupe : vos messages de groupe ne recevront aucune réponse fxclip. Choisissez à nouveau un comportement de groupe pour quitter ce mode.")
            text += "\n\n" + language.text("Links pass through Telegram and any enabled mirror provider.", "Les liens passent par Telegram et les fournisseurs miroirs activés.")
            rows.append([button("\(mode == .secretary ? "✓ " : "")\(language.text("Use Secretary", "Activer Secrétaire"))", "personal:secretary")])
            rows.append([back("p", language: language), closeButton(language: language)])
        case "about", "info":
            text += "\n\n" + about(language: language)
            rows.append([back("p", language: language), closeButton(language: language)])
        default:
            text += "\n\n<b>\(language.text("Behavior: ", "Comportement : "))</b>\(current)"
            text += "\n" + (mode == .secretary
                ? language.text("Private chats only; no replies to my group messages.", "En privé uniquement ; aucune réponse à mes messages de groupe.")
                : language.text("Personal choices take priority. A paused group stays paused.", "Les choix personnels sont prioritaires. Un groupe en pause le reste."))
            rows.append([button(language.text("Behavior →", "Comportement →"), "personal:mode")])
            rows.append([button(language.text("Links & previews →", "Liens et aperçus →"), "rules:p:show")])
            rows.append([button(language.text("Secretary · private chats →", "Secrétaire · en privé →"), "personal:secretary_setup")])
            rows.append([button(language.text("Language: ", "Langue : ") + (preference?.name ?? language.text("Automatic", "Automatique")) + " ›", "language:show")])
            if owner {
                rows.append([button(language.text("Admin · Groups →", "Admin · Groupes →"), "groups:show")])
                rows.append([button(language.text("Admin · Bot defaults →", "Admin · Réglages par défaut →"), "default:show")])
            }
            rows.append([button(language.text("About & privacy", "À propos"), "personal:about"), closeButton(language: language)])
        }
        return panel(text, rows)
    }

    static func languages(selected: BotLanguage?, detected: BotLanguage) -> SettingsUI {
        let language = selected ?? detected
        let automatic = language.text("Automatic", "Automatique")
        let text = scopeHeader("p", language: language) + "\n\n<b>Language / Langue</b>\n" + language.text(
            "Automatic follows your Telegram language (English fallback). Each group has its own language.",
            "Automatique suit la langue de Telegram (anglais par défaut). Chaque groupe a sa propre langue.")
        return panel(text, [
            [button("\(selected == nil ? "✓ " : "")\(automatic) · \(detected.name)", "language:auto")],
            [button("\(selected == .en ? "✓ " : "")English", "language:en")],
            [button("\(selected == .fr ? "✓ " : "")Français", "language:fr")],
            [back("p", language: language), closeButton(language: language)],
        ])
    }

    static func defaults(mode: Mode, language: BotLanguage = .en,
                         section: String = "show") -> SettingsUI {
        var text = scopeHeader("d", language: language)
        var rows: [[[String: String]]] = []
        switch section {
        case "mode":
            text += "\n\n<b>\(language.text("Default behavior", "Comportement par défaut"))</b>\n\(title(mode, language: language))\n\n"
            text += language.text("Applies only when neither the person nor the group has chosen a behavior.",
                                  "S’applique seulement si ni la personne ni le groupe n’a choisi de comportement.")
            if mode == .secretary {
                text += "\n\n" + language.text("Secretary is a saved legacy value. For connected private chats, choose it in My preferences.",
                                               "Secrétaire est une ancienne valeur enregistrée. Pour les conversations privées connectées, choisissez-le dans Mes préférences.")
            } else { text += "\n\n" + outcome(mode, language: language) }
            text += "\n\n" + modeDisclosure(language: language)
            rows = modeRows(selected: mode, scope: "default", language: language)
            rows.append([back("d", language: language), closeButton(language: language)])
        case "about", "info":
            text += "\n\n" + about(language: language)
            rows.append([back("d", language: language), closeButton(language: language)])
        default:
            text += "\n\n<b>\(language.text("Behavior: ", "Comportement : "))</b>\(title(mode, language: language))"
            text += "\n" + language.text("Owner settings. Personal choices take priority over group choices, then these defaults.",
                                         "Réglages du propriétaire. Les choix personnels priment sur ceux du groupe, puis sur ces réglages par défaut.")
            rows.append([button(language.text("Default behavior →", "Comportement par défaut →"), "default:mode")])
            rows.append([button(language.text("Links & previews →", "Liens et aperçus →"), "rules:d:show")])
            rows.append([button(language.text("Admin · Groups →", "Administration · Groupes →"), "groups:show")])
            rows.append([button(language.text("About & privacy →", "À propos et confidentialité →"), "default:about")])
            rows.append([back("p", language: language), closeButton(language: language)])
        }
        return panel(text, rows)
    }

    static func groups(_ groups: [KnownGroup], enabled: (Int64) -> Bool, username: String,
                       language: BotLanguage = .en) -> SettingsUI {
        var text = scopeHeader("d", language: language) + "\n\n<b>\(language.text("Admin · Groups", "Administration · Groupes"))</b>\n"
        text += language.text("Active or paused for everyone. Open a group to check permissions.\nMissing one? Send /chatid@\(escaped(username)) there, then refresh.",
                              "Actif ou en pause pour tout le monde. Ouvrez un groupe pour vérifier les droits.\nUn groupe manque ? Envoyez /chatid@\(escaped(username)) dedans, puis actualisez.")
        if groups.isEmpty { text += "\n\n" + language.text("No groups discovered yet.", "Aucun groupe découvert pour le moment.") }
        var rows = groups.map { group in
            [button("\(enabled(group.chat.id) ? "▶" : "⏸") \(String((group.chat.title ?? String(group.chat.id)).prefix(60)))", "group:\(group.chat.id):show")]
        }
        rows.append([button(language.text("Refresh groups", "Actualiser les groupes"), "groups:show")])
        rows.append([back("d", language: language), closeButton(language: language)])
        return panel(text, rows)
    }

    static func welcome(chatID: Int64, username: String, language: BotLanguage = .en) -> SettingsUI {
        panel(scopeHeader("c:\(chatID)", language: language) + "\n\n" + language.text(
            "Hello 👋 I clean links and improve previews. Admins manage this group. My preferences apply only to your messages, in enabled groups.",
            "Bonjour 👋 Je nettoie les liens et améliore les aperçus. Les admins règlent ce groupe. Mes préférences concernent uniquement vos messages, dans les groupes activés."), [
                [button(language.text("Admin · This group →", "Administration · Ce groupe →"), "chat:\(chatID):show")],
                [personalLink(username: username, language: language)],
                [closeButton(language: language, action: "chat:\(chatID):close")],
            ])
    }

    static func chat(_ chat: Chat, settings: ChatSettings, enabled: Bool, inherited: Bool,
                     username: String, language: BotLanguage = .en,
                     section: String = "show") -> SettingsUI {
        let scope = "c:\(chat.id)"
        let key = "chat:\(chat.id):"
        let close = closeButton(language: language, action: key + "close")
        var text = scopeHeader(scope, groupTitle: chat.title ?? String(chat.id), language: language)
        var rows: [[[String: String]]] = []
        switch section {
        case "mode":
            text += "\n\n<b>\(language.text("Default behavior", "Comportement par défaut"))</b>\n"
            text += (inherited ? follow(scope: scope, language: language) + " · " : "") + title(settings.mode, language: language)
            text += "\n\n" + language.text("Only for members without a personal behavior choice. Personal overrides stay in effect.",
                                          "Uniquement pour les membres sans choix personnel de comportement. Les préférences personnelles restent prioritaires.")
            text += "\n\n" + outcome(settings.mode, language: language)
            text += "\n\n" + modeDisclosure(language: language)
            if !enabled { text += "\n\n" + paused(language: language) }
            rows = modeRows(selected: settings.mode, scope: "chat:\(chat.id)", language: language)
            rows.append([back(scope, language: language), close])
        case "language":
            text += "\n\n<b>\(language.text("Group language", "Langue du groupe"))</b>\n"
            text += language.text("For this group’s bot messages and settings. Personal language choices stay unchanged.",
                                  "Pour les messages du bot et les réglages de ce groupe. Les choix de langue personnels restent inchangés.")
            rows.append([button("\(language == .en ? "✓ " : "")English", key + "lang_en")])
            rows.append([button("\(language == .fr ? "✓ " : "")Français", key + "lang_fr")])
            rows.append([back(scope, language: language), close])
        case "about", "info":
            text += "\n\n" + about(language: language)
            text += "\n\n" + language.text("Enhanced previews: ", "Aperçus améliorés : ") + state(settings.previews, language: language)
            if !enabled { text += "\n" + paused(language: language) }
            if enabled {
                rows.append([button(settings.previews ? language.text("Pause enhanced previews", "Suspendre les aperçus améliorés") : language.text("Allow enhanced previews", "Autoriser les aperçus améliorés"), key + (settings.previews ? "previews_off" : "previews_on"))])
            }
            rows.append([back(scope, language: language), close])
        default:
            text += "\n\n<b>\(enabled ? language.text("Active for everyone", "Actif pour tout le monde") : language.text("Paused for everyone", "En pause pour tout le monde"))</b>"
            text += "\n" + language.text("Default behavior: ", "Comportement par défaut : ") + title(settings.mode, language: language)
            if inherited { text += "\n" + follow(scope: scope, language: language) }
            text += "\n" + language.text("Personal choices take priority when the group is active.", "Les choix personnels sont prioritaires quand le groupe est actif.")
            if !enabled { text += "\n\n" + resumeDisclosure(language: language) }
            rows.append([button(language.text("Default behavior →", "Comportement par défaut →"), key + "mode")])
            rows.append([button(language.text("Links & previews →", "Liens et aperçus →"), "rules:\(scope):show")])
            rows.append([button(language.text("Language: ", "Langue : ") + language.name + " ›", key + "language")])
            rows.append([button(enabled ? language.text("Pause for EVERYONE", "Mettre en pause pour TOUT LE MONDE") : language.text("Resume for EVERYONE", "Réactiver pour TOUT LE MONDE"), key + (enabled ? "disable" : "enable"))])
            rows.append([personalLink(username: username, language: language)])
            rows.append([button(language.text("About & privacy →", "À propos et confidentialité →"), key + "about")])
            rows.append([close])
        }
        return panel(text, rows)
    }

    static func rules(_ settings: UserSettings, builtins: Rules, scope: String,
                      section: String = "show", inherited: Bool, previewsEnabled: Bool = true,
                      youTubeCards: Bool = true, facebookReels: Bool = false,
                      language: BotLanguage = .en, groupTitle: String? = nil,
                      youTubeInherited: Bool = false, facebookInherited: Bool = false,
                      cleaningEnabled: Bool = true) -> SettingsUI {
        let groupID = scope.hasPrefix("c:") ? String(scope.dropFirst(2)) : nil
        let key = "rules:\(scope):"
        let command = groupID != nil ? "/fxclip " : scope == "d" ? "/default " : "/"
        let close = closeButton(language: language, action: groupID.map { "chat:\($0):close" } ?? "panel:close")
        let editable = scope == "d" || !inherited
        var text = scopeHeader(scope, groupTitle: groupTitle ?? groupID, language: language)
        if scope == "p", !["youtube", "youtube:show", "facebook", "facebook:show"].contains(section) {
            text = language.text("<b>My preferences · Links</b>\nMy messages · enabled groups + Secretary private chats",
                                 "<b>Mes préférences · Liens</b>\nMes messages · groupes activés + conversations privées Secrétaire")
        }
        var rows: [[[String: String]]] = []
        // Keep catalog IDs intact: omit a callback that cannot fit Telegram's 64 bytes.
        func add(_ label: String, _ action: String) {
            guard ("fxclip:" + key + action).utf8.count <= 64 else { return }
            rows.append([button(label, key + action)])
        }
        func toggle(_ label: String, enabled: Bool, action: String) -> [String: String]? {
            let callback = key + action + (enabled ? ":off" : ":on")
            guard ("fxclip:" + callback).utf8.count <= 64 else { return nil }
            return button("\(enabled ? "✓ " : "")\(label) · \(state(enabled, language: language))", callback)
        }
        func customize() {
            add(scope == "p" ? language.text("Create my link preferences →", "Créer mes préférences de liens →")
                : language.text("Customize this group →", "Personnaliser ce groupe →"), "customize")
        }
        func serviceActions(_ name: String, enabled: Bool, follows: Bool) {
            let enableLabel = scope == "p" ? language.text("Enable for me", "Activer pour moi")
                : scope == "d" ? language.text("Enable by default", "Activer par défaut")
                : language.text("Enable for this group", "Activer pour ce groupe")
            let disableLabel = scope == "p" ? language.text("Disable for me", "Désactiver pour moi")
                : scope == "d" ? language.text("Disable by default", "Désactiver par défaut")
                : language.text("Disable for this group", "Désactiver pour ce groupe")
            let enable = button(enableLabel, key + name + ":on")
            let disable = button(disableLabel, key + name + ":off")
            rows.append(follows ? [enable, disable] : [enabled ? disable : enable])
            if scope != "d", !follows {
                add(scope == "p" ? language.text("Follow group again", "Suivre à nouveau le groupe")
                    : language.text("Use bot default", "Utiliser le réglage par défaut du bot"), name + ":default")
            }
        }
        func source() -> String {
            if scope == "d" { return language.text("Source: bot defaults. Priority: personal, then group, then bot.", "Source : réglages par défaut du bot. Priorité : personne, puis groupe, puis bot.") }
            if inherited, scope == "p" {
                return language.text("In groups: follow each group. In Secretary private chats: follow bot defaults.",
                                     "En groupe : suivre chaque groupe. En privé avec Secrétaire : suivre les réglages par défaut du bot.")
            }
            if inherited { return language.text("Link rules: ", "Règles des liens : ") + follow(scope: scope, language: language) }
            return language.text("Custom link rules replace the complete inherited configuration.", "Les règles personnalisées remplacent toute la configuration héritée.")
        }
        if groupID != nil, !cleaningEnabled { text += "\n\n" + paused(language: language) }
        else if groupID != nil, !previewsEnabled {
            text += "\n\n" + language.text("Enhanced previews paused here (mirrors, YouTube and Facebook). Cleaning remains active.",
                                           "Aperçus améliorés en pause ici (miroirs, YouTube et Facebook). Le nettoyage reste actif.")
        }
        let normalized = section.hasSuffix(":show") ? String(section.dropLast(5)) : section
        var dashboard = false
        var backAction = "show"
        var backLabel = language.text("← Links & previews", "← Liens et aperçus")
        switch normalized {
        case "clean":
            text += "\n\n<b>\(language.text("Tracker cleaning", "Nettoyage des traceurs"))</b>\n" + source()
            if editable {
                text += "\n" + language.text("General trackers and site rules are independent.", "Traceurs généraux et règles par site sont indépendants.")
                if let global = toggle(language.text("General trackers", "Traceurs généraux"), enabled: settings.trackersEverywhere, action: "trackers") { rows.append([global]) }
                var pair: [[String: String]] = []
                for site in builtins.trackers.sites {
                    if let item = toggle(site.name, enabled: !settings.disabledSites.contains(site.id), action: "site:\(site.id)") {
                        pair.append(item)
                        if pair.count == 2 { rows.append(pair); pair = [] }
                    }
                }
                if !pair.isEmpty { rows.append(pair) }
            } else {
                text += "\n\n" + language.text("Inherited rules are read-only. Create a complete link configuration to change cleaning, mirrors or exclusions.",
                                               "Les règles héritées sont en lecture seule. Créez une configuration complète pour modifier nettoyage, miroirs ou exclusions.")
                customize()
            }
        case "previews":
            text += "\n\n<b>\(language.text("Previews", "Aperçus"))</b>\n" + source()
            text += "\n" + language.text("Choose a service. YouTube and Facebook have separate preferences.", "Choisissez un service. YouTube et Facebook ont des préférences séparées.")
            for preview in builtins.previews {
                let value = editable ? state(mirrorEnabled(preview.id, settings: settings, builtins: builtins), language: language) : follow(scope: scope, language: language)
                add("\(preview.name) · \(value) ›", "preview:\(preview.id):show")
            }
            add("YouTube · \(youTubeInherited && scope != "d" ? follow(scope: scope, language: language) : state(youTubeCards, language: language)) ›", "youtube:show")
            add("Facebook · \(facebookInherited && scope != "d" ? follow(scope: scope, language: language) : state(facebookReels, language: language)) ›", "facebook:show")
            if let groupID, cleaningEnabled, !previewsEnabled {
                text += "\n\n" + resumeDisclosure(language: language)
                rows.append([button(language.text("Resume enhanced previews", "Réactiver les aperçus améliorés"), "chat:\(groupID):previews_on")])
            }
        case "youtube":
            text += "\n\n<b>YouTube</b> · " + (youTubeInherited && scope != "d" ? follow(scope: scope, language: language) : state(youTubeCards, language: language))
            text += "\n\n" + language.text(
                "When enabled, a single plain link gets a title and thumbnail fetched directly from YouTube, even if already clean. Telegram may also show its own preview: duplicates are possible.",
                "Une fois activé, un lien seul et sans mise en forme reçoit un titre et une miniature récupérés directement sur YouTube, même déjà propre. Telegram peut aussi afficher son aperçu : un doublon est possible.")
            text += "\n\n" + removalDisclosure(language: language)
            serviceActions("youtube", enabled: youTubeCards, follows: youTubeInherited && scope != "d")
            backAction = "previews"; backLabel = language.text("← Previews", "← Aperçus")
        case "facebook":
            text += "\n\n<b>Facebook</b> · " + (facebookInherited && scope != "d" ? follow(scope: scope, language: language) : state(facebookReels, language: language))
            text += "\n\n" + facebookDisclosure(language: language)
            text += "\n\n" + removalDisclosure(language: language)
            serviceActions("facebook", enabled: facebookReels, follows: facebookInherited && scope != "d")
            backAction = "previews"; backLabel = language.text("← Previews", "← Aperçus")
        case "excluded":
            text += "\n\n<b>\(language.text("Cleaning exclusions", "Exclusions du nettoyage"))</b>\n" + source()
            text += "\n" + language.text("These domains skip tracker cleaning. Preview choices still apply separately.", "Ces domaines échappent au nettoyage des traceurs. Les choix d’aperçu s’appliquent séparément.")
            if editable {
                if settings.neverClean.isEmpty { text += "\n\n" + language.text("No exclusions.", "Aucune exclusion.") }
                for host in settings.neverClean.prefix(5) {
                    text += "\n• \(escaped(host.host))" + (host.subdomains ? language.text(" (+ subdomains)", " (+ sous-domaines)") : language.text(" (exact)", " (exact)"))
                }
                if settings.neverClean.count > 5 { text += "\n" + language.text("… and \(settings.neverClean.count - 5) more.", "… et \(settings.neverClean.count - 5) autres.") }
                text += "\n\n<code>\(escaped(command))exclude add &lt;domain&gt;</code>\n<code>\(escaped(command))exclude remove &lt;domain&gt;</code>"
            } else { customize() }
        case "customize":
            text += "\n\n<b>\(scope == "p" ? language.text("Create my link preferences?", "Créer mes préférences de liens ?") : language.text("Customize this group?", "Personnaliser ce groupe ?"))</b>"
            text += "\n\n" + language.text(
                "Starts from the bot defaults, not the current group rules. Your new configuration replaces the complete cleaning, mirror and exclusion configuration.\n\nYouTube and Facebook preferences stay separate and unchanged. Behavior is unchanged. After creation, repeat any provider or exclusion command.",
                "Le point de départ est le réglage par défaut du bot, pas les règles actuelles du groupe. La nouvelle configuration remplace l’ensemble du nettoyage, des miroirs et des exclusions.\n\nLes préférences YouTube et Facebook restent séparées et inchangées. Le comportement ne change pas. Après création, répétez toute commande de fournisseur ou d’exclusion.")
            text += "\n\n" + language.text("Enabled mirrors receive preview links through Telegram.", "Les miroirs activés reçoivent les liens d’aperçu via Telegram.")
            if scope != "d" { add(language.text("Create these link preferences", "Créer ces préférences de liens"), "customize:confirm") }
        case "reset":
            text += "\n\n<b>\(language.text("Reset link preferences?", "Réinitialiser les préférences de liens ?"))</b>\n\n"
            text += scope == "d" ? language.text(
                "Restores built-in cleaning, mirrors, exclusions, YouTube and Facebook defaults. Existing personal and group overrides stay unchanged.",
                "Rétablit les réglages d’origine du nettoyage, des miroirs, des exclusions, de YouTube et de Facebook. Les choix personnels et de groupe existants restent inchangés.") : language.text(
                "Removes this scope’s cleaning, mirror, exclusion, YouTube and Facebook preferences. They will follow \(scope == "p" ? "each group" : "the bot defaults") again.",
                "Retire les préférences de nettoyage, miroirs, exclusions, YouTube et Facebook à ce niveau. Elles suivront à nouveau \(scope == "p" ? "chaque groupe" : "les réglages par défaut du bot").")
            text += "\n\n" + language.text("Behavior, language and group activation are unchanged.", "Le comportement, la langue et l’activation du groupe ne changent pas.")
            text += "\n\n" + modeDisclosure(language: language)
            add(language.text("Reset link preferences", "Réinitialiser les préférences de liens"), "reset")
        case "info", "about":
            text += "\n\n" + about(language: language)
            text += "\n\n" + language.text("In groups: personal link rules, then group, then bot defaults. Secretary private chats use personal rules or bot defaults, never group rules. A custom configuration replaces cleaning, mirrors and exclusions together. YouTube and Facebook inherit independently.",
                                          "En groupe : règles personnelles, puis groupe, puis bot. En privé, Secrétaire suit les règles personnelles ou celles du bot, jamais celles d’un groupe. Une configuration personnalisée remplace ensemble nettoyage, miroirs et exclusions. YouTube et Facebook sont hérités séparément.")
        case let leaf where leaf.hasPrefix("preview:") || leaf.hasPrefix("provider:"):
            let provider = leaf.hasPrefix("provider:")
            let id = String(leaf.dropFirst(provider ? 9 : 8))
            backAction = "previews"; backLabel = language.text("← Previews", "← Aperçus")
            if let preview = builtins.previews.first(where: { $0.id == id }) {
                let host = settings.previews[id]?.targetHost.flatMap(Rules.canonicalPreviewHost) ?? preview.to
                text += "\n\n<b>\(escaped(preview.name))</b> · " + (editable ? state(mirrorEnabled(id, settings: settings, builtins: builtins), language: language) : follow(scope: scope, language: language))
                if !editable {
                    text += "\n\n" + (scope == "p" ? language.text(
                        "The inherited mirror and provider can vary by group. Secretary private chats follow bot defaults. Create link preferences before changing them.",
                        "Le miroir et son fournisseur hérités peuvent varier selon le groupe. En privé, Secrétaire suit les réglages par défaut du bot. Créez des préférences de liens pour les modifier.") : language.text(
                        "This mirror and its provider follow the bot defaults. Customize this group before changing them.",
                        "Ce miroir et son fournisseur suivent les réglages par défaut du bot. Personnalisez ce groupe pour les modifier."))
                    customize()
                } else if provider {
                    text += "\n\n" + language.text("Current provider: ", "Fournisseur actuel : ") + "<code>\(escaped(host))</code>"
                    text += "\n" + language.text("Built-in provider: ", "Fournisseur d’origine : ") + escaped(preview.to)
                    text += "\n\n" + language.text("Send a mirror domain (no path). That provider receives enabled preview links.", "Envoyez un domaine miroir (sans chemin). Ce fournisseur reçoit les liens d’aperçu activés.")
                    text += "\n<code>\(escaped(command))provider \(escaped(id)) &lt;domain&gt;</code>"
                    add(language.text("Restore built-in provider", "Rétablir le fournisseur d’origine"), "providerreset:\(id)")
                } else {
                    text += "\n\n" + language.text("When enabled, links use ", "Une fois activé, les liens utilisent ") + "<code>\(escaped(host))</code>."
                    text += "\n" + language.text("Links pass through Telegram and this mirror provider.", "Les liens passent par Telegram et ce fournisseur miroir.")
                    let enabled = mirrorEnabled(id, settings: settings, builtins: builtins)
                    add(enabled ? language.text("Disable mirror", "Désactiver le miroir") : language.text("Enable mirror", "Activer le miroir"), "preview:\(id):" + (enabled ? "off" : "on"))
                    add(language.text("Advanced · Provider →", "Avancé · Fournisseur →"), "provider:\(id)")
                }
            } else { text += "\n\n" + language.text("This preview is no longer available.", "Cet aperçu n’est plus disponible.") }
        default:
            dashboard = true
            text += "\n\n<b>\(language.text("Links & previews", "Liens et aperçus"))</b>\n" + source()
            if scope == "p" { text += "\n" + language.text("Personal link rules take priority in every enabled group.", "Les règles personnelles sont prioritaires dans tous les groupes activés.") }
            else if groupID != nil { text += "\n" + language.text("Personal link preferences take priority.", "Les préférences de liens personnelles sont prioritaires.") }
            add(language.text("Tracker cleaning →", "Nettoyage des traceurs →"), "clean")
            add(language.text("Previews →", "Aperçus →"), "previews")
            add(language.text("Cleaning exclusions →", "Exclusions du nettoyage →"), "excluded")
            add(language.text("Reset link preferences…", "Réinitialiser les préférences de liens…"), "reset:show")
            add(language.text("About & privacy →", "À propos et confidentialité →"), "info")
        }
        if dashboard {
            rows.append([back(scope, language: language), close])
        } else {
            rows.append([button(backLabel, key + backAction), close])
        }
        return panel(text, rows)
    }

    static func group(_ group: KnownGroup, enabled: Bool, rights: ChatMember?,
                      language: BotLanguage = .en) -> SettingsUI {
        let chat = group.chat
        var text = scopeHeader("c:\(chat.id)", groupTitle: chat.title ?? String(chat.id), language: language)
        text += "\n\n<b>\(enabled ? language.text("Active for everyone", "Actif pour tout le monde") : language.text("Paused for everyone", "En pause pour tout le monde"))</b>"
        text += "\n" + language.text("Admin · Activation and bot permissions. Pausing stops all cleaning, including personal choices; behavior preferences stay saved.",
                                     "Administration · Activation et droits du bot. La pause arrête tout nettoyage, même avec un choix personnel ; les comportements restent enregistrés.")
        if let rights {
            text += "\n\n" + language.text("Administrator: ", "Administrateur : ") + (rights.isAdmin ? language.text("yes", "oui") : language.text("no", "non"))
            text += "\n" + language.text("Delete originals: ", "Supprimer les originaux : ") + (rights.canDelete(in: chat) ? language.text("allowed", "autorisé") : language.text("not allowed · replies only", "non autorisé · réponses uniquement"))
            if rights.status == "restricted" {
                text += "\n" + language.text("Send messages: ", "Envoi de messages : ") + permission(rights.can_send_messages, language: language)
                text += "\n" + language.text("Link previews: ", "Aperçus des liens : ") + permission(rights.can_add_web_page_previews, language: language)
            }
            if !rights.isAdmin {
                text += "\n" + language.text("Privacy mode may limit reading. A group admin can grant access and deletion rights in Telegram.",
                                             "Le mode confidentialité peut limiter la lecture. Un admin du groupe peut accorder l’accès et la suppression dans Telegram.")
            }
        } else {
            text += "\n\n" + language.text("Permissions not checked. Refresh before activation.", "Droits non vérifiés. Actualisez avant l’activation.")
        }
        text += "\n\n" + activationDisclosure(language: language)
        let key = "group:\(chat.id):"
        return panel(text, [
            [button(enabled ? language.text("Pause for EVERYONE", "Mettre en pause pour TOUT LE MONDE") : language.text("Resume for EVERYONE", "Réactiver pour TOUT LE MONDE"), key + (enabled ? "off" : "on"))],
            [button(language.text("Refresh permissions", "Actualiser les droits"), key + "refresh")],
            [button(language.text("← Admin · Groups", "← Administration · Groupes"), "groups:show"), closeButton(language: language)],
        ])
    }

    private static func scopeHeader(_ scope: String, groupTitle: String? = nil, language: BotLanguage) -> String {
        if scope == "p" {
            return language.text("<b>My preferences</b>\nOnly my messages · all enabled groups",
                                 "<b>Mes préférences</b>\nMes messages uniquement · tous les groupes activés")
        }
        if scope == "d" {
            return language.text("<b>Bot defaults</b>\nFallback only · existing overrides unchanged",
                                 "<b>Réglages par défaut du bot</b>\nEn dernier recours · choix existants inchangés")
        }
        let title = groupTitle.map { " · \(escaped($0))" } ?? ""
        return language.text("<b>This group\(title)</b>\nMembers without personal overrides",
                             "<b>Ce groupe\(title)</b>\nMembres sans préférence personnelle")
    }

    private static func follow(scope: String, language: BotLanguage) -> String {
        scope == "p" ? language.text("Follow group", "Suivre le groupe") : language.text("Follow bot defaults", "Suivre les réglages par défaut du bot")
    }

    private static func state(_ enabled: Bool, language: BotLanguage) -> String {
        enabled ? language.text("On", "Activé") : language.text("Off", "Désactivé")
    }

    private static func paused(language: BotLanguage) -> String {
        language.text("⏸ Bot paused for everyone here. These choices apply when resumed.",
                      "⏸ Bot en pause pour tout le monde ici. Ces choix s’appliqueront à la reprise.")
    }

    private static func mirrorEnabled(_ id: String, settings: UserSettings, builtins: Rules) -> Bool {
        guard let preview = builtins.previews.first(where: { $0.id == id }) else { return false }
        return (settings.previews[id]?.enabled ?? settings.previewDefaultsEnabled)
            && (settings.previews[id]?.apps ?? preview.apps).contains("telegram")
    }

    private static func personalLink(username: String, language: BotLanguage = .en) -> [String: String] {
        ["text": language.text("My preferences ↗", "Mes préférences ↗"), "url": "https://t.me/\(username)?start=settings"]
    }

    private static func permission(_ value: Bool?, language: BotLanguage = .en) -> String {
        value.map { $0 ? language.text("allowed", "autorisé") : language.text("not allowed", "non autorisé") }
            ?? language.text("not confirmed", "non confirmé")
    }

    private static func removalDisclosure(language: BotLanguage) -> String {
        language.text(
            "Remove preview is available for 5 minutes. Open-button URLs are kept locally until button cleanup, retried for up to 48 h. Full-video replies retain no Open URL. Message text and media are not saved.",
            "Retirer l’aperçu est disponible pendant 5 minutes. Les URL des boutons d’ouverture restent localement jusqu’au retrait du bouton, avec réessais pendant 48 h maximum. Les vidéos complètes ne conservent aucune URL d’ouverture. Texte et médias ne sont pas enregistrés.")
    }

    private static func facebookDisclosure(language: BotLanguage) -> String {
        language.text(
            "Downloads a public Facebook video on the bot server and posts a copy to Telegram. Private resolution, no public facebed.com service or Facebook login. Limit: 20 MiB; larger videos get an Open Facebook link and keep the original. Duplicates are possible if Telegram also shows its preview.",
            "Le bot télécharge une vidéo publique sur Facebook et en envoie une copie à Telegram. Résolution privée, sans service public facebed.com ni connexion Facebook. Limite : 20 Mio ; au-delà, un lien Ouvrir Facebook est envoyé et l’original reste. Des doublons sont possibles si Telegram affiche aussi son aperçu.")
    }

    private static func resumeDisclosure(language: BotLanguage) -> String {
        language.text(
            "Enabled previews contact Telegram, mirrors, YouTube or Facebook. Opening links may stay on the bot server for button cleanup, up to 48 h.",
            "Les aperçus activés contactent Telegram, des miroirs, YouTube ou Facebook. Les liens d’ouverture peuvent rester sur le serveur pour le retrait des boutons, jusqu’à 48 h.")
    }

    private static func activationDisclosure(language: BotLanguage) -> String {
        language.text(
            "Links pass through Telegram and enabled mirror providers. YouTube may fetch titles/thumbnails; Facebook videos are off by default and separately opt-in. Enabled Facebook videos are copied to Telegram. Duplicate previews are possible.",
            "Les liens passent par Telegram et les fournisseurs miroirs activés. YouTube peut fournir titres et miniatures ; les vidéos Facebook sont désactivées par défaut et à activer séparément. Une fois activées, elles sont copiées dans Telegram. Des doublons d’aperçu sont possibles.") + "\n\n" + removalDisclosure(language: language)
    }

    private static func modeDisclosure(language: BotLanguage) -> String {
        language.text(
            "Enabled previews use Telegram, mirror providers or YouTube. Facebook video is separately opt-in. Duplicates are possible. Open-button URLs stay locally for cleanup, up to 48 h.",
            "Les aperçus activés passent par Telegram, des miroirs ou YouTube. La vidéo Facebook s’active séparément. Des doublons sont possibles. Les URL d’ouverture restent localement pour le retrait des boutons, 48 h maximum.")
    }

    private static func about(language: BotLanguage) -> String {
        "<b>\(language.text("About & privacy", "À propos et confidentialité"))</b>\n" + activationDisclosure(language: language)
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func modeRows(selected: Mode?, scope: String, language: BotLanguage = .en) -> [[[String: String]]] {
        [Mode.reply, .replace, .off].map { mode in
            [button("\(selected == mode ? "✓ " : "")\(title(mode, language: language))", "\(scope):\(mode.rawValue)")]
        }
    }

    private static func back(_ scope: String, language: BotLanguage) -> [String: String] {
        if scope == "p" { return button(language.text("← My preferences", "← Mes préférences"), "personal:show") }
        if scope == "d" { return button(language.text("← Bot defaults", "← Défauts du bot"), "default:show") }
        return button(language.text("← This group", "← Ce groupe"), "chat:\(scope.dropFirst(2)):show")
    }

    private static func panel(_ text: String, _ rows: [[[String: String]]]) -> SettingsUI {
        SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    private static func closeButton(language: BotLanguage, action: String = "panel:close") -> [String: String] {
        button(language.text("✕ Close", "✕ Fermer"), action)
    }

    private static func button(_ text: String, _ action: String) -> [String: String] {
        ["text": text, "callback_data": "fxclip:\(action)"]
    }
}
