import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

private final class DirectReddit: RedditVideoProviding {
    var ids: [String] = []
    var fail = false
    func fetch(postID: String) async throws -> Data {
        ids.append(postID)
        if fail { throw URLError(.timedOut) }
        return Data([0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0])
    }
}

private final class DirectFacebook: FacebookReelProviding {
    var ids: [String] = []
    func fetch(reelID: String) async throws -> FacebookReel {
        ids.append(reelID)
        return FacebookReel(author: "Example", caption: "Example", video: Data([1]))
    }
}

extension BotTests {
    private func direct(_ text: String, extra: [String: Any] = [:]) async throws {
        var object: [String: Any] = ["message_id": 5, "date": 1000,
            "chat": ["id": 8, "type": "private"],
            "from": ["id": 8, "first_name": "Member", "is_bot": false], "text": text]
        object.merge(extra) { _, new in new }
        try await bot.handle(decode(Update.self, from: ["update_id": 1, "message": object]), now: 1100)
    }

    func testDirectLinksWorkWithoutAllowedChatsAndAlwaysKeepOriginal() async throws {
        for mode in [Mode.off, .reply, .replace, .secretary] {
            try store.setDefault(mode)
            try store.setMode(mode, userID: 8)
            bot = Bot(api: api, store: store, engine: engine, allowedChats: [], botID: 99, username: "fxclipbot")
            api.calls = []
            try await direct("https://x.com/example/status/1?utm_source=test")
            XCTAssertEqual(api.methods, ["sendMessage"])
            XCTAssertEqual(sent["text"] as? String, "https://fxtwitter.com/example/status/1")
            XCTAssertEqual((sent["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
            let markup = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(sent["reply_markup"]))
            XCTAssertEqual(markup.inline_keyboard.flatMap { $0 }.compactMap(\.callback_data), ["fxclip:preview:delete"])
            XCTAssertTrue(store.state.publications.isEmpty)
            XCTAssertNil(store.state.chats["8"])
        }
    }

    func testDirectAlreadyCleanLinksReplyButOrdinaryChatAndCommandsStaySilent() async throws {
        try await direct("https://example.com/article")
        XCTAssertEqual(sent["text"] as? String, "https://example.com/article")
        for text in ["Hello", "/unknown https://x.com/example/status/1", "/fxclip replace", "/setup"] {
            api.calls = []
            try await direct(text)
            XCTAssertTrue(api.calls.isEmpty, text)
        }
    }

    func testDirectUsesPersonalRulesThenBotDefaultsAndNeverChatSettings() async throws {
        var defaults = UserSettings()
        defaults.previews["x"] = .init(enabled: false, apps: ["telegram"])
        try store.setDefaultLinks(defaults, youTubeCards: false)
        var chat = ChatSettings(); chat.mode = .off; chat.previews = false
        chat.engineSettings = UserSettings()
        try store.set(chat, chatID: 8)
        try store.setGroupEnabled(false, chatID: 8)
        try await direct("https://x.com/example/status/1?utm_source=test")
        XCTAssertEqual(sent["text"] as? String, "https://x.com/example/status/1")
        var personal = UserSettings()
        personal.previews["x"] = .init(enabled: true, apps: ["telegram"], targetHost: "mirror.example")
        try store.setPersonalLinks(personal, youTubeCards: nil, userID: 8)
        api.calls = []
        try await direct("https://x.com/example/status/1")
        XCTAssertEqual(sent["text"] as? String, "https://mirror.example/example/status/1")
        XCTAssertEqual(store.state.chats["8"]?.mode, .off)
        XCTAssertFalse(store.state.groupEnabled["8"] ?? true)
    }

    func testDirectRejectsUnidentifiedBotBusinessAndProtectedMessages() async throws {
        let bad: [[String: Any]] = [
            ["from": NSNull()], ["from": ["id": 7, "first_name": "Other", "is_bot": false]],
            ["from": ["id": 8, "first_name": "Bot", "is_bot": true]],
            ["from": ["id": 8, "first_name": "Unknown"]],
            ["sender_chat": ["id": 8, "type": "private"]],
            ["business_connection_id": "connection"], ["has_protected_content": true],
            ["is_paid_post": true], ["date": 1],
            ["text": NSNull(), "caption": "https://x.com/example/status/1"]
        ]
        for extra in bad {
            api.calls = []
            try await direct("https://x.com/example/status/1", extra: extra)
            XCTAssertTrue(api.calls.isEmpty, "\(extra.keys)")
        }
    }

    func testDirectYouTubeHonorsPersonalOptOutAndDefaultOffMode() async throws {
        try store.setDefault(.off)
        let metadata = enableYouTubeCards()
        try await direct("https://youtu.be/dQw4w9WgXcQ")
        XCTAssertEqual(metadata.requestedIDs, ["dQw4w9WgXcQ"])
        XCTAssertEqual(api.methods, ["sendPhoto"])
        try store.setPersonalLinks(nil, youTubeCards: false, userID: 8)
        api.calls = []
        try await direct("https://youtu.be/dQw4w9WgXcQ")
        XCTAssertEqual(metadata.requestedIDs.count, 1)
        XCTAssertEqual(api.methods, ["sendMessage"])
    }

    func testDirectNativeVideosHonorIndependentOptInsAndFailureRepliesWithLink() async throws {
        let reddit = DirectReddit(), facebook = DirectFacebook()
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [], botID: 99, username: "fxclipbot",
                  facebookReels: facebook, redditVideos: reddit)
        let link = "https://www.reddit.com/r/example/comments/abc123/example/"
        try await direct(link)
        XCTAssertTrue(reddit.ids.isEmpty)
        try store.setPersonalRedditVideos(true, userID: 8)
        api.calls = []
        try await direct(link)
        XCTAssertEqual(reddit.ids, ["abc123"])
        XCTAssertEqual(api.methods, ["sendVideo"])
        reddit.fail = true
        api.calls = []
        try await direct(link)
        XCTAssertEqual(api.methods, ["sendMessage"])
        try store.setPersonalFacebookReels(true, userID: 8)
        api.calls = []
        try await direct("https://www.facebook.com/reel/123456/")
        XCTAssertEqual(facebook.ids, ["123456"])
        XCTAssertEqual(api.methods, ["sendVideo"])
        XCTAssertTrue(store.state.publications.isEmpty)
    }

    func testDirectKeepsUTF16FormattingAndHiddenLinks() async throws {
        let text = "😀 Read this"
        try await direct(text, extra: ["entities": [
            ["type": "bold", "offset": 0, "length": 2],
            ["type": "text_link", "offset": 3, "length": 9, "url": "https://example.com/article"]]])
        XCTAssertEqual(sent["text"] as? String, text)
        let entities = try decode([Entity].self, from: XCTUnwrap(sent["entities"]))
        XCTAssertEqual(entities.map(\.offset), [0, 3])
        XCTAssertEqual(entities.last?.url, "https://example.com/article")
    }

    func testDirectSettingsExplainBehaviorInBothLanguages() throws {
        for language in [BotLanguage.en, .fr] {
            let panel = SettingsUI.personal(mode: .off, defaultMode: .off, owner: false, language: language)
            XCTAssertTrue(panel.plainText.contains(language.text("Send me a link here", "Envoyez-moi un lien ici")))
            XCTAssertTrue(panel.plainText.contains(language.text("keep your message", "garde votre message")))
        }
    }
}
