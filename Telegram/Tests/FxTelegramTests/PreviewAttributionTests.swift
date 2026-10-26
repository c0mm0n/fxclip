import Foundation
import XCTest
@testable import FxTelegram

final class PreviewAttributionTests: XCTestCase {
    private let poster = TelegramUser(id: 7, first_name: "😀 Zoé", last_name: "李")

    private func prefix(_ origin: ForwardOrigin? = nil, language: BotLanguage = .en)
        throws -> (text: String, entities: [Entity]) {
        try XCTUnwrap(PreviewAttribution.prefix(poster: poster, origin: origin, language: language))
    }

    private func label(_ entity: Entity, in text: String) -> String {
        (text as NSString).substring(with: NSRange(location: entity.offset, length: entity.length))
    }

    func testNonforwardCreditsPosterInBothLanguages() throws {
        for (language, expected) in [(BotLanguage.en, "Shared by 😀 Zoé 李\n\n"),
                                     (.fr, "Partagé par 😀 Zoé 李\n\n")] {
            let result = try prefix(language: language)
            XCTAssertEqual(result.text, expected)
            XCTAssertTrue(result.entities.isEmpty)
        }
    }

    func testForwardedUserNamesRemainPlainWithoutAccountLinks() throws {
        let source = TelegramUser(id: 8, first_name: "👩🏽‍💻 Émilie", last_name: "王")
        let result = try prefix(ForwardOrigin(type: "user", date: 1000, sender_user: source), language: .fr)
        XCTAssertEqual(result.text, "Partagé par 😀 Zoé 李\nSource : 👩🏽‍💻 Émilie 王\n\n")
        XCTAssertTrue(result.entities.isEmpty)
    }

    func testAccountUsernamesAndIDsAreNeverEmbeddedInGeneratedCredit() throws {
        let poster = TelegramUser(id: 123456, first_name: "Visible 😀", last_name: "Name", username: "hidden_poster_handle")
        let source = TelegramUser(id: 654321, first_name: "Source 👩🏽‍💻", username: "hidden_source_handle")
        let result = try XCTUnwrap(PreviewAttribution.prefix(poster: poster,
            origin: ForwardOrigin(type: "user", sender_user: source), language: .en))
        XCTAssertEqual(result.text, "Shared by Visible 😀 Name\nSource: Source 👩🏽‍💻\n\n")
        XCTAssertTrue(result.entities.isEmpty)
        let wire = String(decoding: try JSONEncoder().encode(result.entities), as: UTF8.self)
        for forbidden in ["hidden_poster_handle", "hidden_source_handle", "123456", "654321", "tg://user", "text_mention"] {
            XCTAssertFalse((result.text + wire).contains(forbidden))
        }
    }

    func testAddressLikeNamesAreLiteralCodeWithCorrectUTF16Offsets() throws {
        for language in BotLanguage.allCases {
            for name in ["😀 @visible_name", "Zoé t.me/someone", "tg://user?id=123456", "person@example.test", "+33 600 000 000"] {
                let poster = TelegramUser(id: 7, first_name: name, username: "not_the_display_name")
                let origin = ForwardOrigin(type: "user", sender_user: TelegramUser(id: 8, first_name: "Source @source_name"))
                let result = try XCTUnwrap(PreviewAttribution.prefix(poster: poster, origin: origin, language: language))
                XCTAssertEqual(result.entities.map(\.type), ["code", "code"])
                XCTAssertEqual(label(result.entities[0], in: result.text), name)
                XCTAssertEqual(label(result.entities[1], in: result.text), "Source @source_name")
                XCTAssertTrue(result.entities.allSatisfy { $0.user == nil && $0.url == nil })
                XCTAssertFalse(result.text.contains("not_the_display_name"))
            }
        }
    }

    func testHiddenAndPrivateSourceLabelsCannotBecomeAutomaticProfileLinks() throws {
        for origin in [
            ForwardOrigin(type: "hidden_user", sender_user_name: "@hidden_name"),
            ForwardOrigin(type: "chat", sender_chat: Chat(id: -100, type: "supergroup", title: "t.me/private_name"))
        ] {
            let result = try prefix(origin)
            XCTAssertEqual(result.entities.map(\.type), ["code"])
            XCTAssertTrue(result.entities.allSatisfy { $0.user == nil && $0.url == nil })
        }
    }

    func testOrdinaryNamePunctuationRemainsPlainText() throws {
        for name in ["Alice J.", "M. Dupont", "Jean+Marie", "Émilie :)", "O’Connor"] {
            let result = try XCTUnwrap(PreviewAttribution.prefix(poster: TelegramUser(id: 7, first_name: name), origin: nil, language: .fr))
            XCTAssertEqual(result.text, "Partagé par \(name)\n\n")
            XCTAssertTrue(result.entities.isEmpty)
        }
    }

