import Foundation
import XCTest
@testable import FxTelegram

private final class ProfileRecordingAPI: BotAPI {
    var calls: [(method: String, parameters: [String: Any])] = []
    var failure: Error?

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters))
        if let failure { throw failure }
        return true
    }
}

final class BotProfileTests: XCTestCase {
    private func menu(_ api: ProfileRecordingAPI, scope: String, code: String,
                      userID: Int64? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: String]] {
        let matches = api.calls.filter {
            let value = $0.parameters["scope"] as? [String: Any]
            return $0.method == "setMyCommands" && value?["type"] as? String == scope
                && value?["chat_id"] as? Int64 == userID && $0.parameters["language_code"] as? String == code
        }
        XCTAssertEqual(matches.count, 1, file: file, line: line)
        return try XCTUnwrap(matches.first?.parameters["commands"] as? [[String: String]], file: file, line: line)
    }

    func testProfileUsesEnglishFallbackAndFrenchDescriptionFields() async throws {
        let api = ProfileRecordingAPI()
        try await BotProfile.configure(api: api, ownerIDs: [], userLanguages: [:])
        for (method, field, english, french) in [
            ("setMyDescription", "description",
             "fxclip cleans tracking from links and improves previews in Telegram. Open /settings to choose your preferences.",
             "fxclip retire les paramètres de suivi des liens et améliore leurs aperçus dans Telegram. Ouvrez /settings pour choisir vos réglages."),
            ("setMyShortDescription", "short_description",
             "Clean links and better previews in Telegram.",
             "Des liens nettoyés et de meilleurs aperçus dans Telegram.")
        ] {
            let calls = api.calls.filter { $0.method == method }
            XCTAssertEqual(calls.count, 2)
            for (code, expected) in [("", english), ("fr", french)] {
                let payload = try XCTUnwrap(calls.first { $0.parameters["language_code"] as? String == code }?.parameters)
                XCTAssertEqual(payload[field] as? String, expected)
                XCTAssertEqual(Set(payload.keys), ["language_code", field])
                XCTAssertLessThanOrEqual(expected.count, field == "description" ? 512 : 120)
            }
        }
        XCTAssertFalse(api.calls.contains { $0.method == "setMyName" })
    }

    func testDefaultAndGroupScopesHaveStableCommandsInBothLocales() async throws {
        let api = ProfileRecordingAPI()
        try await BotProfile.configure(api: api, ownerIDs: [], userLanguages: [:])
        XCTAssertEqual(api.calls.count, 8)
        for code in ["", "fr"] {
            let personal = try menu(api, scope: "default", code: code)
            let group = try menu(api, scope: "all_group_chats", code: code)
            XCTAssertEqual(personal.compactMap { $0["command"] }, ["settings", "language", "help", "chatid"])
            XCTAssertEqual(group.compactMap { $0["command"] }, ["setup", "fxclip", "help", "chatid"])
            XCTAssertEqual(personal.first?["description"], code == "fr" ? "Choisir vos réglages" : "Choose your settings")
            XCTAssertEqual(group.first?["description"], code == "fr" ? "Configurer ce groupe" : "Configure this group")
        }
        for call in api.calls where call.method == "setMyCommands" {
            let scope = try XCTUnwrap(call.parameters["scope"] as? [String: Any])
            XCTAssertEqual(Set(scope.keys), ["type"])
            for command in try XCTUnwrap(call.parameters["commands"] as? [[String: String]]) {
                let name = try XCTUnwrap(command["command"])
                let description = try XCTUnwrap(command["description"])
                XCTAssertTrue(name.utf8.allSatisfy { (97...122).contains($0) || $0 == 95 })
                XCTAssertFalse(description.isEmpty)
                XCTAssertLessThan(description.count, 256)
            }
        }
    }

    func testExplicitPreferenceOverridesBothTelegramLocaleSlots() async throws {
        for language in BotLanguage.allCases {
            let api = ProfileRecordingAPI()
            try await BotProfile.configureUser(api: api, userID: 8_642_135_790, language: language, owner: false)
            XCTAssertEqual(api.calls.count, 2)
            let fallback = try menu(api, scope: "chat", code: "", userID: 8_642_135_790)
            XCTAssertEqual(fallback, try menu(api, scope: "chat", code: "fr", userID: 8_642_135_790))
            XCTAssertEqual(fallback.first?["description"], language == .fr ? "Choisir vos réglages" : "Choose your settings")
            XCTAssertEqual(fallback.compactMap { $0["command"] }, ["settings", "language", "help", "chatid"])
        }
    }

    func testAutomaticRestoresIndependentEnglishAndFrenchMenus() async throws {
        let api = ProfileRecordingAPI()
        try await BotProfile.configureUser(api: api, userID: 42, language: .fr, owner: false)
        api.calls.removeAll()
        try await BotProfile.configureUser(api: api, userID: 42, language: nil, owner: false)
        XCTAssertEqual(api.calls.map(\.method), ["setMyCommands", "setMyCommands"])
        let english = try menu(api, scope: "chat", code: "", userID: 42)
        let french = try menu(api, scope: "chat", code: "fr", userID: 42)
        XCTAssertEqual(english.first?["description"], "Choose your settings")
        XCTAssertEqual(french.first?["description"], "Choisir vos réglages")
        XCTAssertEqual(english.compactMap { $0["command"] }, french.compactMap { $0["command"] })
    }

    func testStartupOwnersGetPrivateExtrasAndExplicitPreferenceIsPreserved() async throws {
        let api = ProfileRecordingAPI()
        try await BotProfile.configure(api: api, ownerIDs: [314, 927], userLanguages: ["314": .en, "681": .fr])
        XCTAssertEqual(api.calls.count, 14)
        for code in ["", "fr"] {
            let explicitOwner = try menu(api, scope: "chat", code: code, userID: 314)
            let autoOwner = try menu(api, scope: "chat", code: code, userID: 927)
            for commands in [explicitOwner, autoOwner] {
                XCTAssertEqual(commands.compactMap { $0["command"] }, ["settings", "language", "help", "chatid", "default", "groups"])
            }
            XCTAssertEqual(explicitOwner.last?["description"], "Manage connected groups")
            XCTAssertEqual(autoOwner.last?["description"], code == "fr" ? "Gérer les groupes connectés" : "Manage connected groups")
            let user = try menu(api, scope: "chat", code: code, userID: 681)
            XCTAssertEqual(user.first?["description"], "Choisir vos réglages")
            XCTAssertEqual(user.compactMap { $0["command"] }, ["settings", "language", "help", "chatid"])
        }
    }

    func testOwnerExtrasSurviveExplicitAndAutomaticLanguageChanges() async throws {
        for language: BotLanguage? in [.en, .fr, nil] {
            let api = ProfileRecordingAPI()
            try await BotProfile.configureUser(api: api, userID: 9_876_543_210, language: language, owner: true)
            for code in ["", "fr"] {
                let commands = try menu(api, scope: "chat", code: code, userID: 9_876_543_210)
                XCTAssertEqual(commands.suffix(2).compactMap { $0["command"] }, ["default", "groups"])
                let french = language == .fr || (language == nil && code == "fr")
                XCTAssertEqual(commands.last?["description"], french ? "Gérer les groupes connectés" : "Manage connected groups")
                let payload = try XCTUnwrap(api.calls.first { $0.parameters["language_code"] as? String == code }?.parameters)
                let scope = try XCTUnwrap(payload["scope"] as? [String: Any])
                XCTAssertEqual(Set(scope.keys), ["type", "chat_id"])
                XCTAssertTrue(scope["chat_id"] is Int64)
                XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
            }
        }
    }

    func testStartupSkipsInvalidUserIDsSafely() async throws {
        let api = ProfileRecordingAPI()
        try await BotProfile.configure(api: api, ownerIDs: [], userLanguages: [
            "unknown": .fr, "": .fr, "0": .fr, "-123": .fr,
            "9223372036854775808": .fr, " 123": .fr, "0123": .fr, "+123": .fr, "123": .en
        ])
        XCTAssertEqual(api.calls.count, 10)
        for code in ["", "fr"] {
            XCTAssertEqual(try menu(api, scope: "chat", code: code, userID: 123).first?["description"], "Choose your settings")
        }
    }

    func testInvalidPrivateIDsDoNotCallTelegram() async throws {
        let api = ProfileRecordingAPI()
        for id: Int64 in [0, -1, .min] {
            try await BotProfile.configureUser(api: api, userID: id, language: .fr, owner: true)
        }
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testMetadataFailuresAreThrownToCaller() async throws {
        let api = ProfileRecordingAPI()
        api.failure = BotError.telegram(403)
        do {
            try await BotProfile.configure(api: api, ownerIDs: [], userLanguages: [:])
            XCTFail("Expected profile failure")
        } catch BotError.telegram(403) {} catch { XCTFail("Unexpected error: \(error)") }
        api.calls.removeAll()
        do {
            try await BotProfile.configureUser(api: api, userID: 42, language: .en, owner: false)
            XCTFail("Expected command menu failure")
        } catch BotError.telegram(403) {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(api.calls.count, 1)
    }
}
