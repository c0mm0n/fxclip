import Foundation

/// Attribution is built from the live Telegram payload, never from persisted content.
enum PreviewAttribution {
    static func prefix(poster: TelegramUser, origin: ForwardOrigin?, language: BotLanguage)
        -> (text: String, entities: [Entity])? {
        guard poster.id > 0, hasLabel(poster.name) else { return nil }
        var text = language.text("Shared by ", "Partagé par ")
        var entities = [Entity(type: "text_mention", offset: text.utf16.count,
                               length: poster.name.utf16.count, user: poster)]
        text += poster.name
        if let origin {
            let label: String
            var user: TelegramUser?
            var url: String?
            switch origin.type {
            case "user":
                guard let source = origin.sender_user, source.id > 0, hasLabel(source.name) else { return nil }
                label = source.name
                user = source
            case "hidden_user":
                guard let name = origin.sender_user_name, hasLabel(name) else { return nil }
                label = name
            case "chat":
                guard let chat = origin.sender_chat, chat.id != 0,
                      ["group", "supergroup", "channel"].contains(chat.type),
                      let title = chat.title, hasLabel(title) else { return nil }
                label = title
            case "channel":
                guard let chat = origin.chat, chat.id != 0, chat.type == "channel",
                      let title = chat.title, hasLabel(title),
                      let messageID = origin.message_id, messageID > 0 else { return nil }
                label = title
                if let username = chat.username, validUsername(username) {
                    url = "https://t.me/\(username)/\(messageID)"
                }
            default:
                return nil
            }
            text += language.text("\nSource: ", "\nSource : ")
            if let user {
                entities.append(Entity(type: "text_mention", offset: text.utf16.count,
                                       length: label.utf16.count, user: user))
            } else if let url {
                entities.append(Entity(type: "text_link", offset: text.utf16.count,
                                       length: label.utf16.count, url: url))
            }
            text += label
        }
        text += "\n\n"
        // The caller also checks prefix + existing text/caption against its own limit.
        guard text.utf16.count <= 4096, entities.allSatisfy({
            $0.offset >= 0 && $0.length > 0 && $0.offset <= text.utf16.count - $0.length
        }) else { return nil }
        return (text, entities)
    }

    private static func hasLabel(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validUsername(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        guard (5...32).contains(bytes.count), let first = bytes.first, letter(first) else { return false }
        return bytes.allSatisfy { letter($0) || (48...57).contains($0) || $0 == 95 }
    }
}
