import Foundation
import FxEngine

public struct TelegramUser: Codable, Equatable {
    public let id: Int64
    public var is_bot: Bool?
    public var first_name: String
    public var last_name: String?
    public var username: String?
    public var language_code: String?
    var name: String { [first_name, last_name].compactMap { $0 }.joined(separator: " ") }
}

public struct Chat: Codable, Equatable {
    public let id: Int64
    public let type: String
    public var title: String?
    var isGroup: Bool { type == "group" || type == "supergroup" }
}

/// Only the bot's membership and permissions; no member identity or message content.
public struct ChatMember: Codable, Equatable {
    public let status: String
    public var can_delete_messages: Bool?
    public var can_send_messages: Bool?
    public var can_send_other_messages: Bool?
    public var can_add_web_page_previews: Bool?
    public var is_member: Bool?

    var isAbsent: Bool { status == "left" || status == "kicked" || (status == "restricted" && is_member == false) }
    var isAdmin: Bool { status == "creator" || status == "administrator" }
    func canDelete(in chat: Chat) -> Bool {
        status == "creator" || (status == "administrator" && (chat.type == "group" || can_delete_messages == true))
    }
}

public struct ChatMemberUpdated: Decodable {
    public let chat: Chat
    public let old_chat_member: ChatMember?
    public let new_chat_member: ChatMember
}

public struct KnownGroup: Codable, Equatable {
    public var chat: Chat
    public var member: ChatMember?
}

public struct Entity: Codable, Equatable {
    public var type: String
    public var offset: Int
    public var length: Int
    public var url: String?
    public var user: TelegramUser?
    public var language: String?
    public var custom_emoji_id: String?
}

public struct Message: Decodable {
    public let message_id: Int64
    public let date: Int
    public let chat: Chat
    public var from: TelegramUser?
    public var sender_chat: Chat?
    public var text: String?
    public var entities: [Entity]?
    public var caption: String?
    public var caption_entities: [Entity]?
    public var message_thread_id: Int64?
    public var reply_to_message: ReplyTarget?
    public var is_automatic_forward: Bool?
    public var has_protected_content: Bool?
    public var is_paid_post: Bool?
    public var business_connection_id: String?
    public var sender_business_bot: TelegramUser?
    public var forward_origin: ForwardOrigin?
    public var reply_markup: InlineKeyboardMarkup?
    public var link_preview_options: LinkPreviewOptions?
}
public struct LinkPreviewOptions: Decodable {
    public var is_disabled: Bool?
}
public struct InlineKeyboardMarkup: Decodable, Equatable {
    public let inline_keyboard: [[InlineKeyboardButton]]
}
public struct InlineKeyboardButton: Decodable, Equatable {
    public let text: String
    public var callback_data: String?
    public var url: String?
}
public struct ForwardOrigin: Codable { public let type: String }

public struct ReplyTarget: Decodable { public let message_id: Int64 }
public struct CallbackQuery: Decodable {
    public let id: String
    public let from: TelegramUser
    public var message: Message?
    public var data: String?
}
public struct Update: Decodable {
    public let update_id: Int64
    public var message: Message?
    public var edited_message: Message?
    public var business_message: Message?
    public var edited_business_message: Message?
    public var callback_query: CallbackQuery?
    public var my_chat_member: ChatMemberUpdated?
}

public struct BusinessConnection: Decodable {
    public let id: String
    public let user: TelegramUser
    public let is_enabled: Bool
    public var rights: BusinessRights?
}
public struct BusinessRights: Decodable { public var can_reply: Bool? }

public enum Mode: String, Codable { case reply, replace, secretary, off }
public struct ChatSettings: Codable {
    public var mode: Mode = .reply
    public var previews: Bool = true
    public var engineSettings: UserSettings?
    public var youTubeCards: Bool?
    public init() {}
    enum CodingKeys: String, CodingKey { case mode, previews, engineSettings, youTubeCards }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .reply
        previews = try values.decodeIfPresent(Bool.self, forKey: .previews) ?? true
        engineSettings = try values.decodeIfPresent(UserSettings.self, forKey: .engineSettings)
        youTubeCards = try values.decodeIfPresent(Bool.self, forKey: .youTubeCards)
    }
}

public struct RenderedMessage {
    public let text: String
    public let entities: [Entity]
    public let previewURL: String
}
