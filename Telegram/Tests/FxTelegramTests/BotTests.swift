import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

final class FakeAPI: BotAPI {
    var calls: [(String, [String: Any])] = []
    var failSend = false
    var failDelete = false
    var admin = true
    var canDelete = true
    var businessEnabled = true
    var businessCanReply = true
    var businessOwnerID: Int64 = 7
    var sendResult: Any = ["message_id": Int64(42)]
    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters))
        switch method {
        case "sendMessage":
            if failSend { throw URLError(.timedOut) }
            return sendResult
        case "deleteMessage":
            if failDelete { throw BotError.telegram(403) }
            return true
        case "getChatMember":
            return ["status": admin ? "administrator" : "member", "can_delete_messages": canDelete]
        case "getBusinessConnection":
            return ["id": "connection", "user": ["id": businessOwnerID, "first_name": "Alice"],
                    "is_enabled": businessEnabled, "rights": ["can_reply": businessCanReply]]
        default: return true
        }
    }
    var methods: [String] { calls.map(\.0) }
}

final class BotTests: XCTestCase {
    let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared")
    var directory: URL!
    var store: StateStore!
    var engine: Engine!
    var api: FakeAPI!
    var bot: Bot!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try StateStore(directory: directory)
        engine = Engine(rules: try Rules.load(Data(contentsOf: shared.appendingPathComponent("rules.json"))))
        api = FakeAPI()
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func message(_ extra: [String: Any] = [:]) throws -> Message {
        var object: [String: Any] = ["message_id": 5, "date": 1000,
            "chat": ["id": -100, "type": "supergroup"],
            "from": ["id": 7, "first_name": "Alice", "is_bot": false],
            "text": "Look https://x.com/a/status/1?s=2"]
        object.merge(extra) { _, new in new }
        return try decode(Message.self, from: object)
    }
    func update(_ message: Message, business: Bool = false) throws -> Update {
        // Message is deliberately Decodable only; fixtures model the actual wire format.
        let mirror = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WireMessage(message)))
        return try decode(Update.self, from: ["update_id": 1, business ? "business_message" : "message": mirror])
    }
    func handle(_ extra: [String: Any] = [:], business: Bool = false) async throws {
        try await bot.handle(update(message(extra), business: business), now: 1100)
    }
    func replaceMode() throws { var s = ChatSettings(); s.mode = .replace; try store.set(s, chatID: -100) }
    func privateCommand(_ text: String, userID: Int64 = 8) async throws {
        try await handle(["text": text, "chat": ["id": userID, "type": "private"],
                          "from": ["id": userID, "first_name": "Member", "is_bot": false]])
    }
    func callback(_ data: String, userID: Int64 = 8, chatID: Int64 = 8, chatType: String = "private") async throws {
        let update = try decode(Update.self, from: ["update_id": 2, "callback_query": [
            "id": "button-click", "from": ["id": userID, "first_name": "Member", "is_bot": false],
            "data": data, "message": ["message_id": 42, "date": 1000,
                "chat": ["id": chatID, "type": chatType],
                "from": ["id": 99, "first_name": "fxclip", "is_bot": true]],
        ]])
        try await bot.handle(update, now: 1100)
    }
    var sent: [String: Any] { api.calls.first { $0.0 == "sendMessage" }!.1 }

    func testURLWithAtSignIsNotMistakenForBotCommand() async throws {
        try await handle(["text": "https://www.youtube.com/@chaine?utm_source=test"])
        XCTAssertEqual(sent["text"] as? String, "Publié par Alice\n\nhttps://www.youtube.com/@chaine")
    }
    func testCoalescingUsesLatestGroupRevisionButDoesNotRepostEditOnly() throws {
        let original = try update(message(["text": "initial https://x.com/a?s=1"]))
        let edited = try decode(Update.self, from: ["update_id": 2, "edited_message":
            jsonObject(WireMessage(message(["text": "latest https://x.com/b?s=2"])))])
        let batch = coalesced([original, edited])
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch[0].message?.text, "latest https://x.com/b?s=2")
        XCTAssertNil(batch[1].message)
        XCTAssertNil(coalesced([edited])[0].message)
    }
    func testCoalescingBusinessProcessesOnlyLastRevision() throws {
        let initial = try update(message(["business_connection_id": "connection"]), business: true)
        let edited = try decode(Update.self, from: ["update_id": 2, "edited_business_message":
            jsonObject(WireMessage(message(["business_connection_id": "connection", "text": "second"])) )])
        let latest = try decode(Update.self, from: ["update_id": 3, "edited_business_message":
            jsonObject(WireMessage(message(["business_connection_id": "connection", "text": "latest"])) )])
        let batch = coalesced([initial, edited, latest])
        XCTAssertNil(batch[0].business_message)
        XCTAssertNil(batch[1].business_message)
        XCTAssertNil(batch[1].edited_business_message)
        XCTAssertEqual(batch[2].business_message?.text, "latest")
        XCTAssertEqual(batch.map(\.update_id), [1, 2, 3])
    }

    func testReplyCreditsAuthorPreservesTextAndTopic() async throws {
        try await handle(["message_thread_id": 12])
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(sent["text"] as? String, "Publié par Alice\n\nLook https://fxtwitter.com/a/status/1")
        XCTAssertEqual(sent["message_thread_id"] as? Int64, 12)
        XCTAssertEqual((sent["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        let entities = try decode([Entity].self, from: XCTUnwrap(sent["entities"]))
        let mention = try XCTUnwrap(entities.first { $0.type == "text_mention" })
        XCTAssertEqual(mention.user?.id, 7)
        XCTAssertEqual(((try XCTUnwrap(sent["text"] as? String)) as NSString).substring(with: NSRange(location: mention.offset, length: mention.length)), "Alice")
    }
    func testReplaceConfirmsPostBeforeDelete() async throws {
        try replaceMode(); try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
        XCTAssertNil(sent["reply_parameters"])
    }
    func testAmbiguousSendNeverDeletes() async throws {
        try replaceMode(); api.failSend = true
        do { try await handle(); XCTFail("Expected timeout") } catch {}
        XCTAssertFalse(api.methods.contains("deleteMessage"))
    }
    func testDeleteFailureKeepsSuccessfulRepostWithoutSecondSend() async throws {
        try replaceMode(); api.failDelete = true; try await handle()
        XCTAssertEqual(api.methods.filter { $0 == "sendMessage" }.count, 1)
    }
    func testRevokedDeletePermissionFallsBackToReply() async throws {
        try replaceMode(); api.canDelete = false; try await handle()
        XCTAssertFalse(api.methods.contains("deleteMessage")); XCTAssertNotNil(sent["reply_parameters"])
    }
    func testCaptionNeverDeletesMedia() async throws {
        try replaceMode()
        try await handle(["text": NSNull(), "caption": "https://instagram.com/p/abc/?igsh=tracking"])
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertNotNil(sent["reply_parameters"])
    }
    func testNoWorkForUnchangedOldProtectedBotOrUnallowedMessages() async throws {
        for fixture: [String: Any] in [
            ["text": "https://example.com/path"], ["date": 0], ["has_protected_content": true],
            ["from": ["id": 99, "first_name": "Bot", "is_bot": true]],
            ["chat": ["id": -200, "type": "supergroup"]], ["is_automatic_forward": true],
        ] { try await handle(fixture) }
        XCTAssertTrue(api.calls.isEmpty)
    }
    func testOnlyAdminsCanChangeGroupSettings() async throws {
        api.admin = false
        try await handle(["text": "/fxclip replace"])
        XCTAssertNil(store.state.chats["-100"])
        api.admin = true
        try await handle(["text": "/fxclip replace"])
        XCTAssertEqual(store.state.chats["-100"]?.mode, .replace)
        try await handle(["text": "/fxclip off"])
        api.calls = []; try await handle(); XCTAssertTrue(api.calls.isEmpty)
    }
    func testOtherBotCommandsAreIgnored() async throws {
        try await handle(["text": "/fxclip@otherbot replace"])
        XCTAssertTrue(api.calls.isEmpty)
    }
    func testNonAdminCanPrivatelyChangeOnlyTheirOwnPreference() async throws {
        api.admin = false
        try store.setMode(.reply, userID: 7)
        try await privateCommand("/mode replace")
        XCTAssertEqual(store.state.users["8"], .replace)
        XCTAssertEqual(store.state.users["7"], .reply)
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertEqual(store.state.defaultMode, .reply)
        XCTAssertFalse(api.methods.contains("getChatMember"))
        XCTAssertEqual(try StateStore(directory: directory).state.users["8"], .replace)
    }
    func testPersonalOffOverridesGroupReplace() async throws {
        try replaceMode(); try store.setMode(.off, userID: 7)
        try await handle()
        XCTAssertTrue(api.calls.isEmpty)
    }
    func testPersonalReplyOverridesGroupReplace() async throws {
        try replaceMode(); try store.setMode(.reply, userID: 7)
        try await handle()
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual((sent["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
    }
    func testPersonalReplaceOverridesGroupOff() async throws {
        var settings = ChatSettings(); settings.mode = .off
        try store.set(settings, chatID: -100); try store.setMode(.replace, userID: 7)
        try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
    }
    func testResetPersonalPreferenceFollowsGlobalThenGroupMode() async throws {
        try store.setDefault(.off); try store.setMode(.replace, userID: 7)
        try await privateCommand("/mode default", userID: 7)
        XCTAssertNil(store.state.users["7"])
        XCTAssertNil(try StateStore(directory: directory).state.users["7"])
        api.calls = []; try await handle()
        XCTAssertTrue(api.calls.isEmpty)

        try store.setDefault(.replace)
        api.calls = []; try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])

        var settings = ChatSettings(); settings.mode = .reply
        try store.set(settings, chatID: -100)
        api.calls = []; try await handle()
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertNotNil(sent["reply_parameters"])
    }
    func testUnauthorizedDefaultCommandCannotChangeGlobalOrPersonalMode() async throws {
        try store.setDefault(.reply); try store.setMode(.off, userID: 8)
        try await privateCommand("/default replace")
        XCTAssertEqual(store.state.defaultMode, .reply)
        XCTAssertEqual(store.state.users["8"], .off)
        XCTAssertEqual(try StateStore(directory: directory).state.defaultMode, .reply)
        XCTAssertFalse(api.methods.contains("deleteMessage"))
    }
    func testOwnerChangesGlobalDefaultAndItSurvivesRestart() async throws {
        try await privateCommand("/default replace", userID: 7)
        let restarted = try StateStore(directory: directory)
        XCTAssertEqual(restarted.state.defaultMode, .replace)
        XCTAssertTrue(restarted.state.users.isEmpty)
        bot = Bot(api: api, store: restarted, engine: engine, allowedChats: [-100],
                  allowedOwners: [7], botID: 99, username: "fxclipbot")
        api.calls = []; try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
    }
    func testPersonalSecretarySuppressesGroupRewrite() async throws {
        try replaceMode(); try store.setMode(.secretary, userID: 7)
        try await handle()
        XCTAssertTrue(api.calls.isEmpty)
    }
    func testPrivateSettingsOffersNativeInlineChoicesWithoutChangingState() async throws {
        api.admin = false
        try await privateCommand("/settings")
        let markup = try XCTUnwrap(sent["reply_markup"] as? [String: Any])
        XCTAssertNil(markup["keyboard"])
        let rows = try XCTUnwrap(markup["inline_keyboard"] as? [[[String: String]]])
        let actions = Set(rows.flatMap { $0 }.compactMap { $0["callback_data"] })
        XCTAssertEqual(actions, Set(["reply", "replace", "secretary", "off", "default"].map { "fxclip:personal:\($0)" }))
        XCTAssertTrue(store.state.users.isEmpty)
        XCTAssertTrue(store.state.chats.isEmpty)
    }
    func testPrivateCallbackChangesOnlyAuthenticatedUsersPreference() async throws {
        api.admin = false; try store.setMode(.reply, userID: 7)
        try await callback("fxclip:personal:replace")
        XCTAssertEqual(store.state.users["8"], .replace)
        XCTAssertEqual(store.state.users["7"], .reply)
        XCTAssertEqual(store.state.defaultMode, .reply)
        XCTAssertEqual(api.methods, ["answerCallbackQuery", "editMessageText"])
        XCTAssertEqual(api.calls.last?.1["chat_id"] as? Int64, 8)
        XCTAssertEqual(api.calls.last?.1["message_id"] as? Int64, 42)
        XCTAssertEqual(try StateStore(directory: directory).state.users["8"], .replace)
        try await callback("fxclip:personal:default")
        XCTAssertNil(store.state.users["8"])
    }
    func testCallbacksFromGroupsOrAnotherUsersPrivateChatCannotChangeSettings() async throws {
        for (chatID, type): (Int64, String) in [(-100, "supergroup"), (7, "private")] {
            api.calls = []
            try await callback("fxclip:personal:replace", chatID: chatID, chatType: type)
            XCTAssertTrue(store.state.users.isEmpty)
            XCTAssertEqual(store.state.defaultMode, .reply)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        }
    }
    func testUnauthorizedDefaultCallbackCannotChangeGlobalMode() async throws {
        try await callback("fxclip:default:replace")
        XCTAssertEqual(store.state.defaultMode, .reply)
        XCTAssertTrue(store.state.users.isEmpty)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
    }
    func testOwnerDefaultCallbackPersistsWithoutChangingPersonalPreference() async throws {
        try store.setMode(.off, userID: 7)
        try await callback("fxclip:default:replace", userID: 7, chatID: 7)
        let restarted = try StateStore(directory: directory)
        XCTAssertEqual(restarted.state.defaultMode, .replace)
        XCTAssertEqual(restarted.state.users["7"], .off)
        XCTAssertEqual(api.methods, ["answerCallbackQuery", "editMessageText"])
    }
    func testMalformedCallbacksCannotChangeSettings() async throws {
        for data in ["other:personal:replace", "fxclip:unknown:replace", "fxclip:personal:invalid", "fxclip:personal:replace:extra"] {
            api.calls = []; try await callback(data)
            XCTAssertTrue(store.state.users.isEmpty, data)
            XCTAssertEqual(store.state.defaultMode, .reply, data)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"], data)
        }
    }
    func testManualForwardsAlwaysReplyAndRetainOriginal() async throws {
        try replaceMode()
        for origin in ["user", "hidden_user", "channel"] {
            api.calls = []
            try await handle(["forward_origin": ["type": origin]])
            XCTAssertEqual(api.methods, ["sendMessage"], origin)
            XCTAssertEqual((sent["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5, origin)
        }
    }
    func testReplaceKeepsOriginalReplyTarget() async throws {
        try replaceMode()
        try await handle(["reply_to_message": ["message_id": 3]])
        XCTAssertEqual((sent["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 3)
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
    }
    func testJSONNumberSendConfirmationAllowsDeletion() async throws {
        try replaceMode()
        // JSONSerialization is the real API's decoder: message_id arrives as NSNumber.
        api.sendResult = try JSONSerialization.jsonObject(with: Data(#"{"message_id":1234567890123}"#.utf8))
        try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
        let deletion = try XCTUnwrap(api.calls.last?.1)
        XCTAssertEqual(deletion["message_id"] as? Int64, 5)
        XCTAssertEqual(deletion["chat_id"] as? Int64, -100)
    }
    func testMalformedSendSuccessNeverDeletesOriginal() async throws {
        try replaceMode()
        for json in [#"{}"#, #"null"#, #"true"#, #"{"message_id":null}"#,
                     #"{"message_id":"42"}"#, #"{"message_id":0}"#,
                     #"{"message_id":-1}"#, #"{"message_id":true}"#,
                     #"{"message_id":42.5}"#] {
            api.calls = []
            api.sendResult = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            do {
                try await handle()
                XCTFail("Expected invalid response for \(json)")
            } catch BotError.invalidResponse {} catch {
                XCTFail("Unexpected error for \(json): \(error)")
            }
            XCTAssertFalse(api.methods.contains("deleteMessage"), json)
            XCTAssertEqual(api.methods.filter { $0 == "sendMessage" }.count, 1, json)
        }
    }
    func testUnicodeEntitiesAndHiddenLinks() throws {
        let text = "😀 https://x.com/a?s=1 more"
        let result = try XCTUnwrap(Rewriter(engine: engine).rewrite(message([
            "text": text, "entities": [["type": "bold", "offset": 3, "length": 19],
                ["type": "text_link", "offset": 23, "length": 4, "url": "https://youtu.be/abc?si=tracking"]],
        ]), previews: true))
        XCTAssertEqual(result.text, "Publié par Alice\n\n😀 https://fxtwitter.com/a more")
        let bold = try XCTUnwrap(result.entities.first { $0.type == "bold" })
        XCTAssertEqual((result.text as NSString).substring(with: NSRange(location: bold.offset, length: bold.length)), "https://fxtwitter.com/a")
        let hidden = try XCTUnwrap(result.entities.first { $0.type == "text_link" })
        XCTAssertEqual(hidden.url, "https://youtu.be/abc")
        XCTAssertEqual((result.text as NSString).substring(with: NSRange(location: hidden.offset, length: hidden.length)), "more")
    }
    func testCodeAndLongMessagesRemainIntact() throws {
        XCTAssertNil(Rewriter(engine: engine).rewrite(try message([
            "text": "https://x.com/a?s=1", "entities": [["type": "code", "offset": 0, "length": 19]],
        ]), previews: true))
        XCTAssertNil(Rewriter(engine: engine).rewrite(try message([
            "text": String(repeating: "a", count: 4070) + " https://x.com/a?s=1",
        ]), previews: true))
    }
    func testRepeatedAndDistinctURLsRespectCodeAndUTF16EntityPositions() throws {
        let repeated = "https://x.com/a?s=1"
        let instagram = "https://instagram.com/p/abc/?igsh=tracking"
        let text = "😀 \(repeated) puis \(instagram) et \(repeated) code \(repeated) fin"
        let source = text as NSString
        let codeRange = source.range(of: repeated, options: .backwards)
        let tailRange = source.range(of: "fin")
        let result = try XCTUnwrap(Rewriter(engine: engine).rewrite(message([
            "text": text, "entities": [
                ["type": "code", "offset": codeRange.location, "length": codeRange.length],
                ["type": "bold", "offset": tailRange.location, "length": tailRange.length],
            ],
        ]), previews: true, attribution: false))
        XCTAssertEqual(result.text, "😀 https://fxtwitter.com/a puis https://zzinstagram.com/p/abc/ et https://fxtwitter.com/a code \(repeated) fin")
        let code = try XCTUnwrap(result.entities.first { $0.type == "code" })
        XCTAssertEqual((result.text as NSString).substring(with: NSRange(location: code.offset, length: code.length)), repeated)
        let bold = try XCTUnwrap(result.entities.first { $0.type == "bold" })
        XCTAssertEqual((result.text as NSString).substring(with: NSRange(location: bold.offset, length: bold.length)), "fin")
        XCTAssertTrue(result.text.contains(result.previewURL))
        XCTAssertNotEqual(result.previewURL, repeated)
    }
    func testSharedVectorsStillMatchBotEngine() throws {
        struct Vector: Decodable { let input, telegram: String }
        struct File: Decodable { let vectors: [Vector] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: shared.appendingPathComponent("vectors.json")))
        for v in file.vectors {
            let result = Rewriter(engine: engine).rewrite(try message(["text": v.input]), previews: true, attribution: false)
            XCTAssertEqual(result?.text ?? v.input, v.telegram, v.input)
        }
    }
    func testStateRestartSkipsReservedUpdateAndKeepsSettings() throws {
        XCTAssertTrue(try store.reserve(50)); try replaceMode(); try store.setMode(.secretary, userID: 7)
        let restarted = try StateStore(directory: directory)
        XCTAssertFalse(try restarted.reserve(50)); XCTAssertEqual(restarted.state.offset, 51)
        XCTAssertEqual(restarted.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(restarted.state.users["7"], .secretary)
    }
    func testSevenIdleDaysResetOffsetAndKeepPreferencesAcrossRestart() throws {
        let start: TimeInterval = 1000
        let week: TimeInterval = 7 * 24 * 60 * 60
        XCTAssertTrue(try store.reserve(500, now: start))
        try replaceMode(); try store.setMode(.off, userID: 7); try store.setDefault(.secretary)
        try store.resetIdleEpoch(now: start + week - 1)
        XCTAssertEqual(store.state.offset, 501)
        XCTAssertFalse(try store.reserve(12, now: start + week - 1))

        let restarted = try StateStore(directory: directory)
        try restarted.resetIdleEpoch(now: start + week)
        XCTAssertEqual(restarted.state.offset, 0)
        XCTAssertEqual(restarted.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(restarted.state.users["7"], .off)
        XCTAssertEqual(restarted.state.defaultMode, .secretary)
        let reset = try StateStore(directory: directory)
        XCTAssertEqual(reset.state.offset, 0)
        XCTAssertEqual(reset.state.lastUpdateAt, start + week)
        XCTAssertTrue(try reset.reserve(12, now: start + week + 1))
        XCTAssertFalse(try reset.reserve(12, now: start + week + 2))
        XCTAssertEqual(try StateStore(directory: directory).state.offset, 13)
    }
    func testNewUpdateStartsFreshIdlePeriod() throws {
        let week: TimeInterval = 7 * 24 * 60 * 60
        XCTAssertTrue(try store.reserve(500, now: 1000))
        XCTAssertTrue(try store.reserve(501, now: 1000 + week - 1))
        let restarted = try StateStore(directory: directory)
        try restarted.resetIdleEpoch(now: 1000 + week)
        XCTAssertEqual(restarted.state.offset, 502)
        XCTAssertFalse(try restarted.reserve(12, now: 1000 + week))
    }
    func testCorruptStateStopsInsteadOfReplaying() throws {
        try Data("broken".utf8).write(to: directory.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try StateStore(directory: directory))
    }
    func testSecretaryEditsOwnerMessageInPlace() async throws {
        try store.setMode(.secretary, userID: 7)
        try await handle(["chat": ["id": 123, "type": "private"], "business_connection_id": "connection"], business: true)
        XCTAssertEqual(api.methods, ["getBusinessConnection", "editMessageText"])
        let edit = try XCTUnwrap(api.calls.last?.1)
        XCTAssertEqual(edit["text"] as? String, "Look https://fxtwitter.com/a/status/1")
        XCTAssertEqual(edit["business_connection_id"] as? String, "connection")
    }
    func testSecretaryNeverEditsIncomingMessagesOrWithoutConsentAndRights() async throws {
        let fixture: [String: Any] = ["chat": ["id": 123, "type": "private"], "business_connection_id": "connection"]
        try await handle(fixture, business: true); XCTAssertTrue(api.calls.isEmpty)
        try store.setMode(.secretary, userID: 7)
        var incoming = fixture; incoming["from"] = ["id": 8, "first_name": "Bob"]
        try await handle(incoming, business: true); XCTAssertTrue(api.calls.isEmpty)
        api.businessCanReply = false; try await handle(fixture, business: true)
        XCTAssertFalse(api.methods.contains("editMessageText"))
        api.businessCanReply = true; api.businessEnabled = false
        try await handle(fixture, business: true); XCTAssertFalse(api.methods.contains("editMessageText"))
    }
    func testSecretaryIgnoresMessagesSentByBusinessBots() async throws {
        try store.setMode(.secretary, userID: 7)
        try await handle(["chat": ["id": 123, "type": "private"],
                          "business_connection_id": "connection",
                          "sender_business_bot": ["id": 456, "first_name": "Automation", "is_bot": true]], business: true)
        XCTAssertTrue(api.calls.isEmpty)
    }
    func testSecretaryRejectsBusinessConnectionOwnedByAnotherUser() async throws {
        try store.setMode(.secretary, userID: 7)
        api.businessOwnerID = 8
        try await handle(["chat": ["id": 123, "type": "private"],
                          "business_connection_id": "connection"], business: true)
        XCTAssertEqual(api.methods, ["getBusinessConnection"])
    }
    func testSecretaryEditsCaptionAndPreservesCaptionEntities() async throws {
        try store.setMode(.secretary, userID: 7)
        let caption = "😀 https://x.com/a?s=1"
        let urlRange = (caption as NSString).range(of: "https://x.com/a?s=1")
        try await handle(["chat": ["id": 123, "type": "private"],
                          "business_connection_id": "connection", "text": NSNull(), "caption": caption,
                          "caption_entities": [["type": "bold", "offset": urlRange.location, "length": urlRange.length]]], business: true)
        XCTAssertEqual(api.methods, ["getBusinessConnection", "editMessageCaption"])
        let edit = try XCTUnwrap(api.calls.last?.1)
        XCTAssertEqual(edit["caption"] as? String, "😀 https://fxtwitter.com/a")
        XCTAssertEqual(edit["business_connection_id"] as? String, "connection")
        XCTAssertEqual(edit["chat_id"] as? Int64, 123)
        XCTAssertEqual(edit["message_id"] as? Int64, 5)
        XCTAssertNil(edit["text"])
        XCTAssertNil(edit["link_preview_options"])
        let entities = try decode([Entity].self, from: XCTUnwrap(edit["caption_entities"]))
        let bold = try XCTUnwrap(entities.first { $0.type == "bold" })
        XCTAssertEqual(((edit["caption"] as! String) as NSString).substring(with: NSRange(location: bold.offset, length: bold.length)), "https://fxtwitter.com/a")
    }
    func testSecretaryNeverEditsCaptionWhenRightsAreDenied() async throws {
        try store.setMode(.secretary, userID: 7)
        api.businessCanReply = false
        try await handle(["chat": ["id": 123, "type": "private"],
                          "business_connection_id": "connection", "text": NSNull(),
                          "caption": "https://instagram.com/p/abc/?igsh=tracking"], business: true)
        XCTAssertEqual(api.methods, ["getBusinessConnection"])
    }
}

/// Retains the wire fields used in these fixtures, without making incoming product models Encodable.
private struct WireMessage: Encodable {
    let message_id: Int64; let date: Int; let chat: Chat
    let from: TelegramUser?; let sender_chat: Chat?; let text: String?; let entities: [Entity]?
    let caption: String?; let caption_entities: [Entity]?; let message_thread_id: Int64?
    let reply_to_message: [String: Int64]?
    let is_automatic_forward: Bool?; let has_protected_content: Bool?; let is_paid_post: Bool?
    let business_connection_id: String?; let sender_business_bot: TelegramUser?; let forward_origin: ForwardOrigin?
    init(_ m: Message) {
        message_id = m.message_id; date = m.date; chat = m.chat; from = m.from; sender_chat = m.sender_chat
        text = m.text; entities = m.entities; caption = m.caption; caption_entities = m.caption_entities
        message_thread_id = m.message_thread_id; is_automatic_forward = m.is_automatic_forward
        reply_to_message = m.reply_to_message.map { ["message_id": $0.message_id] }
        has_protected_content = m.has_protected_content; is_paid_post = m.is_paid_post
        business_connection_id = m.business_connection_id; sender_business_bot = m.sender_business_bot; forward_origin = m.forward_origin
    }
}
