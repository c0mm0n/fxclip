import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

final class FakeAPI: BotAPI {
    var calls: [(String, [String: Any])] = []
    var failSend = false
    var failDelete = false
    var failEdit = false
    var failMarkup = false
    var markupResult: Any?
    var photoError: Error?
    var videoError: Error?
    var admin = true
    var canDelete = true
    var memberResult: [String: Any]?
    var failMember = false
    var failCommandsLocale: String?
    var commandMenus: [String: [[String: String]]] = [:]
    var businessEnabled = true
    var businessCanReply = true
    var businessOwnerID: Int64 = 7
    var sendResult: Any = ["message_id": Int64(42)]
    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters))
        switch method {
        case "sendVideo":
            if let videoError { throw videoError }
            return sendResult
        case "sendPhoto":
            if let photoError { throw photoError }
            return sendResult
        case "setMyCommands":
            let code = parameters["language_code"] as? String ?? ""
            if code == failCommandsLocale {
                failCommandsLocale = nil
                throw BotError.telegram(500)
            }
            if let scope = parameters["scope"] as? [String: Any], let userID = scope["chat_id"] as? Int64,
               let commands = parameters["commands"] as? [[String: String]] {
                commandMenus["\(userID):\(code)"] = commands
            }
            return true
        case "sendMessage":
            if failSend { throw URLError(.timedOut) }
            return sendResult
        case "deleteMessage":
            if failDelete { throw BotError.telegram(403) }
            return true
        case "editMessageText":
            if failEdit { throw BotError.telegram(403) }
            return true
        case "editMessageReplyMarkup":
            if failMarkup { throw BotError.telegram(500) }
            return markupResult ?? true
        case "getChatMember":
            if failMember { throw BotError.telegram(403) }
            if let memberResult { return memberResult }
            return ["status": admin ? "administrator" : "member", "can_delete_messages": canDelete]
        case "getBusinessConnection":
            return ["id": "connection", "user": ["id": businessOwnerID, "first_name": "Alice"],
                    "is_enabled": businessEnabled, "rights": ["can_reply": businessCanReply]]
        default: return true
        }
    }
    var methods: [String] { calls.map(\.0) }
}

final class FakeYouTubeMetadata: YouTubeMetadataProviding {
    var requestedIDs: [String] = []
    var fail = false
    let title = "🎬 Example video"
    func fetch(videoID: String) async throws -> YouTubeMetadata {
        requestedIDs.append(videoID)
        if fail { throw URLError(.timedOut) }
        return YouTubeMetadata(title: title, thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!)
    }
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
    func privateCommand(_ text: String, userID: Int64 = 8, languageCode: String? = nil) async throws {
        try await handle(["text": text, "chat": ["id": userID, "type": "private"],
                          "from": fixtureUser(userID, languageCode: languageCode)])
    }
    func callback(_ data: String, userID: Int64 = 8, chatID: Int64 = 8, chatType: String = "private",
                  messageText: String? = nil, messageMarkup: [String: Any]? = nil,
                  languageCode: String? = nil) async throws {
        let update = try decode(Update.self, from: ["update_id": 2, "callback_query": [
            "id": "button-click", "from": fixtureUser(userID, languageCode: languageCode),
            "data": data, "message": ["message_id": 42, "date": 1000,
                "chat": ["id": chatID, "type": chatType],
                "from": ["id": 99, "first_name": "fxclip", "is_bot": true], "text": (messageText as Any?) ?? NSNull(),
                "reply_markup": messageMarkup ?? ["inline_keyboard": [[[
                    "text": "Fixture button", "callback_data": data,
                ]]]]],
        ]])
        try await bot.handle(update, now: 1100)
    }
    func fixtureUser(_ userID: Int64, languageCode: String?) -> [String: Any] {
        var user: [String: Any] = ["id": userID, "first_name": "Member", "is_bot": false]
        if let languageCode { user["language_code"] = languageCode }
        return user
    }
    var sent: [String: Any] { api.calls.first { $0.0 == "sendMessage" }!.1 }

    func enableYouTubeCards() -> FakeYouTubeMetadata {
        let metadata = FakeYouTubeMetadata()
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", youTubeMetadata: metadata)
        return metadata
    }

    func testPreviewActivationCommandDisclosesYouTubeAccessAndPossibleDuplicates() async throws {
        for language in [BotLanguage.en, .fr] {
            try store.setGroupLanguage(language, chatID: -100)
            api.calls = []
            try await handle(["text": "/fxclip previews on"])
            let text = try XCTUnwrap(sent["text"] as? String)
            XCTAssertTrue(text.contains(language == .fr ? "récupérés directement sur YouTube" : "fetched directly from YouTube"))
            XCTAssertTrue(text.contains(language == .fr ? "doublon" : "duplicate"))
        }
    }

