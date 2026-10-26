import Foundation
import XCTest
@testable import FxTelegram

private struct ShareableYouTube: YouTubeMetadataProviding {
    func fetch(videoID: String) async throws -> YouTubeMetadata {
        YouTubeMetadata(title: "Example video", thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!, nativePreviewAvailable: true)
    }
}
private struct ShareableFacebook: FacebookReelProviding {
    func fetch(reelID: String) async throws -> FacebookReel {
        FacebookReel(author: "Public source", caption: "Example", video: Data([0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0]))
    }
}
private struct ShareableReddit: RedditVideoProviding {
    func fetch(postID: String) async throws -> Data {
        Data([0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0])
    }
}

extension BotTests {
    func testShareableAutomaticCreditOmitsAccountDataAcrossTextPhotoNativeCardAndVideos() async throws {
        try replaceMode()
        try store.setDefaultFacebookReels(true)
        try store.setDefaultRedditVideos(true)
        let cases: [(String, String, YouTubePreviewStyle)] = [
            ("https://x.com/example/status/1?utm_source=test", "sendMessage", .koutube),
            ("https://youtu.be/aB3_dE-fG09?si=test&t=42", "sendPhoto", .photo),
            ("https://youtu.be/aB3_dE-fG09?si=test&t=42", "sendMessage", .koutube),
            ("https://www.facebook.com/reel/123456/?utm_source=test", "sendVideo", .koutube),
            ("https://www.reddit.com/r/example/comments/abc123/example/?utm_source=test", "sendVideo", .koutube)
        ]
        for language in BotLanguage.allCases {
            try store.setGroupLanguage(language, chatID: -100)
            for name in ["Visible 😀 Name", "Visible @display_label"] {
                for (source, method, style) in cases {
                    try store.setDefaultYouTubeStyle(style)
                    bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], botID: 99, username: "example_bot",
                        youTubeMetadata: ShareableYouTube(), facebookReels: ShareableFacebook(),
                        pendingPreviewDelayNanoseconds: 5_000_000_000, redditVideos: ShareableReddit())
                    api.calls = []
                    try await handle(["text": source, "from": ["id": 7, "is_bot": false,
                        "first_name": name, "username": "private_account_handle"]])
                    let output = try XCTUnwrap(api.calls.first { $0.0 == method }?.1)
                    XCTAssertNil(output["protect_content"])
                    let content = try XCTUnwrap((output["caption"] ?? output["text"]) as? String)
                    XCTAssertTrue(content.hasPrefix(language.text("Posted by ", "Publié par ") + name))
                    XCTAssertFalse(content.contains("private_account_handle"))
                    let entities = try decode([Entity].self, from: XCTUnwrap(output["caption_entities"] ?? output["entities"]))
                    XCTAssertFalse(entities.contains { $0.user != nil || $0.type == "text_mention" })
                    if name.contains("@") {
                        let literal = try XCTUnwrap(entities.first { $0.type == "code" })
                        XCTAssertEqual((content as NSString).substring(with: NSRange(location: literal.offset, length: literal.length)), name)
                    }
                    let wire = String(decoding: try JSONEncoder().encode(entities), as: UTF8.self)
                    XCTAssertFalse(wire.contains("private_account_handle"))
                    XCTAssertFalse(wire.contains("\"user\""))
                    XCTAssertEqual(store.state.publications["-100:42"]?.posterID, 7)
                    XCTAssertEqual(store.state.replyControls["-100:42"]?.posterID, 7)
                    XCTAssertEqual(api.calls.last { $0.0 == "deleteMessage" }?.1["message_id"] as? Int64, 5)
                }
            }
        }
    }

    func testShareableCreditPreservesDeliberateOriginalMentionsAndFormatting() async throws {
        try replaceMode()
        let body = "😀 Friend https://x.com/example/status/1?utm_source=test"
        try await handle(["text": body, "from": ["id": 7, "is_bot": false,
            "first_name": "Display name", "username": "not_for_credit"], "entities": [
                ["type": "text_mention", "offset": 3, "length": 6,
                 "user": ["id": 8, "first_name": "Friend", "username": "deliberately_mentioned"]],
                ["type": "italic", "offset": 0, "length": 2]
            ]])
        let content = try XCTUnwrap(sent["text"] as? String)
        let entities = try decode([Entity].self, from: XCTUnwrap(sent["entities"]))
        let mentions = entities.filter { $0.type == "text_mention" }
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions.first?.user?.id, 8)
        XCTAssertEqual(mentions.first?.user?.username, "deliberately_mentioned")
        XCTAssertEqual(mentions.first?.offset, "Posted by Display name\n\n".utf16.count + 3)
        XCTAssertTrue(content.hasPrefix("Posted by Display name\n\n"))
        XCTAssertFalse(content.contains("not_for_credit"))
        XCTAssertNil(sent["protect_content"])
    }

    func testShareableRemovalUsesReceiptIdentityRatherThanMatchingDisplayName() async throws {
        try await handle(["from": ["id": 7, "is_bot": false, "first_name": "Same display"]])
        let issued = sent
        func callback(_ id: Int64, name: String) throws -> Update {
            try decode(Update.self, from: ["update_id": 2, "callback_query": ["id": "remove", "data": "fxclip:preview:delete",
                "from": ["id": id, "is_bot": false, "first_name": name],
                "message": ["message_id": 42, "date": 1100, "chat": ["id": -100, "type": "supergroup"],
                    "from": ["id": 99, "is_bot": true, "first_name": "Bot"], "reply_markup": issued["reply_markup"]!]]])
        }
        api.calls = []
        try await bot.handle(callback(8, name: "Same display"), now: 1101)
        XCTAssertFalse(api.methods.contains("deleteMessage"))
        XCTAssertEqual(store.state.replyControls["-100:42"]?.posterID, 7)
        api.calls = []
        try await bot.handle(callback(7, name: "Changed display"), now: 1102)
        XCTAssertEqual(api.calls.first { $0.0 == "deleteMessage" }?.1["message_id"] as? Int64, 42)
        XCTAssertNil(store.state.replyControls["-100:42"])
    }
}
