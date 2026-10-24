import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

extension BotTests {
    func testAutomaticCommandsRecoverAfterPartialFailureOnNextSettingsInteractionAndRestart() async throws {
        for recovery in ["command", "callback"] {
            try await callback("fxclip:language:en", languageCode: "fr")
            XCTAssertEqual(api.commandMenus["8:fr"]?.first?["description"], "Choose your settings")
            api.failCommandsLocale = "fr"
            try await callback("fxclip:language:auto", languageCode: "fr")
            XCTAssertNil(store.state.userLanguages["8"])
            XCTAssertEqual(store.userLanguage(8), .fr)
            XCTAssertEqual(api.commandMenus["8:fr"]?.first?["description"], "Choose your settings")

            store = try StateStore(directory: directory)
            bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                      botID: 99, username: "fxclipbot")
            if recovery == "command" { try await privateCommand("/settings", languageCode: "fr") }
            else { try await callback("fxclip:language:show", languageCode: "fr") }
            XCTAssertEqual(api.commandMenus["8:fr"]?.first?["description"], "Choisir vos réglages")
            XCTAssertEqual(api.commandMenus["8:"]?.first?["description"], "Choose your settings")
            XCTAssertNil(store.state.userLanguages["8"])
            XCTAssertTrue(store.state.users.isEmpty)
        }
    }
    func testTelegramLocaleMappingAndNativeLanguageNames() {
        for tag in ["fr", "FR", "fr-FR", "fr_CA", "fr-BE"] {
            XCTAssertEqual(BotLanguage.telegram(tag), .fr, tag)
        }
        for tag in ["en", "en-GB", "de", "es_MX", "unknown", "french"] {
            XCTAssertEqual(BotLanguage.telegram(tag), .en, tag)
        }
        for tag: String? in [nil, "", "  ", "\n"] {
            XCTAssertNil(BotLanguage.telegram(tag))
        }
        XCTAssertEqual(BotLanguage.en.name, "English")
        XCTAssertEqual(BotLanguage.fr.name, "Français")
    }

    func testColdStartLanguagesDefaultToEnglishWithoutCreatingPreferences() throws {
        XCTAssertEqual(store.userLanguage(7), .en)
        XCTAssertEqual(store.groupLanguage(-100), .en)
        XCTAssertTrue(store.state.userLanguages.isEmpty)
        XCTAssertTrue(store.state.detectedLanguages.isEmpty)
        XCTAssertTrue(store.state.groupLanguages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
    }

    func testExplicitLanguagesOverrideLatestTelegramLocaleUntilAutoIsRestored() throws {
        for (selected, detected): (BotLanguage, String) in [(.fr, "en-US"), (.en, "fr-FR")] {
            try store.setUserLanguage(selected, userID: 7)
            try store.observeLanguage(decode(TelegramUser.self, from: fixtureUser(7, languageCode: detected)))
            XCTAssertEqual(store.userLanguage(7), selected)
            XCTAssertEqual(store.state.detectedLanguages["7"], selected == .fr ? .en : .fr)
            let restarted = try StateStore(directory: directory)
            XCTAssertEqual(restarted.userLanguage(7), selected)
            try restarted.setUserLanguage(nil, userID: 7)
            XCTAssertNil(restarted.state.userLanguages["7"])
            XCTAssertEqual(restarted.userLanguage(7), selected == .fr ? .en : .fr)
            XCTAssertEqual(try StateStore(directory: directory).userLanguage(7), selected == .fr ? .en : .fr)
        }
    }

    func testMissingLocaleRetainsLastObservationAndDoesNotBorrowAnotherUsersLanguage() throws {
        try store.observeLanguage(decode(TelegramUser.self, from: fixtureUser(7, languageCode: "fr_CA")))
        for tag: String? in [nil, "", " "] {
            try store.observeLanguage(decode(TelegramUser.self, from: fixtureUser(7, languageCode: tag)))
            XCTAssertEqual(store.userLanguage(7), .fr)
        }
        try store.observeLanguage(nil)
        XCTAssertEqual(store.userLanguage(8), .en)
        try store.observeLanguage(decode(TelegramUser.self, from: fixtureUser(7, languageCode: "de-DE")))
        XCTAssertEqual(store.userLanguage(7), .en)
    }

    func testSameResolvedLocaleAndBotSendersDoNotRewriteLanguageState() throws {
        try store.observeLanguage(decode(TelegramUser.self, from: fixtureUser(7, languageCode: "fr-FR")))
        let path = directory.appendingPathComponent("state.json").path
        let sentinel = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: path)
        try store.observeLanguage(decode(TelegramUser.self, from: fixtureUser(7, languageCode: "fr_CA")))
        try store.observeLanguage(decode(TelegramUser.self, from: fixtureUser(7, languageCode: nil)))
        try store.observeLanguage(decode(TelegramUser.self, from: ["id": 8, "first_name": "Bot", "is_bot": true, "language_code": "fr"]))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, sentinel)
        XCTAssertNil(store.state.detectedLanguages["8"])
    }

    func testDeployedStateMigrationKeepsOffsetModesAndActivationWhenLanguageIsSaved() throws {
        let old = #"{"offset":123,"chats":{"-100":{"mode":"replace","previews":false}},"users":{"7":"off"},"defaultMode":"secretary","lastUpdateAt":1000,"knownGroups":{"-100":{"chat":{"id":-100,"type":"supergroup","title":"Test group"}}},"groupEnabled":{"-100":false,"-200":true}}"#
        try Data(old.utf8).write(to: directory.appendingPathComponent("state.json"))
        let migrated = try StateStore(directory: directory)
        XCTAssertTrue(migrated.state.userLanguages.isEmpty)
        XCTAssertTrue(migrated.state.detectedLanguages.isEmpty)
        XCTAssertTrue(migrated.state.groupLanguages.isEmpty)
        try migrated.observeLanguage(decode(TelegramUser.self, from: fixtureUser(7, languageCode: "fr")))
        try migrated.setUserLanguage(.en, userID: 7)
        try migrated.setGroupLanguage(.fr, chatID: -100)
        let restored = try StateStore(directory: directory)
        XCTAssertEqual(restored.state.offset, 123)
        XCTAssertEqual(restored.state.lastUpdateAt, 1000)
        XCTAssertEqual(restored.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(restored.state.chats["-100"]?.previews, false)
        XCTAssertEqual(restored.state.users, ["7": .off])
        XCTAssertEqual(restored.state.defaultMode, .secretary)
        XCTAssertEqual(restored.state.groupEnabled, ["-100": false, "-200": true])
        XCTAssertEqual(restored.state.knownGroups["-100"]?.chat.title, "Test group")
        XCTAssertEqual(restored.state.userLanguages, ["7": .en])
        XCTAssertEqual(restored.state.detectedLanguages, ["7": .fr])
        XCTAssertEqual(restored.state.groupLanguages, ["-100": .fr])
    }

    func testPrivateSettingsDetectsLocaleAndReusesItWhenTelegramOmitsTag() async throws {
        try await privateCommand("/settings", languageCode: "fr_CA")
        XCTAssertTrue(try XCTUnwrap(sent["text"] as? String).contains("Vos réglages"))
        XCTAssertEqual(store.state.detectedLanguages["8"], .fr)
        api.calls = []
        try await privateCommand("/settings")
        XCTAssertTrue(try XCTUnwrap(sent["text"] as? String).contains("Vos réglages"))
        api.calls = []
        try await privateCommand("/settings", languageCode: "de-DE")
        XCTAssertTrue(try XCTUnwrap(sent["text"] as? String).lowercased().contains("settings"))
        XCTAssertEqual(store.userLanguage(8), .en)
    }

    func testBotObservesLocaleOnEverySupportedSenderEventBeforeContentFilters() async throws {
        for (index, field) in ["message", "edited_message", "business_message", "edited_business_message"].enumerated() {
            let tag = index.isMultiple(of: 2) ? "fr-FR" : "en-GB"
            let event = try decode(Update.self, from: ["update_id": index + 10, field: [
                "message_id": 5, "date": 0, "chat": ["id": 8, "type": "private"],
                "from": fixtureUser(8, languageCode: tag), "text": "No link here",
            ]])
            try await bot.handle(event, now: 1100)
            XCTAssertEqual(store.userLanguage(8), index.isMultiple(of: 2) ? .fr : .en, field)
        }
        XCTAssertTrue(api.calls.isEmpty)
        try await callback("fxclip:language:show", languageCode: "fr_CA")
        XCTAssertEqual(store.state.detectedLanguages["8"], .fr)
        XCTAssertNil(store.state.userLanguages["8"])
    }

    func testRepeatedSettingsRequestWithSameLocaleDoesNotRewriteState() async throws {
        try await privateCommand("/settings", languageCode: "fr-FR")
        let path = directory.appendingPathComponent("state.json").path
        let sentinel = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: path)
        try await privateCommand("/settings", languageCode: "fr_CA")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, sentinel)
        XCTAssertEqual(store.userLanguage(8), .fr)
    }

    func testPrivateSettingsHonorsBothExplicitLanguageOverrides() async throws {
        for (language, tag): (BotLanguage, String) in [(.fr, "en"), (.en, "fr")] {
            try store.setUserLanguage(language, userID: 8)
            api.calls = []
            try await privateCommand("/settings", languageCode: tag)
            let text = try XCTUnwrap(sent["text"] as? String)
            XCTAssertTrue(language == .fr ? text.contains("Vos réglages") : text.lowercased().contains("settings"))
            XCTAssertEqual(store.userLanguage(8), language)
        }
    }

    func testLanguageMenuHasAutoEnglishFrenchAndDoesNotChangeMode() async throws {
        try store.setMode(.off, userID: 8)
        try await callback("fxclip:language:show", languageCode: "fr")
        let panel = try XCTUnwrap(api.calls.last { $0.0 == "editMessageText" }?.1)
        let markup = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(panel["reply_markup"]))
        let buttons = markup.inline_keyboard.flatMap { $0 }
        XCTAssertTrue(Set(buttons.compactMap(\.callback_data)).isSuperset(of: ["fxclip:language:auto", "fxclip:language:en", "fxclip:language:fr"]))
        XCTAssertTrue(buttons.contains { $0.text.contains("English") })
        XCTAssertTrue(buttons.contains { $0.text.contains("Français") })
        XCTAssertNil(store.state.userLanguages["8"])
        XCTAssertEqual(store.state.users["8"], .off)
    }

    func testLanguageCallbacksPreserveModesOtherPreferencesAndResumeLatestLocaleOnAuto() async throws {
        try store.setDefault(.replace)
        try store.setMode(.secretary, userID: 8)
        try store.setUserLanguage(.fr, userID: 7)
        var settings = ChatSettings(); settings.mode = .off; settings.previews = false
        try store.set(settings, chatID: -100)
        try store.setGroupEnabled(false, chatID: -100)
        try store.setGroupLanguage(.fr, chatID: -100)
        for (action, tag, expected): (String, String, BotLanguage) in [("en", "fr", .en), ("fr", "en", .fr), ("auto", "en", .en)] {
            api.calls = []
            try await callback("fxclip:language:\(action)", languageCode: tag)
            XCTAssertEqual(store.userLanguage(8), expected, action)
            XCTAssertEqual(try StateStore(directory: directory).userLanguage(8), expected, action)
            XCTAssertTrue(api.methods.contains("editMessageText"), action)
            XCTAssertEqual(store.state.users, ["8": .secretary])
            XCTAssertEqual(store.state.defaultMode, .replace)
            XCTAssertEqual(store.state.chats["-100"]?.mode, .off)
            XCTAssertEqual(store.state.chats["-100"]?.previews, false)
            XCTAssertEqual(store.state.groupEnabled["-100"], false)
            XCTAssertEqual(store.state.userLanguages["7"], .fr)
            XCTAssertEqual(store.groupLanguage(-100), .fr)
        }
        XCTAssertNil(store.state.userLanguages["8"])
        try await callback("fxclip:language:show", languageCode: "fr-FR")
        XCTAssertEqual(store.userLanguage(8), .fr)
    }

    func testLanguageCommandUsesSameChoicesAndPreservesPersonalMode() async throws {
        try store.setMode(.off, userID: 8)
        for (choice, expected): (String, BotLanguage) in [("en", .en), ("fr", .fr), ("auto", .en)] {
            api.calls = []
            try await privateCommand("/language \(choice)", languageCode: "en")
            XCTAssertEqual(store.userLanguage(8), expected, choice)
            XCTAssertEqual(store.state.users["8"], .off)
            XCTAssertTrue(api.methods.contains("sendMessage"))
        }
        XCTAssertNil(store.state.userLanguages["8"])
    }

    func testLanguageCallbacksRejectCrossChatGroupsAndBotSenders() async throws {
        for action in ["show", "en", "fr", "auto"] {
            for (chatID, type): (Int64, String) in [(7, "private"), (-100, "supergroup")] {
                api.calls = []
                try await callback("fxclip:language:\(action)", chatID: chatID, chatType: type, languageCode: "fr")
                XCTAssertEqual(api.methods, ["answerCallbackQuery"], action)
                XCTAssertTrue(store.state.userLanguages.isEmpty, action)
                XCTAssertTrue(store.state.groupLanguages.isEmpty, action)
                XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true)
            }
        }
        let event = try decode(Update.self, from: ["update_id": 4, "callback_query": [
            "id": "bot-click", "from": ["id": 8, "first_name": "Bot", "is_bot": true, "language_code": "fr"],
            "data": "fxclip:language:fr", "message": ["message_id": 42, "date": 1000, "chat": ["id": 8, "type": "private"]],
        ]])
        api.calls = []
        try await bot.handle(event, now: 1100)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        XCTAssertTrue(store.state.userLanguages.isEmpty)
    }

    func testPrivateCallbackErrorsUseClickersLocaleInsteadOfTargetChatLanguage() async throws {
        try store.setUserLanguage(.en, userID: 7)
        try await callback("fxclip:language:fr", chatID: 7, languageCode: "fr")
        XCTAssertTrue(try XCTUnwrap(api.calls.last?.1["text"] as? String).contains("privée"))
        XCTAssertTrue(store.state.userLanguages["8"] == nil)
        api.calls = []
        try store.setUserLanguage(.en, userID: 8)
        try await callback("fxclip:language:fr", chatID: 7, languageCode: "fr")
        XCTAssertTrue(try XCTUnwrap(api.calls.last?.1["text"] as? String).lowercased().contains("private"))
        XCTAssertEqual(store.state.userLanguages["8"], .en)
    }

    func testMalformedLanguageCallbacksDoNotMutateExplicitPreferences() async throws {
        try store.setUserLanguage(.fr, userID: 8)
        for action in ["fxclip:language:de", "fxclip:language:fr:extra", "fxclip:language", "other:language:en"] {
            api.calls = []
            try await callback(action)
            XCTAssertEqual(store.state.userLanguages["8"], .fr, action)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"], action)
        }
    }

    func testSharedGroupPanelUsesFixedFrenchDespiteEnglishRequesters() async throws {
        try store.setGroupLanguage(.fr, chatID: -100)
        try store.setUserLanguage(.en, userID: 7)
        try await handle(["text": "/setup", "from": fixtureUser(7, languageCode: "en")])
        XCTAssertTrue(try XCTUnwrap(sent["text"] as? String).contains("Réglage de ce groupe"))
        api.calls = []
        try await callback("fxclip:chat:-100:show", chatID: -100, chatType: "supergroup", languageCode: "en")
        XCTAssertTrue(try XCTUnwrap(api.calls.last?.1["text"] as? String).contains("Réglage de ce groupe"))
        XCTAssertEqual(store.userLanguage(8), .en)
    }

    func testGroupDefaultsToEnglishDespiteFrenchRequesters() async throws {
        try store.setUserLanguage(.fr, userID: 7)
        try await handle(["text": "/setup", "from": fixtureUser(7, languageCode: "fr")])
        let text = try XCTUnwrap(sent["text"] as? String)
        XCTAssertTrue(text.lowercased().contains("group"))
        XCTAssertFalse(text.contains("Réglage de ce groupe"))
        XCTAssertEqual(store.groupLanguage(-100), .en)
        XCTAssertTrue(store.state.groupLanguages.isEmpty)
    }

    func testWelcomeUsesPersistedGroupLanguage() async throws {
        for language in BotLanguage.allCases {
            try store.setGroupLanguage(language, chatID: -200)
            api.calls = []
            try await membership(["status": "member"], old: ["status": "left"])
            let text = try XCTUnwrap(sent["text"] as? String)
            if language == .fr { XCTAssertTrue(text.contains("Bonjour")) }
            else { XCTAssertFalse(text.contains("Bonjour")); XCTAssertTrue(text.lowercased().contains("links")) }
        }
    }

    func testGroupLanguageChangesRequireCurrentAdminRightsAndMatchingGroup() async throws {
        try await callback("fxclip:chat:-100:lang_fr", chatID: -100, chatType: "supergroup", languageCode: "en")
        XCTAssertEqual(store.groupLanguage(-100), .fr)
        XCTAssertTrue(try XCTUnwrap(api.calls.last?.1["text"] as? String).contains("Réglage de ce groupe"))
        XCTAssertEqual(api.calls.first?.0, "getChatMember")
        XCTAssertEqual(try StateStore(directory: directory).groupLanguage(-100), .fr)
        api.admin = false; api.calls = []
        try await callback("fxclip:chat:-100:lang_en", chatID: -100, chatType: "supergroup", languageCode: "en")
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
        XCTAssertEqual(store.groupLanguage(-100), .fr)
        XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true)
        api.admin = true
        for (chatID, type): (Int64, String) in [(-200, "supergroup"), (8, "private")] {
            api.calls = []
            try await callback("fxclip:chat:-100:lang_en", chatID: chatID, chatType: type)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"])
            XCTAssertEqual(store.groupLanguage(-100), .fr)
        }
        api.calls = []
        try await callback("fxclip:chat:-100:lang_en", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(store.groupLanguage(-100), .en)
        XCTAssertTrue(store.state.users.isEmpty)
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertTrue(store.state.groupEnabled.isEmpty)
        XCTAssertTrue(store.state.userLanguages.isEmpty)
    }

    func testReplacementAttributionUsesGroupLanguageAndPreservesOriginalProse() async throws {
        try replaceMode()
        for (language, personal, prefix): (BotLanguage, BotLanguage, String) in [(.fr, .en, "Publié par"), (.en, .fr, "Posted by")] {
            try store.setGroupLanguage(language, chatID: -100)
            try store.setUserLanguage(personal, userID: 7)
            api.calls = []
            try await handle(["text": "Voici mon lien 😀 https://x.com/a?s=1"])
            XCTAssertEqual(sent["text"] as? String, "\(prefix) Alice\n\nVoici mon lien 😀 https://fxtwitter.com/a")
            XCTAssertTrue(api.methods.contains("deleteMessage"))
        }
    }

    func testAttributionAndFormattingUseUTF16OffsetsInBothLanguages() throws {
        let text = "😀 Mon lien https://x.com/a?s=1 et café"
        let source = text as NSString
        let urlRange = source.range(of: "https://x.com/a?s=1")
        let tail = source.range(of: "café")
        let fixture = try message(["text": text,
            "from": ["id": 7, "first_name": "😀 Zoé", "last_name": "李"],
            "entities": [["type": "bold", "offset": urlRange.location, "length": urlRange.length],
                         ["type": "italic", "offset": tail.location, "length": tail.length]]])
        for (language, label): (BotLanguage, String) in [(.en, "Posted by "), (.fr, "Publié par ")] {
            let rendered = try XCTUnwrap(Rewriter(engine: engine).rewrite(fixture, previews: true, language: language))
            XCTAssertEqual(rendered.text, "\(label)😀 Zoé 李\n\n😀 Mon lien https://fxtwitter.com/a et café")
            let mention = try XCTUnwrap(rendered.entities.first { $0.type == "text_mention" })
            XCTAssertEqual(mention.offset, label.utf16.count)
            XCTAssertEqual(mention.length, "😀 Zoé 李".utf16.count)
            XCTAssertEqual(mention.user?.id, 7)
            let expected = ["text_mention": "😀 Zoé 李", "bold": "https://fxtwitter.com/a", "italic": "café"]
            for entity in rendered.entities {
                XCTAssertEqual((rendered.text as NSString).substring(with: NSRange(location: entity.offset, length: entity.length)), expected[entity.type])
            }
        }
    }

    func testReplyAndSecretaryNeverAddAttributionOrTranslateProseInEitherLanguage() async throws {
        for language in BotLanguage.allCases {
            try store.setGroupLanguage(language, chatID: -100)
            try store.setUserLanguage(language, userID: 7)
            try store.setMode(nil, userID: 7)
            api.calls = []
            try await handle(["text": "Voici mon lien 😀 https://x.com/a?s=1"])
            XCTAssertEqual(sent["text"] as? String, "Voici mon lien 😀 https://fxtwitter.com/a")
            XCTAssertNotNil(sent["reply_parameters"])
            try store.setMode(.secretary, userID: 7)
            api.calls = []
            try await handle(["text": "Here's my link 😀 https://x.com/a?s=1", "chat": ["id": 8, "type": "private"],
                              "business_connection_id": "connection"], business: true)
            XCTAssertEqual(api.calls.last?.0, "editMessageText")
            XCTAssertEqual(api.calls.last?.1["text"] as? String, "Here's my link 😀 https://fxtwitter.com/a")
        }
    }

    func testSharedURLContractIsIndependentOfPresentationLanguage() throws {
        struct Vector: Decodable { let input, clean, telegram: String }
        struct File: Decodable { let vectors: [Vector] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: shared.appendingPathComponent("vectors.json")))
        for vector in file.vectors {
            for language in BotLanguage.allCases {
                for (previews, expected) in [(false, vector.clean), (true, vector.telegram)] {
                    let result = Rewriter(engine: engine).rewrite(try message(["text": vector.input]), previews: previews,
                                                                 attribution: false, language: language)
                    XCTAssertEqual(result?.text ?? vector.input, expected, "\(language) previews=\(previews): \(vector.input)")
                }
            }
        }
    }
}
