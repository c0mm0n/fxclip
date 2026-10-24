import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

final class FacebookSettingsTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try StateStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func builtins() throws -> Rules {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/rules.json")
        return try Rules.load(Data(contentsOf: shared))
    }

    func testFreshAndLegacyStateDoNotOptIntoFacebookRequests() throws {
        XCTAssertFalse(store.state.defaultFacebookReels)
        XCTAssertTrue(store.state.personalFacebookReels.isEmpty)
        let legacy = #"{"offset":23,"chats":{"-100":{"mode":"replace","previews":false,"youTubeCards":true}},"users":{"8":"off"},"defaultMode":"reply","lastUpdateAt":1000,"defaultYouTubeCards":true,"personalYouTubeCards":{"8":true}}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("state.json"))
        let state = try StateStore(directory: directory).state
        XCTAssertFalse(state.defaultFacebookReels)
        XCTAssertTrue(state.personalFacebookReels.isEmpty)
        XCTAssertNil(state.chats["-100"]?.facebookReels)
        XCTAssertEqual(state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(state.chats["-100"]?.previews, false)
        XCTAssertTrue(state.defaultYouTubeCards)
        XCTAssertEqual(state.personalYouTubeCards["8"], true)
        XCTAssertEqual(state.offset, 23)
        XCTAssertEqual(state.users["8"], .off)
    }

    func testRoundTripPreservesExplicitOffOnAndInheritanceAcrossScopes() throws {
        try store.setDefaultFacebookReels(true)
        try store.setPersonalFacebookReels(false, userID: 8)
        try store.setPersonalFacebookReels(true, userID: 9)
        var group = ChatSettings()
        group.facebookReels = false
        try store.set(group, chatID: -100)
        group.facebookReels = true
        try store.set(group, chatID: -200)
        try store.set(ChatSettings(), chatID: -300)
        let state = try StateStore(directory: directory).state
        XCTAssertTrue(state.defaultFacebookReels)
        XCTAssertEqual(state.personalFacebookReels, ["8": false, "9": true])
        XCTAssertEqual(state.chats["-100"]?.facebookReels, false)
        XCTAssertEqual(state.chats["-200"]?.facebookReels, true)
        XCTAssertNil(state.chats["-300"]?.facebookReels)
        XCTAssertNil(state.personalFacebookReels["10"])
    }

    func testExistingLinkSettersPreserveFacebookChoicesIncludingExplicitFalse() throws {
        try store.setDefaultFacebookReels(true)
        try store.setPersonalFacebookReels(true, userID: 8)
        try store.setPersonalFacebookReels(false, userID: 9)
        var links = UserSettings()
        links.trackersEverywhere = false
        try store.setDefaultLinks(links, youTubeCards: false)
        try store.setPersonalLinks(links, youTubeCards: false, userID: 8)
        try store.setPersonalLinks(nil, youTubeCards: nil, userID: 9)
        let state = try StateStore(directory: directory).state
        XCTAssertTrue(state.defaultFacebookReels)
        XCTAssertEqual(state.personalFacebookReels, ["8": true, "9": false])
        XCTAssertEqual(state.defaultLinkSettings, links)
        XCTAssertEqual(state.personalLinkSettings["8"], links)
    }

    func testFacebookSettersPreserveSharedSettingsAndOtherTelegramPreferences() throws {
        var links = UserSettings()
        links.disabledSites = ["amazon"]
        try store.setDefaultLinks(links, youTubeCards: false)
        try store.setPersonalLinks(links, youTubeCards: true, userID: 8)
        try store.setMode(.off, userID: 8)
        try store.setDefaultFacebookReels(true)
        try store.setPersonalFacebookReels(false, userID: 8)
        try store.setPersonalFacebookReels(nil, userID: 8)
        try store.setDefaultFacebookReels(false)
        let state = try StateStore(directory: directory).state
        XCTAssertFalse(state.defaultFacebookReels)
        XCTAssertNil(state.personalFacebookReels["8"])
        XCTAssertEqual(state.defaultLinkSettings, links)
        XCTAssertEqual(state.personalLinkSettings["8"], links)
        XCTAssertFalse(state.defaultYouTubeCards)
        XCTAssertEqual(state.personalYouTubeCards["8"], true)
        XCTAssertEqual(state.users["8"], .off)
        let sharedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(links)) as? [String: Any])
        XCTAssertNil(sharedJSON["facebookReels"])
    }

    func testChatMissingFacebookKeyInheritsRatherThanOptingIn() throws {
        let settings = try JSONDecoder().decode(ChatSettings.self, from: Data("{}".utf8))
        XCTAssertNil(settings.facebookReels)
        XCTAssertEqual(settings.mode, .reply)
        XCTAssertTrue(settings.previews)
    }

    private func assertPrivateFacebookDisclosure(_ panel: SettingsUI, language: BotLanguage,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        for phrase in language == .en ? [
            "public Facebook", "bot server", "copy to Telegram", "Private resolution",
            "no public facebed.com service or Facebook login", "20 MiB",
            "larger videos", "Open Facebook", "keep the original", "Duplicates",
            "48 h", "locally",
        ] : [
            "vidéo publique sur Facebook", "Le bot télécharge", "copie à Telegram", "Résolution privée",
            "sans service public facebed.com ni connexion Facebook", "20 Mio",
            "Ouvrir Facebook", "l’original reste", "doublons", "48 h", "localement",
        ] {
            XCTAssertTrue(panel.plainText.contains(phrase), phrase, file: file, line: line)
        }
        for stale in ["metadata via Facebed", "sent to Facebed", "envoyé à Facebed",
                      "métadonnées via Facebed", "https://facebed.com"] {
            XCTAssertFalse(panel.text.contains(stale), stale, file: file, line: line)
        }
    }

    func testFacebookPreviewToggleAndDisclosureInBothLanguagesAndEveryScope() throws {
        let rules = try builtins()
        for language in [BotLanguage.en, .fr] {
            for scope in ["p", "d", "c:-100"] {
                for enabled in [false, true] {
                    let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: scope,
                        section: "facebook", inherited: true, facebookReels: enabled, language: language)
                    let rows = try XCTUnwrap(panel.markup["inline_keyboard"] as? [[[String: String]]])
                    let buttons = rows.flatMap { $0 }
                    let actions = buttons.compactMap { $0["callback_data"] }
                    let facebookAction = "fxclip:rules:\(scope):facebook:\(enabled ? "off" : "on")"
                    let facebookButton = try XCTUnwrap(buttons.first { $0["callback_data"] == facebookAction })
                    let scopeLabel = scope == "p" ? language.text("for me", "pour moi")
                        : scope == "d" ? language.text("by default", "par défaut")
                        : language.text("for this group", "pour ce groupe")
                    let actionLabel = enabled ? language.text("Disable", "Désactiver") : language.text("Enable", "Activer")
                    XCTAssertEqual(facebookButton["text"], "\(actionLabel) \(scopeLabel)")
                    let state = enabled ? language.text("On", "Activé") : language.text("Off", "Désactivé")
                    XCTAssertTrue(panel.text.contains("<b>Facebook</b> · \(state)"))
                    assertPrivateFacebookDisclosure(panel, language: language)
                    XCTAssertTrue(panel.plainText.contains("5 minutes"))
                    XCTAssertTrue(panel.plainText.contains(language == .en ? "not saved" : "pas enregistrés"))
                    XCTAssertLessThanOrEqual(panel.plainText.utf16.count, 4096)
                    XCTAssertTrue(actions.allSatisfy { $0.utf8.count <= 64 })
                }
            }
        }
    }

    func testDefaultOffToggleAndMasterPauseAreVisible() throws {
        let rules = try builtins()
        for language in [BotLanguage.en, .fr] {
            let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: "c:-100",
                section: "facebook", inherited: true, previewsEnabled: false, language: language)
            let rows = try XCTUnwrap(panel.markup["inline_keyboard"] as? [[[String: String]]])
            XCTAssertTrue(rows.flatMap { $0 }.contains { $0["callback_data"] == "fxclip:rules:c:-100:facebook:on" })
            XCTAssertTrue(panel.plainText.contains(language == .en ? "Enhanced previews paused" : "Aperçus améliorés en pause"))
            XCTAssertTrue(panel.plainText.contains("YouTube"))
            XCTAssertTrue(panel.plainText.contains("Facebook"))
            XCTAssertTrue(rows.flatMap { $0 }.compactMap { $0["callback_data"] }.allSatisfy { $0.utf8.count <= 64 })
            XCTAssertLessThanOrEqual(panel.plainText.utf16.count, 4096)
        }
    }

    func testPreviewDisclosurePreservesHTMLHostEscaping() throws {
        var rules = try builtins()
        let index = try XCTUnwrap(rules.previews.firstIndex { $0.id == "reddit" })
        rules.previews[index].name = "Public <video> & preview"
        var links = UserSettings()
        links.previews["reddit"] = .init(enabled: true, apps: ["telegram"], targetHost: "mirror.example")
        let panel = SettingsUI.rules(links, builtins: rules, scope: "p", section: "preview:reddit",
            inherited: false, facebookReels: true)
        XCTAssertTrue(panel.text.contains("mirror.example"))
        XCTAssertTrue(panel.text.contains("Public &lt;video&gt; &amp; preview"))
        XCTAssertFalse(panel.text.contains("Public <video> & preview"))
        XCTAssertTrue(panel.plainText.contains("Public <video> & preview"))
        XCTAssertFalse(panel.plainText.contains("<b>"))
    }

    func testAboutAndGroupActivationDiscloseSeparateFacebookOptInInBothLanguages() throws {
        let chat = Chat(id: -100, type: "supergroup", title: "Example")
        for language in [BotLanguage.en, .fr] {
            let panels = [
                SettingsUI.personal(mode: nil, defaultMode: .reply, owner: false, language: language, section: "about"),
                SettingsUI.defaults(mode: .reply, language: language, section: "about"),
                SettingsUI.chat(chat, settings: ChatSettings(), enabled: true, inherited: true,
                    username: "fxclipbot", language: language, section: "about"),
                SettingsUI.group(KnownGroup(chat: chat), enabled: false, rights: nil, language: language),
            ]
            for panel in panels {
                XCTAssertTrue(panel.text.contains(language == .en ? "off by default" : "désactivées par défaut"))
                XCTAssertTrue(panel.text.contains(language == .en ? "separately opt-in" : "à activer séparément"))
                XCTAssertTrue(panel.text.contains(language == .en ? "Facebook videos" : "vidéos Facebook"))
                XCTAssertTrue(panel.text.contains("Telegram"))
                XCTAssertTrue(panel.plainText.contains("5 minutes"))
                XCTAssertTrue(panel.plainText.contains("48 h"))
                XCTAssertTrue(panel.plainText.contains(language == .en ? "Open-button URLs" : "URL des boutons d’ouverture"))
                XCTAssertTrue(panel.plainText.contains(language == .en ? "locally" : "localement"))
                let rows = try XCTUnwrap(panel.markup["inline_keyboard"] as? [[[String: String]]])
                XCTAssertTrue(rows.flatMap { $0 }.compactMap { $0["callback_data"] }.allSatisfy { $0.utf8.count <= 64 })
                XCTAssertLessThanOrEqual(panel.plainText.utf16.count, 4096)
            }
        }
    }
}
