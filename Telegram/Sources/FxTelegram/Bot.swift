import Foundation
import FxEngine

public final class Bot {
    private let api: BotAPI
    private let store: StateStore
    private let rewriter: Rewriter
    private let allowedChats: Set<Int64>
    private let allowedOwners: Set<Int64>
    private let botID: Int64
    private let username: String
    private let youTubeMetadata: YouTubeMetadataProviding?
    public init(api: BotAPI, store: StateStore, engine: Engine,
                allowedChats: Set<Int64>, allowedOwners: Set<Int64> = [], botID: Int64, username: String,
                youTubeMetadata: YouTubeMetadataProviding? = nil) {
        self.api = api; self.store = store; self.rewriter = Rewriter(engine: engine)
        self.allowedChats = allowedChats; self.botID = botID; self.username = username
        self.allowedOwners = allowedOwners
        self.youTubeMetadata = youTubeMetadata
    }

    public func handle(_ update: Update, now: Int = Int(Date().timeIntervalSince1970)) async throws {
        try store.observeLanguage(update.callback_query?.from ?? update.message?.from ?? update.edited_message?.from
                                  ?? update.business_message?.from ?? update.edited_business_message?.from)
        if let membership = update.my_chat_member {
            try store.discover(membership.chat, member: membership.new_chat_member)
            // Only an explicit arrival is a greeting: missing old membership is ambiguous.
            // The runtime reserves each update before this send, including disabled groups.
            if membership.chat.isGroup, membership.old_chat_member?.isAbsent == true,
               ["member", "administrator", "creator"].contains(membership.new_chat_member.status)
                || (membership.new_chat_member.status == "restricted" && membership.new_chat_member.is_member == true) {
                try await sendPanel(SettingsUI.welcome(chatID: membership.chat.id, username: username,
                                                      language: store.groupLanguage(membership.chat.id)),
                                    to: membership.chat.id)
            }
        }
        // Discovery precedes eligibility, age and content checks, and never rewrites edits.
        for message in [update.message, update.edited_message].compactMap({ $0 }) {
            try store.discover(message.chat)
        }
        if let callback = update.callback_query {
            try await settingsCallback(callback, now: now)
            return
        }
        if let message = update.business_message ?? update.edited_business_message {
            try await secretary(message, now: now)
            return
        }
        guard let message = update.message, now - message.date <= 300,
              message.from?.is_bot != true || message.sender_chat != nil,
              message.is_automatic_forward != true,
              message.has_protected_content != true, message.is_paid_post != true else { return }
        let words = (message.text ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let target = (words.first ?? "").split(separator: "@", maxSplits: 1).map(String.init)
        if (words.first ?? "").hasPrefix("/"), target.count == 2,
           target[1].lowercased() != username.lowercased() { return }
        let command = target.first ?? ""
        let language = interfaceLanguage(message)
        if try await rulesCommand(message, command: command, words: words, language: language) { return }
        if command == "/chatid" {
            try await reply(language.text("Chat ID: \(message.chat.id)", "Identifiant de cette conversation : \(message.chat.id)"), to: message)
            return
        }
        if message.chat.type == "private", let user = message.from, message.chat.id == user.id,
           ["/start", "/help", "/settings", "/mode", "/secretary", "/default", "/groups", "/language"].contains(command) {
            if ["/start", "/help", "/settings"].contains(command) {
                await refreshPrivateCommands(user.id)
            }
            if command == "/language" {
                if words.count == 2 {
                    if words[1] == "auto" {
                        try store.setUserLanguage(nil, userID: user.id)
                    } else if let chosen = BotLanguage(rawValue: words[1]) {
                        try store.setUserLanguage(chosen, userID: user.id)
                    }
                }
                try await sendPanel(languagePanel(user.id), to: message.chat.id)
                await refreshPrivateCommands(user.id)
                return
            }
            if command == "/groups" {
                guard allowedOwners.contains(user.id) else {
                    try await reply(language.text("Only the bot owner can manage connected groups.", "La gestion des groupes est réservée au propriétaire du bot."), to: message)
                    return
                }
                try await sendPanel(groupsPanel(language: language), to: message.chat.id)
                return
            }
            if command == "/default" {
                guard allowedOwners.contains(user.id) else {
                    try await reply(language.text("Only the bot owner can change the global default. Open /settings to choose your personal mode.", "Seul le propriétaire du bot peut changer le réglage général. Ouvrez /settings pour choisir votre mode personnel."), to: message)
                    return
                }
                if words.count == 2, let mode = Mode(rawValue: words[1]) { try store.setDefault(mode) }
                try await sendPanel(SettingsUI.defaults(mode: store.state.defaultMode, language: language), to: message.chat.id)
                return
            }
            if command == "/mode", words.count == 2 {
                if words[1] == "default" { try store.setMode(nil, userID: user.id) }
                else if let mode = Mode(rawValue: words[1]) { try store.setMode(mode, userID: user.id) }
            }
            if command == "/secretary", words.count == 2, ["on", "off"].contains(words[1]) {
                try store.setMode(words[1] == "on" ? .secretary : .off, userID: user.id)
            }
            try await sendPanel(personalPanel(userID: user.id), to: message.chat.id)
            return
        }
        if command == "/start" || command == "/help" {
            try await reply(language.text(
                "fxclip cleans links and improves previews.\n\nOpen my private settings to choose what happens to your messages.\n\nAdmins: /setup configures this group. Commands: /fxclip reply, /fxclip replace, /fxclip off or /fxclip previews on|off.\n\nThe bot reads messages in this group. Cleaned links are sent to Telegram and, for some previews, to mirror sites.",
                "fxclip nettoie les liens et améliore leurs aperçus.\n\nOuvrez mes réglages en privé pour choisir le comportement de vos messages.\n\nAdmins : /setup permet de régler ce groupe. Commandes : /fxclip reply, /fxclip replace, /fxclip off ou /fxclip previews on|off.\n\nLe bot lit les messages de ce groupe. Les liens nettoyés passent par Telegram et, pour certains aperçus, par un site miroir."),
                to: message, markup: privateSettingsLink(language: language))
            return
        }
        if message.chat.isGroup, command == "/setup" || (command == "/fxclip" && words.count == 1) {
            try await sendPanel(chatPanel(message.chat), to: message.chat.id)
            return
        }
        var settings = chatSettings(message.chat.id)
        if command == "/fxclip" {
            if words.count > 1 {
                // Anonymous admin identities cannot be authenticated as a particular member.
                guard message.sender_chat == nil, let user = message.from,
                      try await isAdmin(chatID: message.chat.id, userID: user.id) else {
                    try await reply(language.text("Only an identified group admin can change this setting. If you post anonymously, use your personal profile.", "Seul un administrateur identifié du groupe peut changer ce réglage. Si vous publiez anonymement, utilisez votre profil personnel."), to: message)
                    return
                }
                if words.count == 2, let mode = Mode(rawValue: words[1]), mode != .secretary {
                    if mode == .replace, !(try await canDelete(in: message.chat)) {
                        try await reply(language.text("To enable replacement, first grant fxclip Delete messages permission in the group's admin settings.", "Pour activer le remplacement, donnez d’abord à fxclip le droit de supprimer les messages dans les réglages administrateurs du groupe."), to: message)
                        return
                    }
                    settings.mode = mode
                } else if words.count == 3, words[1] == "previews", ["on", "off"].contains(words[2]) {
                    settings.previews = words[2] == "on"
                } else {
                    try await reply(language.text(
                        "Use /fxclip reply to reply, /fxclip replace to replace, or /fxclip off to do nothing.\n\nImproved previews: /fxclip previews on or /fxclip previews off.\n\nChoose Secretary Mode in private with /settings; it only works in connected private chats.",
                        "Choisissez /fxclip reply pour répondre, /fxclip replace pour remplacer ou /fxclip off pour désactiver.\n\nAperçus améliorés : /fxclip previews on ou /fxclip previews off.\n\nLe mode Secrétaire se choisit en privé avec /settings et agit uniquement dans les conversations privées connectées."), to: message)
                    return
                }
                try store.set(settings, chatID: message.chat.id)
            }
            let source = store.state.chats[String(message.chat.id)] == nil
                ? language.text("Global default applied", "Réglage général appliqué")
                : language.text("Group setting", "Réglage du groupe")
            let previews = settings.previews ? language.text("on", "activés") : language.text("off", "désactivés")
            let summary = "\(source): \(SettingsUI.title(settings.mode, language: language)).\n\n\(SettingsUI.outcome(settings.mode, language: language))\n\n"
            try await reply(summary + language.text(
                "Improved previews: \(previews).\nWhen on, plain YouTube links can receive a title and thumbnail fetched directly from YouTube, even if already clean. A duplicate is possible when Telegram's own preview works.\nA personal choice overrides this mode, including /fxclip off, while cleaning is enabled for this group. Choose yours in private.\n\nAdmins: /fxclip reply · /fxclip replace · /fxclip off\n/fxclip previews on|off",
                "Aperçus améliorés : \(previews).\nLorsqu’ils sont activés, les liens YouTube seuls peuvent recevoir un titre et une miniature récupérés directement sur YouTube, même s’ils sont déjà propres. Un doublon est possible si l’aperçu Telegram fonctionne.\nUn choix personnel passe avant ce mode, y compris /fxclip off, tant que le nettoyage est activé pour ce groupe. Choisissez le vôtre en privé.\n\nAdmins : /fxclip reply · /fxclip replace · /fxclip off\n/fxclip previews on|off"),
                to: message, markup: privateSettingsLink(language: language))
            return
        }
        guard isEnabled(chatID: message.chat.id) else { return }
        if message.sender_chat == nil, let user = message.from,
           let personal = store.state.users[String(user.id)] { settings.mode = personal }
        guard ["group", "supergroup", "private"].contains(message.chat.type),
              settings.mode != .off, settings.mode != .secretary else { return }
        let senderID = message.sender_chat == nil ? message.from?.id : nil
        let configured = configuredRewriter(chatID: message.chat.id, userID: senderID)
        let replyContent = configured.rewrite(message, previews: settings.previews, attribution: false)
        // This is presentation, not another cleaning engine. Only plain, single-link
        // messages qualify; formatting, hidden links and media keep their existing path.
        let videoID: String?
        if settings.previews, cardsEnabled(chatID: message.chat.id, userID: senderID),
           message.link_preview_options?.is_disabled != true,
           youTubeMetadata != nil, let text = message.text,
           (message.entities ?? []).allSatisfy({ $0.type == "url" }), isBareURL(text) {
            videoID = YouTubePreview.videoID(in: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else { videoID = nil }
        guard replyContent != nil || videoID != nil else { return }
        // Media, forwards and anonymous/channel-authored posts retain their originals.
        var replace = false
        if replyContent != nil && settings.mode == .replace && message.text != nil && message.sender_chat == nil && message.forward_origin == nil {
            replace = try await canDelete(in: message.chat)
        }
        let rendered: RenderedMessage?
        if replace {
            guard let credited = configured.rewrite(message, previews: settings.previews, language: language) else { return }
            rendered = credited
        } else {
            // Telegram's reply header already identifies the original sender.
            rendered = replyContent
        }
        let removalPoster = !replace && message.sender_chat == nil && message.from?.is_bot == false ? message.from?.id : nil
        if let videoID, let youTubeMetadata {
            // Fetching metadata is safe to fall back from; a timed-out send is not.
            let metadata = try? await youTubeMetadata.fetch(videoID: videoID)
            if let metadata {
                let cleanURL = configured.engine.clean(message.text ?? "").text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanText = rendered?.text ?? cleanURL
                let heading = "YouTube\n"
                let prefix = heading + metadata.title + "\n\n"
                let caption = prefix + cleanText
                if caption.utf16.count <= 1024 {
                    var photo = base(message)
                    photo["photo"] = metadata.thumbnailURL.absoluteString
                    photo["caption"] = caption
                    photo["disable_notification"] = true
                    var entities = [Entity(type: "text_link", offset: 0, length: 7, url: cleanURL),
                                    Entity(type: "bold", offset: heading.utf16.count, length: metadata.title.utf16.count)]
                    if let rendered {
                        var originalEntities = rendered.entities
                        for index in originalEntities.indices { originalEntities[index].offset += prefix.utf16.count }
                        entities += originalEntities
                    } else {
                        entities.append(Entity(type: "url", offset: prefix.utf16.count, length: cleanText.utf16.count))
                    }
                    photo["caption_entities"] = try jsonObject(entities)
                    photo["reply_markup"] = ["inline_keyboard": [[[
                        "text": language.text("▶ Open YouTube", "▶ Ouvrir YouTube"), "url": cleanURL,
                    ]]]]
                    if removalPoster != nil { addRemovalButton(to: &photo, language: language) }
                    if replace {
                        if let parent = message.reply_to_message {
                            photo["reply_parameters"] = ["message_id": parent.message_id, "allow_sending_without_reply": true]
                        }
                    } else {
                        photo["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true]
                    }
                    do {
                        let sent = try await api.call("sendPhoto", photo)
                        guard let sent = sent as? [String: Any], let sentID = confirmedMessageID(sent["message_id"]) else {
                            throw BotError.invalidResponse
                        }
                        if let removalPoster {
                            try store.recordReplyControl(chatID: message.chat.id, messageID: sentID, posterID: removalPoster, now: TimeInterval(now))
                        }
                        if replace { await deleteReplacedOriginal(message) }
                        return
                    } catch BotError.telegram(let code) where code == 400 || code == 403 {
                        // Explicit rejection means no photo was sent. Preserve the normal
                        // cleaned-text path; never retry an ambiguous transport failure.
                    }
                }
            }
        }
        guard let rendered else { return }
        var parameters = base(message)
        parameters["text"] = rendered.text
        parameters["entities"] = try jsonObject(rendered.entities)
        parameters["link_preview_options"] = ["is_disabled": false, "url": rendered.previewURL]
        parameters["disable_notification"] = true
        if removalPoster != nil { addRemovalButton(to: &parameters, language: language) }
        if replace {
            if let parent = message.reply_to_message {
                parameters["reply_parameters"] = ["message_id": parent.message_id, "allow_sending_without_reply": true]
            }
        } else {
            parameters["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true]
        }
        // No delete until Telegram confirms an actual new message ID. Never retry an ambiguous send.
        let sent = try await api.call("sendMessage", parameters)
        guard let sent = sent as? [String: Any], let sentID = confirmedMessageID(sent["message_id"]) else {
            throw BotError.invalidResponse
        }
        if let removalPoster {
            try store.recordReplyControl(chatID: message.chat.id, messageID: sentID, posterID: removalPoster, now: TimeInterval(now))
        }
        if replace { await deleteReplacedOriginal(message) }
    }

    private func addRemovalButton(to parameters: inout [String: Any], language: BotLanguage) {
        var markup = parameters["reply_markup"] as? [String: Any] ?? [:]
        var rows = markup["inline_keyboard"] as? [[[String: String]]] ?? []
        rows.append([["text": language.text("🗑 Remove preview", "🗑 Retirer l’aperçu"),
                      "callback_data": "fxclip:preview:delete"]])
        markup["inline_keyboard"] = rows
        parameters["reply_markup"] = markup
    }

    private func removePreview(_ callback: CallbackQuery, now: TimeInterval) async {
        let language = store.userLanguage(callback.from.id)
        guard callback.data == "fxclip:preview:delete", callback.from.is_bot != true,
              let message = callback.message, message.from?.id == botID,
              let control = store.state.replyControls["\(message.chat.id):\(message.message_id)"],
              now >= control.createdAt, now - control.createdAt < ReplyControl.lifetime else {
            await answer(callback, language.text("This preview can no longer be removed with this button.", "Cet aperçu ne peut plus être retiré avec ce bouton."), alert: true)
            return
        }
        guard callback.from.id == control.posterID else {
            await answer(callback, language.text("Only the person who posted the original link can remove this preview.", "Seule la personne qui a publié le lien d’origine peut retirer cet aperçu."), alert: true)
            return
        }
        do {
            let deleted = try await api.call("deleteMessage", ["chat_id": message.chat.id, "message_id": message.message_id])
            guard deleted as? Bool == true else { throw BotError.invalidResponse }
            do { try store.removeReplyControl(chatID: message.chat.id, messageID: message.message_id) }
            catch { print("Preview removed; control cleanup will finish later.") }
            await answer(callback, nil)
        } catch {
            await answer(callback, language.text("Could not remove the preview. Please try again.", "Impossible de retirer l’aperçu. Réessayez."), alert: true)
        }
    }

    private func deleteReplacedOriginal(_ message: Message) async {
        do {
            _ = try await api.call("deleteMessage", ["chat_id": message.chat.id, "message_id": message.message_id])
        } catch {
            print("Replacement posted; original retained because deletion failed.")
        }
    }

    private func secretary(_ message: Message, now: Int) async throws {
        guard message.chat.type == "private", now - message.date <= 300,
              let sender = message.from,
              (store.state.users[String(sender.id)] ?? store.state.defaultMode) == .secretary,
              message.sender_business_bot == nil, message.has_protected_content != true,
              message.is_paid_post != true, let connectionID = message.business_connection_id else { return }
        // Fetch current rights, including after a restart or permission revocation.
        let connection = try decode(BusinessConnection.self, from: await api.call("getBusinessConnection", ["business_connection_id": connectionID]))
        guard connection.id == connectionID, connection.is_enabled,
              connection.user.id == sender.id, connection.rights?.can_reply == true else { return }
        guard let rendered = configuredRewriter(chatID: nil, userID: sender.id)
            .rewrite(message, previews: true, attribution: false) else { return }
        var parameters: [String: Any] = ["business_connection_id": connectionID,
            "chat_id": message.chat.id, "message_id": message.message_id,
            "\(message.text == nil ? "caption_entities" : "entities")": try jsonObject(rendered.entities)]
        if message.text != nil {
            parameters["text"] = rendered.text
            parameters["link_preview_options"] = ["is_disabled": false, "url": rendered.previewURL]
            _ = try await api.call("editMessageText", parameters)
        } else {
            parameters["caption"] = rendered.text
            _ = try await api.call("editMessageCaption", parameters)
        }
    }

    private func base(_ message: Message) -> [String: Any] {
        var parameters: [String: Any] = ["chat_id": message.chat.id]
        if let thread = message.message_thread_id { parameters["message_thread_id"] = thread }
        return parameters
    }
    private func privateSettingsLink(language: BotLanguage) -> [String: Any] {
        ["inline_keyboard": [[["text": language.text("⚙️ My private settings", "⚙️ Mes réglages en privé"), "url": "https://t.me/\(username)?start=settings"]]]]
    }

    private func interfaceLanguage(_ message: Message) -> BotLanguage {
        message.chat.isGroup ? store.groupLanguage(message.chat.id) : store.userLanguage(message.from?.id ?? message.chat.id)
    }

    private func languagePanel(_ userID: Int64) -> SettingsUI {
        SettingsUI.languages(selected: store.state.userLanguages[String(userID)],
                             detected: store.state.detectedLanguages[String(userID)] ?? .en)
    }

    private func refreshPrivateCommands(_ userID: Int64) async {
        do {
            try await BotProfile.configureUser(api: api, userID: userID,
                language: store.state.userLanguages[String(userID)], owner: allowedOwners.contains(userID))
        } catch {
            // Preference persistence and the in-chat menu must survive a metadata failure.
            print("Private command menu refresh failed; the saved language still applies.")
        }
    }

    private func personalPanel(userID: Int64) -> SettingsUI {
        SettingsUI.personal(mode: store.state.users[String(userID)], defaultMode: store.state.defaultMode,
                            owner: allowedOwners.contains(userID), preference: store.state.userLanguages[String(userID)],
                            language: store.userLanguage(userID))
    }

    private func configuredRewriter(chatID: Int64?, userID: Int64?) -> Rewriter {
        let personal = userID.flatMap { store.state.personalLinkSettings[String($0)] }
        let group = chatID.flatMap { store.state.chats[String($0)]?.engineSettings }
        return Rewriter(engine: Engine(rules: rewriter.engine.rules.applying(personal ?? group ?? store.state.defaultLinkSettings)))
    }

    private func cardsEnabled(chatID: Int64?, userID: Int64?) -> Bool {
        let personal = userID.flatMap { store.state.personalYouTubeCards[String($0)] }
        let group = chatID.flatMap { store.state.chats[String($0)]?.youTubeCards }
        return personal ?? group ?? store.state.defaultYouTubeCards
    }

    private func chatSettings(_ chatID: Int64) -> ChatSettings {
        if let settings = store.state.chats[String(chatID)] { return settings }
        var settings = ChatSettings()
        settings.mode = store.state.defaultMode
        return settings
    }

    private func chatPanel(_ chat: Chat) -> SettingsUI {
        SettingsUI.chat(chat, settings: chatSettings(chat.id), enabled: isEnabled(chatID: chat.id),
                        inherited: store.state.chats[String(chat.id)] == nil, username: username,
                        language: store.groupLanguage(chat.id))
    }

    private func isEnabled(chatID: Int64) -> Bool {
        store.state.groupEnabled[String(chatID)] ?? allowedChats.contains(chatID)
    }

    private func groupsPanel(language: BotLanguage) -> SettingsUI {
        SettingsUI.groups(store.state.knownGroups.values.sorted {
            if $0.chat.title == $1.chat.title { return $0.chat.id < $1.chat.id }
            return ($0.chat.title ?? "") < ($1.chat.title ?? "")
        }, enabled: isEnabled, username: username, language: language)
    }

    private func sendPanel(_ panel: SettingsUI, to chatID: Int64, messageID: Int64? = nil,
                           previousText: String? = nil, previousMarkup: InlineKeyboardMarkup? = nil) async throws {
        if messageID != nil, previousText == panel.plainText, let previousMarkup,
           previousMarkup == (try? decode(InlineKeyboardMarkup.self, from: panel.markup)) { return }
        var parameters: [String: Any] = ["chat_id": chatID, "text": panel.text,
            "parse_mode": "HTML", "reply_markup": panel.markup,
            "link_preview_options": ["is_disabled": true]]
        if let messageID {
            parameters["message_id"] = messageID
            do {
                _ = try await api.call("editMessageText", parameters)
                return
            } catch {
                // Preferences are already saved. A deleted/stale panel must never undo them.
                parameters.removeValue(forKey: "message_id")
            }
        }
        _ = try await api.call("sendMessage", parameters)
    }

    private func settingsCallback(_ callback: CallbackQuery, now: Int) async throws {
        let language = store.userLanguage(callback.from.id)
        // Callback data is client-controlled. Bind every action to a button that
        // Telegram confirms is attached to this exact bot message, before routing.
        guard let message = callback.message, message.from?.id == botID,
              let data = callback.data,
              message.reply_markup?.inline_keyboard.joined().contains(where: { $0.callback_data == data }) == true else {
            await answer(callback, language.text("This button is no longer available. Open settings again.", "Ce bouton n’est plus disponible. Ouvrez de nouveau les réglages."), alert: true)
            return
        }
        let parts = (callback.data ?? "").split(separator: ":").map(String.init)
        if parts.prefix(2) == ["fxclip", "preview"] {
            await removePreview(callback, now: TimeInterval(now))
            return
        }
        if parts.count >= 2, parts[0] == "fxclip", parts[1] == "rules" {
            try await rulesCallback(callback, parts: parts)
            return
        }
        if parts.count >= 2, parts[0] == "fxclip", parts[1] == "chat" {
            try await chatCallback(callback, parts: parts)
            return
        }
        guard let message = callback.message, message.chat.type == "private",
              message.chat.id == callback.from.id, callback.from.is_bot != true else {
            await answer(callback, language.text("Open /settings in your private chat with the bot.", "Ouvrez /settings dans votre conversation privée avec le bot."), alert: true)
            return
        }
        if parts == ["fxclip", "panel", "close"] {
            await dismissPanel(callback, message: message, language: language)
            return
        }
        if parts.count == 3, parts[0] == "fxclip", parts[1] == "language" {
            let action = parts[2]
            if action == "auto" { try store.setUserLanguage(nil, userID: callback.from.id) }
            else if let chosen = BotLanguage(rawValue: action) { try store.setUserLanguage(chosen, userID: callback.from.id) }
            else if action != "show" {
                await answer(callback, language.text("This button is no longer available. Open /settings.", "Ce bouton n’est plus disponible. Ouvrez /settings."))
                return
            }
            let updated = store.userLanguage(callback.from.id)
            await answer(callback, action == "show" ? nil : updated.text("Language saved ✓", "Langue enregistrée ✓"))
            try await sendPanel(languagePanel(callback.from.id), to: message.chat.id, messageID: message.message_id,
                                previousText: message.text, previousMarkup: message.reply_markup)
            await refreshPrivateCommands(callback.from.id)
            return
        }
        if parts.first == "fxclip", parts.count >= 2, ["groups", "group"].contains(parts[1]) {
            // Every navigation, refresh and activation is owner-only, including old panels.
            guard allowedOwners.contains(callback.from.id) else {
                await answer(callback, language.text("Only the bot owner can manage connected groups.", "La gestion des groupes est réservée au propriétaire du bot."), alert: true)
                return
            }
            try await groupCallback(callback, message: message, parts: parts)
            return
        }
        guard parts.count == 3, parts[0] == "fxclip", ["personal", "default"].contains(parts[1]) else {
            await answer(callback, language.text("This button is no longer available. Open /settings.", "Ce bouton n’est plus disponible. Ouvrez /settings."))
            return
        }
        let ownerPanel = parts[1] == "default"
        // Authenticate on every click, including callbacks from previously issued owner panels.
        guard !ownerPanel || allowedOwners.contains(callback.from.id) else {
            await answer(callback, language.text("Only the bot owner can change this setting.", "Ce réglage est réservé au propriétaire du bot."), alert: true)
            return
        }
        let action = parts[2]
        do {
            if action == "show" {
                // Navigation never changes preferences.
            } else if !ownerPanel && action == "default" {
                try store.setMode(nil, userID: callback.from.id)
            } else if let mode = Mode(rawValue: action) {
                if ownerPanel { try store.setDefault(mode) }
                else { try store.setMode(mode, userID: callback.from.id) }
            } else {
                await answer(callback, language.text("This button is no longer available. Open /settings.", "Ce bouton n’est plus disponible. Ouvrez /settings."))
                return
            }
        } catch {
            await answer(callback, language.text("Could not save the setting. Please try again.", "Le réglage n’a pas pu être enregistré. Réessayez."), alert: true)
            throw error
        }
        await answer(callback, action == "show" ? nil : language.text("Setting saved ✓", "Réglage enregistré ✓"))
        let panel = ownerPanel ? SettingsUI.defaults(mode: store.state.defaultMode, language: language) : personalPanel(userID: callback.from.id)
        // Clicking the already selected choice should not create a duplicate panel after
        // Telegram rejects an unchanged edit as "message is not modified".
        try await sendPanel(panel, to: message.chat.id, messageID: message.message_id,
                            previousText: message.text, previousMarkup: message.reply_markup)
        if !ownerPanel && action == "show" { await refreshPrivateCommands(callback.from.id) }
    }

    private func chatCallback(_ callback: CallbackQuery, parts: [String]) async throws {
        let language = store.userLanguage(callback.from.id)
        guard parts.count == 4, let chatID = Int64(parts[2]),
              let message = callback.message, message.chat.isGroup, message.chat.id == chatID,
              callback.from.is_bot != true,
              ["show", "enable", "disable", "reply", "replace", "off", "previews_on", "previews_off", "lang_en", "lang_fr", "close"].contains(parts[3]) else {
            await answer(callback, language.text("This button does not belong to this group. Open /setup.", "Ce bouton ne correspond pas à ce groupe. Ouvrez /setup."), alert: true)
            return
        }
        // Owners keep their existing authority if Telegram's member lookup is unavailable.
        // Everyone else must prove current group admin rights on every click, even old panels.
        if !allowedOwners.contains(callback.from.id) {
            let admin: Bool
            do { admin = try await isAdmin(chatID: chatID, userID: callback.from.id) }
            catch {
                await answer(callback, language.text("Could not verify your permissions. Please try again.", "Impossible de vérifier vos droits. Réessayez."), alert: true)
                return
            }
            guard admin else {
                await answer(callback, language.text("Only group admins can change this. Use “My settings” for your personal choice.", "Réservé aux administrateurs du groupe. Utilisez « Mes réglages » pour votre choix personnel."), alert: true)
                return
            }
        }
        let action = parts[3]
        if action == "close" {
            await dismissPanel(callback, message: message, language: store.groupLanguage(chatID))
            return
        }
        var settings = chatSettings(chatID)
        if action == "replace" || (action == "enable" && settings.mode == .replace) {
            let mayDelete = (try? await canDelete(in: message.chat)) == true
            guard mayDelete else {
                await answer(callback, language.text("Grant fxclip Delete messages permission before enabling replacement. Setting unchanged.", "Accordez à fxclip le droit de supprimer les messages avant d’activer le remplacement. Réglage inchangé."), alert: true)
                return
            }
        }
        if action == "lang_en" || action == "lang_fr" {
            try store.setGroupLanguage(action == "lang_fr" ? .fr : .en, chatID: chatID)
        } else if action == "enable" || action == "disable" {
            try store.setGroupEnabled(action == "enable", chatID: chatID)
        } else if let mode = Mode(rawValue: action) {
            settings.mode = mode
            try store.set(settings, chatID: chatID)
        } else if action == "previews_on" || action == "previews_off" {
            settings.previews = action == "previews_on"
            try store.set(settings, chatID: chatID)
        }
        await answer(callback, action == "show" ? nil : language.text("Setting saved ✓", "Réglage enregistré ✓"))
        try await sendPanel(chatPanel(message.chat), to: chatID, messageID: message.message_id,
                            previousText: message.text, previousMarkup: message.reply_markup)
    }

    private func dismissPanel(_ callback: CallbackQuery, message: Message, language: BotLanguage) async {
        guard message.from?.id == botID else {
            await answer(callback, language.text("This panel cannot be closed.", "Ce panneau ne peut pas être fermé."), alert: true)
            return
        }
        let target: [String: Any] = ["chat_id": message.chat.id, "message_id": message.message_id]
        do {
            _ = try await api.call("deleteMessage", target)
        } catch {
            // Old messages may no longer be deletable. Collapse the panel in place.
            var parameters = target
            parameters["text"] = message.chat.isGroup
                ? language.text("Settings closed. Use /setup to reopen.", "Réglages fermés. /setup pour les rouvrir.")
                : language.text("Settings closed. Use /settings to reopen.", "Réglages fermés. /settings pour les rouvrir.")
            parameters["reply_markup"] = ["inline_keyboard": []] as [String: Any]
            do { _ = try await api.call("editMessageText", parameters) }
            catch {
                await answer(callback, language.text("Could not close this panel. Please try again.", "Impossible de fermer ce panneau. Réessayez."), alert: true)
                return
            }
        }
        await answer(callback, nil)
    }

    private func groupCallback(_ callback: CallbackQuery, message: Message, parts: [String]) async throws {
        let language = store.userLanguage(callback.from.id)
        if parts == ["fxclip", "groups", "show"] {
            await answer(callback, nil)
            try await sendPanel(groupsPanel(language: language), to: message.chat.id, messageID: message.message_id,
                                previousText: message.text, previousMarkup: message.reply_markup)
            return
        }
        guard parts.count == 4, parts[1] == "group", let chatID = Int64(parts[2]),
              ["show", "refresh", "on", "off"].contains(parts[3]),
              let group = store.state.knownGroups[String(chatID)] else {
            await answer(callback, language.text("Group unavailable. Open /groups.", "Groupe indisponible. Ouvrez /groups."), alert: true)
            return
        }
        let action = parts[3]
        // Disabling must remain possible even when Telegram cannot report current rights.
        if action == "off" { try store.setGroupEnabled(false, chatID: chatID) }
        let current: ChatMember
        do {
            current = try await member(chatID: chatID, userID: botID)
        } catch {
            await answer(callback, language.text("Could not verify the bot’s permissions. Please try again.", "Impossible de vérifier les droits du bot. Réessayez."), alert: true)
            try await sendPanel(SettingsUI.group(group, enabled: isEnabled(chatID: chatID), rights: nil, language: language),
                                to: message.chat.id, messageID: message.message_id,
                                previousText: message.text, previousMarkup: message.reply_markup)
            return
        }
        try store.discover(group.chat, member: current)
        if current.isAbsent {
            await answer(callback, language.text("The bot is no longer in this group. Cleaning is disabled.", "Le bot ne fait plus partie de ce groupe. Nettoyage désactivé."), alert: true)
            try await sendPanel(groupsPanel(language: language), to: message.chat.id, messageID: message.message_id,
                                previousText: message.text, previousMarkup: message.reply_markup)
            return
        }
        if action == "on" { try store.setGroupEnabled(true, chatID: chatID) }
        await answer(callback, ["on", "off"].contains(action) ? language.text("Setting saved ✓", "Réglage enregistré ✓") : nil)
        try await sendPanel(SettingsUI.group(group, enabled: isEnabled(chatID: chatID), rights: current, language: language),
                            to: message.chat.id, messageID: message.message_id,
                            previousText: message.text, previousMarkup: message.reply_markup)
    }

    private enum RuleScope {
        case personal(Int64), chat(Int64), defaults
        var key: String {
            switch self {
            case .personal: return "p"
            case .chat(let id): return "c:\(id)"
            case .defaults: return "d"
            }
        }
    }

    private func ruleOverride(_ scope: RuleScope) -> UserSettings? {
        switch scope {
        case .personal(let id): return store.state.personalLinkSettings[String(id)]
        case .chat(let id): return store.state.chats[String(id)]?.engineSettings
        case .defaults: return store.state.defaultLinkSettings
        }
    }

    private func ruleCardsOverride(_ scope: RuleScope) -> Bool? {
        switch scope {
        case .personal(let id): return store.state.personalYouTubeCards[String(id)]
        case .chat(let id): return store.state.chats[String(id)]?.youTubeCards
        case .defaults: return store.state.defaultYouTubeCards
        }
    }

    private func saveRules(_ scope: RuleScope, settings: UserSettings?, cards: Bool?) throws {
        switch scope {
        case .personal(let id): try store.setPersonalLinks(settings, youTubeCards: cards, userID: id)
        case .chat(let id):
            var chat = chatSettings(id)
            chat.engineSettings = settings
            chat.youTubeCards = cards
            try store.set(chat, chatID: id)
        case .defaults: try store.setDefaultLinks(settings ?? UserSettings(), youTubeCards: cards ?? true)
        }
    }

    private func rulesPanel(_ scope: RuleScope, section: String = "show", language: BotLanguage) -> SettingsUI {
        let settings = ruleOverride(scope)
        let previews: Bool
        if case .chat(let id) = scope { previews = chatSettings(id).previews }
        else { previews = true }
        return SettingsUI.rules(settings ?? store.state.defaultLinkSettings, builtins: rewriter.engine.rules,
                                scope: scope.key, section: section, inherited: settings == nil,
                                previewsEnabled: previews,
                                youTubeCards: ruleCardsOverride(scope) ?? store.state.defaultYouTubeCards,
                                language: language)
    }

    private func rulesCallback(_ callback: CallbackQuery, parts: [String]) async throws {
        let language = store.userLanguage(callback.from.id)
        guard parts.count >= 4, let message = callback.message, message.from?.id == botID,
              callback.from.is_bot != true else {
            await answer(callback, language.text("Open settings again.", "Ouvrez de nouveau les réglages."), alert: true)
            return
        }
        let scope: RuleScope
        let actions: [String]
        switch parts[2] {
        case "p", "d":
            guard message.chat.type == "private", message.chat.id == callback.from.id,
                  parts[2] != "d" || allowedOwners.contains(callback.from.id) else {
                await answer(callback, language.text("This setting is not available here.", "Ce réglage n’est pas accessible ici."), alert: true)
                return
            }
            scope = parts[2] == "d" ? .defaults : .personal(callback.from.id)
            actions = Array(parts.dropFirst(3))
        case "c":
            guard parts.count >= 5, let id = Int64(parts[3]), message.chat.isGroup, message.chat.id == id else {
                await answer(callback, language.text("This button belongs to another group.", "Ce bouton appartient à un autre groupe."), alert: true)
                return
            }
            if !allowedOwners.contains(callback.from.id) {
                guard (try? await isAdmin(chatID: id, userID: callback.from.id)) == true else {
                    await answer(callback, language.text("Only current group admins can change this.", "Ce réglage est réservé aux administrateurs actuels du groupe."), alert: true)
                    return
                }
            }
            scope = .chat(id)
            actions = Array(parts.dropFirst(4))
        default:
            await answer(callback, language.text("Open settings again.", "Ouvrez de nouveau les réglages."))
            return
        }
        let panelLanguage: BotLanguage
        if case .chat(let id) = scope { panelLanguage = store.groupLanguage(id) }
        else { panelLanguage = language }
        var section = actions.first ?? "show"
        var settings = ruleOverride(scope) ?? store.state.defaultLinkSettings
        var storedSettings = ruleOverride(scope)
        var cards = ruleCardsOverride(scope)
        var changed = false
        let builtins = rewriter.engine.rules
        switch actions {
        case ["show"], ["clean"], ["previews"], ["excluded"]: break
        case ["reset"]:
            storedSettings = nil; cards = nil; changed = true; section = "show"
        default:
            if actions.count == 2, actions[0] == "provider", builtins.previews.contains(where: { $0.id == actions[1] }) {
                section = "provider:\(actions[1])"
            } else if actions.count == 2, actions[0] == "providerreset",
                      let rule = builtins.previews.first(where: { $0.id == actions[1] }) {
                var value = settings.previews[rule.id] ?? .init(enabled: settings.previewDefaultsEnabled, apps: rule.apps)
                value.targetHost = nil
                settings.previews[rule.id] = value
                storedSettings = settings; changed = true; section = "provider:\(rule.id)"
            } else if actions.count == 2, ["trackers", "youtube"].contains(actions[0]), ["on", "off"].contains(actions[1]) {
                if actions[0] == "trackers" {
                    settings.trackersEverywhere = actions[1] == "on"; storedSettings = settings
                    section = "clean"
                } else {
                    cards = actions[1] == "on"; section = "previews"
                }
                changed = true
            } else if actions.count == 3, ["on", "off"].contains(actions[2]),
                      actions[0] == "site", builtins.trackers.sites.contains(where: { $0.id == actions[1] }) {
                if actions[2] == "off" { settings.disabledSites.insert(actions[1]) }
                else { settings.disabledSites.remove(actions[1]) }
                storedSettings = settings; changed = true; section = "clean"
            } else if actions.count == 3, ["on", "off"].contains(actions[2]), actions[0] == "preview",
                      let rule = builtins.previews.first(where: { $0.id == actions[1] }) {
                var value = settings.previews[rule.id] ?? .init(enabled: settings.previewDefaultsEnabled, apps: rule.apps)
                value.enabled = actions[2] == "on"
                if value.enabled, !value.apps.contains("telegram") { value.apps.append("telegram") }
                settings.previews[rule.id] = value
                storedSettings = settings; changed = true; section = "previews"
            } else {
                await answer(callback, language.text("This button is no longer available.", "Ce bouton n’est plus disponible."))
                return
            }
        }
        if changed { try saveRules(scope, settings: storedSettings, cards: cards) }
        await answer(callback, changed ? panelLanguage.text("Setting saved ✓", "Réglage enregistré ✓") : nil)
        try await sendPanel(rulesPanel(scope, section: section, language: panelLanguage), to: message.chat.id,
                            messageID: message.message_id, previousText: message.text, previousMarkup: message.reply_markup)
    }

    private func rulesCommand(_ message: Message, command: String, words: [String], language: BotLanguage) async throws -> Bool {
        let scope: RuleScope
        let arguments: [String]
        if ["/rules", "/provider", "/exclude"].contains(command),
           message.chat.type == "private", let user = message.from, user.id == message.chat.id {
            scope = .personal(user.id)
            arguments = [String(command.dropFirst())] + words.dropFirst()
        } else if command == "/default", words.count >= 2, ["settings", "provider", "exclude"].contains(words[1]),
                  message.chat.type == "private", let user = message.from, user.id == message.chat.id {
            guard allowedOwners.contains(user.id) else {
                try await reply(language.text("Only the bot owner can change the global defaults.", "Seul le propriétaire du bot peut modifier les réglages généraux."), to: message)
                return true
            }
            scope = .defaults; arguments = Array(words.dropFirst())
        } else if command == "/fxclip", words.count >= 2, ["settings", "provider", "exclude"].contains(words[1]), message.chat.isGroup {
            guard message.sender_chat == nil, let user = message.from else {
                try await reply(language.text("Use your personal admin profile.", "Utilisez votre profil personnel d’administrateur."), to: message)
                return true
            }
            var permitted = allowedOwners.contains(user.id)
            if !permitted { permitted = (try? await isAdmin(chatID: message.chat.id, userID: user.id)) == true }
            guard permitted else {
                try await reply(language.text("Only current group admins can change this.", "Ce réglage est réservé aux administrateurs actuels du groupe."), to: message)
                return true
            }
            scope = .chat(message.chat.id); arguments = Array(words.dropFirst())
        } else { return false }
        var settings = ruleOverride(scope) ?? store.state.defaultLinkSettings
        var section = "show"
        if arguments.first == "provider" {
            guard arguments.count == 3,
                  let rule = rewriter.engine.rules.previews.first(where: { $0.id == arguments[1] }),
                  arguments[2] == "default" || Rules.canonicalPreviewHost(arguments[2]) != nil else {
                try await reply(language.text("Use a known preview ID and a domain only, for example: /provider reddit mirror.example. Use default to restore its provider.", "Utilisez un aperçu connu et un domaine seul, par exemple : /provider reddit mirror.example. Utilisez default pour rétablir le fournisseur."), to: message)
                return true
            }
            var value = settings.previews[rule.id] ?? .init(enabled: settings.previewDefaultsEnabled, apps: rule.apps)
            value.targetHost = arguments[2] == "default" ? nil : Rules.canonicalPreviewHost(arguments[2])
            settings.previews[rule.id] = value
            try saveRules(scope, settings: settings, cards: ruleCardsOverride(scope))
            section = "provider:\(rule.id)"
        } else if arguments.first == "exclude" {
            guard (arguments.count == 3 || arguments.count == 4), ["add", "remove"].contains(arguments[1]),
                  arguments.count == 3 || (arguments[1] == "add" && arguments[3] == "exact"),
                  let host = Rules.canonicalPreviewHost(arguments[2]) else {
                try await reply(language.text("Use /exclude add example.com or /exclude remove example.com. Add exact to exclude only that host. Preview choices remain separate.", "Utilisez /exclude add example.com ou /exclude remove example.com. Ajoutez exact pour exclure uniquement cet hôte. Les aperçus se règlent séparément."), to: message)
                return true
            }
            settings.neverClean.removeAll { $0.host == host }
            if arguments[1] == "add" { settings.neverClean.append(SkipHost(host: host, subdomains: arguments.count == 3)) }
            try saveRules(scope, settings: settings, cards: ruleCardsOverride(scope))
            section = "excluded"
        }
        try await sendPanel(rulesPanel(scope, section: section, language: language), to: message.chat.id)
        return true
    }

    private func answer(_ callback: CallbackQuery, _ text: String?, alert: Bool = false) async {
        var parameters: [String: Any] = ["callback_query_id": callback.id]
        if let text { parameters["text"] = text }
        if alert { parameters["show_alert"] = true }
        // An expired callback acknowledgement must not prevent saving or refreshing the panel.
        _ = try? await api.call("answerCallbackQuery", parameters)
    }

    private func reply(_ text: String, to message: Message, markup: [String: Any]? = nil) async throws {
        var parameters = base(message)
        parameters["text"] = text
        parameters["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true]
        if let markup { parameters["reply_markup"] = markup }
        _ = try await api.call("sendMessage", parameters)
    }
    private func member(chatID: Int64, userID: Int64) async throws -> ChatMember {
        try decode(ChatMember.self, from: await api.call("getChatMember", ["chat_id": chatID, "user_id": userID]))
    }
    private func isAdmin(chatID: Int64, userID: Int64) async throws -> Bool {
        try await member(chatID: chatID, userID: userID).isAdmin
    }
    private func canDelete(in chat: Chat) async throws -> Bool {
        if chat.type == "private" { return true }
        return try await member(chatID: chat.id, userID: botID).canDelete(in: chat)
    }
}