    func testYouTubeCardForAlreadyCleanURLIsAReplyWithoutAttributionOrDeletion() async throws {
        let metadata = enableYouTubeCards()
        try replaceMode()
        let url = "https://youtu.be/dQw4w9WgXcQ?t=42"
        try await handle(["text": url, "message_thread_id": 123])
        XCTAssertEqual(metadata.requestedIDs, ["dQw4w9WgXcQ"])
        XCTAssertEqual(api.methods, ["sendPhoto"])
        let photo = api.calls[0].1
        XCTAssertEqual(photo["caption"] as? String, "YouTube\n" + metadata.title + "\n\n" + url)
        XCTAssertEqual(photo["photo"] as? String, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        XCTAssertEqual((photo["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        XCTAssertEqual(photo["message_thread_id"] as? Int64, 123)
        let entities = try decode([Entity].self, from: XCTUnwrap(photo["caption_entities"]))
        let title = try XCTUnwrap(entities.first { $0.type == "bold" })
        XCTAssertEqual(title.offset, "YouTube\n".utf16.count)
        XCTAssertEqual(title.length, metadata.title.utf16.count)
        let markup = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(photo["reply_markup"]))
        XCTAssertEqual(markup.inline_keyboard.first?.first?.text, "▶ Open YouTube")
        XCTAssertEqual(markup.inline_keyboard.first?.first?.url, url)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: photo))
    }

    func testTrackedYouTubeReplacementConfirmsPhotoAndPreservesAuthorCredit() async throws {
        let metadata = enableYouTubeCards()
        try replaceMode()
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?is=share-token&t=42"])
        XCTAssertEqual(api.methods, ["getChatMember", "sendPhoto", "deleteMessage"])
        let photo = api.calls[1].1
        XCTAssertEqual(photo["caption"] as? String, "YouTube\n" + metadata.title + "\n\nPosted by Alice\n\nhttps://youtu.be/dQw4w9WgXcQ?t=42")
        let entities = try decode([Entity].self, from: XCTUnwrap(photo["caption_entities"]))
        XCTAssertEqual(entities.first { $0.type == "text_mention" }?.offset,
                       "YouTube\n".utf16.count + metadata.title.utf16.count + 2 + "Posted by ".utf16.count)
        try store.setGroupLanguage(.fr, chatID: -100)
        api.calls = []
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?t=42"])
        let markup = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(api.calls.first?.1["reply_markup"]))
        XCTAssertEqual(markup.inline_keyboard.first?.first?.text, "▶ Ouvrir YouTube")
        XCTAssertEqual(markup.inline_keyboard.first?.first?.url, "https://youtu.be/dQw4w9WgXcQ?t=42")
    }

    func testYouTubeCardsHonorPreviewModeAndActivationChoices() async throws {
        let metadata = enableYouTubeCards()
        var settings = ChatSettings(); settings.previews = false
        try store.set(settings, chatID: -100)
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ"])
        XCTAssertTrue(api.calls.isEmpty)
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?is=share-token"])
        XCTAssertEqual(api.methods, ["sendMessage"])
        settings.previews = true; try store.set(settings, chatID: -100)
        for mode in [Mode.off, .secretary] {
            api.calls = []; try store.setMode(mode, userID: 7)
            try await handle(["text": "https://youtu.be/dQw4w9WgXcQ"])
            XCTAssertTrue(api.calls.isEmpty)
        }
        try store.setMode(nil, userID: 7); try store.setGroupEnabled(false, chatID: -100)
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ"])
        XCTAssertTrue(metadata.requestedIDs.isEmpty)
    }

