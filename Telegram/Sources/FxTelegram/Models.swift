import Foundation

public struct TelegramUser: Codable, Equatable {
    public let id: Int64
    public var is_bot: Bool?
    public var first_name: String
    public var last_name: String?
    public var username: String?
    var name: String { [first_name, last_name].compactMap { $0 }.joined(separator: " ") }
}

public struct Chat: Codable {
    public let id: Int64
    public let type: String
    public var title: String?
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
    public init() {}
}

public struct RenderedMessage {
    public let text: String
    public let entities: [Entity]
    public let previewURL: String
}
