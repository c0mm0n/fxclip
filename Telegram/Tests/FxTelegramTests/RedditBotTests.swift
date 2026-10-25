import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

private final class RedditBotProvider: RedditVideoProviding {
    var requestedIDs: [String] = []
    var delay: UInt64 = 0
    var error: Error?
    var video = Data([0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0])

    func fetch(postID: String) async throws -> Data {
        requestedIDs.append(postID)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let error { throw error }
        return video
    }
}

/// Strict Message receipts for edits, independent of the shared FakeAPI defaults.
private final class RedditBotAPI: BotAPI {
    var calls: [(String, [String: Any])] = []
    var outcomes: [String: Result<Any, Error>] = [:]
    var canDelete = true
    var admin = true
    var beforeCall: ((String) -> Void)?
    var finalDelay: UInt64 = 0
    var completedAt: [String: TimeInterval] = [:]
    let sentID: Int64 = 7301
    var methods: [String] { calls.map(\.0) }

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters))
        beforeCall?(method)
        if ["sendVideo", "editMessageMedia"].contains(method), finalDelay > 0 {
            try await Task.sleep(nanoseconds: finalDelay)
        }
        let result: Any
        if let outcome = outcomes[method] { result = try outcome.get() }
        else {
            switch method {
            case "sendMessage", "sendVideo", "sendPhoto": result = ["message_id": sentID]
            case "editMessageMedia", "editMessageText", "editMessageReplyMarkup":
                result = ["message_id": parameters["message_id"] ?? NSNull()]
            case "getChatMember":
                result = ["status": admin ? "administrator" : "member", "can_delete_messages": canDelete]
            default: result = true
            }
        }
        completedAt[method] = Date().timeIntervalSince1970
        return result
    }
}

