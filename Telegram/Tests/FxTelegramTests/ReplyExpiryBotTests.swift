import Foundation
import XCTest
@testable import FxTelegram

private enum ExpiryReplyKind: CaseIterable {
    case text, photo, video

    var method: String {
        switch self {
        case .text: return "sendMessage"
        case .photo: return "sendPhoto"
        case .video: return "sendVideo"
        }
    }

    var source: String {
        switch self {
        case .text: return "https://x.com/example/status/123?utm_source=fixture"
        case .photo: return "https://youtu.be/aB3dE5fG7hI?t=12"
        case .video: return "https://www.facebook.com/reel/123456"
        }
    }
}

private final class ExpiryReelFixture: FacebookReelProviding {
    func fetch(reelID: String) async throws -> FacebookReel {
        FacebookReel(author: "Example creator", caption: "Example reel caption", video: Data([0, 1, 2, 3]))
    }
}

/// Adds precise cleanup failures without changing the shared API fixture.
private final class ExpiryFailingAPI: BotAPI {
    let base: FakeAPI
    var markupError: Error?

    init(base: FakeAPI, error: Error) {
        self.base = base
        self.markupError = error
    }

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        if method == "editMessageReplyMarkup", let markupError {
            base.calls.append((method, parameters))
            throw markupError
        }
        return try await base.call(method, parameters)
    }
}

