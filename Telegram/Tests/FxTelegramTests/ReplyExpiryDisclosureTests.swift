import XCTest
@testable import FxTelegram

final class ReplyExpiryDisclosureTests: XCTestCase {
    func testGroupActivationPanelsDiscloseTemporaryOpenLinkStorageInBothLanguages() {
        let chat = Chat(id: -100, type: "supergroup", title: "Example group")
        for language in [BotLanguage.en, .fr] {
            let panels = [
                SettingsUI.chat(chat, settings: ChatSettings(), enabled: true, inherited: true,
                                username: "fxclipbot", language: language),
                SettingsUI.group(KnownGroup(chat: chat), enabled: true, rights: nil, language: language),
            ]
            for panel in panels {
                XCTAssertTrue(panel.plainText.contains("5 minutes"))
                XCTAssertTrue(panel.plainText.contains("48 h"))
                XCTAssertTrue(panel.plainText.contains(language == .en
                    ? "Open-button links stay locally" : "liens des boutons d’ouverture restent localement"))
                XCTAssertLessThanOrEqual(panel.plainText.utf16.count, 4096)
            }
        }
    }
}