final class RedditBotTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!
    private var engine: Engine!
    private var api: RedditBotAPI!
    private var provider: RedditBotProvider!
    private var bot: Bot!
    private let source = "https://www.reddit.com/r/example/comments/abc123/example/"
    private var dirty: String { source + "?utm_source=fixture" }
    private var mirrored: String { source.replacingOccurrences(of: "www.reddit.com", with: "vxreddit.com") }
    private let receiptKey = "-100:7301"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("reddit-bot-" + UUID().uuidString)
        store = try StateStore(directory: directory)
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/rules.json")
        engine = Engine(rules: try Rules.load(Data(contentsOf: shared)))
        api = RedditBotAPI()
        provider = RedditBotProvider()
        configureBot()
    }

    override func tearDownWithError() throws {
        api.beforeCall = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func configureBot(pendingDelay: UInt64 = 700_000_000, withProvider: Bool = true) {
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", pendingPreviewDelayNanoseconds: pendingDelay,
                  redditVideos: withProvider ? provider : nil)
    }

    private func mirror(_ enabled: Bool) throws {
        var links = store.state.defaultLinkSettings
        links.previews["reddit"] = .init(enabled: enabled, apps: ["telegram"])
        try store.setDefaultLinks(links, youTubeCards: store.state.defaultYouTubeCards)
    }

    private func enable(replace: Bool = false, mirror enabledMirror: Bool = false) throws {
        try store.setDefaultRedditVideos(true)
        try mirror(enabledMirror)
        if replace {
            var group = ChatSettings(); group.mode = .replace
            try store.set(group, chatID: -100)
        }
    }

    private func handle(_ text: String? = nil, extra: [String: Any] = [:],
                        now: Int? = 1100, business: Bool = false) async throws {
        var message: [String: Any] = ["message_id": 5,
            "date": now == nil ? Int(Date().timeIntervalSince1970) : 1000,
            "chat": ["id": -100, "type": "supergroup"],
            "from": ["id": 7, "first_name": "Member 😀", "is_bot": false], "text": text ?? source]
        message.merge(extra) { _, new in new }
        let update = try decode(Update.self, from: ["update_id": 1, business ? "business_message" : "message": message])
        try await bot.handle(update, now: now)
    }

    private func parameters(_ method: String) throws -> [String: Any] {
        try XCTUnwrap(api.calls.first { $0.0 == method }?.1)
    }

    private func buttons(_ parameters: [String: Any]) throws -> [InlineKeyboardButton] {
        try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(parameters["reply_markup"]))
            .inline_keyboard.flatMap { $0 }
    }

    private func snapshot() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.state)
    }

    private func callback(_ data: String, userID: Int64 = 8, chatID: Int64 = 8,
                          type: String = "private", messageID: Int64 = 42, now: Int = 1100) async throws {
        let update = try decode(Update.self, from: ["update_id": 2, "callback_query": [
            "id": "fixture-click", "from": ["id": userID, "first_name": "Member", "is_bot": false],
            "data": data, "message": ["message_id": messageID, "date": 1000,
                "chat": ["id": chatID, "type": type],
                "from": ["id": 99, "first_name": "fxclip", "is_bot": true],
                "reply_markup": ["inline_keyboard": [[["text": "Fixture", "callback_data": data]]]]],
        ]])
        try await bot.handle(update, now: now)
    }

    private func assertBare(_ parameters: [String: Any], file: StaticString = #filePath,
                            line: UInt = #line) throws {
        XCTAssertNil(parameters["caption"], file: file, line: line)
        XCTAssertNil(parameters["caption_entities"], file: file, line: line)
        let controls = try buttons(parameters)
        XCTAssertEqual(controls.map(\.callback_data), ["fxclip:preview:delete", "fxclip:preview:replace"], file: file, line: line)
        let rows = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(parameters["reply_markup"])).inline_keyboard
        XCTAssertEqual(rows.map(\.count), [2], file: file, line: line)
        XCTAssertEqual(store.state.publications[receiptKey]?.original, OriginalPublication(messageID: 5, date: 1000), file: file, line: line)
        XCTAssertNil(controls.first?.url, file: file, line: line)
    }

    func testFreshAndLegacyStateDoNotFetchOrEnableDisabledMirror() async throws {
        try mirror(false)
        try await handle()
        XCTAssertFalse(store.state.defaultRedditVideos)
        XCTAssertTrue(provider.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
        let legacy = #"{"offset":0,"chats":{},"users":{},"defaultMode":"reply","lastUpdateAt":1000,"defaultLinkSettings":{"previews":{"reddit":{"enabled":false,"apps":["telegram"]}}}}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("state.json"))
        store = try StateStore(directory: directory)
        configureBot()
        try await handle()
        XCTAssertFalse(store.state.defaultRedditVideos)
        XCTAssertTrue(store.state.personalRedditVideos.isEmpty)
        XCTAssertEqual(store.state.defaultLinkSettings.previews["reddit"]?.enabled, false)
        XCTAssertTrue(provider.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testNativeOptInAndMirrorSwitchesRemainIndependent() async throws {
        try mirror(false)
        let links = store.state.defaultLinkSettings
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let builtins = try encoder.encode(engine.rules)
        try store.setDefaultRedditVideos(true)
        try await handle()
        XCTAssertEqual(api.methods, ["sendVideo"])
        XCTAssertEqual(store.state.defaultLinkSettings, links)
        XCTAssertEqual(try encoder.encode(engine.rules), builtins)
        try mirror(true)
        XCTAssertTrue(store.state.defaultRedditVideos)
        try store.setDefaultRedditVideos(false)
        XCTAssertEqual(store.state.defaultLinkSettings.previews["reddit"]?.enabled, true)
        api.calls = []
        try await handle()
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(try parameters("sendMessage")["text"] as? String, mirrored)
        XCTAssertEqual(provider.requestedIDs, ["abc123"])
        try mirror(false)
        XCTAssertFalse(store.state.defaultRedditVideos)
    }

    func testSecretaryEnabledWithMirrorDisabledStillRepliesWithNativeRedditVideo() async throws {
        try enable()
        try store.setSecretary(true, userID: 7)
        store = try StateStore(directory: directory)
        configureBot()
        try await handle()
        XCTAssertTrue(store.secretaryEnabled(userID: 7))
        XCTAssertEqual(store.state.defaultLinkSettings.previews["reddit"]?.enabled, false)
        XCTAssertEqual(provider.requestedIDs, ["abc123"])
        XCTAssertEqual(api.methods, ["sendVideo"])
        let video = try parameters("sendVideo")
        XCTAssertEqual((video["video"] as? VideoUpload)?.data, provider.video)
        XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        try assertBare(video)
        XCTAssertEqual(store.state.replyControls[receiptKey]?.posterID, 7)
    }

    func testLegacySecretaryConsentStillAllowsNativeRedditUsingGroupReplyChoice() async throws {
        try enable()
        var state = store.state
        state.users["7"] = .secretary
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"))
        store = try StateStore(directory: directory)
        configureBot()
        try await handle()
        XCTAssertTrue(store.secretaryEnabled(userID: 7))
        XCTAssertEqual(store.state.users["7"], .secretary)
        XCTAssertEqual(store.state.defaultLinkSettings.previews["reddit"]?.enabled, false)
        XCTAssertEqual(provider.requestedIDs, ["abc123"])
        XCTAssertEqual(api.methods, ["sendVideo"])
        try assertBare(parameters("sendVideo"))
        XCTAssertEqual(store.state.replyControls[receiptKey]?.posterID, 7)
    }

    func testSecretaryEnabledDoesNotEnableRedditOrMirrorWithoutSeparateOptIn() async throws {
        try mirror(false)
        try store.setSecretary(true, userID: 7)
        try await handle()
        XCTAssertTrue(store.secretaryEnabled(userID: 7))
        XCTAssertFalse(store.state.defaultRedditVideos)
        XCTAssertTrue(store.state.personalRedditVideos.isEmpty)
        XCTAssertEqual(store.state.defaultLinkSettings.previews["reddit"]?.enabled, false)
        XCTAssertTrue(provider.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testEnabledWithoutProviderKeepsConfiguredTextPath() async throws {
        try enable()
        configureBot(withProvider: false)
        try await handle()
        XCTAssertTrue(api.calls.isEmpty)
        try await handle(dirty)
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(try parameters("sendMessage")["text"] as? String, source)
        XCTAssertTrue(provider.requestedIDs.isEmpty)
    }

    func testCleanNativeInReplaceModeKeepsOriginalEvenWithMirrorEnabled() async throws {
        try enable(replace: true, mirror: true)
        try await handle(extra: ["message_thread_id": 123, "reply_to_message": ["message_id": 3]])
        XCTAssertEqual(provider.requestedIDs, ["abc123"])
        XCTAssertEqual(api.methods, ["sendVideo"])
        let video = try parameters("sendVideo")
        XCTAssertEqual((video["video"] as? VideoUpload)?.data, provider.video)
        XCTAssertNil(video["video"] as? String)
        XCTAssertEqual(video["chat_id"] as? Int64, -100)
        XCTAssertEqual(video["message_thread_id"] as? Int64, 123)
        XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        XCTAssertEqual(video["supports_streaming"] as? Bool, true)
        XCTAssertEqual(video["disable_notification"] as? Bool, true)
        try assertBare(video)
        XCTAssertEqual(store.state.replyControls[receiptKey]?.posterID, 7)
        XCTAssertNil(store.state.replyControls[receiptKey]?.openButton)
    }

    func testDirtyReplacementCreditsSenderAndDeletesOnlyAfterConfirmedUpload() async throws {
        try enable(replace: true)
        provider.delay = 20_000_000
        configureBot(pendingDelay: 0)
        api.beforeCall = { method in
            if method == "sendVideo" {
                XCTAssertFalse(self.api.methods.contains("deleteMessage"))
                XCTAssertTrue(self.store.state.replyControls.isEmpty)
            }
        }
        try await handle(dirty, extra: ["reply_to_message": ["message_id": 3]])
        XCTAssertEqual(api.methods, ["getChatMember", "sendVideo", "deleteMessage"])
        let video = try parameters("sendVideo")
        XCTAssertEqual((video["video"] as? VideoUpload)?.data, provider.video)
        XCTAssertEqual(video["caption"] as? String, "Posted by Member 😀")
        let entities = try decode([Entity].self, from: XCTUnwrap(video["caption_entities"]))
        let credit = try XCTUnwrap(entities.first)
        XCTAssertEqual(entities.count, 1)
        XCTAssertEqual(credit.type, "text_mention")
        XCTAssertEqual(credit.user?.id, 7)
        XCTAssertEqual(credit.offset, "Posted by ".utf16.count)
        XCTAssertEqual(credit.length, "Member 😀".utf16.count)
        XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 3)
        let markup = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(video["reply_markup"]))
        XCTAssertEqual(markup.inline_keyboard.flatMap { $0 }.map(\.callback_data), ["fxclip:preview:delete"])
        XCTAssertEqual(try parameters("deleteMessage")["message_id"] as? Int64, 5)
        XCTAssertEqual(store.state.replyControls["-100:7301"]?.posterID, 7)
        XCTAssertEqual(store.state.publications["-100:7301"]?.posterID, 7)
    }

    func testMissingDeleteRightsProducesBareReplyWithoutDeletingOriginal() async throws {
        try enable(replace: true)
        api.canDelete = false
        try await handle(dirty)
        XCTAssertEqual(api.methods, ["getChatMember", "sendVideo"])
        let video = try parameters("sendVideo")
        try assertBare(video)
        XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        XCTAssertNotNil(store.state.replyControls[receiptKey])
    }

    func testMalformedOrBooleanUploadReceiptsNeverDeleteOrCreateControls() async throws {
        try enable(replace: true)
        for json in ["{}", "null", "true", #"{"message_id":true}"#, #"{"message_id":false}"#,
                     #"{"message_id":0}"#, #"{"message_id":-1}"#, #"{"message_id":"42"}"#,
                     #"{"message_id":42.5}"#, #"{"message_id":null}"#] {
            api.outcomes["sendVideo"] = .success(try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed))
            for url in [source, dirty] {
                api.calls = []
                do { try await handle(url); XCTFail("Accepted \(json)") }
                catch BotError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(api.methods, url == dirty ? ["getChatMember", "sendVideo"] : ["sendVideo"])
                XCTAssertTrue(store.state.replyControls.isEmpty)
            }
        }
    }

    func testPositiveLargeNumericReceiptIsUsedForRemoval() async throws {
        try enable()
        api.outcomes["sendVideo"] = .success(try JSONSerialization.jsonObject(with: Data(#"{"message_id":1234567890123}"#.utf8)))
        try await handle()
        XCTAssertNil(store.state.replyControls[receiptKey])
        XCTAssertEqual(store.state.replyControls["-100:1234567890123"]?.posterID, 7)
    }

    func testModeGroupAndMasterPreviewGatesNeverFetch() async throws {
        try enable()
        for secretary in [false, true] {
            try store.setSecretary(secretary, userID: 7)
            try store.setMode(.off, userID: 7)
            try await handle(dirty)
        }
        try store.setMode(nil, userID: 7)
        try store.setGroupEnabled(false, chatID: -100)
        try await handle(dirty)
        try store.setGroupEnabled(true, chatID: -100)
        var group = ChatSettings(); group.previews = false
        try store.set(group, chatID: -100)
        try await handle()
        XCTAssertTrue(provider.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
        try await handle(dirty)
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(try parameters("sendMessage")["text"] as? String, source)
        XCTAssertTrue(provider.requestedIDs.isEmpty)
    }

    func testDirectRequestFetchesNativeRedditWithPersonalOptIn() async throws {
        try enable()
        try store.setPersonalRedditVideos(true, userID: 7)
        try store.setMode(.reply, userID: 7)
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100, 7], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", pendingPreviewDelayNanoseconds: 0,
                  redditVideos: provider)

        try await handle(extra: ["chat": ["id": 7, "type": "private"]])

        XCTAssertTrue(store.state.defaultRedditVideos)
        XCTAssertEqual(store.state.personalRedditVideos["7"], true)
        XCTAssertEqual(store.state.users["7"], .reply)
        XCTAssertEqual(provider.requestedIDs, ["abc123"])
        XCTAssertTrue(api.methods.contains("sendVideo"))
        XCTAssertFalse(api.methods.contains("getChatMember"))
        XCTAssertFalse(api.methods.contains("deleteMessage"))
    }

    func testProtectedPaidOldBotAndUnapprovedGroupsNeverFetch() async throws {
        try enable()
        for extra: [String: Any] in [["has_protected_content": true], ["is_paid_post": true],
            ["is_automatic_forward": true], ["date": 0],
            ["from": ["id": 99, "first_name": "Bot", "is_bot": true]],
            ["chat": ["id": -200, "type": "supergroup"]]] {
            try await handle(dirty, extra: extra)
        }
        XCTAssertTrue(provider.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testForwardsAnonymousMediaAndHiddenPreviewsSkipNativePath() async throws {
        try enable(replace: true)
        for extra: [String: Any] in [["forward_origin": ["type": "user"]],
            ["forward_origin": ["type": "hidden_user"]],
            ["sender_chat": ["id": -100, "type": "supergroup"]],
            ["text": NSNull(), "caption": dirty], ["link_preview_options": ["is_disabled": true]]] {
            api.calls = []
            try await handle(dirty, extra: extra)
            XCTAssertFalse(api.methods.contains("sendVideo"))
            if extra["link_preview_options"] == nil {
                XCTAssertEqual(api.methods, ["sendMessage"])
                XCTAssertEqual((try parameters("sendMessage")["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
            }
        }
        XCTAssertTrue(provider.requestedIDs.isEmpty)
    }

    func testOnlyOnePlainURLQualifiesWhileURLAutoEntitiesAreAccepted() async throws {
        try enable()
        for type in ["code", "pre", "spoiler", "text_link", "bold", "italic"] {
            try await handle(extra: ["entities": [["type": type, "offset": 0, "length": source.utf16.count, "url": source]]])
        }
        for text in ["Watch " + source, source + " " + source, "https://example.com " + source] {
            try await handle(text)
        }
        XCTAssertTrue(provider.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
        try await handle(extra: ["entities": [["type": "url", "offset": 0, "length": source.utf16.count]]])
        XCTAssertEqual(provider.requestedIDs, ["abc123"])
        XCTAssertEqual(api.methods, ["sendVideo"])
    }

    func testExactRedditAndVxRoutesPassOnlyPostIDToProvider() async throws {
        try enable()
        for url in [source, "https://old.reddit.com/comments/abc123", "https://new.reddit.com/comments/abc123/",
                    "https://m.reddit.com/r/example/comments/abc123/example/", "https://vxreddit.com/abc123",
                    "https://www.vxreddit.com/r/example/comments/abc123/example/"] {
            api.calls = []
            try await handle(url)
            XCTAssertEqual(provider.requestedIDs.last, "abc123", url)
            XCTAssertEqual(api.methods, ["sendVideo"], url)
        }
        XCTAssertEqual(provider.requestedIDs, Array(repeating: "abc123", count: 6))
    }

    func testMalformedHostsIDsAndUnsupportedRoutesNeverFetch() async throws {
        try enable()
        for url in ["https://reddit.com.evil.example/comments/abc123", "https://user@reddit.com/comments/abc123",
                    "https://reddit.com:8443/comments/abc123", "https://redd.it/abc123",
                    "https://v.redd.it/abc123", "https://reddit.com/r/example/s/abc123",
                    "https://reddit.com/comments/ABC123", "https://reddit.com/comments/%61bc123",
                    "https://reddit.com/comments/-abc123", "https://reddit.com/comments/１２３",
                    "https://reddit.com/r/example/comments/abc123/example/comment1",
                    "https://vxreddit.com/abc123/extra"] {
            try await handle(url)
            XCTAssertTrue(provider.requestedIDs.isEmpty, url)
            XCTAssertFalse(api.methods.contains("sendVideo"), url)
        }
    }

    func testPersonalGroupAndDefaultInheritanceDoesNotChangeModeOrMirror() async throws {
        try mirror(false)
        var group = ChatSettings(); group.redditVideos = true; group.mode = .replace
        try store.set(group, chatID: -100)
        try await handle()
        try store.setPersonalRedditVideos(false, userID: 7)
        api.calls = []
        try await handle()
        XCTAssertTrue(api.calls.isEmpty)
        group.redditVideos = false
        try store.set(group, chatID: -100)
        try store.setPersonalRedditVideos(true, userID: 7)
        try await handle()
        try store.setPersonalRedditVideos(nil, userID: 7)
        api.calls = []
        try await handle()
        XCTAssertTrue(api.calls.isEmpty)
        group.redditVideos = nil
        try store.set(group, chatID: -100)
        try store.setDefaultRedditVideos(true)
        try await handle()
        XCTAssertEqual(provider.requestedIDs.count, 3)
        XCTAssertEqual(store.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(store.state.defaultLinkSettings.previews["reddit"]?.enabled, false)
        XCTAssertTrue(store.state.personalLinkSettings.isEmpty)
    }

    func testFastProviderSkipsPendingButSlowReplyEditsSameIDWithNestedBytes() async throws {
        try enable()
        try await handle()
        XCTAssertEqual(api.methods, ["sendVideo"])
        try store.removeReplyControl(key: receiptKey)
        api.calls = []
        provider.delay = 20_000_000
        configureBot(pendingDelay: 0)
        api.beforeCall = { method in
            if method == "editMessageMedia" {
                XCTAssertTrue(self.store.state.replyControls.isEmpty)
            }
        }
        try await handle(extra: ["message_thread_id": 123])
        XCTAssertEqual(api.methods, ["sendMessage", "editMessageMedia"])
        let pending = try parameters("sendMessage")
        XCTAssertEqual(pending["text"] as? String, "Preparing preview…")
        XCTAssertEqual(pending["message_thread_id"] as? Int64, 123)
        XCTAssertEqual((pending["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        XCTAssertNil(pending["reply_markup"])
        let edit = try parameters("editMessageMedia")
        XCTAssertEqual(edit["message_id"] as? Int64, api.sentID)
        XCTAssertEqual(edit["chat_id"] as? Int64, -100)
        XCTAssertNil(edit["reply_parameters"])
        XCTAssertNil(edit["message_thread_id"])
        XCTAssertNil(edit["video"])
        let media = try XCTUnwrap(edit["media"] as? [String: Any])
        XCTAssertEqual(media["type"] as? String, "video")
        XCTAssertEqual((media["media"] as? VideoUpload)?.data, provider.video)
        XCTAssertNil(media["caption"])
        XCTAssertEqual(media["supports_streaming"] as? Bool, true)
        try assertBare(edit)
    }

    func testOversizeReplacementKeepsSourceAndSendsRedditNoticeWithOpenAndRemoval() async throws {
        try enable(replace: true)
        provider.delay = 20_000_000; provider.error = RedditVideoError.videoTooLarge
        configureBot(pendingDelay: 0)
        try await handle(dirty)
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage"])
        let notice = try parameters("sendMessage")
        let text = try XCTUnwrap(notice["text"] as? String)
        XCTAssertTrue(text.hasPrefix("Reddit\n"))
        XCTAssertTrue(text.contains("20 MiB"))
        XCTAssertTrue(text.hasSuffix(source))
        XCTAssertFalse(text.contains("Facebook"))
        XCTAssertFalse(text.contains("Posted by"))
        XCTAssertEqual((notice["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        let controls = try buttons(notice)
        XCTAssertEqual(controls.map(\.text), ["▶ Open Reddit", "🗑 Remove preview"])
        XCTAssertEqual(controls.first?.url, source)
        XCTAssertEqual(controls.last?.callback_data, "fxclip:preview:delete")
        XCTAssertEqual(store.state.replyControls[receiptKey]?.openButton, controls.first)
        XCTAssertEqual(store.state.replyControls[receiptKey]?.posterID, 7)
    }

    func testSlowOversizeReplyEditsPendingNoticeAndExpiryKeepsOpenURL() async throws {
        try enable()
        try store.setGroupLanguage(.fr, chatID: -100)
        provider.delay = 20_000_000; provider.error = RedditVideoError.videoTooLarge
        configureBot(pendingDelay: 0)
        try await handle()
        XCTAssertEqual(api.methods, ["sendMessage", "editMessageText"])
        XCTAssertEqual(try parameters("sendMessage")["text"] as? String, "Préparation de l’aperçu…")
        let edit = try parameters("editMessageText")
        XCTAssertEqual(edit["message_id"] as? Int64, api.sentID)
        XCTAssertTrue((edit["text"] as? String ?? "").contains("20 Mio"))
        XCTAssertEqual(try buttons(edit).first?.text, "▶ Ouvrir Reddit")
        api.calls = []
        try await bot.expireReplyControls(now: 1400)
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        let controls = try buttons(parameters("editMessageReplyMarkup"))
        XCTAssertEqual(controls.count, 1)
        XCTAssertEqual(controls.first?.url, source)
        XCTAssertNil(controls.first?.callback_data)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testFetchFailuresUseOnlyConfiguredMirrorOrTrackerCleaningFallback() async throws {
        try enable()
        for error in [RedditVideoError.invalidResponse as Error, URLError(.timedOut)] {
            provider.error = error
            api.calls = []
            try await handle()
            XCTAssertTrue(api.calls.isEmpty)
            try await handle(dirty)
            XCTAssertEqual(api.methods, ["sendMessage"])
            XCTAssertEqual(try parameters("sendMessage")["text"] as? String, source)
            try mirror(true)
            api.calls = []
            try await handle()
            XCTAssertEqual(api.methods, ["sendMessage"])
            XCTAssertEqual(try parameters("sendMessage")["text"] as? String, mirrored)
            try mirror(false)
        }
    }

    func testSlowFailureDiscardsUnusedPendingOrEditsConfiguredFallback() async throws {
        try enable()
        provider.delay = 20_000_000; provider.error = RedditVideoError.invalidResponse
        configureBot(pendingDelay: 0)
        try await handle()
        XCTAssertEqual(api.methods, ["sendMessage", "deleteMessage"])
        XCTAssertEqual(try parameters("deleteMessage")["message_id"] as? Int64, api.sentID)
        XCTAssertTrue(store.state.replyControls.isEmpty)
        try mirror(true)
        api.calls = []
        try await handle()
        XCTAssertEqual(api.methods, ["sendMessage", "editMessageText"])
        XCTAssertEqual(try parameters("editMessageText")["text"] as? String, mirrored)
        XCTAssertEqual(try parameters("editMessageText")["message_id"] as? Int64, api.sentID)
        XCTAssertNotNil(store.state.replyControls[receiptKey])
    }

    func testAmbiguousUploadNeverFallsBackResendsOrDeletes() async throws {
        try enable(replace: true, mirror: true)
        for error in [URLError(.timedOut) as Error, BotError.telegram(500), BotError.invalidResponse] {
            api.calls = []; api.outcomes["sendVideo"] = .failure(error)
            do { try await handle(dirty); XCTFail("Expected ambiguous send failure") } catch {}
            XCTAssertEqual(api.methods, ["getChatMember", "sendVideo"])
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testAmbiguousAndMismatchedPendingEditReceiptsNeverFallbackOrResend() async throws {
        try enable(mirror: true)
        provider.delay = 20_000_000; configureBot(pendingDelay: 0)
        let outcomes: [Result<Any, Error>] = [.failure(URLError(.timedOut)), .failure(BotError.telegram(500)),
            .success(true), .success(["message_id": true]), .success(["message_id": Int64(0)]),
            .success(["message_id": Int64(7302)])]
        for outcome in outcomes {
            api.calls = []; api.outcomes["editMessageMedia"] = outcome
            do { try await handle(); XCTFail("Expected unconfirmed edit") } catch {}
            XCTAssertEqual(api.methods, ["sendMessage", "editMessageMedia"])
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testNativeReceiptsAreSourceFreeAndClockStartsAfterFinalConfirmation() async throws {
        try enable()
        provider.delay = 20_000_000; api.finalDelay = 20_000_000
        configureBot(pendingDelay: 0)
        api.beforeCall = { method in
            if ["sendMessage", "editMessageMedia"].contains(method) {
                XCTAssertTrue(self.store.state.replyControls.isEmpty)
            }
        }
        try await handle(dirty, now: nil)
        let receipt = try XCTUnwrap(store.state.replyControls[receiptKey])
        XCTAssertGreaterThanOrEqual(receipt.createdAt, try XCTUnwrap(api.completedAt["editMessageMedia"]))
        XCTAssertGreaterThan(receipt.createdAt, try XCTUnwrap(api.completedAt["sendMessage"]))
        XCTAssertNil(receipt.openButton)
        let persisted = String(decoding: try snapshot(), as: UTF8.self)
        for hidden in [source, dirty, "abc123", "reddit.com", "video", "ftyp"] {
            XCTAssertFalse(persisted.contains(hidden), hidden)
        }
        api.calls = []
        try await bot.expireReplyControls(now: receipt.createdAt + 299.99)
        XCTAssertTrue(api.calls.isEmpty)
        try await bot.expireReplyControls(now: receipt.createdAt + 300)
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        XCTAssertTrue(try buttons(parameters("editMessageReplyMarkup")).isEmpty)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testOnlyOriginalSenderCanRemoveConfirmedNativeMessageBeforeExpiry() async throws {
        try enable()
        try await handle()
        api.calls = []
        try await callback("fxclip:preview:delete", userID: 8, chatID: -100, type: "supergroup", messageID: api.sentID)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        XCTAssertEqual(try parameters("answerCallbackQuery")["show_alert"] as? Bool, true)
        XCTAssertNotNil(store.state.replyControls[receiptKey])
        api.calls = []
        try await callback("fxclip:preview:delete", userID: 7, chatID: -100, type: "supergroup", messageID: 42)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        api.calls = []
        try await callback("fxclip:preview:delete", userID: 7, chatID: -100, type: "supergroup", messageID: api.sentID)
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertEqual(try parameters("deleteMessage")["message_id"] as? Int64, api.sentID)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testExpiredNativeRemoveCannotDeleteOriginalOrPreview() async throws {
        try enable(); try await handle()
        api.calls = []
        try await callback("fxclip:preview:delete", userID: 7, chatID: -100, type: "supergroup", messageID: api.sentID, now: 1400)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
    }

    func testNativeSettingsCallbacksPreserveLinksYouTubeFacebookAndGroupMode() async throws {
        try mirror(false)
        let links = store.state.defaultLinkSettings
        try store.setDefaultLinks(links, youTubeCards: false)
        try store.setDefaultFacebookReels(true)
        try store.setPersonalLinks(links, youTubeCards: true, userID: 8)
        try store.setPersonalFacebookReels(false, userID: 8)
        for action in ["show", "on", "off", "default"] {
            try await callback("fxclip:rules:p:reddit:\(action)")
            XCTAssertEqual(store.state.personalLinkSettings["8"], links)
            XCTAssertEqual(store.state.personalYouTubeCards["8"], true)
            XCTAssertEqual(store.state.personalFacebookReels["8"], false)
            XCTAssertEqual(store.state.personalRedditVideos["8"], action == "on" ? true : action == "off" ? false : nil)
        }
        var group = ChatSettings(); group.mode = .replace; group.previews = false
        try store.set(group, chatID: -100)
        for action in ["on", "off", "default"] {
            try await callback("fxclip:rules:c:-100:reddit:\(action)", chatID: -100, type: "supergroup")
            XCTAssertEqual(store.state.chats["-100"]?.redditVideos, action == "on" ? true : action == "off" ? false : nil)
            XCTAssertEqual(store.state.chats["-100"]?.mode, .replace)
            XCTAssertEqual(store.state.chats["-100"]?.previews, false)
            XCTAssertNil(store.state.chats["-100"]?.engineSettings)
        }
        try await callback("fxclip:rules:d:reddit:on", userID: 7, chatID: 7)
        XCTAssertTrue(store.state.defaultRedditVideos)
        try await callback("fxclip:rules:d:reddit:off", userID: 7, chatID: 7)
        XCTAssertFalse(store.state.defaultRedditVideos)
        XCTAssertEqual(store.state.defaultLinkSettings, links)
        XCTAssertFalse(store.state.defaultYouTubeCards)
        XCTAssertTrue(store.state.defaultFacebookReels)
    }

    func testResetAtAllScopesRestoresOffOrInheritanceAndKeepsGroupMode() async throws {
        try enable()
        try store.setPersonalRedditVideos(true, userID: 8)
        try await callback("fxclip:rules:p:reset")
        XCTAssertNil(store.state.personalRedditVideos["8"])
        XCTAssertTrue(store.state.defaultRedditVideos)
        var group = ChatSettings(); group.mode = .replace; group.previews = false; group.redditVideos = true
        try store.set(group, chatID: -100)
        try await callback("fxclip:rules:c:-100:reset", chatID: -100, type: "supergroup")
        XCTAssertNil(store.state.chats["-100"]?.redditVideos)
        XCTAssertEqual(store.state.chats["-100"]?.mode, .replace)
        XCTAssertFalse(try XCTUnwrap(store.state.chats["-100"]?.previews))
        try await callback("fxclip:rules:d:reset", userID: 7, chatID: 7)
        XCTAssertFalse(store.state.defaultRedditVideos)
        XCTAssertNil(try StateStore(directory: directory).state.personalRedditVideos["8"])
    }

    func testCrossScopeUnauthorizedAndMalformedNativeCallbacksDoNotMutateState() async throws {
        let before = try snapshot()
        for (data, user, chat, type) in [
            ("fxclip:rules:p:reddit:on", Int64(8), Int64(7), "private"),
            ("fxclip:rules:p:reddit:on", 8, -100, "supergroup"),
            ("fxclip:rules:d:reddit:on", 8, 8, "private"),
            ("fxclip:rules:d:reddit:on", 7, 8, "private"),
            ("fxclip:rules:c:-100:reddit:on", 8, -200, "supergroup"),
            ("fxclip:rules:c:-100:reddit:on", 7, 7, "private"),
            ("fxclip:rules:p:reddit:maybe", 8, 8, "private"),
            ("fxclip:rules:p:reddit:on:extra", 8, 8, "private")
        ] {
            api.calls = []
            try await callback(data, userID: user, chatID: chat, type: type)
            XCTAssertEqual(try snapshot(), before, data)
            XCTAssertTrue(api.methods.contains("answerCallbackQuery"), data)
            XCTAssertFalse(api.methods.contains("editMessageText"), data)
        }
        api.admin = false; api.calls = []
        try await callback("fxclip:rules:c:-100:reddit:on", chatID: -100, type: "supergroup")
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
        XCTAssertEqual(try snapshot(), before)
    }
}
