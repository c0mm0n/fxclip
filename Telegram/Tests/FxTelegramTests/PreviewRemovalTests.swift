import Foundation
import XCTest
@testable import FxTelegram

extension BotTests {
    private func previewRemovalButtons(_ parameters: [String: Any]) throws -> [InlineKeyboardButton] {
        guard let markup = parameters["reply_markup"] else { return [] }
        return try decode(InlineKeyboardMarkup.self, from: markup).inline_keyboard.flatMap { $0 }
    }

    private func previewRemovalCallback(_ data: String = "fxclip:preview:delete", userID: Int64 = 7,
                                        actorIsBot: Bool = false, chatID: Int64 = -100,
                                        messageID: Int64 = 42, authorID: Int64? = 99,
                                        authorIsBot: Bool = true, includeMessage: Bool = true,
                                        messageMarkup: [String: Any]? = nil, includeMarkup: Bool = true,
                                        now: Int = 1100) async throws {
        var actor = fixtureUser(userID, languageCode: nil)
        actor["is_bot"] = actorIsBot
        var callback: [String: Any] = ["id": "remove-preview", "from": actor, "data": data]
        if includeMessage {
            var message: [String: Any] = ["message_id": messageID, "date": 1000,
                "chat": ["id": chatID, "type": "supergroup"]]
            if let authorID {
                message["from"] = ["id": authorID, "first_name": "fxclip", "is_bot": authorIsBot]
            }
            if includeMarkup {
                message["reply_markup"] = messageMarkup ?? ["inline_keyboard": [[[
                    "text": "🗑 Remove preview", "callback_data": "fxclip:preview:delete",
                ]]]]
            }
            // No reply_to_message: removal must not depend on the original still existing.
            callback["message"] = message
        }
        let update = try decode(Update.self, from: ["update_id": 3, "callback_query": callback])
        try await bot.handle(update, now: now)
    }

