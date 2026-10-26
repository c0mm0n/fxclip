import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

private final class FacebookSourceFixture: FacebookReelProviding {
    var sourceURLs: [String] = []
    var reelIDs: [String] = []
    var error: Error?
    let author = "Example creator 😀"
    let caption = "Example public video."
    let video = Data([0, 1, 2, 3, 255])

    func fetch(reelID: String) async throws -> FacebookReel {
        reelIDs.append(reelID)
        return try result()
    }

    func fetch(sourceURL: String) async throws -> FacebookReel {
        sourceURLs.append(sourceURL)
        return try result()
    }

    private func result() throws -> FacebookReel {
        if let error { throw error }
        return FacebookReel(author: author, caption: caption, video: video)
    }
}

private final class FacebookSourceAPI: BotAPI {
    let base = FakeAPI()
    var noticeError: Error?
    var beforeSend: (() -> Void)?

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        if method == "sendMessage" || method == "sendVideo" { beforeSend?() }
        if method == "sendMessage", let noticeError {
            base.calls.append((method, parameters))
            throw noticeError
        }
        return try await base.call(method, parameters)
    }
}

final class FacebookSourceBotTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!
    private var engine: Engine!
    private var api: FacebookSourceAPI!
    private var provider: FacebookSourceFixture!
    private var bot: Bot!
    private let source = "https://www.facebook.com/share/r/Example123/"
    private var dirtySource: String { source + "?utm_source=Example123&mibextid=Example123&rdid=Example123" }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try StateStore(directory: directory)
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared")
        engine = Engine(rules: try Rules.load(Data(contentsOf: shared.appendingPathComponent("rules.json"))))
        api = FacebookSourceAPI()
        provider = FacebookSourceFixture()
        try store.setDefaultFacebookReels(true)
        try store.setGroupLanguage(.en, chatID: -100)
        rebuildBot()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func rebuildBot() {
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", facebookReels: provider)
    }

    private func handle(_ text: String? = nil, extra: [String: Any] = [:]) async throws {
        var message: [String: Any] = ["message_id": 5, "date": 1000,
            "chat": ["id": -100, "type": "supergroup"],
            "from": ["id": 7, "first_name": "Example123", "is_bot": false], "text": text ?? source]
        message.merge(extra) { _, new in new }
        let update = try decode(Update.self, from: ["update_id": 1, "message": message])
        try await bot.handle(update, now: 1100)
    }

    private func sent(_ method: String) throws -> [String: Any] {
        try XCTUnwrap(api.base.calls.first { $0.0 == method }?.1)
    }

    private func buttons(_ parameters: [String: Any]) throws -> [[InlineKeyboardButton]] {
        try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(parameters["reply_markup"])).inline_keyboard
    }

    private func replaceMode() throws {
        var settings = ChatSettings()
        settings.mode = .replace
        try store.set(settings, chatID: -100)
    }

    private func oversized() {
        provider.error = FacebookReelError.videoTooLarge(author: provider.author, caption: provider.caption)
    }

    private func assertBareVideo(_ video: [String: Any], file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        XCTAssertNil(video["caption"], file: file, line: line)
        XCTAssertNil(video["caption_entities"], file: file, line: line)
        XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5,
                       file: file, line: line)
        let rows = try buttons(video)
        XCTAssertEqual(rows.count, 1, file: file, line: line)
        XCTAssertEqual(rows.first?.count, 2, file: file, line: line)
        XCTAssertEqual(rows.first?.map(\.callback_data), ["fxclip:preview:delete", "fxclip:preview:replace"], file: file, line: line)
        XCTAssertNil(rows.first?.first?.url, file: file, line: line)
        XCTAssertEqual(store.state.publications["-100:42"]?.original, OriginalPublication(messageID: 5, date: 1000), file: file, line: line)
        let receipt = try XCTUnwrap(store.state.replyControls["-100:42"], file: file, line: line)
        XCTAssertEqual(receipt.posterID, 7, file: file, line: line)
        XCTAssertNil(receipt.openButton, file: file, line: line)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("state.json"))) as? [String: Any])
        let receipts = try XCTUnwrap(state["replyControls"] as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(receipts["-100:42"]).keys), ["posterID", "createdAt"],
                       file: file, line: line)
        let payload = try JSONSerialization.data(withJSONObject: video.filter { $0.key != "video" },
                                                options: [.withoutEscapingSlashes])
        let text = String(decoding: payload, as: UTF8.self)
        for hidden in [provider.author, provider.caption, "facebook.com", "facebed.com", "utm_source", "mibextid", "rdid"] {
            XCTAssertFalse(text.contains(hidden), hidden, file: file, line: line)
        }
    }

    private func removeNotice(userID: Int64, messageID: Int64, markup: Any) async throws {
        let update = try decode(Update.self, from: ["update_id": 2, "callback_query": [
            "id": "Example123", "from": ["id": userID, "first_name": "Example123", "is_bot": false],
            "data": "fxclip:preview:delete", "message": ["message_id": messageID, "date": 1100,
                "chat": ["id": -100, "type": "supergroup"],
                "from": ["id": 99, "first_name": "fxclip", "is_bot": true], "reply_markup": markup],
        ]])
        try await bot.handle(update, now: 1101)
    }

    func testSupportedContentRoutesFetchSourceAndUploadNativeVideo() async throws {
        let sources = [
            source,
            "https://facebook.com/share/p/Example123/",
            "https://facebook.com/share/v/Example123/",
            "https://facebook.com/share/Example123/",
            "https://facebook.com/watch/?v=Example123",
            "https://facebook.com/Example123/posts/Example456",
            "https://facebook.com/groups/Example123/permalink/Example456/",
            "https://m.facebook.com/story.php?story_fbid=Example123&id=Example456",
            "https://facebed.com/share/p/Example123/",
            "https://www.facebed.com/watch/?v=Example123",
        ]
        for input in sources {
            api.base.calls = []
            let expected = engine.clean(input).text
            let previous = provider.sourceURLs.count
            try await handle(input)
            XCTAssertEqual(Array(provider.sourceURLs.dropFirst(previous)), [expected], input)
            XCTAssertTrue(provider.reelIDs.isEmpty, "Source routes must use fetch(sourceURL:)")
            XCTAssertEqual(api.base.methods, ["sendVideo"], input)
            let video = try sent("sendVideo")
            XCTAssertEqual((video["video"] as? VideoUpload)?.data, provider.video, input)
            XCTAssertNil(video["video"] as? String, input)
            try assertBareVideo(video)
        }
    }

    func testConfiguredCleaningIsTheOnlySourceOfTrackerRemovalAndKeepsContentIDs() async throws {
        let input = "https://www.facebook.com/story.php?story_fbid=Example123&id=Example456&comment_id=Example789"
            + "&utm_source=Example123&mibextid=Example123&rdid=Example123#Example123"
        let clean = "https://www.facebook.com/story.php?story_fbid=Example123&id=Example456&comment_id=Example789#Example123"
        XCTAssertEqual(engine.clean(input).text, clean)
        try await handle(input)
        XCTAssertEqual(provider.sourceURLs, [clean])
        let video = try sent("sendVideo")
        try assertBareVideo(video)

        var settings = UserSettings()
        settings.trackersEverywhere = false
        settings.disabledSites = ["facebook"]
        try store.setPersonalLinks(settings, youTubeCards: nil, userID: 7)
        api.base.calls = []
        try await handle(input)
        XCTAssertEqual(provider.sourceURLs, [clean, input])
        try assertBareVideo(sent("sendVideo"))
    }

    func testSourceVideoDirtyReplacementKeepsOnlyPosterCreditAndDeletesAfterConfirmation() async throws {
        try replaceMode()
        api.base.sendResult = ["message_id": Int64(84)]
        api.beforeSend = { [self] in
            XCTAssertFalse(api.base.methods.contains("deleteMessage"))
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
        try await handle(dirtySource, extra: ["reply_to_message": ["message_id": 3]])
        XCTAssertEqual(provider.sourceURLs, [source])
        XCTAssertTrue(provider.reelIDs.isEmpty)
        XCTAssertEqual(api.base.methods, ["getChatMember", "sendVideo", "deleteMessage"])
        let video = try sent("sendVideo")
        XCTAssertEqual(video["caption"] as? String, "Posted by Example123")
        let entities = try decode([Entity].self, from: XCTUnwrap(video["caption_entities"]))
        XCTAssertTrue(entities.isEmpty)
        let markup = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(video["reply_markup"]))
        XCTAssertEqual(markup.inline_keyboard.flatMap { $0 }.map(\.callback_data), ["fxclip:preview:delete"])
        XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 3)
        XCTAssertEqual(api.base.calls.last?.1["message_id"] as? Int64, 5)
        XCTAssertEqual(store.state.replyControls["-100:84"]?.posterID, 7)
        XCTAssertEqual(store.state.publications["-100:84"]?.posterID, 7)
    }

    func testCleanSourceInReplaceModeRemainsBareReplyAndKeepsOriginal() async throws {
        try replaceMode()
        try await handle()
        XCTAssertEqual(provider.sourceURLs, [source])
        XCTAssertEqual(api.base.methods, ["sendVideo"])
        try assertBareVideo(sent("sendVideo"))
    }

    func testMasterPreviewGroupAndModeGatesPreventSourceFetching() async throws {
        var settings = ChatSettings()
        settings.previews = false
        try store.set(settings, chatID: -100)
        try await handle()
        settings.previews = true
        try store.set(settings, chatID: -100)
        for secretary in [false, true] {
            try store.setSecretary(secretary, userID: 7)
            try store.setMode(.off, userID: 7)
            try await handle()
        }
        try store.setMode(nil, userID: 7)
        try store.setGroupEnabled(false, chatID: -100)
        try await handle()
        XCTAssertTrue(provider.sourceURLs.isEmpty)
        XCTAssertTrue(provider.reelIDs.isEmpty)
        XCTAssertTrue(api.base.calls.isEmpty)
    }

    func testPersonalChoiceOverridesFacebookDefaultAndCanInheritAgain() async throws {
        try store.setPersonalFacebookReels(false, userID: 7)
        try await handle()
        XCTAssertTrue(provider.sourceURLs.isEmpty)
        XCTAssertTrue(api.base.calls.isEmpty)
        try store.setDefaultFacebookReels(false)
        try store.setPersonalFacebookReels(true, userID: 7)
        try await handle()
        XCTAssertEqual(provider.sourceURLs, [source])
        api.base.calls = []
        try store.setPersonalFacebookReels(nil, userID: 7)
        try await handle()
        XCTAssertEqual(provider.sourceURLs, [source])
        XCTAssertTrue(api.base.calls.isEmpty)
    }

    func testMalformedAuthoritiesUnsafePathsAndFacebedDiagnosticsNeverFetch() async throws {
        for input in [
            "https://facebook.com.evil.example/share/r/Example123",
            "https://notfacebook.com/share/r/Example123",
            "https://Example123@facebook.com/share/r/Example123",
            "https://facebook.com:8443/share/r/Example123",
            "ftp://facebook.com/share/r/Example123",
            "https://facebook.com//evil.example/Example123",
            "https://facebook.com/share/../Example123",
            "https://facebook.com/share/r/Example%2F123",
            "https://facebook.com/share/r/Example%250A123",
            "https://facebed.com/", "https://facebed.com/dump?url=Example123",
            "https://facebed.com/healthz", "https://facebed.com/assets/Example123.png",
            "https://facebed.com/update", "https://facebed.com/share/r/dump",
        ] {
            try await handle(input)
            XCTAssertTrue(provider.sourceURLs.isEmpty, input)
            XCTAssertTrue(provider.reelIDs.isEmpty, input)
            XCTAssertFalse(api.base.methods.contains("sendVideo"), input)
        }
    }

    func testFormattedProtectedForwardedAndNonSingleLinksNeverFetch() async throws {
        for type in ["code", "pre", "spoiler", "text_link", "bold"] {
            try await handle(extra: ["entities": [["type": type, "offset": 0,
                "length": source.utf16.count, "url": source]]])
        }
        for input in ["Example123 " + source, source + " " + source] { try await handle(input) }
        for extra: [String: Any] in [
            ["link_preview_options": ["is_disabled": true]], ["has_protected_content": true],
            ["is_paid_post": true], ["is_automatic_forward": true], ["date": 0],
            ["forward_origin": ["type": "hidden_user"]],
            ["sender_chat": ["id": -100, "type": "supergroup"]],
            ["from": ["id": 99, "first_name": "Example123", "is_bot": true]],
            ["text": NSNull(), "caption": source],
        ] { try await handle(extra: extra) }
        XCTAssertTrue(provider.sourceURLs.isEmpty)
        XCTAssertTrue(provider.reelIDs.isEmpty)
        XCTAssertTrue(api.base.calls.isEmpty)
    }

    func testOversizedNoticeIsLocalizedLinksToCleanSourceAndRetainsDirtyReplacement() async throws {
        oversized()
        try replaceMode()
        for language in [BotLanguage.en, .fr] {
            try store.setGroupLanguage(language, chatID: -100)
            api.base.calls = []
            try await handle(dirtySource, extra: ["message_thread_id": 123,
                                                "reply_to_message": ["message_id": 3]])
            XCTAssertEqual(provider.sourceURLs.last, source)
            XCTAssertEqual(api.base.methods.filter { $0.hasPrefix("send") }, ["sendMessage"])
            XCTAssertFalse(api.base.methods.contains("deleteMessage"))
            let notice = try sent("sendMessage")
            let text = try XCTUnwrap(notice["text"] as? String)
            XCTAssertTrue(text.hasPrefix("Facebook\n"))
            XCTAssertTrue(text.contains(provider.author))
            XCTAssertTrue(text.contains(language == .fr ? "20 Mio" : "20 MiB"))
            XCTAssertTrue(text.hasSuffix(source))
            XCTAssertFalse(text.contains("Posted by"))
            XCTAssertLessThanOrEqual(text.utf16.count, 4096)
            XCTAssertEqual(notice["message_thread_id"] as? Int64, 123)
            XCTAssertEqual((notice["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
            XCTAssertEqual(notice["disable_notification"] as? Bool, true)
            XCTAssertEqual((notice["link_preview_options"] as? [String: Any])?["is_disabled"] as? Bool, true)
            let entities = try decode([Entity].self, from: XCTUnwrap(notice["entities"]))
            let heading = try XCTUnwrap(entities.first { $0.type == "text_link" })
            XCTAssertEqual(heading.url, source)
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: heading.offset, length: heading.length)), "Facebook")
            let author = try XCTUnwrap(entities.first { $0.type == "bold" })
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: author.offset, length: author.length)), provider.author)
            let url = try XCTUnwrap(entities.first { $0.type == "url" })
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: url.offset, length: url.length)), source)
            let rows = try buttons(notice)
            let open = try XCTUnwrap(rows.first?.first)
            XCTAssertEqual(open.url, source)
            XCTAssertTrue(open.text.contains(language == .fr ? "Ouvrir Facebook" : "Open Facebook"))
            XCTAssertEqual(rows.last?.first?.callback_data, "fxclip:preview:delete")
            XCTAssertEqual(store.state.replyControls["-100:42"]?.openButton, open)
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: notice), as: UTF8.self)
            for hidden in ["fbcdn.net", "facebed.com", "utm_source", "mibextid", "rdid"] {
                XCTAssertFalse(payload.contains(hidden), hidden)
            }
        }
    }

    func testOversizedAlreadyCleanSourceStillGetsNoticeWithoutDeletePermission() async throws {
        oversized()
        try replaceMode()
        api.base.canDelete = false
        try await handle()
        XCTAssertEqual(api.base.methods, ["sendMessage"])
        XCTAssertEqual(try buttons(sent("sendMessage")).first?.first?.url, source)
        XCTAssertEqual(store.state.replyControls["-100:42"]?.posterID, 7)
    }

    func testOversizedNoticeRecordsOnlyConfirmedReceiptAndOnlySenderCanRemoveIt() async throws {
        oversized()
        api.base.sendResult = ["message_id": Int64(84)]
        api.beforeSend = { [self] in XCTAssertTrue(store.state.replyControls.isEmpty) }
        try await handle()
        api.beforeSend = nil
        XCTAssertNil(store.state.replyControls["-100:42"])
        XCTAssertEqual(store.state.replyControls["-100:84"]?.posterID, 7)
        let markup = try XCTUnwrap(sent("sendMessage")["reply_markup"])
        api.base.calls = []
        try await removeNotice(userID: 8, messageID: 84, markup: markup)
        XCTAssertEqual(api.base.methods, ["answerCallbackQuery"])
        XCTAssertEqual(api.base.calls.last?.1["show_alert"] as? Bool, true)
        XCTAssertNotNil(store.state.replyControls["-100:84"])
        api.base.calls = []
        try await removeNotice(userID: 7, messageID: 42, markup: markup)
        XCTAssertEqual(api.base.methods, ["answerCallbackQuery"])
        api.base.calls = []
        try await removeNotice(userID: 7, messageID: 84, markup: markup)
        XCTAssertEqual(api.base.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertEqual(api.base.calls.first?.1["message_id"] as? Int64, 84)
        XCTAssertNil(store.state.replyControls["-100:84"])
    }

    func testOversizedNoticeExpiryAfterRestartPreservesExactOpenButton() async throws {
        oversized()
        api.base.sendResult = ["message_id": Int64(84)]
        try await handle()
        let open = try XCTUnwrap(buttons(sent("sendMessage")).first?.first)
        store = try StateStore(directory: directory)
        rebuildBot()
        XCTAssertEqual(store.state.replyControls["-100:84"]?.openButton, open)
        api.base.calls = []
        try await bot.expireReplyControls(now: 1399)
        XCTAssertTrue(api.base.calls.isEmpty)
        try await bot.expireReplyControls(now: 1400)
        XCTAssertEqual(api.base.methods, ["editMessageReplyMarkup"])
        let edit = try sent("editMessageReplyMarkup")
        XCTAssertEqual(edit["message_id"] as? Int64, 84)
        XCTAssertEqual(try buttons(edit), [[open]])
        XCTAssertTrue(store.state.replyControls.isEmpty)
        XCTAssertTrue(try StateStore(directory: directory).state.replyControls.isEmpty)
        XCTAssertEqual(provider.sourceURLs.count, 1)
    }

    func testOversizedNoticeMalformedReceiptNeverRecordsControlsOrDeletesOriginal() async throws {
        oversized()
        try replaceMode()
        for json in [#"{}"#, #"null"#, #"true"#, #"{"message_id":null}"#, #"{"message_id":"42"}"#,
                     #"{"message_id":0}"#, #"{"message_id":-1}"#, #"{"message_id":true}"#, #"{"message_id":42.5}"#] {
            api.base.sendResult = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            api.base.calls = []
            do { try await handle(dirtySource); XCTFail("Expected invalid notice receipt: \(json)") }
            catch BotError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(api.base.methods.filter { $0.hasPrefix("send") }, ["sendMessage"])
            XCTAssertFalse(api.base.methods.contains("deleteMessage"))
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testOversizedNoticeExplicitRejectionPropagatesWithoutFallbackOrDeletion() async throws {
        oversized()
        try replaceMode()
        for code in [400, 403] {
            api.noticeError = BotError.telegram(code)
            api.base.calls = []
            do { try await handle(dirtySource); XCTFail("Expected notice rejection") }
            catch BotError.telegram(let actual) { XCTAssertEqual(actual, code) }
            catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(api.base.methods.filter { $0.hasPrefix("send") }, ["sendMessage"])
            XCTAssertFalse(api.base.methods.contains("deleteMessage"))
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testOversizedNoticeAmbiguousSendNeverRetriesRecordsOrDeletes() async throws {
        oversized()
        try replaceMode()
        for failure in [URLError(.timedOut) as Error, BotError.invalidResponse, BotError.telegram(500)] {
            api.noticeError = failure
            api.base.calls = []
            do { try await handle(dirtySource); XCTFail("Expected ambiguous notice send failure") }
            catch { XCTAssertEqual(String(describing: error), String(describing: failure)) }
            XCTAssertEqual(api.base.methods.filter { $0.hasPrefix("send") }, ["sendMessage"])
            XCTAssertFalse(api.base.methods.contains("deleteMessage"))
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testSourceVideoAmbiguousSendNeverRetriesOrDeletes() async throws {
        try replaceMode()
        for failure in [URLError(.timedOut) as Error, BotError.invalidResponse, BotError.telegram(500)] {
            api.base.videoError = failure
            api.base.calls = []
            do { try await handle(dirtySource); XCTFail("Expected ambiguous video send failure") }
            catch { XCTAssertEqual(String(describing: error), String(describing: failure)) }
            XCTAssertEqual(provider.sourceURLs.last, source)
            XCTAssertEqual(api.base.methods.filter { $0.hasPrefix("send") }, ["sendVideo"])
            XCTAssertFalse(api.base.methods.contains("deleteMessage"))
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }
}
