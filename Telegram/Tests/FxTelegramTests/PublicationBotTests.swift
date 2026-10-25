import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

private final class PublicationAPI: BotAPI {
    var calls: [(String, [String: Any])] = []
    var outcomes: [String: Result<Any, Error>] = [:]
    var beforeCall: ((String, [String: Any]) throws -> Void)?
    var sentID: Int64 = 7301
    var methods: [String] { calls.map(\.0) }

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters))
        try beforeCall?(method, parameters)
        if let outcome = outcomes[method] { return try outcome.get() }
        switch method {
        case "sendMessage", "sendPhoto", "sendVideo": return ["message_id": sentID]
        case "editMessageMedia", "editMessageText", "editMessageReplyMarkup":
            return ["message_id": parameters["message_id"] ?? NSNull()]
        case "getChatMember": return ["status": "administrator", "can_delete_messages": true]
        default: return true
        }
    }
}

private final class PublicationYouTube: YouTubeMetadataProviding {
    func fetch(videoID: String) async throws -> YouTubeMetadata {
        YouTubeMetadata(title: "Fixture title", thumbnailURL: URL(string: "https://example.invalid/thumbnail.jpg")!)
    }
}

private final class PublicationReddit: RedditVideoProviding {
    var error: Error?

    func fetch(postID: String) async throws -> Data {
        if let error { throw error }
        return Data([0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0])
    }
}

