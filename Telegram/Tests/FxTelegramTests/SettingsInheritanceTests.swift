import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

extension BotTests {
    private func inheritanceSnapshot() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.state)
    }

    private func inheritancePanel(_ method: String = "editMessageText") throws -> SettingsUI {
        let parameters = try XCTUnwrap(api.calls.last { $0.0 == method }?.1)
        return SettingsUI(text: try XCTUnwrap(parameters["text"] as? String),
            markup: try XCTUnwrap(parameters["reply_markup"] as? [String: Any]))
    }

    private func inheritanceActions(_ panel: SettingsUI) throws -> Set<String> {
        Set(try decode(InlineKeyboardMarkup.self, from: panel.markup).inline_keyboard.flatMap { $0 }.compactMap(\.callback_data))
    }

    func testInheritedEngineCallbacksRequireCustomizationEvenFromAttachedLegacyButtons() async throws {
        try store.setPersonalFacebookReels(true, userID: 8)
        try store.setPersonalLinks(nil, youTubeCards: false, userID: 8)
        let before = try inheritanceSnapshot()
        for (scope, chatID, type) in [("p", Int64(8), "private"), ("c:-100", Int64(-100), "supergroup")] {
            for action in ["trackers:off", "site:reddit:off", "preview:reddit:on", "preview:reddit:off", "providerreset:reddit"] {
                api.calls = []
                try await callback("fxclip:rules:\(scope):\(action)", chatID: chatID, chatType: type)
                XCTAssertEqual(try inheritanceSnapshot(), before, "\(scope) \(action)")
                XCTAssertTrue(try inheritanceActions(inheritancePanel()).contains("fxclip:rules:\(scope):customize:confirm"))
            }
        }
    }

    func testResetInAnotherPanelMakesPreviouslyIssuedEngineToggleReadOnlyAgain() async throws {
        for (scope, chatID, type) in [("p", Int64(8), "private"), ("c:-100", Int64(-100), "supergroup")] {
            try await callback("fxclip:rules:\(scope):customize:confirm", chatID: chatID, chatType: type)
            api.calls = []
            try await callback("fxclip:rules:\(scope):clean", chatID: chatID, chatType: type)
            let oldPanel = try inheritancePanel()
            let toggle = "fxclip:rules:\(scope):trackers:off"
            XCTAssertTrue(try inheritanceActions(oldPanel).contains(toggle))
            // A second issued panel resets the configuration while the first remains open.
            api.calls = []
            try await callback("fxclip:rules:\(scope):reset:show", chatID: chatID, chatType: type)
            let resetPanel = try inheritancePanel()
            try await callback("fxclip:rules:\(scope):reset", chatID: chatID, chatType: type,
                messageText: resetPanel.plainText, messageMarkup: resetPanel.markup)
            let before = try inheritanceSnapshot()
            api.calls = []
            try await callback(toggle, chatID: chatID, chatType: type,
                messageText: oldPanel.plainText, messageMarkup: oldPanel.markup)
            XCTAssertEqual(try inheritanceSnapshot(), before, scope)
            let confirmation = try inheritancePanel()
            XCTAssertTrue(try inheritanceActions(confirmation).contains("fxclip:rules:\(scope):customize:confirm"))
            try await callback("fxclip:rules:\(scope):customize:confirm", chatID: chatID, chatType: type,
                messageText: confirmation.plainText, messageMarkup: confirmation.markup)
            try await callback(toggle, chatID: chatID, chatType: type,
                messageText: oldPanel.plainText, messageMarkup: oldPanel.markup)
            let links = scope == "p" ? store.state.personalLinkSettings["8"] : store.state.chats["-100"]?.engineSettings
            XCTAssertEqual(links?.trackersEverywhere, false, scope)
        }
    }

    func testInheritedProviderAndExclusionCommandsRequireConfirmationAndExplicitReissue() async throws {
        try store.discover(message().chat)
        for (scope, chatID, type) in [("p", Int64(8), "private"), ("c:-100", Int64(-100), "supergroup")] {
            for tail in ["provider reddit mirror.example", "exclude add excluded.example"] {
                let command = scope == "p" ? "/\(tail)" : "/fxclip \(tail)"
                let before = try inheritanceSnapshot()
                api.calls = []
                if scope == "p" { try await privateCommand(command) }
                else { try await handle(["text": command, "from": fixtureUser(8, languageCode: nil)]) }
                XCTAssertEqual(try inheritanceSnapshot(), before, command)
                let panel = try inheritancePanel("sendMessage")
                XCTAssertTrue(try inheritanceActions(panel).contains("fxclip:rules:\(scope):customize:confirm"))
                try await callback("fxclip:rules:\(scope):customize:confirm", chatID: chatID, chatType: type,
                    messageText: panel.plainText, messageMarkup: panel.markup)
                let initial = scope == "p" ? store.state.personalLinkSettings["8"] : store.state.chats["-100"]?.engineSettings
                XCTAssertEqual(initial, store.state.defaultLinkSettings, command)
                if scope == "p" { try await privateCommand(command) }
                else { try await handle(["text": command, "from": fixtureUser(8, languageCode: nil)]) }
                let links = scope == "p" ? store.state.personalLinkSettings["8"] : store.state.chats["-100"]?.engineSettings
                if tail.hasPrefix("provider") { XCTAssertEqual(links?.previews["reddit"]?.targetHost, "mirror.example") }
                else { XCTAssertEqual(links?.neverClean, [.init(host: "excluded.example", subdomains: true)]) }
                try await callback("fxclip:rules:\(scope):reset", chatID: chatID, chatType: type)
            }
        }
    }

    func testResetOfUntouchedGroupDoesNotCreateSettingsOrFreezeTheCurrentDefaultMode() async throws {
        let before = try inheritanceSnapshot()
        try await callback("fxclip:rules:c:-100:reset", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(try inheritanceSnapshot(), before)
        XCTAssertNil(store.state.chats["-100"])
        try store.setDefault(.off)
        api.calls = []; try await handle()
        XCTAssertTrue(api.calls.isEmpty)
        try store.setDefault(.replace)
        api.calls = []; try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
        XCTAssertNil(store.state.chats["-100"])
    }

    func testFirstLinkServiceAndPreviewPauseWritesKeepFollowingLaterDefaultModes() async throws {
        let actions = ["rules:c:-100:customize:confirm", "rules:c:-101:facebook:on",
                       "rules:c:-102:youtube:off", "chat:-103:previews_off"]
        for (index, action) in actions.enumerated() {
            let chatID = Int64(-100 - index)
            try store.setGroupEnabled(true, chatID: chatID)
            try store.setDefault(.reply)
            try await callback("fxclip:\(action)", chatID: chatID, chatType: "supergroup")
            XCTAssertEqual(store.state.chats[String(chatID)]?.modeInherited, true, action)
            try store.setDefault(.off)
            api.calls = []
            try await handle(["chat": ["id": chatID, "type": "supergroup"], "from": fixtureUser(8, languageCode: nil)])
            XCTAssertTrue(api.calls.isEmpty, action)
            api.calls = []
            try await callback("fxclip:chat:\(chatID):mode", chatID: chatID, chatType: "supergroup")
            let panel = try inheritancePanel()
            XCTAssertTrue(panel.plainText.contains("Follow bot defaults"), action)
            XCTAssertTrue(panel.plainText.contains(SettingsUI.title(.off)), action)
            try store.setDefault(.reply)
            api.calls = []
            try await handle(["chat": ["id": chatID, "type": "supergroup"], "from": fixtureUser(8, languageCode: nil)])
            XCTAssertEqual(api.methods, ["sendMessage"], action)
        }
        let restarted = try StateStore(directory: directory)
        for id in [-100, -101, -102, -103] { XCTAssertEqual(restarted.state.chats[String(id)]?.modeInherited, true) }
    }

    func testExplicitGroupModeCommandsAndCallbacksStopFollowingDefaults() async throws {
        for (chatID, command) in [(Int64(-100), false), (Int64(-101), true)] {
            try store.setGroupEnabled(true, chatID: chatID)
            try store.setDefault(.reply)
            if command {
                try await handle(["text": "/fxclip reply", "chat": ["id": chatID, "type": "supergroup"],
                                  "from": fixtureUser(8, languageCode: nil)])
            } else { try await callback("fxclip:chat:\(chatID):reply", chatID: chatID, chatType: "supergroup") }
            XCTAssertEqual(store.state.chats[String(chatID)]?.modeInherited, false)
            try store.setDefault(.off)
            api.calls = []
            try await handle(["chat": ["id": chatID, "type": "supergroup"], "from": fixtureUser(8, languageCode: nil)])
            XCTAssertEqual(api.methods, ["sendMessage"])
            api.calls = []
            try await callback("fxclip:chat:\(chatID):mode", chatID: chatID, chatType: "supergroup")
            XCTAssertFalse(try inheritancePanel().plainText.contains("Follow bot defaults"))
        }
    }

    func testLegacyChatModeRemainsExplicitWhileNewInheritanceFlagRoundTrips() throws {
        for json in [#"{}"#, #"{"mode":"replace","previews":false}"#] {
            let legacy = try JSONDecoder().decode(ChatSettings.self, from: Data(json.utf8))
            XCTAssertFalse(legacy.modeInherited)
            XCTAssertEqual(legacy.mode, json == "{}" ? .reply : .replace)
        }
        var group = ChatSettings(); group.modeInherited = true; group.mode = .off
        try store.set(group, chatID: -100)
        let restored = try StateStore(directory: directory).state.chats["-100"]
        XCTAssertEqual(restored?.modeInherited, true)
        XCTAssertEqual(restored?.mode, .off)
    }

    func testActualGroupSetupAndPreviewResumePanelsDiscloseNetworkAndTemporaryOpenURLs() async throws {
        for language in BotLanguage.allCases {
            try store.setGroupLanguage(language, chatID: -100)
            try store.setGroupEnabled(false, chatID: -100)
            api.calls = []
            try await handle(["text": "/setup", "from": fixtureUser(8, languageCode: nil)])
            let setup = try inheritancePanel("sendMessage")
            try assertResumeNotice(setup, language: language)
            XCTAssertTrue(try inheritanceActions(setup).contains("fxclip:chat:-100:enable"))
            try await callback("fxclip:chat:-100:enable", chatID: -100, chatType: "supergroup",
                messageText: setup.plainText, messageMarkup: setup.markup)
            XCTAssertEqual(store.state.groupEnabled["-100"], true)
            api.calls = []
            try await callback("fxclip:chat:-100:previews_off", chatID: -100, chatType: "supergroup")
            let previews = try inheritancePanel()
            try assertResumeNotice(previews, language: language)
            XCTAssertTrue(try inheritanceActions(previews).contains("fxclip:chat:-100:previews_on"))
            try await callback("fxclip:chat:-100:previews_on", chatID: -100, chatType: "supergroup",
                messageText: previews.plainText, messageMarkup: previews.markup)
            XCTAssertEqual(store.state.chats["-100"]?.previews, true)
        }
    }

    private func assertResumeNotice(_ panel: SettingsUI, language: BotLanguage,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        for phrase in ["Telegram", "YouTube", "Facebook", "48 h", language == .en ? "mirrors" : "miroirs",
                       language == .en ? "Opening links" : "liens d’ouverture", language == .en ? "server" : "serveur"] {
            XCTAssertTrue(panel.plainText.contains(phrase), phrase, file: file, line: line)
        }
    }
}
