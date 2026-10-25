import Foundation
import XCTest
@testable import FxTelegram

extension BotTests {
    func testSecretaryGroupReplyReplaceAndOffAreIndependentOfPrivateEdits() async throws {
        for choice in [Mode.reply, .replace, .off] {
            try store.setMode(choice, userID: 7)
            try store.setSecretary(true, userID: 7)
            api.calls = []
            try await handle()
            let expected = choice == .reply ? ["sendMessage"]
                : choice == .replace ? ["getChatMember", "sendMessage", "deleteMessage"] : []
            XCTAssertEqual(api.methods, expected, choice.rawValue)
            api.calls = []
            try await handle(["chat": ["id": 123, "type": "private"],
                              "business_connection_id": "connection"], business: true)
            XCTAssertEqual(api.methods, ["getBusinessConnection", "editMessageText"], choice.rawValue)
            XCTAssertEqual(api.calls.last?.1["text"] as? String, "Look https://fxtwitter.com/a/status/1")
            XCTAssertEqual(api.calls.last?.1["message_id"] as? Int64, 5)
            XCTAssertEqual(store.state.users["7"], choice)
        }
    }

    func testDisablingSecretaryStopsBusinessEditsWithoutChangingGroupReplacement() async throws {
        try store.setMode(.replace, userID: 7)
        try store.setSecretary(true, userID: 7)
        try store.setSecretary(false, userID: 7)
        try await handle(["chat": ["id": 123, "type": "private"],
                          "business_connection_id": "connection"], business: true)
        XCTAssertTrue(api.calls.isEmpty)
        try await handle()
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "deleteMessage"])
        XCTAssertFalse(try StateStore(directory: directory).secretaryEnabled(userID: 7))
    }

    func testLegacyPersonalSecretaryFollowsReplyReplaceAndOffGroupChoices() async throws {
        for choice in [Mode.reply, .replace, .off] {
            var state = BotState()
            state.users["7"] = .secretary
            var group = ChatSettings(); group.mode = choice
            state.chats["-100"] = group
            try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"))
            store = try StateStore(directory: directory)
            bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                      botID: 99, username: "fxclipbot")
            api.calls = []
            try await handle()
            let expected = choice == .reply ? ["sendMessage"]
                : choice == .replace ? ["getChatMember", "sendMessage", "deleteMessage"] : []
            XCTAssertEqual(api.methods, expected, choice.rawValue)
            XCTAssertEqual(store.state.users["7"], .secretary)
            XCTAssertTrue(store.secretaryEnabled(userID: 7))
        }
    }

    func testSecretarySlashCommandsPreserveGroupChoicesAndOnlyChangeAuthorsConsent() async throws {
        try store.setSecretary(true, userID: 7)
        for choice: Mode? in [.reply, .replace, .off, nil] {
            try store.setMode(choice, userID: 8)
            for (command, enabled) in [("/secretary on", true), ("/secretary off", false)] {
                api.calls = []
                try await privateCommand(command)
                let restored = try StateStore(directory: directory)
                XCTAssertEqual(restored.secretaryEnabled(userID: 8), enabled, command)
                XCTAssertEqual(restored.state.users["8"], choice, command)
                XCTAssertTrue(restored.secretaryEnabled(userID: 7))
                XCTAssertEqual(restored.state.defaultMode, .reply)
                XCTAssertFalse(restored.state.defaultRedditVideos)
                XCTAssertTrue(restored.state.personalRedditVideos.isEmpty)
                XCTAssertTrue(restored.state.personalLinkSettings.isEmpty)
                XCTAssertTrue(api.methods.contains("sendMessage"))
            }
        }
    }

    func testSecretaryCallbacksRequirePrivateIdentityAndExactAttachedKeyboard() async throws {
        for action in ["secretary", "secretary_off"] {
            // Start opposite to the requested value, so an unauthorized mutation is visible.
            try store.setSecretary(action == "secretary_off", userID: 8)
            try store.setMode(.replace, userID: 8)
            let before = try JSONEncoder.sortedSecretarySnapshot(store.state)
            for (chatID, type): (Int64, String) in [(7, "private"), (-100, "supergroup")] {
                api.calls = []
                try await callback("fxclip:personal:\(action)", chatID: chatID, chatType: type)
                XCTAssertEqual(api.methods, ["answerCallbackQuery"], action)
                XCTAssertEqual(try JSONEncoder.sortedSecretarySnapshot(store.state), before, action)
            }
            api.calls = []
            try await callback("fxclip:personal:\(action)", messageMarkup: ["inline_keyboard": [[[
                "text": "Other action", "callback_data": "fxclip:personal:show",
            ]]]])
            XCTAssertEqual(api.methods, ["answerCallbackQuery"], action)
            XCTAssertEqual(try JSONEncoder.sortedSecretarySnapshot(store.state), before, action)
        }
    }

    func testSecretaryCallbacksToggleConsentReturnSetupAndPreserveGroupAndLinkChoices() async throws {
        try store.setMode(.off, userID: 8)
        let defaultLinks = store.state.defaultLinkSettings
        for (action, enabled) in [("secretary", true), ("secretary_off", false)] {
            api.calls = []
            try await callback("fxclip:personal:\(action)")
            let restored = try StateStore(directory: directory)
            XCTAssertEqual(restored.secretaryEnabled(userID: 8), enabled)
            XCTAssertEqual(restored.state.personalSecretary["8"], enabled)
            XCTAssertEqual(restored.state.users["8"], .off)
            XCTAssertFalse(restored.secretaryEnabled(userID: 7))
            XCTAssertEqual(restored.state.defaultLinkSettings, defaultLinks)
            XCTAssertTrue(restored.state.personalLinkSettings.isEmpty)
            XCTAssertFalse(restored.state.defaultRedditVideos)
            XCTAssertTrue(restored.state.personalRedditVideos.isEmpty)
            XCTAssertEqual(api.methods, ["answerCallbackQuery", "editMessageText"])
            let edit = try XCTUnwrap(api.calls.last?.1)
            XCTAssertTrue((edit["text"] as? String)?.contains("My preferences · Secretary") == true)
            XCTAssertEqual(edit["chat_id"] as? Int64, 8)
            let markup = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(edit["reply_markup"]))
            let actions = Set(markup.inline_keyboard.flatMap { $0 }.compactMap(\.callback_data))
            XCTAssertTrue(actions.contains("fxclip:personal:\(enabled ? "secretary_off" : "secretary")"))
            XCTAssertFalse(actions.contains("fxclip:personal:reply"))
        }
    }
}

private extension JSONEncoder {
    static func sortedSecretarySnapshot(_ state: BotState) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }
}
