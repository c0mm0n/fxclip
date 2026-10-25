import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

final class RedditSettingsTests: XCTestCase {
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

    private func buttons(_ panel: SettingsUI) throws -> [[String: String]] {
        try XCTUnwrap(panel.markup["inline_keyboard"] as? [[[String: String]]]).flatMap { $0 }
    }

    private func assertTelegramLimits(_ panel: SettingsUI, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertLessThanOrEqual(panel.plainText.utf16.count, 4096, file: file, line: line)
        XCTAssertTrue(try buttons(panel).compactMap { $0["callback_data"] }.allSatisfy { $0.utf8.count <= 64 },
                      file: file, line: line)
    }

    func testFreshAndLegacyUpgradeStayOffAndPreserveDisabledMirror() throws {
        XCTAssertFalse(store.state.defaultRedditVideos)
        XCTAssertTrue(store.state.personalRedditVideos.isEmpty)
        let legacy = #"{"offset":23,"chats":{"-100":{"mode":"replace","previews":false,"engineSettings":{"previews":{"reddit":{"enabled":false,"apps":["telegram"]}}},"facebookReels":true}},"users":{"8":"off"},"defaultMode":"reply","lastUpdateAt":1000,"defaultLinkSettings":{"previews":{"reddit":{"enabled":false,"apps":["telegram"]}}},"personalLinkSettings":{"8":{"previews":{"reddit":{"enabled":false,"apps":["telegram"]}}}},"defaultFacebookReels":true,"personalFacebookReels":{"8":false}}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("state.json"))
        let state = try StateStore(directory: directory).state
        XCTAssertFalse(state.defaultRedditVideos)
        XCTAssertTrue(state.personalRedditVideos.isEmpty)
        XCTAssertNil(state.chats["-100"]?.redditVideos)
        XCTAssertEqual(state.defaultLinkSettings.previews["reddit"]?.enabled, false)
        XCTAssertEqual(state.personalLinkSettings["8"]?.previews["reddit"]?.enabled, false)
        XCTAssertEqual(state.chats["-100"]?.engineSettings?.previews["reddit"]?.enabled, false)
        XCTAssertEqual(state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(state.chats["-100"]?.previews, false)
        XCTAssertEqual(state.chats["-100"]?.facebookReels, true)
        XCTAssertTrue(state.defaultFacebookReels)
        XCTAssertEqual(state.personalFacebookReels["8"], false)
        XCTAssertEqual(state.offset, 23)
        XCTAssertEqual(state.users["8"], .off)
    }

    func testPartialAndNullFieldsInheritWithoutOptingIn() throws {
        for json in ["{}", #"{"redditVideos":null,"facebookReels":true}"#] {
            let group = try JSONDecoder().decode(ChatSettings.self, from: Data(json.utf8))
            XCTAssertNil(group.redditVideos)
            XCTAssertEqual(group.mode, .reply)
            XCTAssertTrue(group.previews)
        }
        let json = #"{"offset":0,"chats":{},"users":{},"defaultMode":"reply","lastUpdateAt":1,"defaultRedditVideos":null,"personalRedditVideos":null}"#
        let state = try JSONDecoder().decode(BotState.self, from: Data(json.utf8))
        XCTAssertFalse(state.defaultRedditVideos)
        XCTAssertTrue(state.personalRedditVideos.isEmpty)
    }

    func testPersistenceOfOnOffAndNilAtEachScope() throws {
        try store.setDefaultRedditVideos(true)
        try store.setPersonalRedditVideos(false, userID: 8)
        try store.setPersonalRedditVideos(true, userID: 9)
        var group = ChatSettings()
        group.redditVideos = false
        try store.set(group, chatID: -100)
        group.redditVideos = true
        try store.set(group, chatID: -200)
        group.redditVideos = nil
        try store.set(group, chatID: -300)
        let state = try StateStore(directory: directory).state
        XCTAssertTrue(state.defaultRedditVideos)
        XCTAssertEqual(state.personalRedditVideos, ["8": false, "9": true])
        XCTAssertEqual(state.chats["-100"]?.redditVideos, false)
        XCTAssertEqual(state.chats["-200"]?.redditVideos, true)
        XCTAssertNil(state.chats["-300"]?.redditVideos)
        // Scalar inheritance: explicit false beats a true group/default value.
        XCTAssertFalse(state.personalRedditVideos["8"] ?? state.chats["-200"]?.redditVideos ?? state.defaultRedditVideos)
        XCTAssertTrue(state.personalRedditVideos["10"] ?? state.chats["-300"]?.redditVideos ?? state.defaultRedditVideos)
        try store.setPersonalRedditVideos(nil, userID: 8)
        try store.setDefaultRedditVideos(false)
        let reset = try StateStore(directory: directory).state
        XCTAssertNil(reset.personalRedditVideos["8"])
        XCTAssertEqual(reset.personalRedditVideos["9"], true)
        XCTAssertFalse(reset.defaultRedditVideos)
    }

    func testOldLinkAndFacebookSettersDoNotClobberReddit() throws {
        try store.setDefaultRedditVideos(true)
        try store.setPersonalRedditVideos(false, userID: 8)
        try store.setPersonalRedditVideos(true, userID: 9)
        var links = UserSettings()
        links.previews["reddit"] = .init(enabled: false, apps: ["telegram"])
        try store.setDefaultLinks(links, youTubeCards: false)
        try store.setPersonalLinks(links, youTubeCards: false, userID: 8)
        try store.setPersonalLinks(nil, youTubeCards: nil, userID: 9)
        try store.setDefaultFacebookReels(true)
        try store.setPersonalFacebookReels(true, userID: 8)
        try store.setPersonalFacebookReels(nil, userID: 9)
        let state = try StateStore(directory: directory).state
        XCTAssertTrue(state.defaultRedditVideos)
        XCTAssertEqual(state.personalRedditVideos, ["8": false, "9": true])
        XCTAssertEqual(state.defaultLinkSettings.previews["reddit"]?.enabled, false)
        XCTAssertEqual(state.personalLinkSettings["8"]?.previews["reddit"]?.enabled, false)
    }

    func testDedicatedRedditSettersPreserveOtherChoicesAndSharedSettings() throws {
        var links = UserSettings()
        links.disabledSites = ["amazon"]
        links.previews["reddit"] = .init(enabled: false, apps: ["telegram"], targetHost: "mirror.example")
        try store.setDefaultLinks(links, youTubeCards: false)
        try store.setPersonalLinks(links, youTubeCards: true, userID: 8)
        try store.setDefaultFacebookReels(true)
        try store.setPersonalFacebookReels(false, userID: 8)
        try store.setMode(.off, userID: 8)
        var group = ChatSettings()
        group.engineSettings = links
        group.facebookReels = true
        try store.set(group, chatID: -100)
        try store.setDefaultRedditVideos(true)
        try store.setPersonalRedditVideos(false, userID: 8)
        try store.setPersonalRedditVideos(nil, userID: 8)
        try store.setDefaultRedditVideos(false)
        let state = try StateStore(directory: directory).state
        XCTAssertEqual(state.defaultLinkSettings, links)
        XCTAssertEqual(state.personalLinkSettings["8"], links)
        XCTAssertEqual(state.chats["-100"]?.engineSettings, links)
        XCTAssertEqual(state.chats["-100"]?.facebookReels, true)
        XCTAssertNil(state.chats["-100"]?.redditVideos)
        XCTAssertFalse(state.defaultYouTubeCards)
        XCTAssertEqual(state.personalYouTubeCards["8"], true)
        XCTAssertTrue(state.defaultFacebookReels)
        XCTAssertEqual(state.personalFacebookReels["8"], false)
        XCTAssertEqual(state.users["8"], .off)
        let shared = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(links)) as? [String: Any])
        XCTAssertNil(shared["redditVideos"])
        XCTAssertNil(shared["defaultRedditVideos"])
    }

    func testRedditParentAndMirrorLeafKeepIndependentCallbacksEvenWhenReadOnly() throws {
        let rules = try builtins()
        for language in [BotLanguage.en, .fr] {
            for scope in ["p", "d", "c:-100"] {
                for inherited in [false, true] {
                    for native in [false, true] {
                        var links = UserSettings()
                        links.previews["reddit"] = .init(enabled: false, apps: ["telegram"], targetHost: "mirror.example")
                        let list = SettingsUI.rules(links, builtins: rules, scope: scope, section: "previews",
                            inherited: inherited, language: language, redditVideos: native)
                        let parent = try XCTUnwrap(try buttons(list).first { $0["callback_data"] == "fxclip:rules:\(scope):preview:reddit:show" })
                        XCTAssertEqual(parent["text"], language.text("Reddit · Video & links ›", "Reddit · Vidéos et liens ›"))
                        let leaf = SettingsUI.rules(links, builtins: rules, scope: scope, section: "preview:reddit:show",
                            inherited: inherited, language: language, redditVideos: native)
                        let actions = try buttons(leaf)
                        XCTAssertTrue(actions.contains { $0["callback_data"] == "fxclip:rules:\(scope):reddit:show"
                            && $0["text"] == language.text("Videos in Telegram →", "Vidéos dans Telegram →") })
                        XCTAssertFalse(actions.contains { $0["callback_data"] == "fxclip:rules:\(scope):reddit:on" })
                        if scope == "d" || !inherited {
                            XCTAssertTrue(actions.contains { $0["callback_data"] == "fxclip:rules:\(scope):preview:reddit:on" })
                            XCTAssertFalse(actions.contains { $0["callback_data"] == "fxclip:rules:\(scope):preview:reddit:off" })
                            XCTAssertTrue(actions.contains { $0["callback_data"] == "fxclip:rules:\(scope):provider:reddit" })
                        } else {
                            XCTAssertFalse(actions.contains { $0["callback_data"] == "fxclip:rules:\(scope):preview:reddit:on" })
                        }
                        try assertTelegramLimits(list)
                        try assertTelegramLimits(leaf)
                    }
                }
            }
        }
    }

    func testNativeScalarControlsScopesAliasesAndPrivacyDisclosures() throws {
        let rules = try builtins()
        for language in [BotLanguage.en, .fr] {
            for scope in ["p", "d", "c:-9223372036854775808"] {
                for section in ["reddit", "reddit:show"] {
                    for inherited in [false, true] {
                        for enabled in [false, true] {
                            let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: scope,
                                section: section, inherited: true, language: language,
                                redditVideos: enabled, redditInherited: inherited)
                            let actions = try buttons(panel)
                            let follows = inherited && scope != "d"
                            let scopeLabel = scope == "p" ? language.text("for me", "pour moi")
                                : scope == "d" ? language.text("by default", "par défaut")
                                : language.text("for this group", "pour ce groupe")
                            for action in ["on", "off"] {
                                let control = actions.first { $0["callback_data"] == "fxclip:rules:\(scope):reddit:\(action)" }
                                if follows || (action == "on") != enabled {
                                    let label = action == "on" ? language.text("Enable", "Activer") : language.text("Disable", "Désactiver")
                                    XCTAssertEqual(control?["text"], "\(label) \(scopeLabel)")
                                } else { XCTAssertNil(control) }
                            }
                            let reset = actions.first { $0["callback_data"] == "fxclip:rules:\(scope):reddit:default" }
                            XCTAssertEqual(reset != nil, scope != "d" && !follows)
                            if let reset {
                                XCTAssertEqual(reset["text"], scope == "p" ? language.text("Follow group again", "Suivre à nouveau le groupe")
                                    : language.text("Use bot default", "Utiliser le réglage par défaut du bot"))
                            }
                            XCTAssertFalse(actions.compactMap { $0["callback_data"] }.contains { $0.contains(":provider:") || $0.contains(":preview:reddit:on") || $0.contains(":customize") })
                            XCTAssertTrue(actions.contains { $0["callback_data"] == "fxclip:rules:\(scope):preview:reddit:show" })
                            let phrases = language == .en ? ["Off by default", "enable explicitly", "group messages and direct links to this bot", "never Secretary",
                                "public Reddit", "privately", "bot server", "pinned vx code", "Reddit CDN", "copy to Telegram",
                                "No public vx service or Reddit login", "highest resolution", "20 MiB", "lowering quality",
                                "audio when present", "faststart", "clean original", "independent and unchanged",
                                "only if separately enabled", "not guaranteed", "Duplicates", "5 minutes", "48 h", "locally", "not saved"]
                                : ["Désactivées par défaut", "activer explicitement", "messages de groupe", "jamais Secrétaire",
                                "Reddit publiques", "son serveur", "code vx à version figée", "CDN Reddit", "copie à Telegram",
                                "Sans service vx public ni connexion Reddit", "meilleure résolution", "20 Mio", "réduire la qualité",
                                "son est assemblé", "faststart", "original propre", "indépendants et inchangés",
                                "activé séparément", "pas garantie", "doublons", "5 minutes", "48 h", "localement", "pas enregistrés"]
                            for phrase in phrases { XCTAssertTrue(panel.plainText.contains(phrase), phrase) }
                            if scope == "p" {
                                XCTAssertTrue(panel.plainText.contains(language.text("Only my messages · all enabled groups", "Mes messages uniquement · tous les groupes activés")))
                                XCTAssertFalse(panel.plainText.contains("+ Secretary"))
                            }
                            try assertTelegramLimits(panel)
                        }
                    }
                }
            }
        }
    }

    func testPauseActivationAndResetDiscloseRedditWithoutEnablingIt() throws {
        let rules = try builtins()
        let chat = Chat(id: -100, type: "supergroup", title: "Example <group> & friends")
        for language in [BotLanguage.en, .fr] {
            let panels = [
                SettingsUI.personal(mode: nil, defaultMode: .reply, owner: false, language: language, section: "about"),
                SettingsUI.defaults(mode: .reply, language: language, section: "about"),
                SettingsUI.defaults(mode: .reply, language: language, section: "mode"),
                SettingsUI.chat(chat, settings: ChatSettings(), enabled: false, inherited: true,
                    username: "fxclipbot", language: language, section: "about"),
                SettingsUI.group(KnownGroup(chat: chat), enabled: false, rights: nil, language: language),
            ]
            for panel in panels {
                XCTAssertTrue(panel.plainText.contains("Reddit"))
                XCTAssertTrue(panel.plainText.contains(language.text("off by default", "désactivées par défaut")))
                XCTAssertTrue(panel.plainText.contains(language.text("separately opt-in", "activer séparément")))
                XCTAssertTrue(panel.plainText.contains("48 h"))
                try assertTelegramLimits(panel)
            }
            let paused = SettingsUI.rules(UserSettings(), builtins: rules, scope: "c:-100", section: "reddit:show",
                inherited: true, previewsEnabled: false, language: language)
            XCTAssertTrue(paused.plainText.contains(language.text("Enhanced previews paused", "Aperçus améliorés en pause")))
            XCTAssertTrue(paused.plainText.contains("YouTube"))
            XCTAssertTrue(paused.plainText.contains("Facebook"))
            XCTAssertTrue(try buttons(paused).contains { $0["callback_data"] == "fxclip:rules:c:-100:reddit:on" })
            let previews = SettingsUI.rules(UserSettings(), builtins: rules, scope: "c:-100", section: "previews",
                inherited: true, previewsEnabled: false, language: language)
            XCTAssertTrue(previews.plainText.contains(language.text("native videos", "vidéos natives")))
            for scope in ["p", "d", "c:-100"] {
                let reset = SettingsUI.rules(UserSettings(), builtins: rules, scope: scope, section: "reset:show",
                    inherited: true, language: language)
                XCTAssertTrue(reset.plainText.contains(language.text("Reddit video", "vidéos Facebook et Reddit")))
                XCTAssertTrue(try buttons(reset).contains { $0["callback_data"] == "fxclip:rules:\(scope):reset" })
                try assertTelegramLimits(reset)
            }
            XCTAssertFalse(store.state.defaultRedditVideos)
            XCTAssertTrue(store.state.personalRedditVideos.isEmpty)
            try assertTelegramLimits(paused)
            try assertTelegramLimits(previews)
        }
    }
}