    func testChannelLinksOnlyOriginalPublicPost() throws {
        let chat = Chat(id: -100, type: "channel", title: "📣 Actualités", username: "Actualites_24")
        let result = try prefix(ForwardOrigin(type: "channel", date: 1000, chat: chat,
                                            message_id: 123, author_signature: "Not the source"))
        XCTAssertEqual(result.text, "Shared by 😀 Zoé 李\nSource: 📣 Actualités\n\n")
        let link = try XCTUnwrap(result.entities.last)
        XCTAssertEqual(link.type, "text_link")
        XCTAssertEqual(link.url, "https://t.me/Actualites_24/123")
        XCTAssertEqual(label(link, in: result.text), "📣 Actualités")
        XCTAssertFalse(result.text.contains("Not the source"))
    }

    func testChatOriginUsesChatNameRatherThanAnonymousSignature() throws {
        for type in ["group", "supergroup", "channel"] {
            let chat = Chat(id: -100, type: type, title: "Le groupe 🐈", username: "SomeGroup")
            let result = try prefix(ForwardOrigin(type: "chat", date: 1000, sender_chat: chat,
                                                author_signature: "Admin"))
            XCTAssertEqual(result.text, "Shared by 😀 Zoé 李\nSource: Le groupe 🐈\n\n")
            XCTAssertTrue(result.entities.isEmpty)
            XCTAssertFalse(result.text.contains("Admin"))
        }
    }

    func testHiddenSourceRemainsPlainNameWithoutInventedUser() throws {
        let result = try prefix(ForwardOrigin(type: "hidden_user", date: 1000, sender_user_name: "Alice 🦊"))
        XCTAssertEqual(result.text, "Shared by 😀 Zoé 李\nSource: Alice 🦊\n\n")
        XCTAssertTrue(result.entities.isEmpty)
    }

    func testPrivateOrUnsafeChannelUsernameFallsBackToPlainLabel() throws {
        let invalid: [String?] = [nil, "", "tiny", "1channel", "@channel", "https://evil.example",
                                  "valid_name/123", "valid_name?x=1", "valid_name#123", "valid_name\n",
                                  "valid%2fname", "café_channel", String(repeating: "a", count: 33)]
        for username in invalid {
            let chat = Chat(id: -100, type: "channel", title: "Private source", username: username)
            let result = try prefix(ForwardOrigin(type: "channel", chat: chat, message_id: 123))
            XCTAssertEqual(result.text, "Shared by 😀 Zoé 李\nSource: Private source\n\n")
            XCTAssertTrue(result.entities.isEmpty, "Unsafe username: \(username ?? "nil")")
        }
    }

    func testUnknownAndIncompleteOriginsRejectWithoutFalseProvenance() {
        let channel = Chat(id: -100, type: "channel", title: "Source")
        let malformed = [
            ForwardOrigin(type: "future_type", sender_user_name: "Not verified"),
            ForwardOrigin(type: "user"),
            ForwardOrigin(type: "user", sender_user: TelegramUser(id: 0, first_name: "Alice")),
            ForwardOrigin(type: "user", sender_user: TelegramUser(id: 8, first_name: " \n")),
            ForwardOrigin(type: "hidden_user"),
            ForwardOrigin(type: "hidden_user", sender_user_name: " \n"),
            ForwardOrigin(type: "chat"),
            ForwardOrigin(type: "chat", sender_chat: Chat(id: 0, type: "group", title: "Source")),
            ForwardOrigin(type: "chat", sender_chat: Chat(id: -100, type: "private", title: "Source")),
            ForwardOrigin(type: "chat", sender_chat: Chat(id: -100, type: "group")),
            ForwardOrigin(type: "channel"),
            ForwardOrigin(type: "channel", chat: channel),
            ForwardOrigin(type: "channel", chat: channel, message_id: 0),
            ForwardOrigin(type: "channel", chat: channel, message_id: -1),
            ForwardOrigin(type: "channel", chat: Chat(id: 0, type: "channel", title: "Source"), message_id: 1),
            ForwardOrigin(type: "channel", chat: Chat(id: -100, type: "group", title: "Source"), message_id: 1),
            ForwardOrigin(type: "channel", chat: Chat(id: -100, type: "channel", title: ""), message_id: 1),
        ]
        for origin in malformed {
            XCTAssertNil(PreviewAttribution.prefix(poster: poster, origin: origin, language: .en), origin.type)
        }
    }

