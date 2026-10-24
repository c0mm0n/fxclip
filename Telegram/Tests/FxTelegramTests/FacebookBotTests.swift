import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

private final class BotFacebookReelFixture: FacebookReelProviding {
    var requestedIDs: [String] = []
    var error: Error?
    var author = "Example creator 😀"
    var caption = "A short example caption."
    let video = Data([0, 1, 2, 3, 255])

    func fetch(reelID: String) async throws -> FacebookReel {
        requestedIDs.append(reelID)
        if let error { throw error }
        return FacebookReel(author: author, caption: caption, video: video)
    }
}

extension BotTests {
    private var facebookCleanURL: String { "https://www.facebook.com/reel/123456" }
    private var facebookDirtyURL: String { facebookCleanURL + "?utm_source=share&mibextid=tracking&rdid=tracking" }

    private func facebookProvider(enabled: Bool = true) throws -> BotFacebookReelFixture {
        let provider = BotFacebookReelFixture()
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", facebookReels: provider)
        if enabled { try store.setDefaultFacebookReels(true) }
        return provider
    }

    private func facebookHandle(_ url: String? = nil, extra: [String: Any] = [:]) async throws {
        var fixture: [String: Any] = ["text": url ?? facebookCleanURL,
                                      "from": ["id": 7, "first_name": "Member", "is_bot": false]]
        fixture.merge(extra) { _, new in new }
        try await handle(fixture)
    }

    private func facebookVideo() throws -> [String: Any] {
        try XCTUnwrap(api.calls.first { $0.0 == "sendVideo" }?.1)
    }