final class PublicationBotTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!
    private var engine: Engine!
    private var api: PublicationAPI!
    private var bot: Bot!
    private let group: Int64 = -1001234567890
    private var key: String { "\(group):7301" }
    private let now = 200_000

    override func setUpWithError() throws {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/rules.json")
        engine = Engine(rules: try Rules.load(Data(contentsOf: shared)))
        try reset()
    }

    override func tearDownWithError() throws {
        api.beforeCall = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func reset() throws {
        api?.beforeCall = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("fxclip-publication-tests-" + UUID().uuidString)
        store = try StateStore(directory: directory)
        api = PublicationAPI()
        configureBot()
    }

    private func configureBot() {
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [group], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", youTubeMetadata: PublicationYouTube(),
                  pendingPreviewDelayNanoseconds: 5_000_000_000, redditVideos: PublicationReddit())
    }

    private func actor(_ id: Int64 = 8, bot: Bool = false) -> [String: Any] {
        ["id": id, "first_name": "Fixture member", "is_bot": bot]
    }

    private func message(_ text: String, userID: Int64 = 8, at: Int? = nil,
                         extra: [String: Any] = [:]) async throws {
        let timestamp = at ?? now
        var wire: [String: Any] = ["message_id": 5, "date": timestamp,
            "chat": ["id": group, "type": "supergroup", "title": "Fixture group"],
            "from": actor(userID), "text": text]
        wire.merge(extra) { _, new in new }
        try await bot.handle(decode(Update.self, from: ["update_id": 1, "message": wire]), now: timestamp)
    }

    private func command(_ text: String = "/delete", userID: Int64 = 8, replyID: Int64? = 7301,
                         at: Int? = nil, extra: [String: Any] = [:]) async throws {
        var fields = extra
        if let replyID, fields["reply_to_message"] == nil { fields["reply_to_message"] = ["message_id": replyID] }
        try await message(text, userID: userID, at: at, extra: fields)
    }

    private func privateCommand(_ text: String = "/publications", userID: Int64 = 8,
                                at: Int? = nil, chatID: Int64? = nil) async throws {
        try await message(text, userID: userID, at: at,
                          extra: ["chat": ["id": chatID ?? userID, "type": "private"]])
    }

    private func callback(_ data: String, markup: Any?, userID: Int64 = 8,
                          chatID: Int64? = nil, groupChat: Bool = false, at: Int? = nil,
                          actorIsBot: Bool = false, authorID: Int64 = 99) async throws {
        var panel: [String: Any] = ["message_id": Int64(7301), "date": now,
            "chat": ["id": chatID ?? userID, "type": groupChat ? "supergroup" : "private"],
            "from": actor(authorID, bot: authorID == 99)]
        if let markup { panel["reply_markup"] = markup }
        let update = try decode(Update.self, from: ["update_id": 2, "callback_query": [
            "id": "publication-click", "from": actor(userID, bot: actorIsBot), "data": data, "message": panel]])
        try await bot.handle(update, now: at ?? now)
    }

    private func panel() throws -> [String: Any] {
        try XCTUnwrap(api.calls.last { ["sendMessage", "editMessageText"].contains($0.0) }?.1)
    }

    private func buttons(_ fields: [String: Any]) throws -> [InlineKeyboardButton] {
        guard let markup = fields["reply_markup"] else { return [] }
        return try decode(InlineKeyboardMarkup.self, from: markup).inline_keyboard.flatMap { $0 }
    }

    private func snapshot() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.state)
    }

    private func seed(_ id: Int64 = 7301, poster: Int64 = 8, createdAt: Int? = nil,
                      chatID: Int64? = nil) throws {
        try store.recordPublication(chatID: chatID ?? group, messageID: id, posterID: poster,
                                    now: TimeInterval(createdAt ?? now - 1000))
    }

    private func assertNoPublicationDeletion(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(api.calls.contains { $0.0 == "deleteMessage" && $0.1["message_id"] as? Int64 == 7301 },
                       file: file, line: line)
        XCTAssertNotNil(store.state.publications[key], file: file, line: line)
    }

    func testPublicationReplacementTextPhotoAndVideoPersistOwnershipBeforeOriginalDeletion() async throws {
        for (method, source) in [("sendMessage", "https://x.com/a/status/1?s=2"),
                                  ("sendPhoto", "https://youtu.be/AAAAAAAAAAA?si=fixture"),
                                  ("sendVideo", "https://www.reddit.com/r/example/comments/abc123/example/?utm_source=fixture")] {
            try reset()
            var settings = ChatSettings(); settings.mode = .replace
            try store.set(settings, chatID: group)
            try store.setDefaultRedditVideos(true)
            api.beforeCall = { [unowned self] method, fields in
                if method == "deleteMessage", fields["message_id"] as? Int64 == 5 {
                    let persisted = try StateStore(directory: self.directory)
                    XCTAssertEqual(persisted.state.publications[self.key]?.posterID, 8)
                    XCTAssertEqual(persisted.state.publications[self.key]?.createdAt, TimeInterval(self.now))
                }
            }
            try await message(source)
            XCTAssertEqual(api.methods, ["getChatMember", method, "deleteMessage"])
            let sent = try XCTUnwrap(api.calls.first { $0.0 == method }?.1)
            XCTAssertTrue(try buttons(sent).contains { $0.callback_data == "fxclip:preview:delete" })
            XCTAssertEqual(try buttons(sent).last?.text, "🗑 Delete my message")
            XCTAssertEqual(store.state.replyControls[key]?.posterID, 8)
            XCTAssertEqual(store.state.publications[key]?.posterID, 8)
            api.beforeCall = nil
        }
    }

    func testPublicationReplacementButtonFrenchAndFiveMinuteOwnershipBoundary() async throws {
        var settings = ChatSettings(); settings.mode = .replace
        try store.set(settings, chatID: group)
        try store.setGroupLanguage(.fr, chatID: group)
        try await message("https://x.com/a/status/1?s=2")
        let issued = try panel()
        XCTAssertEqual(try buttons(issued).last?.text, "🗑 Supprimer mon message")
        for (user, timestamp): (Int64, Int) in [(7, now + 1), (9, now + 299), (8, now + 300)] {
            api.calls = []
            try await callback("fxclip:preview:delete", markup: issued["reply_markup"], userID: user,
                               chatID: group, groupChat: true, at: timestamp)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"])
            assertNoPublicationDeletion()
        }
        api.calls = []
        try await callback("fxclip:preview:delete", markup: issued["reply_markup"], chatID: group,
                           groupChat: true, at: now + 299)
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertNil(store.state.publications[key])
        XCTAssertNil(store.state.replyControls[key])
    }

    func testPublicationMalformedOrAmbiguousReplacementNeverOwnsOrDeletes() async throws {
        for method in ["sendMessage", "sendPhoto", "sendVideo"] {
            for outcome: Result<Any, Error> in [.success(["message_id": true]), .success(["message_id": "7301"]),
                                               .success(["message_id": 0]), .failure(URLError(.timedOut))] {
                try reset()
                var settings = ChatSettings(); settings.mode = .replace
                try store.set(settings, chatID: group)
                try store.setDefaultRedditVideos(true)
                api.outcomes[method] = outcome
                let source = method == "sendPhoto" ? "https://youtu.be/AAAAAAAAAAA?si=fixture"
                    : method == "sendVideo" ? "https://www.reddit.com/r/example/comments/abc123/example/?utm_source=fixture"
                    : "https://x.com/a/status/1?s=2"
                do { try await message(source); XCTFail("Expected unconfirmed \(method) to fail") } catch { }
                XCTAssertFalse(api.methods.contains("deleteMessage"))
                XCTAssertTrue(store.state.publications.isEmpty)
                XCTAssertTrue(store.state.replyControls.isEmpty)
            }
        }
    }

    func testPublicationFullReceiptCapacityFallsBackToReplyWithoutDeletingOrEvicting() async throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot()) as? [String: Any])
        var receipts: [String: [String: Any]] = [:]
        for id in 1...20_000 { receipts["\(group):\(id)"] = ["posterID": 9, "createdAt": now - 100] }
        json["publications"] = receipts
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("state.json"))
        store = try StateStore(directory: directory)
        configureBot()
        var settings = ChatSettings(); settings.mode = .replace
        try store.set(settings, chatID: group)
        XCTAssertFalse(store.canRecordPublication(now: TimeInterval(now)))
        api.sentID = 30_001
        try await message("https://x.com/a/status/1?s=2")
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(store.state.publications.count, 20_000)
        XCTAssertEqual(store.state.publications["\(group):1"]?.posterID, 9)
        XCTAssertNil(store.state.publications["\(group):30001"])
        XCTAssertFalse(api.methods.contains("deleteMessage"))
    }

    func testPublicationOversizedNoticeKeepsDurableReceiptWhenTemporaryControlQueueIsFull() async throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot()) as? [String: Any])
        var controls: [String: [String: Any]] = [:]
        for id in 1...4096 { controls["\(group):\(id)"] = ["posterID": 9, "createdAt": now - 100] }
        json["replyControls"] = controls
        json["publications"] = [String: [String: Any]]()
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("state.json"))
        store = try StateStore(directory: directory)
        XCTAssertTrue(store.state.publications.isEmpty)
        XCTAssertTrue(store.canRecordPublication(now: TimeInterval(now)))
        let originalControls = store.state.replyControls
        XCTAssertEqual(originalControls.count, 4096)
        try store.setDefaultRedditVideos(true)
        let reddit = PublicationReddit(); reddit.error = RedditVideoError.videoTooLarge
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [group], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", pendingPreviewDelayNanoseconds: 5_000_000_000,
                  redditVideos: reddit)

        try await message("https://www.reddit.com/r/example/comments/abc123/example/?utm_source=fixture")
        XCTAssertEqual(api.methods, ["sendMessage"])
        let notice = try panel()
        XCTAssertTrue((notice["text"] as? String)?.contains("20 MiB") == true)
        XCTAssertEqual((notice["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        let noticeButtons = try buttons(notice)
        XCTAssertEqual(noticeButtons.count, 1)
        XCTAssertEqual(noticeButtons.first?.text, "▶ Open Reddit")
        XCTAssertNotNil(noticeButtons.first?.url)
        XCTAssertFalse(noticeButtons.contains { $0.callback_data == "fxclip:preview:delete" })
        XCTAssertNil(store.state.replyControls[key])
        XCTAssertEqual(store.state.replyControls, originalControls)
        XCTAssertEqual(store.state.publications[key]?.posterID, 8)
        XCTAssertEqual(store.state.publications[key]?.createdAt, TimeInterval(now))

        store = try StateStore(directory: directory)
        configureBot()
        XCTAssertEqual(store.state.publications[key]?.posterID, 8)
        api.calls = []
        try await privateCommand()
        let listButtons = try buttons(panel())
        XCTAssertTrue(listButtons.contains { $0.callback_data == "fxclip:posts:ask:\(group):7301:0" })
        XCTAssertTrue(listButtons.contains { $0.url == "https://t.me/c/1234567890/7301" })
        api.calls = []
        try await command("/delete")
        XCTAssertEqual(api.methods, ["deleteMessage", "sendMessage"])
        XCTAssertEqual(api.calls.first?.1["chat_id"] as? Int64, group)
        XCTAssertEqual(api.calls.first?.1["message_id"] as? Int64, 7301)
        XCTAssertNil(store.state.publications[key])
        XCTAssertNil(try StateStore(directory: directory).state.publications[key])
        XCTAssertEqual(store.state.replyControls, originalControls)
    }

    func testPublicationPersistenceFailureAfterSendNeverDeletesOriginal() async throws {
        var settings = ChatSettings(); settings.mode = .replace
        try store.set(settings, chatID: group)
        api.beforeCall = { [unowned self] method, _ in
            if method == "sendMessage" {
                let path = self.directory.appendingPathComponent("state.json")
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            }
        }
        do { try await message("https://x.com/a/status/1?s=2"); XCTFail("Expected receipt persistence failure") } catch { }
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage"])
        XCTAssertTrue(store.state.publications.isEmpty)
        XCTAssertFalse(api.methods.contains("deleteMessage"))
    }

    func testPublicationCommandsAuthorizePersistedReceiptAfterButtonExpiryAndWhilePausedOrOff() async throws {
        for (index, text) in ["/delete", "/supprimer", "/delete@fxclipbot", "/supprimer@FXCLIPBOT"].enumerated() {
            try reset()
            try seed()
            try store.recordReplyControl(chatID: group, messageID: 7301, posterID: 8, now: TimeInterval(now - 1000))
            try await bot.expireReplyControls(now: TimeInterval(now))
            XCTAssertTrue(store.state.replyControls.isEmpty)
            XCTAssertNotNil(store.state.publications[key])
            if index % 2 == 0 { try store.setGroupEnabled(false, chatID: group) }
            else { var settings = ChatSettings(); settings.mode = .off; try store.set(settings, chatID: group) }
            store = try StateStore(directory: directory)
            configureBot()
            api.calls = []
            try await command(text)
            XCTAssertEqual(api.calls.filter { $0.0 == "deleteMessage" && $0.1["message_id"] as? Int64 == 7301 }.count, 1)
            XCTAssertFalse(api.methods.contains("getChatMember"))
            XCTAssertNil(store.state.publications[key])
            XCTAssertNil(try StateStore(directory: directory).state.publications[key])
        }
    }

    func testPublicationDeleteCommandsRejectOtherAuthorsOwnerAdminAnonymousBotAndPrivate() async throws {
        try seed()
        for text in ["/delete", "/supprimer"] {
            for fields: [String: Any] in [
                ["from": actor(7)], ["from": actor(9)], ["from": actor(8, bot: true)],
                ["from": actor(8), "sender_chat": ["id": group, "type": "supergroup"]],
                ["from": ["id": 8, "first_name": "Unknown"]], ["from": actor(0)],
                ["chat": ["id": 8, "type": "private"]],
            ] {
                api.calls = []
                try await command(text, extra: fields)
                assertNoPublicationDeletion()
            }
            api.calls = []
            try await command(text, replyID: nil)
            assertNoPublicationDeletion()
            api.calls = []
            try await command(text, replyID: 9999)
            assertNoPublicationDeletion()
        }
    }

    func testPublicationCommandTrustsReceiptRatherThanUntrustedRepliedMessageAuthorFields() async throws {
        try seed()
        try await command(extra: ["reply_to_message": ["message_id": 7301, "from": actor(9)]])
        XCTAssertNil(store.state.publications[key])
        api.calls = []
        try await command(replyID: 7302, extra: ["reply_to_message": ["message_id": 7302, "from": actor(99, bot: true)]])
        XCTAssertFalse(api.calls.contains { $0.0 == "deleteMessage" && $0.1["message_id"] as? Int64 == 7302 })
    }

    func testPublicationCommandsStrict48HourBoundaryAndFutureReceipt() async throws {
        for age in [48 * 60 * 60 - 1, 48 * 60 * 60, 48 * 60 * 60 + 1, -1] {
            try reset(); try seed(createdAt: now - age)
            try await command()
            let deleted = api.calls.contains { $0.0 == "deleteMessage" && $0.1["message_id"] as? Int64 == 7301 }
            XCTAssertEqual(deleted, age == 48 * 60 * 60 - 1, "age \(age)")
        }
    }

    func testPublicationCommandDeleteFailureAndUnconfirmedResultPreserveReceipt() async throws {
        for result: Result<Any, Error> in [.failure(BotError.telegram(403)), .failure(URLError(.timedOut)),
                                         .success(false), .success(NSNumber(value: 1))] {
            try reset(); try seed()
            api.outcomes["deleteMessage"] = result
            try await command()
            XCTAssertNotNil(store.state.publications[key])
            XCTAssertNotNil(try StateStore(directory: directory).state.publications[key])
        }
    }

    func testPublicationPrivateListContainsOnlyOwnFiveNewestWithSafeLinksAndEscapedTitle() async throws {
        try store.discover(Chat(id: group, type: "supergroup", title: "Group <b>& \"title\""))
        for id in 7301...7307 { try seed(Int64(id), createdAt: now - (7310 - id)) }
        try seed(9000, poster: 7)
        try seed(9001, createdAt: now - 48 * 60 * 60)
        try seed(9002, createdAt: now + 1)
        for language in [BotLanguage.en, .fr] {
            try store.setUserLanguage(language, userID: 8)
            api.calls = []
            try await privateCommand()
            let first = try panel()
            let firstButtons = try buttons(first)
            let deleteActions = firstButtons.compactMap(\.callback_data).filter { $0.hasPrefix("fxclip:posts:ask:") }
            XCTAssertEqual(deleteActions.count, 5)
            XCTAssertEqual(Set(deleteActions), Set((7303...7307).map { "fxclip:posts:ask:\(group):\($0):0" }))
            let urls = firstButtons.compactMap(\.url)
            XCTAssertEqual(Set(urls), Set((7303...7307).map { "https://t.me/c/1234567890/\($0)" }))
            XCTAssertTrue(firstButtons.contains { $0.callback_data == "fxclip:posts:show:1" })
            let text = try XCTUnwrap(first["text"] as? String)
            XCTAssertTrue(text.contains("&lt;b&gt;&amp;"))
            XCTAssertFalse(text.contains("Group <b>"))
            XCTAssertTrue(text.contains("03/01/1970 07:33 UTC"))
            XCTAssertTrue(firstButtons.contains { $0.text.contains(language == .fr ? "Voir" : "View") })
            XCTAssertTrue(firstButtons.contains { $0.text.contains(language == .fr ? "Supprimer" : "Delete") })
            api.calls = []
            try await callback("fxclip:posts:show:1", markup: first["reply_markup"])
            let second = try panel()
            let actions = try buttons(second).compactMap(\.callback_data)
            XCTAssertEqual(Set(actions.filter { $0.hasPrefix("fxclip:posts:ask:") }),
                           Set((7301...7302).map { "fxclip:posts:ask:\(group):\($0):1" }))
            XCTAssertTrue(actions.contains("fxclip:posts:show:0"))
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("state.json"))) as? [String: Any])
        let publications = try XCTUnwrap(json["publications"] as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(publications[key]).keys), ["posterID", "createdAt"])
    }

    func testPublicationPrivateDeepLinkOpensOwnListAndBasicGroupsNeverInventViewURLs() async throws {
        try seed()
        try seed(10, chatID: -55)
        try seed(11, chatID: -100)
        try await privateCommand("/start publications")
        let issued = try panel()
        let actions = try buttons(issued)
        XCTAssertTrue(actions.contains { $0.callback_data == "fxclip:posts:ask:\(group):7301:0" })
        XCTAssertTrue(actions.contains { $0.callback_data == "fxclip:posts:ask:-55:10:0" })
        XCTAssertTrue(actions.contains { $0.callback_data == "fxclip:posts:ask:-100:11:0" })
        XCTAssertEqual(actions.compactMap(\.url), ["https://t.me/c/1234567890/7301"])
    }

    func testPublicationDashboardIssuedNavigationAndConfirmationAreReadOnlyUntilConfirmed() async throws {
        try seed()
        try await privateCommand("/settings")
        let dashboard = try panel()
        XCTAssertTrue(try buttons(dashboard).contains { $0.callback_data == "fxclip:personal:publications" })
        let before = try snapshot()
        api.calls = []
        try await callback("fxclip:personal:publications", markup: dashboard["reply_markup"])
        let list = try panel()
        let ask = "fxclip:posts:ask:\(group):7301:0"
        XCTAssertTrue(try buttons(list).contains { $0.callback_data == ask })
        api.calls = []
        try await callback(ask, markup: list["reply_markup"])
        let confirmation = try panel()
        let deletion = "fxclip:posts:del:\(group):7301:0"
        XCTAssertTrue(try buttons(confirmation).contains { $0.callback_data == deletion })
        XCTAssertEqual(try snapshot(), before)
        XCTAssertFalse(api.methods.contains("deleteMessage"))
        api.calls = []
        try await callback(deletion, markup: confirmation["reply_markup"])
        XCTAssertTrue(api.calls.contains { $0.0 == "deleteMessage" && $0.1["chat_id"] as? Int64 == group
            && $0.1["message_id"] as? Int64 == 7301 })
        XCTAssertNil(store.state.publications[key])
    }

    func testPublicationForgedCallbacksDenyOtherAuthorWrongPrivateChatBotAndMissingKeyboard() async throws {
        try seed()
        let deletion = "fxclip:posts:del:\(group):7301:0"
        let attached = ["inline_keyboard": [[["text": "Fixture", "callback_data": deletion]]]]
        for (user, chat, isBot): (Int64, Int64, Bool) in [(7, 7, false), (9, 9, false), (8, 7, false), (8, group, false), (8, 8, true)] {
            api.calls = []
            try await callback(deletion, markup: attached, userID: user, chatID: chat,
                               groupChat: chat == group, actorIsBot: isBot)
            assertNoPublicationDeletion()
        }
        for markup: Any? in [nil, ["inline_keyboard": [[["text": "Different", "callback_data": "fxclip:posts:show:0"]]]]] {
            api.calls = []
            try await callback(deletion, markup: markup)
            assertNoPublicationDeletion()
        }
    }

    func testPublicationPrivateConfirmedDeleteFailurePreservesReceiptAndControl() async throws {
        try seed()
        try store.recordReplyControl(chatID: group, messageID: 7301, posterID: 8, now: TimeInterval(now))
        try await privateCommand()
        let list = try panel()
        api.calls = []
        try await callback("fxclip:posts:ask:\(group):7301:0", markup: list["reply_markup"])
        let confirmation = try panel()
        api.outcomes["deleteMessage"] = .failure(BotError.telegram(403))
        api.calls = []
        try await callback("fxclip:posts:del:\(group):7301:0", markup: confirmation["reply_markup"])
        XCTAssertNotNil(store.state.publications[key])
        XCTAssertNotNil(store.state.replyControls[key])
        XCTAssertNotNil(try StateStore(directory: directory).state.publications[key])
    }

    func testPublicationGroupCommandLinksToPrivateListAndWrongPrivateIdentityCannotList() async throws {
        try seed()
        try await message("/publications")
        let groupPanel = try panel()
        XCTAssertTrue(try buttons(groupPanel).contains { $0.url == "https://t.me/fxclipbot?start=publications" })
        XCTAssertFalse(try buttons(groupPanel).contains { $0.callback_data?.hasPrefix("fxclip:posts:ask:") == true })
        api.calls = []
        try await privateCommand(chatID: 7)
        for call in api.calls {
            XCTAssertFalse(try buttons(call.1).contains { $0.callback_data?.hasPrefix("fxclip:posts:ask:") == true })
        }
    }
}
