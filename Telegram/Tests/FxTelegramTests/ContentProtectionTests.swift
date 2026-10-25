import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

extension BotTests {
    func testProtectionDisclosureExplainsScopeAndRetroactiveLimitInBothLanguages() {
        for language in BotLanguage.allCases {
            let panel = SettingsUI.rules(UserSettings(), builtins: engine.rules, scope: "p", section: "info",
                                         inherited: true, language: language)
            XCTAssertTrue(panel.plainText.contains(language.text("cannot be forwarded or saved", "bloquent le transfert et l’enregistrement")))
            XCTAssertTrue(panel.plainText.contains(language.text("Direct link replies stay shareable", "Les liens traités en privé restent partageables")))
            XCTAssertTrue(panel.plainText.contains(language.text("not protected retroactively", "pas protégés rétroactivement")))
            XCTAssertLessThanOrEqual(panel.text.utf16.count, 4096)
        }
    }

    func testGroupRepliesAndAutomaticReplacementsAreProtectedBeforeCreditLeavesBot() async throws {
        for mode in [Mode.reply, .replace] {
            var settings = ChatSettings(); settings.mode = mode
            try store.set(settings, chatID: -100)
            api.calls = []
            try await handle()
            XCTAssertEqual(sent["protect_content"] as? Bool, true)
            XCTAssertEqual(api.methods.contains("deleteMessage"), mode == .replace)
            if mode == .replace { XCTAssertTrue((sent["text"] as? String)?.contains("Posted by") == true) }
        }
    }

    func testGroupPhotoAndPanelsAreProtectedButDirectLinksRemainShareable() async throws {
        _ = enableYouTubeCards()
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ"])
        XCTAssertEqual(api.calls.first { $0.0 == "sendPhoto" }?.1["protect_content"] as? Bool, true)
        api.calls = []
        try await membership(["status": "administrator"], old: ["status": "left"])
        XCTAssertEqual(sent["protect_content"] as? Bool, true)
        api.calls = []
        try await handle(["text": "/setup"])
        XCTAssertEqual(sent["protect_content"] as? Bool, true)
        api.calls = []
        try await privateCommand("https://example.com/article")
        XCTAssertNil(sent["protect_content"], "Direct link replies carry no generated author credit")
        XCTAssertEqual(sent["text"] as? String, "https://example.com/article")
    }

    func testGroupPanelEditsDoNotAttemptUnsupportedProtectionChangeButFallbackSendsDo() async throws {
        try await callback("fxclip:chat:-100:show", chatID: -100, chatType: "supergroup")
        XCTAssertNil(api.calls.first { $0.0 == "editMessageText" }?.1["protect_content"])
        api.calls = []; api.failEdit = true
        try await callback("fxclip:chat:-100:show", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(sent["protect_content"] as? Bool, true)
    }
}