    private func facebookButtons(_ parameters: [String: Any]) throws -> [InlineKeyboardButton] {
        try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(parameters["reply_markup"]))
            .inline_keyboard.flatMap { $0 }
    }

    private func facebookStateSnapshot() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.state)
    }

    func testFacebookAlreadyCleanReelUploadsBytesAndRepliesEvenInReplaceMode() async throws {
        let provider = try facebookProvider()
        try replaceMode()
        try facebookHandleSettingsLanguage(.en)
        try await facebookHandle(extra: ["message_thread_id": 123])
        XCTAssertEqual(provider.requestedIDs, ["123456"])
        XCTAssertEqual(api.methods, ["sendVideo"])
        let video = try facebookVideo()
        XCTAssertEqual((video["video"] as? VideoUpload)?.data, provider.video)
        XCTAssertEqual(video["chat_id"] as? Int64, -100)
        XCTAssertEqual(video["message_thread_id"] as? Int64, 123)
        XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        XCTAssertEqual(video["disable_notification"] as? Bool, true)
        let caption = try XCTUnwrap(video["caption"] as? String)
        XCTAssertTrue(caption.hasPrefix("Facebook\n"))
        XCTAssertTrue(caption.contains(provider.author))
        XCTAssertTrue(caption.contains(provider.caption))
        XCTAssertTrue(caption.hasSuffix(facebookCleanURL))
        XCTAssertFalse(caption.contains("Posted by"))
        XCTAssertLessThanOrEqual(caption.utf16.count, 1024)
        let entities = try decode([Entity].self, from: XCTUnwrap(video["caption_entities"]))
        let author = try XCTUnwrap(entities.first { $0.type == "bold" })
        XCTAssertEqual((caption as NSString).substring(with: NSRange(location: author.offset, length: author.length)), provider.author)
        let buttons = try facebookButtons(video)
        XCTAssertTrue(buttons.contains { $0.url == facebookCleanURL && $0.text.contains("Open Facebook") })
        XCTAssertEqual(buttons.last?.callback_data, "fxclip:preview:delete")
        XCTAssertEqual(store.state.replyControls["-100:42"]?.posterID, 7)
    }

    private func facebookHandleSettingsLanguage(_ language: BotLanguage) throws {
        try store.setGroupLanguage(language, chatID: -100)
    }

    func testFacebookDirtyReplacementWaitsForConfirmedVideoAndCreditsOriginalSender() async throws {
        _ = try facebookProvider()
        try replaceMode()
        api.sendResult = try JSONSerialization.jsonObject(with: Data(#"{"message_id":1234567890123}"#.utf8))
        try await facebookHandle(facebookDirtyURL, extra: ["reply_to_message": ["message_id": 3]])
        XCTAssertEqual(api.methods, ["getChatMember", "sendVideo", "deleteMessage"])
        let video = try facebookVideo()
        let caption = try XCTUnwrap(video["caption"] as? String)
        XCTAssertTrue(caption.contains("Posted by Member"))
        XCTAssertTrue(caption.hasSuffix(facebookCleanURL))
        XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 3)
        let entities = try decode([Entity].self, from: XCTUnwrap(video["caption_entities"]))
        let credit = try XCTUnwrap(entities.first { $0.type == "text_mention" })
        XCTAssertEqual(credit.user?.id, 7)
        XCTAssertEqual((caption as NSString).substring(with: NSRange(location: credit.offset, length: credit.length)), "Member")
        XCTAssertFalse(try facebookButtons(video).contains { $0.callback_data == "fxclip:preview:delete" })
        XCTAssertTrue(store.state.replyControls.isEmpty)
        XCTAssertEqual(api.calls.last?.1["message_id"] as? Int64, 5)
    }

    func testFacebookMissingDeletePermissionTurnsReplacementIntoControllableReply() async throws {
        _ = try facebookProvider()
        try replaceMode()
        api.canDelete = false
        try await facebookHandle(facebookDirtyURL)
        XCTAssertEqual(api.methods, ["getChatMember", "sendVideo"])
        let video = try facebookVideo()
        XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        XCTAssertFalse((video["caption"] as? String ?? "").contains("Posted by"))
        XCTAssertEqual(try facebookButtons(video).last?.callback_data, "fxclip:preview:delete")
        XCTAssertEqual(store.state.replyControls["-100:42"]?.posterID, 7)
    }

    func testFacebookVideoRemovalUsesConfirmedReceiptAndOnlyOriginalSenderCanRemove() async throws {
        _ = try facebookProvider()
        api.sendResult = ["message_id": Int64(84)]
        try await facebookHandle()
        XCTAssertNil(store.state.replyControls["-100:42"])
        XCTAssertEqual(store.state.replyControls["-100:84"]?.posterID, 7)
        let markup = try XCTUnwrap(facebookVideo()["reply_markup"])
        func remove(userID: Int64, messageID: Int64) async throws {
            let update = try decode(Update.self, from: ["update_id": 3, "callback_query": [
                "id": "remove-video", "from": fixtureUser(userID, languageCode: nil),
                "data": "fxclip:preview:delete", "message": ["message_id": messageID, "date": 1000,
                    "chat": ["id": -100, "type": "supergroup"],
                    "from": ["id": 99, "first_name": "fxclip", "is_bot": true], "reply_markup": markup],
            ]])
            try await bot.handle(update, now: 1100)
        }
        api.calls = []
        try await remove(userID: 8, messageID: 84)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true)
        XCTAssertNotNil(store.state.replyControls["-100:84"])
        api.calls = []
        try await remove(userID: 7, messageID: 42)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        api.calls = []
        try await remove(userID: 7, messageID: 84)
        XCTAssertEqual(api.methods, ["deleteMessage", "answerCallbackQuery"])
        XCTAssertEqual(api.calls.first?.1["message_id"] as? Int64, 84)
        XCTAssertNil(store.state.replyControls["-100:84"])
    }

    func testFacebookFrenchButtonPointsToEngineCleanedSourceAndKeepsMeaningfulParams() async throws {
        _ = try facebookProvider()
        try facebookHandleSettingsLanguage(.fr)
        let source = facebookDirtyURL + "&t=12#part"
        try await facebookHandle(source)
        let clean = engine.clean(source).text
        XCTAssertEqual(clean, facebookCleanURL + "?t=12#part")
        let video = try facebookVideo()
        let button = try XCTUnwrap(facebookButtons(video).first { $0.url != nil })
        XCTAssertEqual(button.url, clean)
        XCTAssertTrue(button.text.contains("Ouvrir Facebook"))
        XCTAssertTrue((video["caption"] as? String ?? "").hasSuffix(clean))
        XCTAssertEqual(try facebookButtons(video).last?.text, "🗑 Retirer l’aperçu")
    }

    func testFacebookConfiguredEngineDecidesCanonicalSourceWithoutAnotherMirror() async throws {
        _ = try facebookProvider()
        var settings = UserSettings()
        settings.trackersEverywhere = false
        settings.disabledSites = ["facebook"]
        try store.setPersonalLinks(settings, youTubeCards: nil, userID: 7)
        try replaceMode()
        try await facebookHandle(facebookDirtyURL)
        XCTAssertEqual(api.methods, ["sendVideo"])
        let video = try facebookVideo()
        XCTAssertEqual(try facebookButtons(video).first?.url, facebookDirtyURL)
        XCTAssertTrue((video["caption"] as? String ?? "").hasSuffix(facebookDirtyURL))
        XCTAssertFalse(engine.rules.previews.contains { $0.id == "facebook" })
    }

    func testFacebookFacebedReelUsesProviderWithoutUploadingARemoteURL() async throws {
        let provider = try facebookProvider()
        let source = "https://facebed.com/reel/123456?utm_source=share"
        try await facebookHandle(source)
        XCTAssertEqual(provider.requestedIDs, ["123456"])
        let video = try facebookVideo()
        XCTAssertEqual((video["video"] as? VideoUpload)?.data, provider.video)
        XCTAssertNil(video["video"] as? String)
        XCTAssertEqual(try facebookButtons(video).first?.url, engine.clean(source).text)
    }

    func testFacebookFeatureDefaultsOffAndProviderIsOptional() async throws {
        let provider = try facebookProvider(enabled: false)
        try await facebookHandle()
        XCTAssertTrue(provider.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
        try await facebookHandle(facebookDirtyURL)
        XCTAssertEqual(api.methods, ["sendMessage"])
        api.calls = []
        try store.setDefaultFacebookReels(true)
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot")
        try await facebookHandle()
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testFacebookPersonalGroupDefaultPrecedenceAndNilInheritance() async throws {
        let provider = try facebookProvider(enabled: false)
        var group = ChatSettings()
        group.facebookReels = true
        try store.set(group, chatID: -100)
        try await facebookHandle()
        XCTAssertEqual(provider.requestedIDs.count, 1)
        try store.setPersonalFacebookReels(false, userID: 7)
        api.calls = []
        try await facebookHandle()
        XCTAssertTrue(api.calls.isEmpty)
        try store.setDefaultFacebookReels(true)
        group.facebookReels = false
        try store.set(group, chatID: -100)
        try store.setPersonalFacebookReels(true, userID: 7)
        try await facebookHandle()
        XCTAssertEqual(provider.requestedIDs.count, 2)
        try store.setPersonalFacebookReels(nil, userID: 7)
        api.calls = []
        try await facebookHandle()
        XCTAssertTrue(api.calls.isEmpty)
        group.facebookReels = nil
        try store.set(group, chatID: -100)
        try await facebookHandle()
        XCTAssertEqual(provider.requestedIDs.count, 3)
        api.calls = []
        try store.setPersonalFacebookReels(false, userID: 8)
        try await facebookHandle(extra: ["from": fixtureUser(8, languageCode: nil)])
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testFacebookGroupMasterPreviewsAndModeGateProviderBeforeFetching() async throws {
        let provider = try facebookProvider()
        var settings = ChatSettings()
        settings.previews = false
        try store.set(settings, chatID: -100)
        try await facebookHandle()
        try await facebookHandle(facebookDirtyURL)
        XCTAssertEqual(api.methods, ["sendMessage"])
        settings.previews = true
        try store.set(settings, chatID: -100)
        for mode in [Mode.off, .secretary] {
            api.calls = []
            try store.setMode(mode, userID: 7)
            try await facebookHandle(facebookDirtyURL)
            XCTAssertTrue(api.calls.isEmpty)
        }
        try store.setMode(nil, userID: 7)
        try store.setGroupEnabled(false, chatID: -100)
        try await facebookHandle(facebookDirtyURL)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertTrue(provider.requestedIDs.isEmpty)
    }

    func testFacebookProtectedBotOldAndAutomaticForwardMessagesNeverFetch() async throws {
        let provider = try facebookProvider()
        for fixture: [String: Any] in [
            ["has_protected_content": true], ["is_paid_post": true], ["is_automatic_forward": true],
            ["date": 0], ["from": ["id": 99, "first_name": "Bot", "is_bot": true]],
            ["chat": ["id": -200, "type": "supergroup"]],
        ] {
            try await facebookHandle(facebookDirtyURL, extra: fixture)
        }
        XCTAssertTrue(provider.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testFacebookForwardsAnonymousAndMediaKeepOriginalsAndSkipVideo() async throws {
        let provider = try facebookProvider()
        try replaceMode()
        for fixture: [String: Any] in [
            ["forward_origin": ["type": "user"]], ["forward_origin": ["type": "hidden_user"]],
            ["sender_chat": ["id": -100, "type": "supergroup"]],
            ["text": NSNull(), "caption": facebookDirtyURL],
        ] {
            api.calls = []
            try await facebookHandle(facebookDirtyURL, extra: fixture)
            XCTAssertEqual(api.methods, ["sendMessage"])
            XCTAssertEqual((sent["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
        }
        XCTAssertTrue(provider.requestedIDs.isEmpty)
    }

    func testFacebookOnlyPlainSingleReelLinksQualify() async throws {
        let provider = try facebookProvider()
        for type in ["code", "pre", "spoiler", "text_link", "bold"] {
            try await facebookHandle(extra: ["entities": [["type": type, "offset": 0,
                                                           "length": facebookCleanURL.utf16.count,
                                                           "url": facebookCleanURL]]])
        }
        for text in ["Watch " + facebookCleanURL, facebookCleanURL + " " + facebookCleanURL,
                     "https://example.com " + facebookCleanURL] {
            try await facebookHandle(text)
        }
        try await facebookHandle(extra: ["link_preview_options": ["is_disabled": true]])
        XCTAssertTrue(provider.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
        try await facebookHandle(extra: ["entities": [["type": "url", "offset": 0,
                                                       "length": facebookCleanURL.utf16.count]]])
        XCTAssertEqual(provider.requestedIDs, ["123456"])
    }

    func testFacebookMalformedIDsAndUnsupportedRoutesNeverReachProvider() async throws {
        let provider = try facebookProvider()
        for source in [
            "https://facebook.com/reel/", "https://facebook.com/reel/123abc",
            "https://facebook.com/reel/１２３４５６", "https://facebook.com/reel/-123456",
            "https://facebook.com/reel/%31%32%33", "https://facebook.com/reel/123456/extra",
            "https://facebook.com.evil.example/reel/123456", "https://notfacebook.com/reel/123456",
            "https://user@facebook.com/reel/123456", "https://facebook.com:8443/reel/123456",
            "ftp://facebook.com/reel/123456",
        ] {
            try await facebookHandle(source)
            XCTAssertTrue(provider.requestedIDs.isEmpty, source)
            XCTAssertFalse(api.methods.contains("sendVideo"), source)
        }
    }

    func testFacebookFetchFailureFallsBackOnlyWhenCleaningChangedSource() async throws {
        let provider = try facebookProvider()
        provider.error = URLError(.timedOut)
        try await facebookHandle(facebookDirtyURL)
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(sent["text"] as? String, facebookCleanURL)
        api.calls = []
        try await facebookHandle()
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(provider.requestedIDs, ["123456", "123456"])
    }

    func testFacebookExplicitVideoRejectionFallsBackToConfirmedCleanText() async throws {
        _ = try facebookProvider()
        try replaceMode()
        for code in [400, 403] {
            api.calls = []
            api.videoError = BotError.telegram(code)
            try await facebookHandle(facebookDirtyURL)
            XCTAssertEqual(api.methods, ["getChatMember", "sendVideo", "sendMessage", "deleteMessage"])
            XCTAssertTrue((sent["text"] as? String ?? "").hasSuffix(facebookCleanURL))
            api.calls = []
            try await facebookHandle()
            XCTAssertEqual(api.methods, ["sendVideo"])
        }
    }

    func testFacebookAmbiguousVideoSendNeverRetriesFallsBackOrDeletes() async throws {
        _ = try facebookProvider()
        try replaceMode()
        for failure in [URLError(.timedOut) as Error, BotError.invalidResponse, BotError.telegram(500)] {
            api.calls = []
            api.videoError = failure
            do { try await facebookHandle(facebookDirtyURL); XCTFail("Expected send failure") } catch {}
            XCTAssertEqual(api.methods, ["getChatMember", "sendVideo"])
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testFacebookMalformedVideoReceiptNeverDeletesOrRecordsControl() async throws {
        _ = try facebookProvider()
        try replaceMode()
        for json in [#"{}"#, #"null"#, #"true"#, #"{"message_id":null}"#, #"{"message_id":"42"}"#,
                     #"{"message_id":0}"#, #"{"message_id":-1}"#, #"{"message_id":true}"#, #"{"message_id":42.5}"#] {
            api.sendResult = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            for source in [facebookDirtyURL, facebookCleanURL] {
                api.calls = []
                do { try await facebookHandle(source); XCTFail("Expected invalid receipt: \(json)") }
                catch BotError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(api.methods.filter { $0 == "sendVideo" }.count, 1)
                XCTAssertFalse(api.methods.contains("sendMessage"))
                XCTAssertFalse(api.methods.contains("deleteMessage"))
                XCTAssertTrue(store.state.replyControls.isEmpty)
            }
        }
    }

    func testFacebookLongCaptionFitsTelegramUTF16LimitAndKeepsSource() async throws {
        let provider = try facebookProvider()
        provider.caption = String(repeating: "Example 😀 ", count: 200)
        try await facebookHandle()
        let video = try facebookVideo()
        let caption = try XCTUnwrap(video["caption"] as? String)
        XCTAssertLessThanOrEqual(caption.utf16.count, 1024)
        XCTAssertTrue(caption.contains(provider.author))
        XCTAssertTrue(caption.hasSuffix(facebookCleanURL))
        let entities = try decode([Entity].self, from: XCTUnwrap(video["caption_entities"]))
        for entity in entities {
            XCTAssertGreaterThanOrEqual(entity.offset, 0)
            XCTAssertLessThanOrEqual(entity.offset + entity.length, caption.utf16.count)
            XCTAssertNotNil(Range(NSRange(location: entity.offset, length: entity.length), in: caption))
        }
    }

    func testFacebookPrivateToggleIsPersonalAndResetRestoresInheritance() async throws {
        _ = try facebookProvider()
        try await callback("fxclip:rules:p:facebook:off")
        XCTAssertEqual(store.state.personalFacebookReels["8"], false)
        XCTAssertTrue(store.state.defaultFacebookReels)
        try await callback("fxclip:rules:p:facebook:on")
        XCTAssertEqual(store.state.personalFacebookReels["8"], true)
        try await callback("fxclip:rules:p:reset")
        XCTAssertNil(store.state.personalFacebookReels["8"])
        XCTAssertTrue(store.state.defaultFacebookReels)
    }

    func testFacebookGroupAndOwnerToggleResetPreserveOtherChoices() async throws {
        var group = ChatSettings()
        group.mode = .replace
        group.previews = false
        try store.set(group, chatID: -100)
        try await callback("fxclip:rules:c:-100:facebook:on", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(store.state.chats["-100"]?.facebookReels, true)
        try await callback("fxclip:rules:c:-100:reset", chatID: -100, chatType: "supergroup")
        XCTAssertNil(store.state.chats["-100"]?.facebookReels)
        XCTAssertEqual(store.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(store.state.chats["-100"]?.previews, false)
        try await callback("fxclip:rules:d:facebook:on", userID: 7, chatID: 7)
        XCTAssertTrue(store.state.defaultFacebookReels)
        try await callback("fxclip:rules:d:reset", userID: 7, chatID: 7)
        XCTAssertFalse(store.state.defaultFacebookReels)
    }

    func testFacebookCallbacksRejectCrossScopeUnauthorizedAndMalformedActions() async throws {
        let before = try facebookStateSnapshot()
        for (data, userID, chatID, type) in [
            ("fxclip:rules:p:facebook:on", Int64(8), Int64(7), "private"),
            ("fxclip:rules:p:facebook:on", 8, -100, "supergroup"),
            ("fxclip:rules:d:facebook:on", 8, 8, "private"),
            ("fxclip:rules:d:facebook:on", 7, 8, "private"),
            ("fxclip:rules:c:-100:facebook:on", 8, -200, "supergroup"),
            ("fxclip:rules:c:-100:facebook:on", 7, 7, "private"),
            ("fxclip:rules:p:facebook:maybe", 8, 8, "private"),
            ("fxclip:rules:p:facebook:on:extra", 8, 8, "private"),
        ] {
            api.calls = []
            try await callback(data, userID: userID, chatID: chatID, chatType: type)
            XCTAssertEqual(try facebookStateSnapshot(), before, data)
            XCTAssertTrue(api.methods.contains("answerCallbackQuery"), data)
            XCTAssertFalse(api.methods.contains("editMessageText"), data)
        }
        api.admin = false
        api.calls = []
        try await callback("fxclip:rules:c:-100:facebook:on", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
        XCTAssertEqual(try facebookStateSnapshot(), before)
    }
}
