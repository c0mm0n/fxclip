import Foundation
import XCTest
@testable import FxTelegram

final class SecretaryStateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("secretary-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func legacy(users: [String: String] = ["7": "secretary"], defaultMode: String = "reply") throws -> StateStore {
        let object: [String: Any] = ["offset": 51, "chats": [:], "users": users,
                                   "defaultMode": defaultMode, "lastUpdateAt": 1000]
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("state.json"))
        return try StateStore(directory: directory)
    }

    func testMissingSecretaryFieldKeepsLegacyConsentAndOtherUsersUnchanged() throws {
        let store = try legacy(users: ["7": "secretary", "8": "off", "9": "reply"])
        XCTAssertTrue(store.state.personalSecretary.isEmpty)
        XCTAssertTrue(store.secretaryEnabled(userID: 7))
        for user: Int64 in [8, 9, 10] { XCTAssertFalse(store.secretaryEnabled(userID: user)) }
        try store.setGroupEnabled(false, chatID: -100)
        let restored = try StateStore(directory: directory)
        XCTAssertTrue(restored.secretaryEnabled(userID: 7))
        XCTAssertEqual(restored.state.users["7"], .secretary)
        XCTAssertEqual(restored.state.offset, 51)
    }

    func testSecretaryCompatibilitySetterPreservesEveryGroupOverrideAcrossReload() throws {
        let store = try StateStore(directory: directory)
        let choices: [Mode?] = [.reply, .replace, .off, nil]
        for (index, choice) in choices.enumerated() {
            let user = Int64(index + 7)
            try store.setMode(choice, userID: user)
            try store.setMode(.secretary, userID: user)
            let restored = try StateStore(directory: directory)
            XCTAssertEqual(restored.state.users[String(user)], choice)
            XCTAssertEqual(restored.state.personalSecretary[String(user)], true)
            XCTAssertTrue(restored.secretaryEnabled(userID: user))
        }
    }

    func testChangingLegacyGroupChoiceCapturesConsentBeforeOverwritingOrRemovingIt() throws {
        for choice: Mode? in [.reply, .replace, .off, nil] {
            let store = try legacy()
            try store.setMode(choice, userID: 7)
            let restored = try StateStore(directory: directory)
            XCTAssertEqual(restored.state.users["7"], choice)
            XCTAssertEqual(restored.state.personalSecretary["7"], true)
            XCTAssertTrue(restored.secretaryEnabled(userID: 7))
        }
    }

    func testExplicitFalseOverridesLegacyUserConsentAfterReloadAndGroupChanges() throws {
        let store = try legacy()
        try store.setSecretary(false, userID: 7)
        var restored = try StateStore(directory: directory)
        XCTAssertEqual(restored.state.personalSecretary["7"], false)
        XCTAssertFalse(restored.secretaryEnabled(userID: 7))
        for choice: Mode? in [.reply, .replace, .off, nil] {
            try restored.setMode(choice, userID: 7)
            restored = try StateStore(directory: directory)
            XCTAssertFalse(restored.secretaryEnabled(userID: 7))
            XCTAssertEqual(restored.state.personalSecretary["7"], false)
            XCTAssertEqual(restored.state.users["7"], choice)
        }
        try restored.setSecretary(true, userID: 7)
        XCTAssertTrue(try StateStore(directory: directory).secretaryEnabled(userID: 7))
    }

    func testLegacySecretaryDefaultFallbackHonorsPersonalModeAndExplicitFalse() throws {
        let store = try legacy(users: ["8": "reply", "9": "off", "10": "secretary"], defaultMode: "secretary")
        XCTAssertTrue(store.secretaryEnabled(userID: 7))
        XCTAssertFalse(store.secretaryEnabled(userID: 8))
        XCTAssertFalse(store.secretaryEnabled(userID: 9))
        XCTAssertTrue(store.secretaryEnabled(userID: 10))
        try store.setSecretary(false, userID: 7)
        let restored = try StateStore(directory: directory)
        XCTAssertFalse(restored.secretaryEnabled(userID: 7))
        XCTAssertEqual(restored.state.personalSecretary["7"], false)
        XCTAssertEqual(restored.state.defaultMode, .secretary)
        XCTAssertTrue(restored.secretaryEnabled(userID: 10))
    }

    func testGroupChoicesPreserveDefaultLegacySecretaryConsentBeforeWrite() throws {
        for choice: Mode? in [.reply, .replace, .off, nil] {
            let store = try legacy(users: [:], defaultMode: "secretary")
            try store.setMode(choice, userID: 7)
            let restored = try StateStore(directory: directory)
            XCTAssertTrue(restored.secretaryEnabled(userID: 7))
            XCTAssertEqual(restored.state.users["7"], choice)
        }
    }

    func testSecretaryTogglesDoNotOptIntoNativeRedditOrChangeMirrorSettings() throws {
        let store = try StateStore(directory: directory)
        let links = store.state.defaultLinkSettings
        for enabled in [true, false] {
            try store.setSecretary(enabled, userID: 7)
            let restored = try StateStore(directory: directory)
            XCTAssertEqual(restored.state.defaultLinkSettings, links)
            XCTAssertTrue(restored.state.personalLinkSettings.isEmpty)
            XCTAssertFalse(restored.state.defaultRedditVideos)
            XCTAssertTrue(restored.state.personalRedditVideos.isEmpty)
            XCTAssertTrue(restored.state.users.isEmpty)
            XCTAssertEqual(restored.state.defaultMode, .reply)
            XCTAssertEqual(restored.secretaryEnabled(userID: 7), enabled)
        }
    }
}