    func testInvalidPosterAndOversizedAttributionRejectWithoutTruncation() throws {
        for user in [TelegramUser(id: 0, first_name: "Alice"), TelegramUser(id: 7, first_name: " \n"),
                     TelegramUser(id: 7, first_name: String(repeating: "😀", count: 2048))] {
            XCTAssertNil(PreviewAttribution.prefix(poster: user, origin: nil, language: .en))
        }
        let name = String(repeating: "😀", count: 2048)
        XCTAssertNil(PreviewAttribution.prefix(poster: poster,
                     origin: ForwardOrigin(type: "hidden_user", sender_user_name: name), language: .en))
        let fittingName = String(repeating: "a", count: 4096 - "Shared by \n\n".utf16.count)
        let fitting = try XCTUnwrap(PreviewAttribution.prefix(poster: TelegramUser(id: 7, first_name: fittingName),
                                                            origin: nil, language: .en))
        XCTAssertEqual(fitting.text.utf16.count, 4096)
        XCTAssertTrue(fitting.entities.isEmpty)
    }

    func testExpandedModelsDecodeLegacyAndCurrentPayloads() throws {
        let decoder = JSONDecoder()
        let target = try decoder.decode(ReplyTarget.self, from: Data(#"{"message_id":42}"#.utf8))
        XCTAssertEqual(target.message_id, 42)
        XCTAssertNil(target.date)
        XCTAssertNil(target.from)
        XCTAssertNil(target.text)
        XCTAssertNil(target.forward_origin)
        XCTAssertNil(target.edit_date)
        let origin = try decoder.decode(ForwardOrigin.self, from: Data(#"{"type":"channel"}"#.utf8))
        XCTAssertNil(origin.chat)
        XCTAssertNil(origin.date)
        XCTAssertNil(PreviewAttribution.prefix(poster: poster, origin: origin, language: .en))

        let json = #"{"message_id":43,"date":1100,"edit_date":1101,"chat":{"id":-100,"type":"supergroup"},"reply_to_message":{"message_id":42,"date":1000,"edit_date":1001,"from":{"id":7,"first_name":"Alice"},"sender_chat":{"id":-101,"type":"channel","title":"Channel","username":"source_channel"},"text":"A link","forward_origin":{"type":"channel","date":900,"chat":{"id":-102,"type":"channel","title":"Original","username":"original_channel"},"message_id":12,"author_signature":"Author"},"has_protected_content":true,"is_paid_post":true,"is_automatic_forward":true}}"#
        let message = try decoder.decode(Message.self, from: Data(json.utf8))
        XCTAssertEqual(message.edit_date, 1101)
        let reply = try XCTUnwrap(message.reply_to_message)
        XCTAssertEqual(reply.date, 1000)
        XCTAssertEqual(reply.edit_date, 1001)
        XCTAssertEqual(reply.from?.id, 7)
        XCTAssertEqual(reply.sender_chat?.username, "source_channel")
        XCTAssertEqual(reply.text, "A link")
        XCTAssertEqual(reply.forward_origin?.date, 900)
        XCTAssertEqual(reply.forward_origin?.chat?.username, "original_channel")
        XCTAssertEqual(reply.forward_origin?.message_id, 12)
        XCTAssertEqual(reply.forward_origin?.author_signature, "Author")
        XCTAssertEqual(reply.has_protected_content, true)
        XCTAssertEqual(reply.is_paid_post, true)
        XCTAssertEqual(reply.is_automatic_forward, true)
    }

    func testLinkPreviewOptionsPreserveEveryFieldWhenEncoded() throws {
        let data = Data(#"{"is_disabled":false,"url":"https://example.com/path","prefer_small_media":true,"prefer_large_media":false,"show_above_text":true}"#.utf8)
        let options = try JSONDecoder().decode(LinkPreviewOptions.self, from: data)
        XCTAssertEqual(options.is_disabled, false)
        XCTAssertEqual(options.url, "https://example.com/path")
        XCTAssertEqual(options.prefer_small_media, true)
        XCTAssertEqual(options.prefer_large_media, false)
        XCTAssertEqual(options.show_above_text, true)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? NSDictionary
        XCTAssertEqual(encoded, try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let legacy = try JSONDecoder().decode(LinkPreviewOptions.self, from: Data(#"{"is_disabled":true}"#.utf8))
        XCTAssertEqual(legacy.is_disabled, true)
        XCTAssertNil(legacy.url)
        XCTAssertNil(legacy.prefer_small_media)
        XCTAssertNil(legacy.prefer_large_media)
        XCTAssertNil(legacy.show_above_text)
    }
}
