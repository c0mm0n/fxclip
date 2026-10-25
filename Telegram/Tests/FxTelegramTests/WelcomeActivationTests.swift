import Foundation
import XCTest
@testable import FxTelegram

extension BotTests {
    func testWelcomeActivationWorksFromRealButtonsWithoutCommands() async throws {
        try await membership(["status": "administrator"], old: ["status": "left"])
        let welcome = sent
        let welcomeMarkup = try XCTUnwrap(welcome["reply_markup"] as? [String: Any])
        let welcomeText = try XCTUnwrap(welcome["text"] as? String)
        XCTAssertNil(store.state.groupEnabled["-200"])

        api.calls = []; api.admin = false
        try await callback("fxclip:chat:-200:activation", chatID: -200, chatType: "group",
                           messageText: welcomeText, messageMarkup: welcomeMarkup)
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
        XCTAssertNil(store.state.groupEnabled["-200"])

        api.calls = []; api.admin = true
        try await callback("fxclip:chat:-200:activation", chatID: -200, chatType: "group",
                           messageText: welcomeText, messageMarkup: welcomeMarkup)
        XCTAssertNil(store.state.groupEnabled["-200"], "Reviewing activation must not activate it")
        let confirmation = try XCTUnwrap(api.calls.last { $0.0 == "editMessageText" }?.1)
        let text = try XCTUnwrap(confirmation["text"] as? String)
        XCTAssertTrue(text.contains("Activate fxclip here?"))
        XCTAssertTrue(text.contains("bot server"))
        XCTAssertTrue(text.contains("48 h"))
        XCTAssertTrue(text.contains("5-minute"))
        let markup = try XCTUnwrap(confirmation["reply_markup"] as? [String: Any])
        let buttons = try decode(InlineKeyboardMarkup.self, from: markup).inline_keyboard.flatMap { $0 }
        XCTAssertEqual(buttons.first?.callback_data, "fxclip:chat:-200:enable")

        api.calls = []
        try await callback("fxclip:chat:-200:enable", chatID: -200, chatType: "group",
                           messageText: text, messageMarkup: markup)
        XCTAssertEqual(store.state.groupEnabled["-200"], true)
        XCTAssertNil(store.state.chats["-200"], "Activation preserves inherited behavior")
        XCTAssertEqual(api.methods.first, "getChatMember", "Admin rights are checked again at confirmation")
        XCTAssertTrue((api.calls.last?.1["text"] as? String)?.contains("Active for everyone") == true)
    }

    func testWelcomeCannotSkipDisclosureWithForgedAttachedActionOrForeignChat() async throws {
        try await membership(["status": "member"], old: ["status": "left"])
        let markup = try XCTUnwrap(sent["reply_markup"] as? [String: Any])
        api.calls = []
        try await callback("fxclip:chat:-200:enable", chatID: -200, chatType: "group", messageMarkup: markup)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        XCTAssertNil(store.state.groupEnabled["-200"])
        api.calls = []
        try await callback("fxclip:chat:-200:activation", chatID: -201, chatType: "group", messageMarkup: markup)
        XCTAssertEqual(api.methods, ["answerCallbackQuery"])
        XCTAssertNil(store.state.groupEnabled["-200"])
        XCTAssertNil(store.state.groupEnabled["-201"])
    }

    func testWelcomeConfirmationRechecksRevokedAdminAndDeleteRights() async throws {
        var settings = ChatSettings(); settings.mode = .replace
        try store.set(settings, chatID: -200)
        let panel = SettingsUI.chat(Chat(id: -200, type: "supergroup"), settings: settings,
            enabled: false, inherited: false, username: "fxclipbot", section: "activation")
        api.admin = false
        try await callback("fxclip:chat:-200:enable", chatID: -200, chatType: "supergroup",
                           messageText: panel.text, messageMarkup: panel.markup)
        XCTAssertNil(store.state.groupEnabled["-200"])
        api.admin = true; api.canDelete = false; api.calls = []
        try await callback("fxclip:chat:-200:enable", chatID: -200, chatType: "supergroup",
                           messageText: panel.text, messageMarkup: panel.markup)
        XCTAssertNil(store.state.groupEnabled["-200"])
        XCTAssertEqual(api.methods.filter { $0 == "getChatMember" }.count, 2)
        XCTAssertFalse(api.methods.contains("editMessageText"))
    }

    func testWelcomeShowsActualActivationAndSafeGroupTitleInEnglishAndFrench() throws {
        for language in BotLanguage.allCases {
            for enabled in [false, true] {
                let panel = SettingsUI.welcome(chatID: -200, username: "fxclipbot", language: language,
                    enabled: enabled, groupTitle: "Example <group> & friends")
                XCTAssertTrue(panel.text.contains("Example &lt;group&gt; &amp; friends"))
                XCTAssertFalse(panel.plainText.contains(language.text("without personal overrides", "sans préférence personnelle")))
                let rows = try decode(InlineKeyboardMarkup.self, from: panel.markup).inline_keyboard
                let actions = rows.flatMap { $0 }.compactMap(\.callback_data)
                XCTAssertEqual(actions.contains("fxclip:chat:-200:activation"), !enabled)
                XCTAssertFalse(actions.contains("fxclip:chat:-200:enable"))
                XCTAssertTrue(panel.plainText.contains(enabled
                    ? language.text("Active here", "Actif ici") : language.text("Not active yet", "Pas encore actif")))
                XCTAssertLessThanOrEqual(panel.text.utf16.count, 4096)
                XCTAssertLessThanOrEqual(rows.count, 4)
                XCTAssertTrue(actions.allSatisfy { $0.utf8.count <= 64 })
                let confirmation = SettingsUI.chat(Chat(id: -200, type: "group"), settings: ChatSettings(),
                    enabled: enabled, inherited: true, username: "fxclipbot", language: language, section: "activation")
                let confirmActions = try decode(InlineKeyboardMarkup.self, from: confirmation.markup)
                    .inline_keyboard.flatMap { $0 }.compactMap(\.callback_data)
                XCTAssertTrue(confirmation.plainText.contains(language.text("for everyone here", "pour tout le monde ici")))
                XCTAssertEqual(confirmActions.contains("fxclip:chat:-200:enable"), !enabled)
                if !enabled {
                    for phrase in language == .en ? ["Telegram", "bot server", "48 h", "not saved"]
                        : ["Telegram", "serveur du bot", "48 h", "pas enregistrés"] {
                        XCTAssertTrue(confirmation.plainText.contains(phrase), phrase)
                    }
                }
                XCTAssertLessThanOrEqual(confirmation.text.utf16.count, 4096)
            }
        }
    }

    func testJoinToAlreadyEnabledGroupDoesNotOfferActivation() async throws {
        try await membership(["status": "administrator"], chatID: -100, old: ["status": "left"])
        XCTAssertTrue((sent["text"] as? String)?.contains("Active here") == true)
        let actions = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(sent["reply_markup"]))
            .inline_keyboard.flatMap { $0 }.compactMap(\.callback_data)
        XCTAssertFalse(actions.contains("fxclip:chat:-100:activation"))
        XCTAssertTrue(actions.contains("fxclip:chat:-100:show"))
        XCTAssertNil(store.state.groupEnabled["-100"])
    }
}
