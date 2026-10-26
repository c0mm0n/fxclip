import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

/// Wire fixtures deliberately bypass WireMessage: source/edit metadata must survive decoding.
final class ManualReplacementBotTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!
    private var engine: Engine!
    private var api: ManualReplacementAPI!
    private var bot: Bot!
    private let receiptKey = "-100:42"
    private let remove = "fxclip:preview:delete"
    private let replace = "fxclip:preview:replace"
    private let confirm = "fxclip:preview:replace:confirm"
    private let cancel = "fxclip:preview:replace:cancel"
    private let dirty = "Look 😀 https://x.com/a/status/1?s=2"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try StateStore(directory: directory)
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared")
        engine = Engine(rules: try Rules.load(Data(contentsOf: shared.appendingPathComponent("rules.json"))))
        api = ManualReplacementAPI()
        rebuildBot()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func rebuildBot(photo: Bool = false) {
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", youTubeMetadata: photo ? ManualReplacementYouTube() : nil)
    }

    private func user(_ id: Int64 = 7, name: String = "Alice 😀", bot: Bool = false) -> [String: Any] {
        ["id": id, "first_name": name, "is_bot": bot]
    }

    private func original(_ extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["message_id": Int64(5), "date": 1000,
            "chat": ["id": Int64(-100), "type": "supergroup"], "from": user(), "text": dirty]
        result.merge(extra) { _, new in new }
        return result
    }

    private func wire<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    @discardableResult
    private func publish(_ source: [String: Any]? = nil, now: Int = 1100) async throws -> [String: Any] {
        api.calls = []
        try await bot.handle(wire(Update.self, ["update_id": 1, "message": source ?? original()]), now: now)
        for call in api.calls where ["sendMessage", "sendPhoto", "sendVideo"].contains(call.0)
            && (call.1["chat_id"] as? Int64 ?? 0) < 0 {
            XCTAssertNil(call.1["protect_content"] as? Bool,
                           "Replacement-capable replies stay shareable without account-linked credit")
        }
        return api.calls.first { ["sendMessage", "sendPhoto", "sendVideo"].contains($0.0) }?.1 ?? [:]
    }

    private func reply(_ sent: [String: Any], source: [String: Any]? = nil,
                       extra: [String: Any] = [:]) -> [String: Any] {
        var result = sent
        result.removeValue(forKey: "reply_parameters")
        result["message_id"] = Int64(42)
        result["date"] = 1100
        if sent["protect_content"] as? Bool == true { result["has_protected_content"] = true }
        result["chat"] = ["id": Int64(-100), "type": "supergroup"]
        result["from"] = user(99, name: "fxclip", bot: true)
        result["reply_to_message"] = source ?? original()
        result.merge(extra) { _, new in new }
        return result
    }

    private func click(_ action: String, message: [String: Any], actor: [String: Any]? = nil,
                       now: Int = 1101) async throws {
        api.calls = []
        let update = try wire(Update.self, ["update_id": 2, "callback_query": [
            "id": "manual-replace", "from": actor ?? user(), "data": action, "message": message]])
        try await bot.handle(update, now: now)
    }

    private func rows(_ parameters: [String: Any]) throws -> [[InlineKeyboardButton]] {
        guard let markup = parameters["reply_markup"] else { return [] }
        return try wire(InlineKeyboardMarkup.self, markup).inline_keyboard
    }

    private func stateJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("state.json"))) as? [String: Any])
    }

    private func persistedOriginal() throws -> [String: Any]? {
        let publications = try stateJSON()["publications"] as? [String: [String: Any]]
        return publications?[receiptKey]?["original"] as? [String: Any]
    }

    private func snapshot() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.state)
    }

    /// Ask through the issued button and carry Telegram's edited keyboard into confirmation.
    private func ask(_ message: [String: Any], now: Int = 1101) async throws -> [String: Any] {
        try await click(replace, message: message, now: now)
        let edit = try XCTUnwrap(api.calls.first { $0.0 == "editMessageReplyMarkup" }?.1)
        var result = message
        result["reply_markup"] = try XCTUnwrap(edit["reply_markup"])
        return result
    }

    private func assertNoDestructiveCalls(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(api.calls.contains { ["deleteMessage", "sendMessage", "sendPhoto", "sendVideo",
                                             "editMessageText", "editMessageCaption", "editMessageMedia"].contains($0.0) },
                       "Unexpected calls: \(api.methods)", file: file, line: line)
    }

    private func assertDenied(file: StaticString = #filePath, line: UInt = #line) {
        assertNoDestructiveCalls(file: file, line: line)
        XCTAssertTrue(api.calls.contains { $0.0 == "answerCallbackQuery" && $0.1["show_alert"] as? Bool == true },
                      file: file, line: line)
    }

    private func assertOriginalDeleted(file: StaticString = #filePath, line: UInt = #line) {
        for call in api.calls where ["editMessageText", "editMessageCaption"].contains(call.0) {
            XCTAssertNil(call.1["protect_content"], "Edits preserve initial protection", file: file, line: line)
        }
        let deletes = api.calls.filter { $0.0 == "deleteMessage" }
        XCTAssertEqual(deletes.count, 1, file: file, line: line)
        XCTAssertEqual(deletes.first?.1["chat_id"] as? Int64, -100, file: file, line: line)
        XCTAssertEqual(deletes.first?.1["message_id"] as? Int64, 5, file: file, line: line)
        XCTAssertFalse(api.methods.contains { $0.hasPrefix("send") || $0 == "editMessageMedia" }, file: file, line: line)
    }

    func testEligibleTextRepliesHaveTwoEqualWidthLocalizedActionsAndMinimalOriginalReceipt() async throws {
        for (language, labels) in [(BotLanguage.en, ["🗑 Remove", "🔁 Replace"]), (.fr, ["🗑 Retirer", "🔁 Remplacer"])] {
            try store.setGroupLanguage(language, chatID: -100)
            let sent = try await publish()
            let keyboard = try rows(sent)
            XCTAssertEqual(keyboard.count, 1)
            XCTAssertEqual(keyboard.last?.map(\.text), labels)
            XCTAssertEqual(keyboard.last?.compactMap(\.callback_data), [remove, replace])
            XCTAssertEqual(keyboard.last?.count, 2, "A single row gives both actions equal width")
            XCTAssertFalse(api.methods.contains("deleteMessage"))
            let metadata = try XCTUnwrap(persistedOriginal())
            XCTAssertEqual(Set(metadata.keys), ["messageID", "date"])
            XCTAssertEqual(metadata["messageID"] as? Int, 5)
            XCTAssertEqual(metadata["date"] as? Int, 1000)
            let persisted = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
            XCTAssertFalse(persisted.contains(dirty))
            XCTAssertFalse(persisted.contains("Alice"))
        }
    }

    func testPhotoReplyKeepsOnlyPairedControlsThroughAskAndCancel() async throws {
        rebuildBot(photo: true)
        let source = original(["text": "https://youtu.be/aB3_dE-fG09?si=tracking"])
        let sent = try await publish(source)
        XCTAssertTrue(api.methods.contains("sendPhoto"))
        let initialRows = try rows(sent)
        XCTAssertEqual(initialRows.count, 1)
        XCTAssertEqual(initialRows.last?.compactMap(\.callback_data), [remove, replace])
        XCTAssertTrue(initialRows.flatMap { $0 }.allSatisfy { $0.url == nil })
        let asked = try await ask(reply(sent, source: source))
        XCTAssertEqual(try rows(asked).count, 1)
        XCTAssertEqual(try rows(asked).last?.compactMap(\.callback_data), [confirm, cancel])
        try await click(cancel, message: asked)
        assertNoDestructiveCalls()
        let restored = try XCTUnwrap(api.calls.first { $0.0 == "editMessageReplyMarkup" }?.1)
        XCTAssertEqual(try rows(restored), initialRows)
        XCTAssertNotNil(try persistedOriginal())
    }

    func testPhotoManualCreditKeepsCaptionAboveMediaAndLinkedHeadingWithoutAnOpenButton() async throws {
        rebuildBot(photo: true)
        let source = original(["text": "https://youtu.be/aB3_dE-fG09?t=42"])
        let sent = try await publish(source)
        XCTAssertEqual(sent["show_caption_above_media"] as? Bool, true)
        let asked = try await ask(reply(sent, source: source))
        try await click(confirm, message: asked)
        let edit = try XCTUnwrap(api.calls.first { $0.0 == "editMessageCaption" }?.1)
        XCTAssertEqual(edit["show_caption_above_media"] as? Bool, true)
        XCTAssertTrue((edit["caption"] as? String)?.hasPrefix("Shared by Alice 😀\n\nYouTube\n") == true)
        XCTAssertTrue(try rows(edit).flatMap { $0 }.allSatisfy { $0.url == nil })
        let entities = try wire([Entity].self, XCTUnwrap(edit["caption_entities"]))
        XCTAssertEqual(entities.first { $0.type == "text_link" }?.url, "https://youtu.be/aB3_dE-fG09?t=42")
        assertOriginalDeleted()
    }

    func testFirstReplaceOnlyShowsWarningAndConfirmationWithoutConsumingOriginal() async throws {
        let sent = try await publish()
        let before = try snapshot()
        let asked = try await ask(reply(sent))
        assertNoDestructiveCalls()
        XCTAssertTrue(api.calls.contains { $0.0 == "answerCallbackQuery" && $0.1["show_alert"] as? Bool == true })
        XCTAssertEqual(try rows(asked).last?.compactMap(\.callback_data), [confirm, cancel])
        XCTAssertEqual(try snapshot(), before)
    }

    func testConfirmationMarkupAcceptsTrueOrExactMessageIDWithoutConsumingOriginal() async throws {
        for result: Any in [true, ["message_id": Int64(42)]] {
            let sent = try await publish()
            let before = try snapshot()
            api.markupResult = result
            _ = try await ask(reply(sent))
            assertNoDestructiveCalls()
            XCTAssertEqual(try snapshot(), before)
        }
    }

    func testCancellationNeverChangesContentOrOwnershipAndCanBeAskedAgain() async throws {
        let sent = try await publish()
        let before = try snapshot()
        let asked = try await ask(reply(sent))
        try await click(cancel, message: asked)
        assertNoDestructiveCalls()
        XCTAssertEqual(try snapshot(), before)
        var restored = asked
        restored["reply_markup"] = try XCTUnwrap(api.calls.first { $0.0 == "editMessageReplyMarkup" }?.1["reply_markup"])
        _ = try await ask(restored)
        assertNoDestructiveCalls()
    }

    func testConfirmationCreditsTextPreservingUTF16EntitiesAndAllPreviewOptionsBeforeExactDelete() async throws {
        for language in [BotLanguage.en, .fr] {
            try store.setGroupLanguage(language, chatID: -100)
            try store.setUserLanguage(language, userID: 7)
            let sent = try await publish()
            let body = "😀 A link and a spoiler https://example.org/"
            let spoiler = (body as NSString).range(of: "spoiler")
            let link = (body as NSString).range(of: "https://example.org/")
            let existing: [[String: Any]] = [
                ["type": "bold", "offset": 3, "length": 6],
                ["type": "spoiler", "offset": spoiler.location, "length": spoiler.length],
                ["type": "text_link", "offset": link.location, "length": link.length, "url": "https://example.org/"]]
            let preview: [String: Any] = ["is_disabled": false, "url": "https://example.org/",
                "prefer_large_media": true, "prefer_small_media": false, "show_above_text": true]
            let message = reply(sent, extra: ["text": body, "entities": existing, "link_preview_options": preview])
            let asked = try await ask(message)
            api.beforeCredit = { [self] in
                XCTAssertNil(try persistedOriginal(), "Consume must be durable before any credit edit")
            }
            try await click(confirm, message: asked)
            let edit = try XCTUnwrap(api.calls.first { $0.0 == "editMessageText" }?.1)
            XCTAssertEqual(edit["chat_id"] as? Int64, -100)
            XCTAssertEqual(edit["message_id"] as? Int64, 42)
            let credited = try XCTUnwrap(edit["text"] as? String)
            let label = language == .fr ? "Partagé par " : "Shared by "
            XCTAssertTrue(credited.hasPrefix(label + "Alice 😀"))
            XCTAssertTrue(credited.hasSuffix(body))
            let entities = try wire([Entity].self, XCTUnwrap(edit["entities"]))
            XCTAssertFalse(entities.contains { $0.user != nil || $0.type == "text_mention" })
            let prefixLength = credited.utf16.count - body.utf16.count
            for old in try wire([Entity].self, existing) {
                var shifted = old
                shifted.offset += prefixLength
                XCTAssertTrue(entities.contains(shifted), "Existing entity must survive unchanged except its UTF-16 offset")
            }
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(edit["link_preview_options"]), options: [.sortedKeys]),
                           try JSONSerialization.data(withJSONObject: preview, options: [.sortedKeys]))
            assertOriginalDeleted()
            let editIndex = try XCTUnwrap(api.methods.firstIndex(of: "editMessageText"))
            let deleteIndex = try XCTUnwrap(api.methods.firstIndex(of: "deleteMessage"))
            XCTAssertLessThan(editIndex, deleteIndex)
            XCTAssertNil(try persistedOriginal())
            XCTAssertNotNil(store.state.publications[receiptKey], "The credited bot publication remains manageable")
        }
    }

    func testPhotoAndVideoCaptionConfirmationPreservesBodyEntitiesAndMedia() async throws {
        rebuildBot(photo: true)
        for media in ["photo", "video"] {
            let source = original(["text": "https://youtu.be/aB3_dE-fG09?si=tracking"])
            let sent = try await publish(source)
            let caption = "🎬 Existing caption"
            var message = reply(sent, source: source, extra: ["text": NSNull(), "caption": caption,
                "caption_entities": [["type": "bold", "offset": 3, "length": 8]]])
            message[media] = media == "photo" ? [["file_id": "same-photo", "width": 400, "height": 300]]
                : ["file_id": "same-video", "width": 400, "height": 300, "duration": 1]
            let asked = try await ask(message)
            try await click(confirm, message: asked)
            let edit = try XCTUnwrap(api.calls.first { $0.0 == "editMessageCaption" }?.1)
            let credited = try XCTUnwrap(edit["caption"] as? String)
            XCTAssertTrue(credited.hasPrefix("Shared by Alice 😀"))
            XCTAssertTrue(credited.hasSuffix(caption))
            let entities = try wire([Entity].self, XCTUnwrap(edit["caption_entities"]))
            XCTAssertEqual(entities.first { $0.type == "bold" }?.offset, 3 + credited.utf16.count - caption.utf16.count)
            XCTAssertFalse(entities.contains { $0.user != nil || $0.type == "text_mention" })
            XCTAssertEqual(try rows(edit).flatMap { $0 }.compactMap(\.callback_data), [remove])
            XCTAssertTrue(try rows(edit).flatMap { $0 }.allSatisfy { $0.url == nil })
            XCTAssertNil(edit["media"])
            XCTAssertNil(edit["photo"])
            XCTAssertNil(edit["video"])
            assertOriginalDeleted()
        }
    }

    func testKnownForwardOriginsAreEligibleAndPublicChannelSourceIsCredited() async throws {
        let origins: [[String: Any]] = [
            ["type": "user", "date": 900, "sender_user": user(8, name: "Source user")],
            ["type": "hidden_user", "date": 900, "sender_user_name": "Visible source 😀"],
            ["type": "chat", "date": 900, "sender_chat": ["id": -200, "type": "supergroup", "title": "Source group"]],
            ["type": "channel", "date": 900, "chat": ["id": -100200, "type": "channel",
                "title": "Source channel 😀", "username": "public_source"], "message_id": 77]]
        for origin in origins {
            let source = original(["forward_origin": origin])
            let sent = try await publish(source)
            XCTAssertTrue(try rows(sent).joined().contains { $0.callback_data == replace })
            XCTAssertNotNil(try persistedOriginal())
            let asked = try await ask(reply(sent, source: source))
            try await click(confirm, message: asked)
            let edit = try XCTUnwrap(api.calls.first { $0.0 == "editMessageText" }?.1)
            let creditedEntities = try wire([Entity].self, XCTUnwrap(edit["entities"]))
            XCTAssertFalse(creditedEntities.contains { $0.user != nil || $0.type == "text_mention" })
            if origin["type"] as? String == "channel" {
                XCTAssertTrue((edit["text"] as? String)?.contains("Source channel 😀") == true)
                let entities = try wire([Entity].self, XCTUnwrap(edit["entities"]))
                XCTAssertTrue(entities.contains { $0.type == "text_link" && $0.url == "https://t.me/public_source/77" })
            }
            if origin["type"] as? String == "hidden_user" {
                XCTAssertTrue((edit["text"] as? String)?.contains("Visible source 😀") == true)
                let entities = try wire([Entity].self, XCTUnwrap(edit["entities"]))
                XCTAssertFalse(entities.contains { $0.user != nil || $0.type == "text_mention" })
                XCTAssertFalse(entities.contains { $0.type == "text_link" && $0.url?.contains("t.me/") == true })
            }
            assertOriginalDeleted()
        }
    }

    func testIneligibleOriginalsNeverReceiveReplacementAuthority() async throws {
        let excluded: [[String: Any]] = [
            ["edit_date": 1001], ["has_protected_content": true], ["is_paid_post": true],
            ["sender_chat": ["id": -100, "type": "supergroup"]], ["from": user(7, bot: true)],
            ["from": NSNull()], ["text": NSNull(), "caption": dirty],
            ["is_automatic_forward": true],
            ["forward_origin": ["type": "hidden_user", "date": 900]],
            ["forward_origin": ["type": "user", "date": 900]],
            ["forward_origin": ["type": "channel", "date": 900]],
            ["forward_origin": ["type": "future_origin", "date": 900]],
            ["chat": ["id": 7, "type": "private"]]]
        for extra in excluded {
            try store.removePublication(chatID: -100, messageID: 42)
            let sent = try await publish(original(extra))
            if !sent.isEmpty {
                XCTAssertFalse(try rows(sent).joined().contains { $0.callback_data == replace }, "\(extra)")
            }
            XCTAssertNil(try persistedOriginal(), "\(extra)")
            XCTAssertFalse(api.methods.contains("deleteMessage"))
        }
    }

    func testFreshSourceAndExactBotReceiptAreRequiredForAskAndConfirm() async throws {
        let invalidSources: [[String: Any]] = [
            ["message_id": Int64(6)], ["date": 999], ["date": 1102], ["edit_date": 1001],
            ["from": user(8)], ["from": user(7, bot: true)], ["from": NSNull()],
            ["sender_chat": ["id": -100, "type": "supergroup"]], ["has_protected_content": true],
            ["is_paid_post": true], ["text": NSNull()],
            ["forward_origin": ["type": "hidden_user", "date": 900]]]
        for extra in invalidSources {
            let sent = try await publish()
            let before = try snapshot()
            let valid = reply(sent)
            let asked = try await ask(valid)
            var invalid = asked
            invalid["reply_to_message"] = original(extra)
            try await click(confirm, message: invalid)
            assertDenied()
            XCTAssertEqual(try snapshot(), before, "Refusal must not consume a valid original: \(extra)")
            try await click(replace, message: reply(sent, source: original(extra)))
            assertDenied()
        }
    }

    func testMissingSourceKeyboardWrongMessageChatOrBotAuthorCannotAuthorizeReplacement() async throws {
        let invalid: [[String: Any]] = [
            ["reply_to_message": NSNull()], ["reply_markup": NSNull()],
            ["reply_markup": ["inline_keyboard": []]], ["message_id": Int64(43)],
            ["chat": ["id": -200, "type": "supergroup"]],
            ["from": user(98, bot: true)], ["from": user(99, bot: false)], ["from": NSNull()]]
        for extra in invalid {
            let sent = try await publish()
            let asked = try await ask(reply(sent))
            var message = asked
            message.merge(extra) { _, new in new }
            let before = try snapshot()
            try await click(confirm, message: message)
            assertDenied()
            XCTAssertEqual(try snapshot(), before, "\(extra)")
        }
    }

    func testBotReplyEditTimestampDoesNotBlockARealPendingPreview() async throws {
        let sent = try await publish()
        let asked = try await ask(reply(sent, extra: ["edit_date": 1100]))
        try await click(confirm, message: asked)
        assertOriginalDeleted()
    }

    func testFastNativeVideoWithoutCaptionCanBeCreditedInPlace() async throws {
        try store.setDefaultRedditVideos(true)
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", redditVideos: ManualReplacementReddit())
        let source = original(["text": "https://www.reddit.com/r/example/comments/abc123/example/?utm_source=fixture"])
        let sent = try await publish(source)
        XCTAssertEqual(api.methods, ["sendVideo"])
        XCTAssertEqual(try rows(sent).last?.compactMap(\.callback_data), [remove, replace])
        var message = reply(sent, source: source)
        // The outbound upload is not a Telegram wire object. Supply only Telegram's received media.
        message["video"] = ["file_id": "same-video", "width": 400, "height": 300, "duration": 1]
        let asked = try await ask(message)
        try await click(confirm, message: asked)
        let edit = try XCTUnwrap(api.calls.first { $0.0 == "editMessageCaption" }?.1)
        XCTAssertEqual(edit["caption"] as? String, "Shared by Alice 😀\n\n")
        XCTAssertNil(edit["video"])
        assertOriginalDeleted()
    }

    func testOtherPosterBotActorAndOwnerAdminBypassAreDenied() async throws {
        let source = original(["from": user(8)])
        let sent = try await publish(source)
        try await click(replace, message: reply(sent, source: source), actor: user(7))
        assertDenied()
        try await click(replace, message: reply(sent, source: source), actor: user(9))
        assertDenied()
        try await click(replace, message: reply(sent, source: source), actor: user(8, bot: true))
        assertDenied()
        XCTAssertFalse(api.calls.contains { $0.0 == "getChatMember" && $0.1["user_id"] as? Int64 != 99 })
    }

    func testRightsAreCheckedAgainOnConfirmationAndRevocationKeepsOriginal() async throws {
        let sent = try await publish()
        let asked = try await ask(reply(sent))
        for failure in [false, true] {
            api.canDelete = false
            api.memberError = failure ? BotError.telegram(403) : nil
            let before = try snapshot()
            try await click(confirm, message: asked)
            assertDenied()
            XCTAssertTrue(api.calls.contains { $0.0 == "getChatMember" && $0.1["user_id"] as? Int64 == 99 })
            XCTAssertEqual(try snapshot(), before)
        }
    }

    func testAmbiguousBooleanWrongOrNonpositiveEditIDsNeverDeleteAndConsumeAcrossRestart() async throws {
        let results: [Any] = [true, false, ["message_id": true], ["message_id": false],
            ["message_id": Int64(43)], ["message_id": 0], ["message_id": -42],
            ["message_id": "42"], ["message_id": 42.5], ["ok": true]]
        for result in results {
            let sent = try await publish()
            let asked = try await ask(reply(sent))
            api.creditResult = result
            try await click(confirm, message: asked)
            XCTAssertEqual(api.methods.filter { $0 == "editMessageText" }.count, 1)
            XCTAssertFalse(api.methods.contains("deleteMessage"), "Ambiguous edit: \(result)")
            XCTAssertNil(try persistedOriginal())
            store = try StateStore(directory: directory)
            rebuildBot()
            api.creditResult = nil
            try await click(confirm, message: asked)
            assertDenied()
        }
    }

    func testEditErrorsAreOneShotAndNeverDeleteOrResend() async throws {
        for error in [BotError.telegram(400) as Error, BotError.telegram(403), URLError(.timedOut), BotError.invalidResponse] {
            let sent = try await publish()
            let asked = try await ask(reply(sent))
            api.creditError = error
            try await click(confirm, message: asked)
            XCTAssertEqual(api.methods.filter { $0 == "editMessageText" }.count, 1)
            XCTAssertFalse(api.methods.contains("deleteMessage"))
            XCTAssertFalse(api.methods.contains { $0.hasPrefix("send") })
            XCTAssertNil(try persistedOriginal())
            api.creditError = nil
            store = try StateStore(directory: directory)
            rebuildBot()
            try await click(confirm, message: asked)
            assertDenied()
        }
    }

    func testSourceDeleteFailureKeepsCreditedBotAndNeverRetriesOriginalAfterRestart() async throws {
        let sent = try await publish()
        let asked = try await ask(reply(sent))
        api.deleteError = BotError.telegram(403)
        try await click(confirm, message: asked)
        XCTAssertTrue(api.methods.contains("editMessageText"))
        assertOriginalDeleted()
        XCTAssertNotNil(store.state.publications[receiptKey])
        XCTAssertNil(try persistedOriginal())
        api.deleteError = nil
        store = try StateStore(directory: directory)
        rebuildBot()
        try await click(confirm, message: asked)
        assertDenied()
    }

    func testSuccessfulConfirmationIsOneShotEvenWithStaleKeyboardAfterRestart() async throws {
        let sent = try await publish()
        let asked = try await ask(reply(sent))
        try await click(confirm, message: asked)
        assertOriginalDeleted()
        try await click(confirm, message: asked)
        assertDenied()
        store = try StateStore(directory: directory)
        rebuildBot()
        try await click(confirm, message: asked)
        assertDenied()
    }

    func testCoalescedConfirmationBeforeOriginalEditNeverCreditsOrDeletes() async throws {
        for photo in [false, true] {
            rebuildBot(photo: photo)
            let source = photo ? original(["text": "https://youtu.be/aB3_dE-fG09?si=tracking"]) : original()
            let sent = try await publish(source)
            let asked = try await ask(reply(sent, source: source))
            let staleConfirmation = try wire(Update.self, ["update_id": 3, "callback_query": [
                "id": "stale-confirm-before-edit", "from": user(), "data": confirm, "message": asked]])
            var changed = source
            changed["edit_date"] = 1102
            changed["text"] = try XCTUnwrap(source["text"] as? String) + "\nNew content I want to keep."
            let edited = try wire(Update.self, ["update_id": 4, "edited_message": changed])
            api.calls = []
            for update in coalesced([staleConfirmation, edited]) {
                try await bot.handle(update, now: 1103)
            }
            assertDenied()
            XCTAssertNil(try persistedOriginal())
            XCTAssertNotNil(store.state.publications[receiptKey])
            XCTAssertNotNil(store.state.replyControls[receiptKey])
        }
    }

    func testHandledOriginalEditInvalidatesStaleConfirmationAcrossRestart() async throws {
        for photo in [false, true] {
            rebuildBot(photo: photo)
            let source = photo ? original(["text": "https://youtu.be/aB3_dE-fG09?si=tracking"]) : original()
            let sent = try await publish(source)
            let asked = try await ask(reply(sent, source: source))
            var changed = source
            changed["edit_date"] = 1102
            changed["text"] = try XCTUnwrap(source["text"] as? String) + "\nNew content I want to keep."
            api.calls = []
            try await bot.handle(wire(Update.self, ["update_id": 3, "edited_message": changed]), now: 1103)
            assertNoDestructiveCalls()
            XCTAssertNil(try persistedOriginal(), "An observed source edit must retire its stored authority")
            store = try StateStore(directory: directory)
            rebuildBot(photo: photo)
            try await click(confirm, message: asked, now: 1104)
            assertDenied()
            XCTAssertNil(try persistedOriginal())
            XCTAssertNotNil(store.state.publications[receiptKey])
        }
    }

    func testCoalescedUnrelatedMessageOrOtherChatEditPreservesExactSourceAuthority() async throws {
        let unrelated: [[String: Any]] = [
            ["message_id": Int64(6)],
            ["chat": ["id": Int64(-200), "type": "supergroup"]]]
        for extra in unrelated {
            let sent = try await publish()
            let asked = try await ask(reply(sent))
            let confirmation = try wire(Update.self, ["update_id": 3, "callback_query": [
                "id": "confirm-unrelated-edit", "from": user(), "data": confirm, "message": asked]])
            var changed = original(extra)
            changed["edit_date"] = 1102
            changed["text"] = "An unrelated edited message."
            let edited = try wire(Update.self, ["update_id": 4, "edited_message": changed])
            api.calls = []
            for update in coalesced([confirmation, edited]) {
                try await bot.handle(update, now: 1103)
            }
            assertOriginalDeleted()
            XCTAssertTrue(api.methods.contains("editMessageText"))
        }
    }

    func testFiveMinuteBoundaryExpiresBothActionsAndRetiresOriginalButKeeps48HourPublication() async throws {
        rebuildBot(photo: true)
        let source = original(["text": "https://youtu.be/aB3_dE-fG09?si=tracking"])
        let sent = try await publish(source)
        let asked = try await ask(reply(sent, source: source), now: 1399)
        try await click(confirm, message: asked, now: 1400)
        assertDenied()
        try await click(remove, message: reply(sent, source: source), now: 1400)
        assertDenied()
        api.calls = []
        try await bot.expireReplyControls(now: 1400)
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        let edit = try XCTUnwrap(api.calls.first?.1)
        XCTAssertTrue(try rows(edit).isEmpty)
        XCTAssertNil(try persistedOriginal())
        XCTAssertNil(store.state.replyControls[receiptKey])
        XCTAssertNotNil(store.state.publications[receiptKey])
        store = try StateStore(directory: directory)
        XCTAssertNotNil(store.state.publications[receiptKey])
        try store.prunePublications(now: 1100 + 48 * 60 * 60 - 1)
        XCTAssertNotNil(store.state.publications[receiptKey])
        try store.prunePublications(now: 1100 + 48 * 60 * 60)
        XCTAssertNil(store.state.publications[receiptKey])
    }

    func testTextAndCaptionUTF16LimitsRefuseOverflowWithoutDeletingOriginal() async throws {
        for (field, limit, editMethod) in [("text", 4096, "editMessageText"), ("caption", 1024, "editMessageCaption")] {
            let sent = try await publish()
            let body = String(repeating: "😀", count: limit / 2)
            XCTAssertEqual(body.utf16.count, limit)
            var message = reply(sent)
            message[field] = body
            message[field == "text" ? "entities" : "caption_entities"] = []
            if field == "caption" { message["text"] = NSNull(); message["video"] = ["file_id": "keep-video"] }
            let asked = try await ask(message)
            try await click(confirm, message: asked)
            XCTAssertFalse(api.methods.contains(editMethod))
            XCTAssertFalse(api.methods.contains("deleteMessage"))
            XCTAssertFalse(api.methods.contains { $0.hasPrefix("send") })
        }
    }

    func testTextAndCaptionAcceptExactUTF16LimitIncludingEmojiCredit() async throws {
        let prefix = "Shared by Alice 😀\n\n"
        for (field, limit, editMethod) in [("text", 4096, "editMessageText"), ("caption", 1024, "editMessageCaption")] {
            let sent = try await publish()
            let available = limit - prefix.utf16.count
            let body = String(repeating: "😀", count: available / 2) + (available % 2 == 0 ? "" : "a")
            var message = reply(sent)
            message[field] = body
            message[field == "text" ? "entities" : "caption_entities"] = []
            if field == "caption" { message["text"] = NSNull(); message["video"] = ["file_id": "keep-video"] }
            let asked = try await ask(message)
            try await click(confirm, message: asked)
            let edit = try XCTUnwrap(api.calls.first { $0.0 == editMethod }?.1)
            XCTAssertEqual((edit[field] as? String)?.utf16.count, limit)
            XCTAssertEqual(edit[field] as? String, prefix + body)
            assertOriginalDeleted()
        }
    }

    func testAutomaticReplacementKeepsItsExistingSingleDeleteAction() async throws {
        var settings = ChatSettings()
        settings.mode = .replace
        try store.set(settings, chatID: -100)
        let sent = try await publish()
        XCTAssertEqual(try rows(sent).last?.count, 1)
        XCTAssertEqual(try rows(sent).last?.first?.callback_data, remove)
        XCTAssertEqual(try rows(sent).last?.first?.text, "🗑 Delete my message")
        XCTAssertNil(try persistedOriginal())
        XCTAssertTrue(api.methods.contains("deleteMessage"))
    }
}