extension BotTests {
    func testReplyExpiryFullQueueOmitsNewRemovalButtonWithoutEvictingPendingCleanup() async throws {
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.state)) as? [String: Any])
        state["replyControls"] = Dictionary(uniqueKeysWithValues: (1...4096).map { index in
            ("-100:\(index)", ["posterID": 7, "createdAt": 1000])
        })
        try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("state.json"))
        try replyExpiryRestart()
        api.sendResult = ["message_id": Int64(9000)]
        try await handle()
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertNil(sent["reply_markup"])
        XCTAssertEqual(store.state.replyControls.count, 4096)
        XCTAssertNotNil(store.state.replyControls["-100:1"])
        XCTAssertNil(store.state.replyControls["-100:9000"])
    }

    func testReplyExpiryRealClockReceiptStartsAfterSendCompletion() async throws {
        let timedAPI = ExpiryTimestampAPI(base: api)
        bot = Bot(api: timedAPI, store: store, engine: engine,
                  allowedChats: [-100], allowedOwners: [7], botID: 99, username: "fxclipbot")
        let source = try message(["date": Int(Date().timeIntervalSince1970)])
        try await bot.handle(update(source))
        let completedAt = try XCTUnwrap(timedAPI.completedAt)
        let receipt = try XCTUnwrap(store.state.replyControls["-100:42"])
        XCTAssertGreaterThanOrEqual(receipt.createdAt, completedAt)
    }

    private func replyExpiryRestart(api replacementAPI: (any BotAPI)? = nil) throws {
        store = try StateStore(directory: directory)
        bot = Bot(api: replacementAPI ?? api, store: store, engine: engine,
                  allowedChats: [-100], allowedOwners: [7], botID: 99, username: "fxclipbot")
    }

    /// Exercise the real send path so cleanup must use the IDs and keyboard it recorded.
    private func replyExpirySend(_ kind: ExpiryReplyKind = .text, messageID: Int64 = 7301,
                                 language: BotLanguage = .en) async throws -> [String: Any] {
        try store.setGroupLanguage(language, chatID: -100)
        if kind == .video { try store.setDefaultFacebookReels(true) }
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot",
                  youTubeMetadata: kind == .photo ? FakeYouTubeMetadata() : nil,
                  facebookReels: kind == .video ? ExpiryReelFixture() : nil)
        api.sendResult = ["message_id": messageID]
        api.calls = []
        try await handle(["text": kind.source, "from": fixtureUser(7, languageCode: nil)])
        XCTAssertEqual(api.methods, [kind.method])
        let parameters = try XCTUnwrap(api.calls.first?.1)
        XCTAssertEqual((parameters["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        XCTAssertNotNil(store.state.replyControls["-100:\(messageID)"])
        return parameters
    }

    private func replyExpiryRows(_ parameters: [String: Any]) throws -> [[InlineKeyboardButton]] {
        try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(parameters["reply_markup"])).inline_keyboard
    }

    private func replyExpiryAssertEdit(_ parameters: [String: Any], messageID: Int64,
                                       chatID: Int64 = -100, file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertEqual(Set(parameters.keys), ["chat_id", "message_id", "reply_markup"], file: file, line: line)
        XCTAssertEqual(parameters["chat_id"] as? Int64, chatID, file: file, line: line)
        XCTAssertEqual(parameters["message_id"] as? Int64, messageID, file: file, line: line)
    }

    private func replyExpiryCallback(messageID: Int64, markup: Any, now: Int) async throws {
        let callback = try decode(Update.self, from: ["update_id": 2, "callback_query": [
            "id": "expiry-click", "from": fixtureUser(7, languageCode: nil),
            "data": "fxclip:preview:delete", "message": [
                "message_id": messageID, "date": 1100,
                "chat": ["id": -100, "type": "supergroup"],
                "from": ["id": 99, "first_name": "fxclip", "is_bot": true],
                "reply_markup": markup,
            ],
        ]])
        try await bot.handle(callback, now: now)
    }

    func testReplyExpiryTextWaitsUntilExactlyFiveMinutesAndOnlyClearsMarkup() async throws {
        let parameters = try await replyExpirySend()
        let originalRows = try replyExpiryRows(parameters)
        XCTAssertEqual(originalRows.flatMap { $0 }.map(\.callback_data), ["fxclip:preview:delete"])
        XCTAssertNil(store.state.replyControls["-100:7301"]?.openButton)
        try replyExpiryRestart()
        api.calls = []

        try await bot.expireReplyControls(now: 1399)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertNotNil(store.state.replyControls["-100:7301"])

        try await bot.expireReplyControls(now: 1400)
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        let edit = try XCTUnwrap(api.calls.first?.1)
        replyExpiryAssertEdit(edit, messageID: 7301)
        XCTAssertTrue(try replyExpiryRows(edit).isEmpty)
        XCTAssertTrue(store.state.replyControls.isEmpty)
        XCTAssertTrue(try StateStore(directory: directory).state.replyControls.isEmpty)

        api.calls = []
        try await bot.expireReplyControls(now: 1500)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testReplyExpiryMediaAfterRestartKeepsOnlyTheExactLocalizedOpenButton() async throws {
        for kind in [ExpiryReplyKind.photo, .video] {
            for language in [BotLanguage.en, .fr] {
                let parameters = try await replyExpirySend(kind, language: language)
                let originalRows = try replyExpiryRows(parameters)
                XCTAssertEqual(originalRows.count, 2)
                let open = try XCTUnwrap(originalRows.first?.first)
                XCTAssertEqual(open.url, kind.source)
                XCTAssertNil(open.callback_data)
                XCTAssertEqual(originalRows.last?.first?.callback_data, "fxclip:preview:delete")
                XCTAssertEqual(store.state.replyControls["-100:7301"]?.openButton, open)

                try replyExpiryRestart()
                XCTAssertEqual(store.state.replyControls["-100:7301"]?.openButton, open)
                api.calls = []
                try await bot.expireReplyControls(now: 1399)
                XCTAssertTrue(api.calls.isEmpty)
                try await bot.expireReplyControls(now: 1400)

                XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
                let edit = try XCTUnwrap(api.calls.first?.1)
                replyExpiryAssertEdit(edit, messageID: 7301)
                XCTAssertEqual(try replyExpiryRows(edit), [[open]])
                XCTAssertTrue(store.state.replyControls.isEmpty)
                let persisted = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
                XCTAssertFalse(persisted.contains(kind.source))
            }
        }
    }

    func testReplyExpiryPersistsOnlyKnownOpenButtonWithoutMessageBodyOrMedia() async throws {
        for kind in ExpiryReplyKind.allCases {
            let parameters = try await replyExpirySend(kind)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with:
                Data(contentsOf: directory.appendingPathComponent("state.json"))) as? [String: Any])
            let receipts = try XCTUnwrap(state["replyControls"] as? [String: [String: Any]])
            let receipt = try XCTUnwrap(receipts["-100:7301"])
            let expectedKeys: Set<String> = kind == .text
                ? ["posterID", "createdAt"] : ["posterID", "createdAt", "openButton"]
            XCTAssertEqual(Set(receipt.keys), expectedKeys)
            if kind != .text {
                let open = try XCTUnwrap(receipt["openButton"] as? [String: Any])
                XCTAssertEqual(Set(open.keys), ["text", "url"])
                XCTAssertEqual(open["url"] as? String, kind.source)
            }
            let encoded = try String(decoding: JSONSerialization.data(withJSONObject: receipt), as: UTF8.self)
            for key in ["text", "caption", "photo", "video"] {
                if let body = parameters[key] as? String {
                    XCTAssertFalse(encoded.contains(body), "Receipt contains \(key)")
                }
            }
            try store.removeReplyControl(chatID: -100, messageID: 7301)
        }
    }

    func testReplyExpiryRemovalCallbackWorksAt299SecondsAndIsDeniedAt300() async throws {
        for kind in ExpiryReplyKind.allCases {
            let active = try await replyExpirySend(kind, messageID: 7301)
            let expired = try await replyExpirySend(kind, messageID: 7302)
            api.calls = []
            try await replyExpiryCallback(messageID: 7301, markup: XCTUnwrap(active["reply_markup"]), now: 1399)
            XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
            XCTAssertEqual(api.calls.first?.1["chat_id"] as? Int64, -100)
            XCTAssertEqual(api.calls.first?.1["message_id"] as? Int64, 7301)
            XCTAssertNil(store.state.replyControls["-100:7301"])

            api.calls = []
            try await replyExpiryCallback(messageID: 7302, markup: XCTUnwrap(expired["reply_markup"]), now: 1400)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"])
            XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true)
            XCTAssertNotNil(store.state.replyControls["-100:7302"])
        }
    }

    func testReplyExpiryTransientFailuresKeepDurableReceiptAndRetryOnlyAfter30Seconds() async throws {
        for error in [BotError.telegram(500) as Error, URLError(.timedOut)] {
            _ = try await replyExpirySend(.photo)
            let receipt = try XCTUnwrap(store.state.replyControls["-100:7301"])
            let failing = ExpiryFailingAPI(base: api, error: error)
            try replyExpiryRestart(api: failing)
            api.calls = []

            // Cleanup may report an error to its caller; the retry state must survive either policy.
            do { try await bot.expireReplyControls(now: 1400) } catch { }
            XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
            replyExpiryAssertEdit(try XCTUnwrap(api.calls.first?.1), messageID: 7301)
            XCTAssertEqual(store.state.replyControls["-100:7301"], receipt)
            XCTAssertEqual(try StateStore(directory: directory).state.replyControls["-100:7301"], receipt)

            failing.markupError = nil
            api.calls = []
            try await bot.expireReplyControls(now: 1400)
            try await bot.expireReplyControls(now: 1429)
            XCTAssertTrue(api.calls.isEmpty)
            try await bot.expireReplyControls(now: 1430)
            XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
            let edit = try XCTUnwrap(api.calls.first?.1)
            replyExpiryAssertEdit(edit, messageID: 7301)
            XCTAssertEqual(try replyExpiryRows(edit).first?.first, receipt.openButton)
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testReplyExpiryUsesSharedMarkupFailureFixtureWithoutResendingOrDeleting() async throws {
        _ = try await replyExpirySend(.video)
        api.failMarkup = true
        api.calls = []
        do { try await bot.expireReplyControls(now: 1400) } catch { }
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        XCTAssertNotNil(store.state.replyControls["-100:7301"])
        api.failMarkup = false
        api.calls = []
        try await bot.expireReplyControls(now: 1430)
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testReplyExpiryRetryBackoffBelongsToEachReceipt() async throws {
        _ = try await replyExpirySend()
        let failing = ExpiryFailingAPI(base: api, error: URLError(.timedOut))
        try replyExpiryRestart(api: failing)
        api.calls = []
        do { try await bot.expireReplyControls(now: 1400) } catch { }
        XCTAssertEqual(api.calls.compactMap { $0.1["message_id"] as? Int64 }, [7301])

        try store.recordReplyControl(chatID: -100, messageID: 7302, posterID: 7, now: 1101)
        api.calls = []
        do { try await bot.expireReplyControls(now: 1401) } catch { }
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        replyExpiryAssertEdit(try XCTUnwrap(api.calls.first?.1), messageID: 7302)

        failing.markupError = nil
        api.calls = []
        try await bot.expireReplyControls(now: 1430)
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        replyExpiryAssertEdit(try XCTUnwrap(api.calls.first?.1), messageID: 7301)
        XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:7302"])
        api.calls = []
        try await bot.expireReplyControls(now: 1431)
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        replyExpiryAssertEdit(try XCTUnwrap(api.calls.first?.1), messageID: 7302)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testReplyExpiryExplicit400And403DropReceiptWithoutDeletingOrResending() async throws {
        for code in [400, 403] {
            _ = try await replyExpirySend()
            try replyExpiryRestart(api: ExpiryFailingAPI(base: api, error: BotError.telegram(code)))
            api.calls = []
            do { try await bot.expireReplyControls(now: 1400) } catch { }
            XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
            XCTAssertTrue(store.state.replyControls.isEmpty)
            XCTAssertTrue(try StateStore(directory: directory).state.replyControls.isEmpty)
            api.calls = []
            try await bot.expireReplyControls(now: 1430)
            XCTAssertTrue(api.calls.isEmpty)
        }
    }

    func testReplyExpiryConfirmsActualJSONMessageIDRatherThanRequiringBooleanResult() async throws {
        let messageID: Int64 = 1_234_567_890_123
        _ = try await replyExpirySend(.photo, messageID: messageID)
        api.markupResult = try JSONSerialization.jsonObject(with: Data("""
            {"message_id":1234567890123,"date":1100,"chat":{"id":-100,"type":"supergroup"},
             "reply_markup":{"inline_keyboard":[[{"text":"▶ Open YouTube","url":"https://youtu.be/aB3dE5fG7hI?t=12"}]]}}
            """.utf8))
        api.calls = []
        try await bot.expireReplyControls(now: 1400)
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
        replyExpiryAssertEdit(try XCTUnwrap(api.calls.first?.1), messageID: messageID)
        XCTAssertTrue(store.state.replyControls.isEmpty)
        XCTAssertTrue(try StateStore(directory: directory).state.replyControls.isEmpty)
    }

    func testReplyExpiryUnconfirmedResultsKeepReceiptAndBackOff() async throws {
        let results: [Any] = [false, 1, ["message_id": true], ["message_id": Int64(7302)], ["ok": true]]
        for result in results {
            _ = try await replyExpirySend()
            api.markupResult = result
            api.calls = []
            do { try await bot.expireReplyControls(now: 1400) } catch { }
            XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
            XCTAssertNotNil(store.state.replyControls["-100:7301"])
            XCTAssertNotNil(try StateStore(directory: directory).state.replyControls["-100:7301"])
            api.markupResult = true
            api.calls = []
            try await bot.expireReplyControls(now: 1429)
            XCTAssertTrue(api.calls.isEmpty)
            try await bot.expireReplyControls(now: 1430)
            XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testReplyExpiryDoesNothingWithoutStoredReceiptEvenAfterRestart() async throws {
        try replyExpiryRestart()
        try await bot.expireReplyControls(now: 1400)
        try await bot.expireReplyControls(now: 2000)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testReplyExpirySameMessageIDInDifferentChatsEditsEachExactChat() async throws {
        try store.recordReplyControl(chatID: -200, messageID: 7301, posterID: 7, now: 1100)
        try store.recordReplyControl(chatID: 8, messageID: 7301, posterID: 8, now: 1101)
        try replyExpiryRestart()
        try await bot.expireReplyControls(now: 1401)
        XCTAssertEqual(api.methods, ["editMessageReplyMarkup", "editMessageReplyMarkup"])
        guard api.calls.count == 2 else { return }
        replyExpiryAssertEdit(api.calls[0].1, messageID: 7301, chatID: -200)
        replyExpiryAssertEdit(api.calls[1].1, messageID: 7301, chatID: 8)
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testReplyExpiryBatchIsLimitedTo20OldestExactStoredMessages() async throws {
        for index in (0..<25).reversed() {
            try store.recordReplyControl(chatID: -100, messageID: Int64(8000 + index),
                                        posterID: 7, now: TimeInterval(1000 + index))
        }
        try replyExpiryRestart()
        try await bot.expireReplyControls(now: 2000)
        XCTAssertEqual(api.methods, Array(repeating: "editMessageReplyMarkup", count: 20))
        XCTAssertEqual(api.calls.compactMap { $0.1["message_id"] as? Int64 }, (8000..<8020).map(Int64.init))
        for (index, call) in api.calls.enumerated() {
            replyExpiryAssertEdit(call.1, messageID: Int64(8000 + index))
        }
        XCTAssertEqual(Set(store.state.replyControls.keys), Set((8020..<8025).map { "-100:\($0)" }))
        api.calls = []
        try await bot.expireReplyControls(now: 2000)
        XCTAssertEqual(api.methods, Array(repeating: "editMessageReplyMarkup", count: 5))
        XCTAssertEqual(api.calls.compactMap { $0.1["message_id"] as? Int64 }, (8020..<8025).map(Int64.init))
        XCTAssertTrue(store.state.replyControls.isEmpty)
    }

    func testReplyExpiryMalformedReceiptKeysAreDiscardedWithoutAPICalls() async throws {
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.state)) as? [String: Any])
        let malformed = ["invalid", "-100", "-100:7301:7", "-100:not-a-message", "-100:99999999999999999999999999"]
        state["replyControls"] = Dictionary(uniqueKeysWithValues: malformed.map {
            ($0, ["posterID": 7, "createdAt": 1100])
        })
        try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("state.json"))
        try replyExpiryRestart()
        try await bot.expireReplyControls(now: 1400)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertTrue(store.state.replyControls.isEmpty)
        XCTAssertTrue(try StateStore(directory: directory).state.replyControls.isEmpty)
    }
}

private final class ExpiryTimestampAPI: BotAPI {
    let base: FakeAPI
    var completedAt: TimeInterval?
    init(base: FakeAPI) { self.base = base }
    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        let result = try await base.call(method, parameters)
        if method == "sendMessage" { completedAt = Date().timeIntervalSince1970 }
        return result
    }
}