    func testYouTubeCardsRespectExplicitPreviewSuppressionAndFormattedContent() async throws {
        let metadata = enableYouTubeCards()
        let url = "https://youtu.be/dQw4w9WgXcQ"
        try await handle(["text": url, "link_preview_options": ["is_disabled": true]])
        for type in ["code", "pre", "spoiler", "text_link"] {
            try await handle(["text": url, "entities": [["type": type, "offset": 0, "length": url.utf16.count]]])
        }
        try await handle(["text": url + " " + url])
        try await handle(["text": NSNull(), "caption": url])
        XCTAssertTrue(metadata.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testYouTubeMetadataFailureKeepsNormalCleaningAndLeavesCleanLinksQuiet() async throws {
        let metadata = enableYouTubeCards(); metadata.fail = true
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?is=share-token"])
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(sent["text"] as? String, "https://youtu.be/dQw4w9WgXcQ")
        api.calls = []
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ"])
        try await handle(["text": "https://example.com/clean"])
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testRejectedYouTubePhotoFallsBackButAmbiguousSendsNeverDuplicateOrDelete() async throws {
        _ = enableYouTubeCards(); try replaceMode()
        let url = "https://youtu.be/dQw4w9WgXcQ?is=share-token"
        api.photoError = BotError.telegram(400)
        try await handle(["text": url])
        XCTAssertEqual(api.methods, ["getChatMember", "sendPhoto", "sendMessage", "deleteMessage"])
        for failure in [URLError(.timedOut) as Error, BotError.invalidResponse] {
            api.calls = []; api.photoError = failure
            do { try await handle(["text": url]); XCTFail("Expected send failure") } catch { }
            XCTAssertEqual(api.methods, ["getChatMember", "sendPhoto"])
        }
        api.calls = []; api.photoError = nil; api.sendResult = ["message_id": true]
        do { try await handle(["text": url]); XCTFail("Expected malformed success failure") } catch { }
        XCTAssertEqual(api.methods, ["getChatMember", "sendPhoto"])
    }

    func testPrivateCloseDeletesOnlyPanelAndKeepsSettings() async throws {
        try store.setMode(.off, userID: 8)
        try await callback("fxclip:panel:close")
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertEqual(api.calls[0].1["chat_id"] as? Int64, 8)
        XCTAssertEqual(api.calls[0].1["message_id"] as? Int64, 42)
        XCTAssertEqual(store.state.users["8"], .off)
    }

    func testGroupCloseRequiresAdminAndMatchingGroup() async throws {
        api.admin = false
        try await callback("fxclip:chat:-100:close", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
        api.calls = []
        try await callback("fxclip:chat:-200:close", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        api.calls = []; api.admin = true; api.canDelete = false
        try await callback("fxclip:chat:-100:close", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(api.methods, ["getChatMember", "deleteMessage", "answerCallbackQuery"])
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertNil(store.state.groupEnabled["-100"])
    }

    func testPrivateCloseCannotDismissAnotherUsersPanelOrGroupPanel() async throws {
        for (chatID, type): (Int64, String) in [(7, "private"), (-100, "supergroup")] {
            api.calls = []
            try await callback("fxclip:panel:close", chatID: chatID, chatType: type)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        }
    }

    func testCloseCollapsesUndeletablePanelAndReportsEditFailure() async throws {
        api.failDelete = true
        try await callback("fxclip:panel:close", languageCode: "fr")
        XCTAssertEqual(api.methods, ["deleteMessage", "editMessageText", "answerCallbackQuery"])
        let edit = api.calls[1].1
        XCTAssertTrue((edit["text"] as? String)?.contains("Réglages fermés") == true)
        let markup = try XCTUnwrap(edit["reply_markup"] as? [String: Any])
        XCTAssertEqual(try decode(InlineKeyboardMarkup.self, from: markup).inline_keyboard.count, 0)
        api.calls = []; api.failEdit = true
        try await callback("fxclip:panel:close")
        XCTAssertEqual(api.methods, ["deleteMessage", "editMessageText", "answerCallbackQuery"])
        XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true)
        XCTAssertFalse(api.methods.contains("sendMessage"))
    }

    func testSettingsPanelsHaveLocalizedCloseButtons() throws {
        for language in [BotLanguage.en, .fr] {
            let panels = [SettingsUI.personal(mode: nil, defaultMode: .reply, owner: false, language: language),
                          SettingsUI.defaults(mode: .reply, language: language),
                          SettingsUI.languages(selected: language, detected: language),
                          SettingsUI.groups([], enabled: { _ in false }, username: "fxclipbot", language: language),
                          SettingsUI.chat(try message().chat, settings: ChatSettings(), enabled: true,
                                          inherited: true, username: "fxclipbot", language: language)]
            for panel in panels {
                let markup = try decode(InlineKeyboardMarkup.self, from: panel.markup)
                XCTAssertEqual(markup.inline_keyboard.last?.first?.text, language == .fr ? "✕ Fermer" : "✕ Close")
            }
        }
    }

    func testURLWithAtSignIsNotMistakenForBotCommand() async throws {
        try await handle(["text": "https://www.youtube.com/@chaine?utm_source=test"])
        XCTAssertEqual(sent["text"] as? String, "https://www.youtube.com/@chaine")
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

    func testReplyUsesNativeAttributionAndPreservesTextAndTopic() async throws {
        try await handle(["message_thread_id": 12])
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(sent["text"] as? String, "Look https://fxtwitter.com/a/status/1")
        XCTAssertEqual(sent["message_thread_id"] as? Int64, 12)
        XCTAssertEqual((sent["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        let entities = try decode([Entity].self, from: XCTUnwrap(sent["entities"]))
        XCTAssertFalse(entities.contains { $0.type == "text_mention" })
    }
    func testReplaceConfirmsPostBeforeDelete() async throws {
        try replaceMode(); try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
        XCTAssertNil(sent["reply_parameters"])
        XCTAssertEqual(sent["text"] as? String, "Posted by Alice\n\nLook https://fxtwitter.com/a/status/1")
        let entities = try decode([Entity].self, from: XCTUnwrap(sent["entities"]))
        let mention = try XCTUnwrap(entities.first { $0.type == "text_mention" })
        XCTAssertEqual(mention.user?.id, 7)
        XCTAssertEqual(((try XCTUnwrap(sent["text"] as? String)) as NSString).substring(with: NSRange(location: mention.offset, length: mention.length)), "Alice")
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
        XCTAssertEqual(sent["text"] as? String, "Look https://fxtwitter.com/a/status/1")
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
    func testEveryClientCleanedSharedVectorIsSilentInReplyAndReplaceModes() async throws {
        struct Vector: Decodable { let telegram: String }
        struct File: Decodable { let vectors: [Vector] }
        let vectors = try JSONDecoder().decode(File.self,
            from: Data(contentsOf: shared.appendingPathComponent("vectors.json"))).vectors
        for mode in [Mode.reply, .replace] {
            var settings = ChatSettings(); settings.mode = mode
            try store.set(settings, chatID: -100)
            for vector in vectors {
                api.calls = []
                try await handle(["text": vector.telegram])
                XCTAssertTrue(api.calls.isEmpty, "\(mode): \(vector.telegram)")
            }
        }
    }
    func testClientCleanedHiddenLinksAndCaptionsAreSilentInReplaceMode() async throws {
        try replaceMode()
        try await handle(["text": "Already shared", "entities": [[
            "type": "text_link", "offset": 0, "length": 14,
            "url": "https://fxtwitter.com/example/status/1",
        ]]])
        try await handle(["text": NSNull(), "caption": "https://zzinstagram.com/reel/example/"])
        XCTAssertTrue(api.calls.isEmpty)
    }
    func testSecretaryDoesNotEditClientCleanedPreviewLinks() async throws {
        try store.setMode(.secretary, userID: 7)
        for link in ["https://fxtwitter.com/example/status/1", "https://zzinstagram.com/reel/example/"] {
            api.calls = []
            try await handle(["text": link, "chat": ["id": 8, "type": "private"],
                              "business_connection_id": "connection"], business: true)
            XCTAssertFalse(api.methods.contains("sendMessage"))
            XCTAssertFalse(api.methods.contains("deleteMessage"))
            XCTAssertFalse(api.methods.contains("editMessageText"))
            XCTAssertFalse(api.methods.contains("editMessageCaption"))
        }
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
        XCTAssertTrue((sent["text"] as? String)?.contains("Your fxclip settings") == true)
        let markup = try XCTUnwrap(sent["reply_markup"] as? [String: Any])
        XCTAssertNil(markup["keyboard"])
        let rows = try XCTUnwrap(markup["inline_keyboard"] as? [[[String: String]]])
        let actions = Set(rows.flatMap { $0 }.compactMap { $0["callback_data"] })
        XCTAssertEqual(actions, Set(["reply", "replace", "secretary", "off", "default"].map { "fxclip:personal:\($0)" } + ["fxclip:language:show", "fxclip:panel:close", "fxclip:rules:p:show"]))
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
        ]), previews: true, language: .fr))
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

    func membership(_ fields: [String: Any], chatID: Int64 = -200, type: String = "supergroup", title: String = "Test group",
                    old: [String: Any]? = nil) async throws {
        var event: [String: Any] = [
            "chat": ["id": chatID, "type": type, "title": title], "new_chat_member": fields,
        ]
        if let old { event["old_chat_member"] = old }
        let update = try decode(Update.self, from: ["update_id": 3, "my_chat_member": event])
        try await bot.handle(update, now: 1100)
    }

    func testJoinWelcomeIsShortWithPersonalDeepLinkAndGroupButtonEvenWhenDisabled() async throws {
        try await membership(["status": "member"], old: ["status": "left"])
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(sent["chat_id"] as? Int64, -200)
        let text = try XCTUnwrap(sent["text"] as? String)
        XCTAssertLessThan(text.count, 200)
        XCTAssertEqual(text.filter { $0 == "." }.count, 2)
        XCTAssertTrue(text.contains("clean links"))
        let rows = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(sent["reply_markup"]))
        XCTAssertEqual(rows.inline_keyboard.flatMap { $0 }.map(\.text), ["⚙️ My settings", "⚙️ Group settings"])
        XCTAssertEqual(rows.inline_keyboard[0][0].url, "https://t.me/fxclipbot?start=settings")
        XCTAssertNil(rows.inline_keyboard[0][0].callback_data)
        XCTAssertEqual(rows.inline_keyboard[1][0].callback_data, "fxclip:chat:-200:show")
        XCTAssertEqual((sent["link_preview_options"] as? [String: Bool])?["is_disabled"], true)
        XCTAssertNil(store.state.groupEnabled["-200"])
    }

    func testJoinFromKickedOrRestrictedNonmemberAlsoGreets() async throws {
        for old: [String: Any] in [["status": "kicked"], ["status": "restricted", "is_member": false]] {
            api.calls = []
            try await membership(["status": "administrator"], old: old)
            XCTAssertEqual(api.methods, ["sendMessage"])
        }
    }

    func testMembershipPromotionRefreshDepartureAndMissingOldNeverGreet() async throws {
        try await membership(["status": "member"])
        try await membership(["status": "administrator"], old: ["status": "member"])
        try await membership(["status": "administrator", "can_delete_messages": true], old: ["status": "administrator"])
        try await membership(["status": "member"], old: ["status": "restricted", "is_member": true])
        try await membership(["status": "left"], old: ["status": "member"])
        try await membership(["status": "kicked"], old: ["status": "left"])
        try await membership(["status": "member"], chatID: 8, type: "private", old: ["status": "left"])
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testReservedJoinCannotGreetAgainAfterRestart() async throws {
        let update = try decode(Update.self, from: ["update_id": 12, "my_chat_member": [
            "chat": ["id": -200, "type": "group"], "old_chat_member": ["status": "left"],
            "new_chat_member": ["status": "member"],
        ]])
        if try store.reserve(update.update_id) { try await bot.handle(update) }
        let restarted = try StateStore(directory: directory)
        if try restarted.reserve(update.update_id) { try await bot.handle(update); XCTFail("Already reserved") }
        XCTAssertEqual(api.methods, ["sendMessage"])
    }

    func testDisabledGroupSetupAndFxclipPanelAreReachableWithoutStateChanges() async throws {
        try store.setGroupEnabled(false, chatID: -100)
        for command in ["/setup", "/fxclip", "/setup@fxclipbot"] {
            api.calls = []
            try await handle(["text": command])
            XCTAssertEqual(api.methods, ["sendMessage", "getChatMember", "deleteMessage"])
            XCTAssertTrue((sent["text"] as? String)?.contains("Cleaning: off") == true)
            let markup = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(sent["reply_markup"]))
            let buttons = markup.inline_keyboard.flatMap { $0 }
            XCTAssertTrue(buttons.contains { $0.callback_data == "fxclip:chat:-100:enable" })
            XCTAssertFalse(buttons.contains { $0.callback_data?.contains("secretary") == true })
            let personal = try XCTUnwrap(buttons.first { $0.url == "https://t.me/fxclipbot?start=settings" })
            XCTAssertNil(personal.callback_data)
            XCTAssertTrue(buttons.contains { $0.callback_data == "fxclip:chat:-100:lang_en" })
            XCTAssertTrue(buttons.contains { $0.callback_data == "fxclip:chat:-100:lang_fr" })
        }
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertTrue(store.state.users.isEmpty)
        XCTAssertEqual(store.state.groupEnabled["-100"], false)
        api.calls = []; try await handle()
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testAdminGroupPanelChangesOnlyItsChatAndPersists() async throws {
        var other = ChatSettings(); other.mode = .off
        try store.set(other, chatID: -300)
        try store.setMode(.reply, userID: 7)
        for action in ["show", "enable", "replace", "previews_off", "off", "reply", "disable"] {
            api.calls = []
            try await callback("fxclip:chat:-200:\(action)", userID: 8, chatID: -200, chatType: "supergroup")
            XCTAssertEqual(api.calls.first?.0, "getChatMember", action)
            XCTAssertEqual(api.calls.first?.1["user_id"] as? Int64, 8, action)
            XCTAssertTrue(api.calls.filter { $0.0 == "getChatMember" }.allSatisfy { $0.1["chat_id"] as? Int64 == -200 })
            XCTAssertEqual(api.calls.last?.1["chat_id"] as? Int64, -200, action)
            XCTAssertEqual(store.state.defaultMode, .reply)
            XCTAssertEqual(store.state.users, ["7": .reply])
            XCTAssertEqual(store.state.chats["-300"]?.mode, .off)
            XCTAssertNil(store.state.groupEnabled["-300"])
        }
        XCTAssertEqual(store.state.chats["-200"]?.mode, .reply)
        XCTAssertEqual(store.state.chats["-200"]?.previews, false)
        let restored = try StateStore(directory: directory)
        XCTAssertEqual(restored.state.groupEnabled["-200"], false)
        XCTAssertEqual(restored.state.chats["-200"]?.mode, .reply)
    }

    func testEveryLocalGroupActionRejectsNonAdminWithPersonalSettingsHint() async throws {
        api.admin = false
        for action in ["show", "enable", "disable", "reply", "replace", "off", "previews_on", "previews_off"] {
            api.calls = []
            try await callback("fxclip:chat:-200:\(action)", userID: 8, chatID: -200, chatType: "group")
            XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"], action)
            XCTAssertTrue((api.calls.last?.1["text"] as? String)?.hasPrefix("Only group admins") == true)
            XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true)
        }
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertTrue(store.state.users.isEmpty)
        XCTAssertTrue(store.state.groupEnabled.isEmpty)
    }

    func testLocalGroupCallbackChecksRevokedAdminRightsOnNextClick() async throws {
        try await callback("fxclip:chat:-200:reply", chatID: -200, chatType: "supergroup")
        api.admin = false; api.calls = []
        try await callback("fxclip:chat:-200:off", chatID: -200, chatType: "supergroup")
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
        XCTAssertEqual(store.state.chats["-200"]?.mode, .reply)
    }

    func testForgedLocalGroupTargetsAndInvalidActionsAreDeniedBeforeRemoteEffects() async throws {
        for (data, chatID, type): (String, Int64, String) in [
            ("fxclip:chat:-300:enable", -200, "supergroup"),
            ("fxclip:chat:-200:enable", -200, "private"),
            ("fxclip:chat:-200:enable", 8, "private"),
            ("fxclip:chat:-200:secretary", -200, "group"),
            ("fxclip:chat:-200:default", -200, "group"),
            ("fxclip:chat:no:enable", -200, "group"),
            ("fxclip:chat:-200:enable:extra", -200, "group"),
        ] {
            api.calls = []
            try await callback(data, chatID: chatID, chatType: type)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"], data)
        }
        XCTAssertTrue(store.state.groupEnabled.isEmpty)
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertTrue(store.state.users.isEmpty)
        XCTAssertEqual(store.state.defaultMode, .reply)
    }

    func testReplaceSelectionAndActivationKeepCurrentSettingsWithoutDeletePermission() async throws {
        api.canDelete = false
        try await callback("fxclip:chat:-200:replace", chatID: -200, chatType: "supergroup")
        XCTAssertEqual(api.methods, ["getChatMember", "getChatMember", "answerCallbackQuery"])
        XCTAssertNil(store.state.chats["-200"])
        XCTAssertTrue((api.calls.last?.1["text"] as? String)?.contains("Setting unchanged") == true)
        var settings = ChatSettings(); settings.mode = .replace
        try store.set(settings, chatID: -200)
        try store.setGroupEnabled(false, chatID: -200)
        api.calls = []
        try await callback("fxclip:chat:-200:enable", chatID: -200, chatType: "supergroup")
        XCTAssertEqual(store.state.groupEnabled["-200"], false)
        XCTAssertEqual(store.state.chats["-200"]?.mode, .replace)
        XCTAssertFalse(api.methods.contains("editMessageText"))
    }

    func testLocalGroupPermissionsFailureDoesNotMutateSettings() async throws {
        api.failMember = true
        try await callback("fxclip:chat:-200:enable", chatID: -200, chatType: "group")
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
        XCTAssertTrue(store.state.groupEnabled.isEmpty)
    }

    func testOwnerCanUseLocalPanelEvenWhenMemberLookupFails() async throws {
        api.admin = false; api.failMember = true
        try await callback("fxclip:chat:-200:enable", userID: 7, chatID: -200, chatType: "group")
        XCTAssertEqual(api.methods, ["answerCallbackQuery", "editMessageText"])
        XCTAssertEqual(store.state.groupEnabled["-200"], true)
    }

    func testPersonalPreferenceStillWinsAfterGroupAdminEnablesAndChangesMode() async throws {
        try store.setMode(.off, userID: 7)
        try await callback("fxclip:chat:-200:enable", chatID: -200, chatType: "supergroup")
        try await callback("fxclip:chat:-200:replace", chatID: -200, chatType: "supergroup")
        api.calls = []
        try await handle(["chat": ["id": -200, "type": "supergroup"]])
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(store.state.users["7"], .off)
    }

    func testLegacyGroupCommandsRemainReachableWhenDisabledAndRejectSecretary() async throws {
        try store.setGroupEnabled(false, chatID: -100)
        try await handle(["text": "/fxclip reply"])
        XCTAssertEqual(store.state.chats["-100"]?.mode, .reply)
        try await handle(["text": "/fxclip secretary"])
        XCTAssertEqual(store.state.chats["-100"]?.mode, .reply)
        XCTAssertEqual(store.state.groupEnabled["-100"], false)
    }

    func testOldDeployedStateDecodesWithoutNewFields() throws {
        let old = #"{"offset":123,"chats":{"-100":{"mode":"replace","previews":false}},"users":{"7":"off"},"defaultMode":"reply","lastUpdateAt":1000}"#
        try Data(old.utf8).write(to: directory.appendingPathComponent("state.json"))
        let restored = try StateStore(directory: directory)
        XCTAssertEqual(restored.state.offset, 123)
        XCTAssertEqual(restored.state.lastUpdateAt, 1000)
        XCTAssertEqual(restored.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(restored.state.chats["-100"]?.previews, false)
        XCTAssertEqual(restored.state.users["7"], .off)
        XCTAssertTrue(restored.state.knownGroups.isEmpty)
        XCTAssertTrue(restored.state.groupEnabled.isEmpty)
        XCTAssertTrue(restored.state.userLanguages.isEmpty)
        XCTAssertTrue(restored.state.detectedLanguages.isEmpty)
        XCTAssertTrue(restored.state.groupLanguages.isEmpty)
    }

    func testUnallowedGroupIsDiscoveredWithoutSendingOrPersistingContent() async throws {
        try await handle(["chat": ["id": -200, "type": "supergroup", "title": "Test group"],
                          "text": "secret https://x.com/a?s=1"])
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(store.state.knownGroups["-200"]?.chat.title, "Test group")
        XCTAssertNil(store.state.groupEnabled["-200"])
        let json = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("https"))
        XCTAssertEqual(try StateStore(directory: directory).state.knownGroups["-200"]?.chat.id, -200)
    }

    func testDiscoveryRunsBeforeOldProtectedBotAndEditedMessageFilters() async throws {
        try await handle(["chat": ["id": -200, "type": "group", "title": "Initial"],
                          "date": 0, "has_protected_content": true,
                          "from": ["id": 99, "first_name": "Bot", "is_bot": true]])
        let edited = try decode(Update.self, from: ["update_id": 2, "edited_message":
            jsonObject(WireMessage(message(["chat": ["id": -200, "type": "group", "title": "Renamed"]])) )])
        try await bot.handle(edited, now: 1100)
        XCTAssertEqual(store.state.knownGroups["-200"]?.chat.title, "Renamed")
        XCTAssertTrue(api.calls.isEmpty)
        try await privateCommand("/settings")
        XCTAssertNil(store.state.knownGroups["8"])
    }

    func testUnchangedDiscoveryAndMembershipDoNotRewriteStateFile() async throws {
        let rights: [String: Any] = ["status": "administrator", "can_delete_messages": false]
        try await membership(rights)
        let path = directory.appendingPathComponent("state.json").path
        let sentinel = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: path)
        try await membership(rights)
        try await handle(["chat": ["id": -200, "type": "supergroup", "title": "Test group"]])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, sentinel)
        try await membership(["status": "administrator", "can_delete_messages": true])
        XCTAssertEqual(store.state.knownGroups["-200"]?.member?.can_delete_messages, true)
    }

    func testMembershipDepartureDisablesEnvironmentDefaultAcrossRestartAndRejoin() async throws {
        for status in ["left", "kicked"] {
            try await membership(["status": "administrator", "can_delete_messages": true], chatID: -100)
            try store.setGroupEnabled(true, chatID: -100)
            try await membership(["status": status], chatID: -100)
            XCTAssertNil(store.state.knownGroups["-100"])
            XCTAssertEqual(store.state.groupEnabled["-100"], false)
            let restarted = try StateStore(directory: directory)
            bot = Bot(api: api, store: restarted, engine: engine, allowedChats: [-100], allowedOwners: [7], botID: 99, username: "fxclipbot")
            api.calls = []; try await handle()
            XCTAssertTrue(api.calls.isEmpty)
            bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7], botID: 99, username: "fxclipbot")
            try await membership(["status": "member"], chatID: -100)
            api.calls = []; try await handle()
            XCTAssertTrue(api.calls.isEmpty)
            XCTAssertEqual(store.state.groupEnabled["-100"], false)
        }
    }

    func testRestrictedNonmemberIsRemovedAndPrivateMembershipIsIgnored() async throws {
        try await membership(["status": "restricted", "is_member": false])
        XCTAssertNil(store.state.knownGroups["-200"])
        XCTAssertEqual(store.state.groupEnabled["-200"], false)
        try await membership(["status": "kicked"], chatID: 7, type: "private")
        XCTAssertNil(store.state.groupEnabled["7"])
        XCTAssertNil(store.state.knownGroups["7"])
    }

    func testOwnerGroupsCommandAndSettingsNavigation() async throws {
        try await membership(["status": "member"])
        try await privateCommand("/groups", userID: 7)
        let rows = try XCTUnwrap((sent["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: String]]])
        XCTAssertTrue(rows.flatMap { $0 }.contains { $0["callback_data"] == "fxclip:group:-200:show" })
        XCTAssertTrue((sent["text"] as? String)?.contains("Telegram does not let") == true)
        for command in ["/settings", "/default"] {
            api.calls = []; try await privateCommand(command, userID: 7)
            let markup = try XCTUnwrap((sent["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: String]]])
            XCTAssertTrue(markup.flatMap { $0 }.contains { $0["callback_data"] == "fxclip:groups:show" })
        }
        api.calls = []; try await privateCommand("/groups", userID: 8)
        XCTAssertFalse((sent["text"] as? String)?.contains("Test group") == true)
    }

    func testOwnerCanEnableDiscoveredGroupWithoutDeleteRightsThenDisableAllPersonalModes() async throws {
        try await membership(["status": "member"])
        api.admin = false
        try await callback("fxclip:group:-200:on", userID: 7, chatID: 7)
        XCTAssertEqual(store.state.groupEnabled["-200"], true)
        XCTAssertEqual(try StateStore(directory: directory).state.groupEnabled["-200"], true)
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertTrue(store.state.users.isEmpty)
        XCTAssertEqual(store.state.defaultMode, .reply)
        let rightsRequest = try XCTUnwrap(api.calls.first { $0.0 == "getChatMember" })
        XCTAssertEqual(rightsRequest.1["user_id"] as? Int64, 99)
        XCTAssertEqual(rightsRequest.1["chat_id"] as? Int64, -200)
        let text = try XCTUnwrap(api.calls.last?.1["text"] as? String)
        XCTAssertTrue(text.contains("Delete messages: not allowed"))
        XCTAssertTrue(text.contains("privacy mode"))
        XCTAssertTrue(text.contains("without deleting the original"))
        api.calls = []; try await handle(["chat": ["id": -200, "type": "supergroup"]])
        XCTAssertEqual(api.methods, ["sendMessage"])
        try await callback("fxclip:group:-200:off", userID: 7, chatID: 7)
        try store.setMode(.replace, userID: 7)
        api.calls = []; try await handle(["chat": ["id": -200, "type": "supergroup"]])
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(store.state.groupEnabled["-200"], false)
    }

    func testEveryGroupCallbackAuthenticatesOwnerAndMatchingPrivateChat() async throws {
        try await membership(["status": "member"])
        for action in ["fxclip:groups:show", "fxclip:group:-200:show", "fxclip:group:-200:refresh", "fxclip:group:-200:on", "fxclip:group:-200:off"] {
            for (userID, chatID, type): (Int64, Int64, String) in [(8, 8, "private"), (7, 8, "private"), (7, -100, "supergroup")] {
                api.calls = []
                try await callback(action, userID: userID, chatID: chatID, chatType: type)
                XCTAssertEqual(api.methods, ["answerCallbackQuery"], action)
                XCTAssertTrue(store.state.groupEnabled.isEmpty, action)
            }
        }
    }

    func testUnknownOrMalformedGroupCallbacksCannotEnableGroups() async throws {
        try await membership(["status": "member"])
        for action in ["fxclip:group:-300:on", "fxclip:group:no:on", "fxclip:group:-200:on:extra", "fxclip:group:-200:invalid", "fxclip:groups:on"] {
            api.calls = []; try await callback(action, userID: 7, chatID: 7)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"], action)
            XCTAssertTrue(store.state.groupEnabled.isEmpty, action)
        }
    }

    func testRefreshUsesCurrentRestrictedPermissionsAndNeverChangesActivation() async throws {
        try await membership(["status": "administrator", "can_delete_messages": true], title: "<b>Group & name</b>")
        api.memberResult = ["status": "restricted", "is_member": true, "can_send_messages": false,
                            "can_send_other_messages": false, "can_add_web_page_previews": false]
        try await callback("fxclip:group:-200:refresh", userID: 7, chatID: 7)
        XCTAssertTrue(store.state.groupEnabled.isEmpty)
        XCTAssertEqual(store.state.knownGroups["-200"]?.member?.status, "restricted")
        let text = try XCTUnwrap(api.calls.last?.1["text"] as? String)
        XCTAssertTrue(text.contains("&lt;b&gt;Group &amp; name&lt;/b&gt;"))
        XCTAssertTrue(text.contains("Administrator: no"))
        XCTAssertTrue(text.contains("Send messages: not allowed"))
        XCTAssertTrue(text.contains("Stickers and other messages: not allowed"))
        XCTAssertTrue(text.contains("Read: may be limited"))
        XCTAssertFalse(api.methods.contains("promoteChatMember"))
        XCTAssertFalse(api.methods.contains("restrictChatMember"))
    }

    func testRefreshDetectsDepartureAndStalePanelCannotReenable() async throws {
        try await membership(["status": "member"], chatID: -100)
        api.memberResult = ["status": "left"]
        try await callback("fxclip:group:-100:on", userID: 7, chatID: 7)
        XCTAssertNil(store.state.knownGroups["-100"])
        XCTAssertEqual(store.state.groupEnabled["-100"], false)
        api.calls = []; try await callback("fxclip:group:-100:on", userID: 7, chatID: 7)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
    }

    func testFailedRightsCheckCannotEnableButCanDisable() async throws {
        try await membership(["status": "administrator", "can_delete_messages": true])
        api.failMember = true
        try await callback("fxclip:group:-200:on", userID: 7, chatID: 7)
        XCTAssertNil(store.state.groupEnabled["-200"])
        XCTAssertTrue((api.calls.last?.1["text"] as? String)?.contains("Permissions not checked") == true)
        try store.setGroupEnabled(true, chatID: -200)
        try await callback("fxclip:group:-200:off", userID: 7, chatID: 7)
        XCTAssertEqual(store.state.groupEnabled["-200"], false)
    }

    func testDeletePermissionMatchesGroupAndSupergroupSemantics() async throws {
        try replaceMode()
        api.canDelete = false
        try await handle(["chat": ["id": -100, "type": "group"]])
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
        api.calls = []; try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage"])
        api.memberResult = ["status": "member", "can_delete_messages": true]
        api.calls = []; try await handle(["chat": ["id": -100, "type": "group"]])
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage"])
    }

    func testRefreshingUnchangedGroupPanelOnlyAcknowledgesAfterCheckingRights() async throws {
        try await membership(["status": "administrator", "can_delete_messages": true])
        try await callback("fxclip:group:-200:show", userID: 7, chatID: 7)
        let group = try XCTUnwrap(store.state.knownGroups["-200"])
        let panel = SettingsUI.group(group, enabled: false, rights: group.member)
        api.calls = []
        try await callback("fxclip:group:-200:refresh", userID: 7, chatID: 7,
                           messageText: panel.plainText, messageMarkup: panel.markup)
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
    }

    func testGroupListRefreshUpdatesChangedButtonsEvenWhenTextIsUnchanged() async throws {
        try await membership(["status": "member"])
        func currentPanel() -> SettingsUI {
            SettingsUI.groups(store.state.knownGroups.values.sorted { $0.chat.id < $1.chat.id },
                              enabled: { store.state.groupEnabled[String($0)] ?? false }, username: "fxclipbot")
        }
        var previous = currentPanel()
        for change in ["added", "renamed", "activated", "removed"] {
            switch change {
            case "added": try await membership(["status": "member"], chatID: -300, title: "Another group")
            case "renamed": try await membership(["status": "member"], title: "Renamed group")
            case "activated": try store.setGroupEnabled(true, chatID: -200)
            default: try await membership(["status": "left"], chatID: -300)
            }
            let current = currentPanel()
            XCTAssertEqual(current.plainText, previous.plainText, change)
            api.calls = []
            try await callback("fxclip:groups:show", userID: 7, chatID: 7,
                               messageText: previous.plainText, messageMarkup: previous.markup)
            XCTAssertEqual(api.methods, ["answerCallbackQuery", "editMessageText"], change)
            let actual = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(api.calls.last?.1["reply_markup"]))
            let expectedRows = try decode(InlineKeyboardMarkup.self, from: current.markup).inline_keyboard
            XCTAssertEqual(Set(actual.inline_keyboard.flatMap { $0 }.map(\.text)), Set(expectedRows.flatMap { $0 }.map(\.text)), change)
            previous = current
        }
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
    let link_preview_options: [String: Bool]?
    init(_ m: Message) {
        message_id = m.message_id; date = m.date; chat = m.chat; from = m.from; sender_chat = m.sender_chat
        text = m.text; entities = m.entities; caption = m.caption; caption_entities = m.caption_entities
        message_thread_id = m.message_thread_id; is_automatic_forward = m.is_automatic_forward
        reply_to_message = m.reply_to_message.map { ["message_id": $0.message_id] }
        has_protected_content = m.has_protected_content; is_paid_post = m.is_paid_post
        business_connection_id = m.business_connection_id; sender_business_bot = m.sender_business_bot; forward_origin = m.forward_origin
        link_preview_options = m.link_preview_options?.is_disabled.map { ["is_disabled": $0] }
    }
}
