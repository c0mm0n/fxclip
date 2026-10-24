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
    public init(api: BotAPI, store: StateStore, engine: Engine,
                allowedChats: Set<Int64>, allowedOwners: Set<Int64> = [], botID: Int64, username: String) {
        self.api = api; self.store = store; self.rewriter = Rewriter(engine: engine)
        self.allowedChats = allowedChats; self.botID = botID; self.username = username
        self.allowedOwners = allowedOwners
    }

    public func handle(_ update: Update, now: Int = Int(Date().timeIntervalSince1970)) async throws {
        if let callback = update.callback_query {
            try await settingsCallback(callback)
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
        if command == "/chatid" {
            try await reply("Identifiant de cette conversation : \(message.chat.id)", to: message)
            return
        }
        if message.chat.type == "private", let user = message.from, message.chat.id == user.id,
           ["/start", "/help", "/settings", "/mode", "/secretary", "/default"].contains(command) {
            if command == "/default" {
                guard allowedOwners.contains(user.id) else {
                    try await reply("Seul le propriétaire du bot peut changer le réglage général. Ouvrez /settings pour choisir votre mode personnel.", to: message)
                    return
                }
                if words.count == 2, let mode = Mode(rawValue: words[1]) { try store.setDefault(mode) }
                try await sendPanel(SettingsUI.defaults(mode: store.state.defaultMode), to: message.chat.id)
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
        guard allowedChats.contains(message.chat.id) else { return }
        if command == "/start" || command == "/help" {
            try await reply("fxclip nettoie les liens et améliore leurs aperçus.\n\nOuvrez mes réglages en privé pour choisir le comportement de vos messages.\n\nAdmins : /fxclip affiche le réglage du groupe. Pour le changer : /fxclip reply, /fxclip replace, /fxclip off ou /fxclip previews on|off.\n\nLe bot lit les messages de ce groupe. Les liens nettoyés passent par Telegram et, pour certains aperçus, par un site miroir.", to: message, markup: privateSettingsLink)
            return
        }
        var settings = store.state.chats[String(message.chat.id)] ?? ChatSettings()
        if store.state.chats[String(message.chat.id)] == nil { settings.mode = store.state.defaultMode }
        if command == "/fxclip" {
            if words.count > 1 {
                // Anonymous admin identities cannot be authenticated as a particular member.
                guard message.sender_chat == nil, let user = message.from,
                      try await isAdmin(chatID: message.chat.id, userID: user.id) else {
                    try await reply("Seul un administrateur identifié du groupe peut changer ce réglage. Si vous publiez anonymement, utilisez votre profil personnel.", to: message)
                    return
                }
                if words.count == 2, let mode = Mode(rawValue: words[1]) {
                    if mode == .replace, !(try await canDelete(in: message.chat)) {
                        try await reply("Pour activer le remplacement, donnez d’abord à fxclip le droit de supprimer les messages dans les réglages administrateurs du groupe.", to: message)
                        return
                    }
                    settings.mode = mode
                } else if words.count == 3, words[1] == "previews", ["on", "off"].contains(words[2]) {
                    settings.previews = words[2] == "on"
                } else {
                    try await reply("Choisissez /fxclip reply pour répondre, /fxclip replace pour remplacer ou /fxclip off pour désactiver.\n\nAperçus améliorés : /fxclip previews on ou /fxclip previews off.\n\nLe mode Secrétaire se choisit en privé avec /settings et agit uniquement dans les conversations privées connectées.", to: message)
                    return
                }
                try store.set(settings, chatID: message.chat.id)
            }
            let source = store.state.chats[String(message.chat.id)] == nil ? "Réglage général appliqué" : "Réglage du groupe"
            try await reply("\(source) : \(SettingsUI.title(settings.mode).lowercased()).\n\n\(SettingsUI.outcome(settings.mode))\n\nAperçus améliorés : \(settings.previews ? "activés" : "désactivés").\nUn choix personnel passe avant ce réglage, même si le groupe est désactivé. Choisissez le vôtre en privé.\n\nAdmins : /fxclip reply · /fxclip replace · /fxclip off\n/fxclip previews on|off", to: message, markup: privateSettingsLink)
            return
        }
        if message.sender_chat == nil, let user = message.from,
           let personal = store.state.users[String(user.id)] { settings.mode = personal }
        guard ["group", "supergroup", "private"].contains(message.chat.type),
              settings.mode != .off, settings.mode != .secretary,
              let rendered = rewriter.rewrite(message, previews: settings.previews) else { return }
        // Media, forwards and anonymous/channel-authored posts retain their originals.
        var replace = false
        if settings.mode == .replace && message.text != nil && message.sender_chat == nil && message.forward_origin == nil {
            replace = try await canDelete(in: message.chat)
        }
        var parameters = base(message)
        parameters["text"] = rendered.text
        parameters["entities"] = try jsonObject(rendered.entities)
        parameters["link_preview_options"] = ["is_disabled": false, "url": rendered.previewURL]
        parameters["disable_notification"] = true
        if replace {
            if let parent = message.reply_to_message {
                parameters["reply_parameters"] = ["message_id": parent.message_id, "allow_sending_without_reply": true]
            }
        } else {
            parameters["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true]
        }
        // No delete until Telegram confirms an actual new message ID. Never retry an ambiguous send.
        let sent = try await api.call("sendMessage", parameters)
        guard let sent = sent as? [String: Any], confirmedMessageID(sent["message_id"]) != nil else {
            throw BotError.invalidResponse
        }
        if replace {
            do {
                _ = try await api.call("deleteMessage", ["chat_id": message.chat.id, "message_id": message.message_id])
            } catch {
                print("Replacement posted; original retained because deletion failed.")
            }
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
              connection.user.id == sender.id, connection.rights?.can_reply == true,
              let rendered = rewriter.rewrite(message, previews: true, attribution: false) else { return }
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
    private var privateSettingsLink: [String: Any] {
        ["inline_keyboard": [[["text": "⚙️ Mes réglages en privé", "url": "https://t.me/\(username)?start=settings"]]]]
    }

    private func personalPanel(userID: Int64) -> SettingsUI {
        SettingsUI.personal(mode: store.state.users[String(userID)], defaultMode: store.state.defaultMode,
                            owner: allowedOwners.contains(userID))
    }

    private func sendPanel(_ panel: SettingsUI, to chatID: Int64, messageID: Int64? = nil) async throws {
        var parameters: [String: Any] = ["chat_id": chatID, "text": panel.text,
            "parse_mode": "HTML", "reply_markup": panel.markup]
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

    private func settingsCallback(_ callback: CallbackQuery) async throws {
        guard let message = callback.message, message.chat.type == "private",
              message.chat.id == callback.from.id, callback.from.is_bot != true else {
            await answer(callback, "Ouvrez /settings dans votre conversation privée avec le bot.", alert: true)
            return
        }
        let parts = (callback.data ?? "").split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "fxclip", ["personal", "default"].contains(parts[1]) else {
            await answer(callback, "Ce bouton n’est plus disponible. Ouvrez /settings.")
            return
        }
        let ownerPanel = parts[1] == "default"
        // Authenticate on every click, including callbacks from previously issued owner panels.
        guard !ownerPanel || allowedOwners.contains(callback.from.id) else {
            await answer(callback, "Ce réglage est réservé au propriétaire du bot.", alert: true)
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
                await answer(callback, "Ce bouton n’est plus disponible. Ouvrez /settings.")
                return
            }
        } catch {
            await answer(callback, "Le réglage n’a pas pu être enregistré. Réessayez.", alert: true)
            throw error
        }
        await answer(callback, action == "show" ? nil : "Réglage enregistré ✓")
        let panel = ownerPanel ? SettingsUI.defaults(mode: store.state.defaultMode) : personalPanel(userID: callback.from.id)
        // Clicking the already selected choice should not create a duplicate panel after
        // Telegram rejects an unchanged edit as "message is not modified".
        guard message.text != panel.plainText else { return }
        try await sendPanel(panel, to: message.chat.id, messageID: message.message_id)
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
    private func member(chatID: Int64, userID: Int64) async throws -> [String: Any] {
        guard let result = try await api.call("getChatMember", ["chat_id": chatID, "user_id": userID]) as? [String: Any] else {
            throw BotError.invalidResponse
        }
        return result
    }
    private func isAdmin(chatID: Int64, userID: Int64) async throws -> Bool {
        let status = try await member(chatID: chatID, userID: userID)["status"] as? String
        return status == "creator" || status == "administrator"
    }
    private func canDelete(in chat: Chat) async throws -> Bool {
        if chat.type == "private" { return true }
        let status = try await member(chatID: chat.id, userID: botID)
        return status["status"] as? String == "creator" ||
            (status["status"] as? String == "administrator" &&
             (chat.type == "group" || status["can_delete_messages"] as? Bool == true))
    }
}