/// No network and no shared FakeAPI defaults: content edits return exact Telegram IDs.
private final class ManualReplacementAPI: BotAPI {
    var calls: [(String, [String: Any])] = []
    var canDelete = true
    var memberError: Error?
    var creditError: Error?
    var deleteError: Error?
    var creditResult: Any?
    var markupResult: Any?
    var beforeCredit: (() throws -> Void)?
    var methods: [String] { calls.map(\.0) }

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters))
        switch method {
        case "sendMessage", "sendPhoto", "sendVideo":
            return try exactMessage(42)
        case "getChatMember":
            if let memberError { throw memberError }
            return ["status": "administrator", "can_delete_messages": canDelete]
        case "editMessageText", "editMessageCaption":
            try beforeCredit?()
            if let creditError { throw creditError }
            return try creditResult ?? exactMessage(try XCTUnwrap(parameters["message_id"] as? Int64))
        case "editMessageReplyMarkup":
            return try markupResult ?? exactMessage(try XCTUnwrap(parameters["message_id"] as? Int64))
        case "deleteMessage":
            if let deleteError { throw deleteError }
            return true
        case "answerCallbackQuery": return true
        default:
            XCTFail("Unexpected API operation: \(method)")
            throw BotError.invalidResponse
        }
    }

    private func exactMessage(_ id: Int64) throws -> Any {
        try JSONSerialization.jsonObject(with: Data("{\"message_id\":\(id)}".utf8))
    }
}

private final class ManualReplacementYouTube: YouTubeMetadataProviding {
    func fetch(videoID: String) async throws -> YouTubeMetadata {
        YouTubeMetadata(title: "A video 😀", thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!)
    }
}

private final class ManualReplacementReddit: RedditVideoProviding {
    func fetch(postID: String) async throws -> Data {
        Data([0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0])
    }
}