    private func previewRemovalAssertDenied(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(api.methods, ["answerCallbackQuery"], file: file, line: line)
        XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true, file: file, line: line)
        XCTAssertNotNil(store.state.replyControls["-100:42"], file: file, line: line)
    }

    private func previewRemovalLoadControls(_ controls: [String: [String: Any]]) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.state)) as? [String: Any])
        json["replyControls"] = controls
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("state.json"))
        store = try StateStore(directory: directory)
    }

    private func previewRemovalStateSnapshot() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.state)
    }

    private func previewRemovalOtherPosterMarkup() async throws -> [String: Any] {
        try await handle(["from": fixtureUser(8, languageCode: nil)])
        let markup = try XCTUnwrap(sent["reply_markup"] as? [String: Any])
        var settings = ChatSettings()
        settings.mode = .replace
        settings.previews = false
        settings.engineSettings = .init()
        settings.engineSettings?.trackersEverywhere = false
        try store.set(settings, chatID: -100)
        return markup
    }

    private func previewRemovalAssertForgedSettingsDenied(markup: [String: Any], now: Int = 1100,
                                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try previewRemovalStateSnapshot()
        api.admin = true
        for actor: Int64 in [7, 9] {
            for data in ["fxclip:chat:-100:close", "fxclip:chat:-100:show", "fxclip:rules:c:-100:reset"] {
                api.calls = []
                try await previewRemovalCallback(data, userID: actor, messageMarkup: markup, now: now)
                XCTAssertEqual(api.methods, ["answerCallbackQuery"], "actor \(actor): \(data)", file: file, line: line)
                XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true, file: file, line: line)
                XCTAssertEqual(try previewRemovalStateSnapshot(), before, "actor \(actor): \(data)", file: file, line: line)
            }
        }
    }

    func testPreviewRemovalIssuedKeyboardRejectsForgedSettingsActionsFromOwnerAndAdmin() async throws {
        let markup = try await previewRemovalOtherPosterMarkup()
        try await previewRemovalAssertForgedSettingsDenied(markup: markup)
        XCTAssertEqual(store.state.replyControls["-100:42"]?.posterID, 8)
    }

    func testPreviewRemovalIssuedKeyboardRejectsForgedSettingsAfterControlRemoval() async throws {
        let markup = try await previewRemovalOtherPosterMarkup()
        try store.removeReplyControl(chatID: -100, messageID: 42)
        try await previewRemovalAssertForgedSettingsDenied(markup: markup)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testPreviewRemovalIssuedKeyboardRejectsForgedSettingsAfterExpiryPruning() async throws {
        let markup = try await previewRemovalOtherPosterMarkup()
        let expiredAt = 1100 + 48 * 60 * 60
        try store.pruneReplyControls(now: TimeInterval(expiredAt))
        XCTAssertTrue(store.state.replyControls.isEmpty)
        try await previewRemovalAssertForgedSettingsDenied(markup: markup, now: expiredAt)
    }

    func testPreviewRemovalDirectWireRejectsMissingKeyboardAndNonBotMessage() async throws {
        let markup = try await previewRemovalOtherPosterMarkup()
        let before = try previewRemovalStateSnapshot()
        for data in ["fxclip:preview:delete", "fxclip:chat:-100:close", "fxclip:chat:-100:show",
                     "fxclip:rules:c:-100:reset"] {
            api.calls = []
            try await previewRemovalCallback(data, userID: 8, includeMarkup: false)
            try previewRemovalAssertDenied()
            XCTAssertEqual(try previewRemovalStateSnapshot(), before)
        }
        api.calls = []
        try await previewRemovalCallback(userID: 8, authorID: 8, authorIsBot: false, messageMarkup: markup)
        try previewRemovalAssertDenied()
        XCTAssertEqual(try previewRemovalStateSnapshot(), before)
    }

    func testPreviewRemovalCopiedDeleteButtonNeedsControlForExactBotMessage() async throws {
        let markup = try await previewRemovalOtherPosterMarkup()
        let before = try previewRemovalStateSnapshot()
        api.calls = []
        try await previewRemovalCallback(userID: 8, messageID: 43, messageMarkup: markup)
        try previewRemovalAssertDenied()
        XCTAssertEqual(try previewRemovalStateSnapshot(), before)
        api.calls = []
        try await previewRemovalCallback(userID: 8, messageMarkup: markup)
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertEqual(api.calls.first?.1["message_id"] as? Int64, 42)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testPreviewRemovalTextReplyHasLocalizedButtonAndMinimalReceipt() async throws {
        for (language, label) in [(BotLanguage.en, "🗑 Remove preview"), (.fr, "🗑 Retirer l’aperçu")] {
            try store.setGroupLanguage(language, chatID: -100)
            api.calls = []
            try await handle()
            XCTAssertEqual(api.methods, ["sendMessage"])
            XCTAssertEqual((sent["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
            let buttons = try previewRemovalButtons(sent)
            XCTAssertEqual(buttons.count, 1)
            XCTAssertEqual(buttons.first?.text, label)
            XCTAssertEqual(buttons.first?.callback_data, "fxclip:preview:delete")
            XCTAssertNil(buttons.first?.url)
            XCTAssertEqual(store.state.replyControls["-100:42"]?.posterID, 7)
            XCTAssertEqual(store.state.replyControls["-100:42"]?.createdAt, 1100)
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("state.json"))) as? [String: Any])
        let controls = try XCTUnwrap(json["replyControls"] as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(controls["-100:42"]).keys), ["posterID", "createdAt"])
        let persisted = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("https://"))
        XCTAssertFalse(persisted.contains("Look "))
    }

    func testPreviewRemovalYouTubeReplyKeepsOpenActionAndAddsSecondRow() async throws {
        _ = enableYouTubeCards()
        try replaceMode() // An already clean YouTube URL is still an actual reply.
        for (language, label) in [(BotLanguage.en, "🗑 Remove preview"), (.fr, "🗑 Retirer l’aperçu")] {
            try store.setGroupLanguage(language, chatID: -100)
            api.calls = []
            try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?t=42"])
            XCTAssertEqual(api.methods, ["sendPhoto"])
            let photo = try XCTUnwrap(api.calls.first?.1)
            let rows = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(photo["reply_markup"])).inline_keyboard
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.first?.first?.url, "https://youtu.be/dQw4w9WgXcQ?t=42")
            XCTAssertEqual(rows.first?.first?.text, language == .fr ? "▶ Ouvrir YouTube" : "▶ Open YouTube")
            XCTAssertEqual(rows.last?.first?.text, label)
            XCTAssertEqual(rows.last?.first?.callback_data, "fxclip:preview:delete")
            XCTAssertEqual(store.state.replyControls["-100:42"]?.posterID, 7)
        }
    }

    func testPreviewRemovalOnlyPosterDeletesBotReplyAndRepeatedClickIsStale() async throws {
        try await handle()
        api.calls = []
        try await previewRemovalCallback()
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertEqual(api.calls.first?.1["chat_id"] as? Int64, -100)
        XCTAssertEqual(api.calls.first?.1["message_id"] as? Int64, 42)
        XCTAssertNil(api.calls.last?.1["text"])
        XCTAssertNil(store.state.replyControls["-100:42"])
        XCTAssertTrue(try StateStore(directory: directory).state.replyControls.isEmpty)
        XCTAssertFalse(api.calls.contains { $0.0 == "deleteMessage" && $0.1["message_id"] as? Int64 == 5 })
        api.calls = []
        try await previewRemovalCallback()
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true)
    }

    func testPreviewRemovalNonPosterCannotDeleteEvenAsGroupAdmin() async throws {
        try await handle()
        api.admin = true
        api.calls = []
        try await previewRemovalCallback(userID: 8)
        try previewRemovalAssertDenied()
    }

    func testPreviewRemovalOwnerCannotOverrideAnotherPoster() async throws {
        try await handle(["from": fixtureUser(8, languageCode: nil)])
        api.calls = []
        try await previewRemovalCallback(userID: 7)
        try previewRemovalAssertDenied()
        api.calls = []
        try await previewRemovalCallback(userID: 8)
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
    }

    func testPreviewRemovalRejectsBotActorsAndWrongOrMissingMessageAuthor() async throws {
        try await handle()
        api.calls = []
        try await previewRemovalCallback(actorIsBot: true)
        try previewRemovalAssertDenied()
        for authorID: Int64? in [98, 7, nil] {
            api.calls = []
            try await previewRemovalCallback(authorID: authorID)
            try previewRemovalAssertDenied()
        }
        api.calls = []
        try await previewRemovalCallback(includeMessage: false)
        try previewRemovalAssertDenied()
    }

    func testPreviewRemovalRejectsCrossChatAndMessageForgery() async throws {
        try await handle()
        for (chatID, messageID): (Int64, Int64) in [(-200, 42), (-100, 43), (-100, 5)] {
            api.calls = []
            try await previewRemovalCallback(chatID: chatID, messageID: messageID)
            try previewRemovalAssertDenied()
        }
    }

    func testPreviewRemovalRejectsForgedActorDataAndExtraComponents() async throws {
        try await handle()
        for data in ["fxclip:preview:delete:7", "fxclip:preview:delete:8", "fxclip:preview:delete:",
                     "fxclip:preview:delete:-100:42:7", "fxclip:preview:delete:extra",
                     "fxclip:preview:delete::", "fxclip:preview:delete "] {
            api.calls = []
            try await previewRemovalCallback(data)
            try previewRemovalAssertDenied()
        }
    }

    func testPreviewRemovalDeleteFailureAlertsAndPreservesReceiptForRetry() async throws {
        try await handle()
        api.failDelete = true
        api.calls = []
        try await previewRemovalCallback()
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertEqual(api.calls.first?.1["message_id"] as? Int64, 42)
        XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true)
        XCTAssertNotNil(store.state.replyControls["-100:42"])
        XCTAssertNotNil(try StateStore(directory: directory).state.replyControls["-100:42"])
        api.failDelete = false
        api.calls = []
        try await previewRemovalCallback()
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testPreviewRemovalReceiptSurvivesRestartWithSyntheticClock() async throws {
        try store.recordReplyControl(chatID: -100, messageID: 42, posterID: 8, now: 1000)
        store = try StateStore(directory: directory)
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot")
        try await previewRemovalCallback(userID: 7, now: 1100)
        try previewRemovalAssertDenied()
        api.calls = []
        try await previewRemovalCallback(userID: 8, now: 1100)
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
    }

    func testPreviewRemovalExpiredReceiptCannotDeleteBeforeExplicitPruning() async throws {
        try store.recordReplyControl(chatID: -100, messageID: 42, posterID: 7, now: 1000)
        try await previewRemovalCallback(now: 1000 + 48 * 60 * 60)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true)
    }

    func testPreviewRemovalExplicitPruneUses48HourBoundaryAndPersists() throws {
        let now: TimeInterval = 200_000
        try previewRemovalLoadControls([
            "-100:40": ["posterID": 7, "createdAt": now - 48 * 60 * 60 - 1],
            "-100:41": ["posterID": 7, "createdAt": now - 48 * 60 * 60],
            "-100:42": ["posterID": 8, "createdAt": now - 48 * 60 * 60 + 1],
        ])
        try store.pruneReplyControls(now: now)
        XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:42"])
        XCTAssertEqual(try StateStore(directory: directory).state.replyControls, store.state.replyControls)
    }

    func testPreviewRemovalRecordCaps4096ControlsAndRetainsNewReceipt() throws {
        var controls: [String: [String: Any]] = [:]
        for id in 1...4096 {
            controls["-100:\(id)"] = ["posterID": 7, "createdAt": TimeInterval(id)]
        }
        try previewRemovalLoadControls(controls)
        try store.recordReplyControl(chatID: -100, messageID: 5000, posterID: 8, now: 5000)
        XCTAssertEqual(store.state.replyControls.count, 4096)
        XCTAssertNil(store.state.replyControls["-100:1"])
        XCTAssertEqual(store.state.replyControls["-100:5000"]?.posterID, 8)
        XCTAssertEqual(try StateStore(directory: directory).state.replyControls.count, 4096)
    }

    func testPreviewRemovalLegacyStateDefaultsToEmptyControls() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.state)) as? [String: Any])
        json.removeValue(forKey: "replyControls")
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("state.json"))
        XCTAssertTrue(try StateStore(directory: directory).state.replyControls.isEmpty)
    }

    func testPreviewRemovalActualReplacementHasNoButtonOrReceipt() async throws {
        try replaceMode()
        try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
        XCTAssertTrue(try previewRemovalButtons(sent).isEmpty)
        XCTAssertTrue(store.state.replyControls.isEmpty)
        _ = enableYouTubeCards()
        api.calls = []
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?si=tracking"])
        XCTAssertEqual(api.methods, ["getChatMember", "sendPhoto", "deleteMessage"])
        let buttons = try previewRemovalButtons(XCTUnwrap(api.calls.first { $0.0 == "sendPhoto" }?.1))
        XCTAssertEqual(buttons.count, 1)
        XCTAssertNotNil(buttons.first?.url)
        XCTAssertNil(buttons.first?.callback_data)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testPreviewRemovalReplacementDeleteFailureKeepsOriginalWithoutReplyControl() async throws {
        try replaceMode()
        api.failDelete = true
        try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
        XCTAssertEqual(api.calls.last?.1["message_id"] as? Int64, 5)
        XCTAssertTrue(try previewRemovalButtons(sent).isEmpty)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testPreviewRemovalReplacementWithoutDeleteRightsIsControllableReply() async throws {
        try replaceMode()
        api.canDelete = false
        try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage"])
        XCTAssertEqual(try previewRemovalButtons(sent).first?.callback_data, "fxclip:preview:delete")
        XCTAssertEqual(store.state.replyControls["-100:42"]?.posterID, 7)
    }

    func testPreviewRemovalAnonymousOrUnidentifiedSourcesHaveNoControl() async throws {
        for source: [String: Any] in [
            ["sender_chat": ["id": -100, "type": "supergroup"]],
            ["from": NSNull()],
            ["from": ["id": 7, "first_name": "Unknown"]],
        ] {
            api.calls = []
            try await handle(source)
            XCTAssertEqual(api.methods, ["sendMessage"])
            XCTAssertTrue(try previewRemovalButtons(sent).isEmpty)
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testPreviewRemovalSettingsAndSecretaryNeverReceiveControls() async throws {
        try await privateCommand("/settings", userID: 7)
        for call in api.calls {
            XCTAssertFalse(try previewRemovalButtons(call.1).contains { $0.callback_data == "fxclip:preview:delete" })
        }
        XCTAssertTrue(store.state.replyControls.isEmpty)
        try store.setMode(.secretary, userID: 7)
        api.calls = []
        try await handle(["chat": ["id": 8, "type": "private"], "business_connection_id": "connection"], business: true)
        XCTAssertEqual(api.methods, ["getBusinessConnection", "editMessageText"])
        XCTAssertNil(api.calls.last?.1["reply_markup"])
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testPreviewRemovalPhotoAndRejectedPhotoFallbackUseConfirmedReceiptID() async throws {
        _ = enableYouTubeCards()
        api.sendResult = ["message_id": Int64(81)]
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?si=tracking"])
        XCTAssertEqual(api.methods, ["sendPhoto"])
        XCTAssertEqual(store.state.replyControls["-100:81"]?.posterID, 7)
        XCTAssertNil(store.state.replyControls["-100:42"])
        api.photoError = BotError.telegram(400)
        api.sendResult = ["message_id": Int64(82)]
        api.calls = []
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?si=tracking"])
        XCTAssertEqual(api.methods, ["sendPhoto", "sendMessage"])
        XCTAssertEqual(try previewRemovalButtons(sent).first?.callback_data, "fxclip:preview:delete")
        XCTAssertEqual(store.state.replyControls["-100:82"]?.posterID, 7)
        api.calls = []
        try await previewRemovalCallback(messageID: 82)
        XCTAssertEqual(api.calls.first?.1["message_id"] as? Int64, 82)
        XCTAssertNotNil(store.state.replyControls["-100:81"])
        XCTAssertNil(store.state.replyControls["-100:82"])
        api.calls = []
        try await previewRemovalCallback(messageID: 81)
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertEqual(api.calls.first?.1["message_id"] as? Int64, 81)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testPreviewRemovalMalformedTextAndPhotoReceiptsAreNeverRecorded() async throws {
        for photo in [false, true] {
            if photo { _ = enableYouTubeCards() }
            for json in [#"{}"#, #"true"#, #"null"#, #"{"message_id":true}"#, #"{"message_id":false}"#,
                         #"{"message_id":"42"}"#, #"{"message_id":0}"#, #"{"message_id":-1}"#,
                         #"{"message_id":42.5}"#, #"{"message_id":null}"#] {
                api.calls = []
                api.sendResult = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
                do {
                    try await handle(photo ? ["text": "https://youtu.be/dQw4w9WgXcQ?si=tracking"] : [:])
                    XCTFail("Expected invalid receipt: \(json)")
                } catch BotError.invalidResponse {} catch {
                    XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(api.methods, [photo ? "sendPhoto" : "sendMessage"], json)
                XCTAssertTrue(store.state.replyControls.isEmpty, json)
            }
        }
    }

    func testPreviewRemovalAmbiguousSendDoesNotRecordControl() async throws {
        api.failSend = true
        do { try await handle(); XCTFail("Expected send failure") } catch {}
        XCTAssertTrue(store.state.replyControls.isEmpty)
        XCTAssertFalse(api.methods.contains("deleteMessage"))
        _ = enableYouTubeCards()
        api.photoError = URLError(.timedOut)
        api.calls = []
        do {
            try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?si=tracking"])
            XCTFail("Expected photo failure")
        } catch {}
        XCTAssertEqual(api.methods, ["sendPhoto"])
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }
}
