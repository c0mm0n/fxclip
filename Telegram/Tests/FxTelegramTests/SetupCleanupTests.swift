import Foundation
import XCTest
@testable import FxTelegram

extension BotTests {
    func testSetupCleanupDeletesOnlyItsGroupCommandAfterPanelConfirmation() async throws {
        for command in ["/setup", "/setup@fxclipbot", "/fxclip", "/fxclip@fxclipbot"] {
            api.calls = []
            try await handle(["text": command, "message_id": 17])
            XCTAssertEqual(api.methods, ["sendMessage", "getChatMember", "deleteMessage"])
            let lookup = try XCTUnwrap(api.calls.first { $0.0 == "getChatMember" }?.1)
            XCTAssertEqual(lookup["user_id"] as? Int64, 99)
            let deletion = try XCTUnwrap(api.calls.last?.1)
            XCTAssertEqual(deletion["chat_id"] as? Int64, -100)
            XCTAssertEqual(deletion["message_id"] as? Int64, 17)
        }
    }

    func testSetupWithoutDeleteRightsKeepsCommandAndWorkingPanel() async throws {
        for member: [String: Any] in [
            ["status": "member"],
            ["status": "administrator", "can_delete_messages": false],
        ] {
            api.calls = []; api.memberResult = member
            try await handle(["text": "/setup"])
            XCTAssertEqual(api.methods, ["sendMessage", "getChatMember"])
        }
    }

    func testSetupCleanupLookupAndDeleteFailuresNeverResendPanel() async throws {
        api.failMember = true
        try await handle(["text": "/setup"])
        XCTAssertEqual(api.methods, ["sendMessage", "getChatMember"])
        api.calls = []; api.failMember = false; api.failDelete = true
        try await handle(["text": "/setup"])
        XCTAssertEqual(api.methods, ["sendMessage", "getChatMember", "deleteMessage"])
        XCTAssertTrue(store.state.chats.isEmpty)
    }

    func testSetupAmbiguousOrFailedPanelSendNeverDeletesCommand() async throws {
        for result: Any in [true, [:] as [String: Any], ["message_id": true],
                            ["message_id": 0], ["message_id": 5]] {
            api.calls = []; api.sendResult = result
            try await handle(["text": "/setup"])
            XCTAssertEqual(api.methods, ["sendMessage"])
        }
        api.calls = []; api.failSend = true
        do { try await handle(["text": "/setup"]); XCTFail("Expected failed panel send") }
        catch {}
        XCTAssertEqual(api.methods, ["sendMessage"])
    }

    func testSetupForAnotherBotAndPrivateSettingsAreNotDeleted() async throws {
        try await handle(["text": "/setup@anotherbot"])
        XCTAssertTrue(api.calls.isEmpty)
        try await privateCommand("/settings")
        XCTAssertTrue(api.methods.contains("sendMessage"))
        XCTAssertFalse(api.methods.contains("deleteMessage"))
    }
}
