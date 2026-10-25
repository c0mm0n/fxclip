import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

private func uxRows(_ panel: SettingsUI) throws -> [[[String: String]]] {
    try XCTUnwrap(panel.markup["inline_keyboard"] as? [[[String: String]]])
}

private func uxActions(_ panel: SettingsUI) throws -> Set<String> {
    Set(try uxRows(panel).flatMap { $0 }.compactMap { $0["callback_data"] })
}

final class SettingsScopeUXTests: XCTestCase {
    private func builtins() throws -> Rules {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/rules.json")
        return try Rules.load(Data(contentsOf: shared))
    }

    func testDashboardsAreShortScopedNavigationRatherThanModePickers() throws {
        let chat = Chat(id: -100, type: "supergroup", title: "Example group")
        for language in BotLanguage.allCases {
            let panels: [(SettingsUI, Set<String>)] = [
                (SettingsUI.personal(mode: nil, defaultMode: .replace, owner: false, language: language),
                 ["fxclip:personal:mode", "fxclip:personal:secretary_setup", "fxclip:personal:about", "fxclip:personal:publications", "fxclip:rules:p:show", "fxclip:language:show", "fxclip:panel:close"]),
                (SettingsUI.personal(mode: nil, defaultMode: .replace, owner: true, language: language),
                 ["fxclip:personal:mode", "fxclip:personal:secretary_setup", "fxclip:personal:about", "fxclip:personal:publications", "fxclip:rules:p:show", "fxclip:language:show", "fxclip:default:show", "fxclip:groups:show", "fxclip:panel:close"]),
                (SettingsUI.defaults(mode: .replace, language: language),
                 ["fxclip:default:mode", "fxclip:default:about", "fxclip:rules:d:show", "fxclip:groups:show", "fxclip:personal:show", "fxclip:panel:close"]),
                (SettingsUI.chat(chat, settings: ChatSettings(), enabled: true, inherited: true,
                                 username: "fxclipbot", language: language),
                 ["fxclip:chat:-100:mode", "fxclip:chat:-100:language", "fxclip:chat:-100:about", "fxclip:rules:c:-100:show", "fxclip:chat:-100:close"]),
            ]
            for (panel, navigation) in panels {
                let actions = try uxActions(panel)
                XCTAssertTrue(actions.isSuperset(of: navigation))
                let ownerDashboard = actions.contains("fxclip:personal:publications") && actions.contains("fxclip:default:show")
                XCTAssertLessThanOrEqual(try uxRows(panel).count, ownerDashboard ? 8 : 7)
                XCTAssertLessThan(panel.plainText.utf16.count, 800)
                for mode in [Mode.reply, .replace, .secretary, .off] {
                    XCTAssertFalse(actions.contains("fxclip:personal:\(mode.rawValue)"))
                    XCTAssertFalse(actions.contains("fxclip:default:\(mode.rawValue)"))
                    XCTAssertFalse(actions.contains("fxclip:chat:-100:\(mode.rawValue)"))
                }
            }
        }
    }

    func testSecretaryStatusAndControlsAreIndependentOfEveryGroupChoice() throws {
        for language in BotLanguage.allCases {
            for mode: Mode? in [.reply, .replace, .off, nil] {
                for enabled in [false, true] {
                    for section in ["show", "mode", "secretary_setup"] {
                        let panel = SettingsUI.personal(mode: mode, defaultMode: .reply, owner: false,
                            language: language, section: section, secretaryEnabled: enabled)
                        let status = language.text("Secretary · private chats: ", "Secrétaire · en privé : ")
                            + (enabled ? language.text("On", "Activé") : language.text("Off", "Désactivé"))
                        XCTAssertTrue(panel.plainText.contains(status), "\(mode?.rawValue ?? "default") \(section)")
                        let actions = try uxActions(panel)
                        if section == "secretary_setup" {
                            XCTAssertTrue(actions.contains("fxclip:personal:\(enabled ? "secretary_off" : "secretary")"))
                            XCTAssertFalse(actions.contains("fxclip:personal:\(enabled ? "secretary" : "secretary_off")"))
                            XCTAssertTrue(panel.plainText.contains(language.text("never incoming", "jamais les messages reçus")))
                            XCTAssertTrue(panel.plainText.contains(language.text("independent", "indépendant")))
                        } else if section == "mode" {
                            let selected = try uxRows(panel).flatMap { $0 }.filter { $0["text"]?.hasPrefix("✓ ") == true }
                            XCTAssertEqual(selected.count, 1)
                            XCTAssertEqual(selected.first?["callback_data"], "fxclip:personal:\(mode?.rawValue ?? "default")")
                        }
                        for stale in ["no fxclip replies", "no replies to my group messages", "replaces your personal group behavior",
                                      "aucune réponse à mes messages de groupe", "remplace votre comportement personnel en groupe"] {
                            XCTAssertFalse(panel.plainText.contains(stale), stale)
                        }
                    }
                }
            }
        }
    }

    func testLegacySecretaryIsShownAsFollowingGroupWithResolvedPrivateConsent() throws {
        for enabled in [false, true] {
            let panel = SettingsUI.personal(mode: .secretary, defaultMode: .reply, owner: false,
                section: "mode", secretaryEnabled: enabled)
            let selected = try uxRows(panel).flatMap { $0 }.filter { $0["text"]?.hasPrefix("✓ ") == true }
            XCTAssertEqual(selected.first?["callback_data"], "fxclip:personal:default")
            let setup = SettingsUI.personal(mode: .secretary, defaultMode: .reply, owner: false,
                section: "secretary_setup", secretaryEnabled: enabled)
            XCTAssertTrue(try uxActions(setup).contains("fxclip:personal:\(enabled ? "secretary_off" : "secretary")"))
        }
    }

    func testEveryPersonalDefaultAndGroupSectionExplainsItsScope() throws {
        let chat = Chat(id: -100, type: "supergroup", title: "Example <group> & friends")
        for language in BotLanguage.allCases {
            for section in ["show", "mode", "about", "secretary_setup"] {
                let panel = SettingsUI.personal(mode: nil, defaultMode: .replace, owner: true,
                                                language: language, section: section)
                XCTAssertTrue(panel.plainText.contains(language == .en ? "My preferences" : "Mes préférences"), section)
                if section == "secretary_setup" {
                    for phrase in language == .en ? ["private", "outgoing"] : ["privées", "sortants"] {
                        XCTAssertTrue(panel.plainText.contains(phrase), section)
                    }
                } else {
                    XCTAssertTrue(panel.plainText.lowercased().contains(language == .en ? "enabled groups" : "groupes activés"), section)
                }
            }
            for section in ["show", "mode", "about"] {
                let panel = SettingsUI.defaults(mode: .replace, language: language, section: section)
                XCTAssertTrue(panel.plainText.contains(language == .en ? "Bot defaults" : "Réglages par défaut du bot"), section)
            }
            for section in ["show", "mode", "language", "about"] {
                let panel = SettingsUI.chat(chat, settings: ChatSettings(), enabled: true, inherited: true,
                    username: "fxclipbot", language: language, section: section)
                XCTAssertTrue(panel.plainText.contains(language == .en ? "This group" : "Ce groupe"), section)
                XCTAssertTrue(panel.text.contains("Example &lt;group&gt; &amp; friends"), section)
                XCTAssertFalse(panel.text.contains("Example <group>"), section)
            }
        }
    }

    func testPreviewListHasOneNavigationRowPerServiceAndKeepsProvidersInDetails() throws {
        let rules = try builtins()
        var settings = UserSettings()
        settings.previews["reddit"] = .init(enabled: true, apps: ["telegram"], targetHost: "mirror.example")
        for language in BotLanguage.allCases {
            let panel = SettingsUI.rules(settings, builtins: rules, scope: "p", section: "previews",
                inherited: false, language: language)
            let rows = try uxRows(panel)
            let expected = rules.previews.map { "fxclip:rules:p:preview:\($0.id):show" }
                + ["fxclip:rules:p:youtube:show", "fxclip:rules:p:facebook:show"]
            for action in expected {
                XCTAssertEqual(rows.filter { $0.contains { $0["callback_data"] == action } }.count, 1, action)
                XCTAssertEqual(rows.first { $0.contains { $0["callback_data"] == action } }?.count, 1, action)
            }
            XCTAssertFalse(panel.text.contains("mirror.example"))
            XCTAssertFalse(try uxActions(panel).contains("fxclip:rules:p:provider:reddit"))
            let detail = SettingsUI.rules(settings, builtins: rules, scope: "p", section: "preview:reddit",
                inherited: false, language: language)
            XCTAssertTrue(detail.text.contains("mirror.example"))
            XCTAssertTrue(try uxActions(detail).contains("fxclip:rules:p:provider:reddit"))
            XCTAssertTrue(try uxActions(detail).contains("fxclip:rules:p:preview:reddit:off"))
        }
    }

    func testInheritedEnginePagesRequireExplicitCustomizationBeforeShowingEditors() throws {
        let rules = try builtins()
        for language in BotLanguage.allCases {
            for scope in ["p", "c:-100"] {
                for section in ["clean", "preview:reddit", "provider:reddit", "excluded"] {
                    let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: scope,
                        section: section, inherited: true, language: language, groupTitle: "Example group")
                    let actions = try uxActions(panel)
                    XCTAssertTrue(actions.contains("fxclip:rules:\(scope):customize"), "\(scope) \(section)")
                    XCTAssertFalse(actions.contains { $0.contains(":trackers:") || $0.contains(":site:") || $0.contains(":providerreset:") })
                    XCTAssertFalse(actions.contains("fxclip:rules:\(scope):preview:reddit:off"))
                    XCTAssertFalse(panel.text.contains("<code>/provider"))
                    XCTAssertFalse(panel.text.contains("<code>/exclude"))
                }
            }
            let defaults = SettingsUI.rules(UserSettings(), builtins: rules, scope: "d", section: "clean",
                inherited: false, language: language)
            XCTAssertTrue(try uxActions(defaults).contains("fxclip:rules:d:trackers:off"))
            XCTAssertFalse(try uxActions(defaults).contains("fxclip:rules:d:customize"))
        }
    }

    func testYouTubeActivationLeafExplainsDirectRequestsAndPossibleDuplicatePreviews() throws {
        let rules = try builtins()
        for language in BotLanguage.allCases {
            for scope in ["p", "d", "c:-100"] {
                let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: scope, section: "youtube",
                    inherited: true, language: language, youTubeInherited: true)
                XCTAssertTrue(try uxActions(panel).contains("fxclip:rules:\(scope):youtube:off"))
                for phrase in language == .en ? ["YouTube", "Koutube", "photo", "already", "public", "cache", "Telegram"]
                    : ["YouTube", "Koutube", "photo", "déjà", "public", "cache", "Telegram"] {
                    XCTAssertTrue(panel.plainText.contains(phrase), "\(scope) \(phrase)")
                }
                XCTAssertTrue(panel.plainText.contains("5 minutes"))
                XCTAssertTrue(panel.plainText.contains("48 h"))
            }
        }
    }

    func testPersonalInheritanceDoesNotPresentBuiltInEngineStateAsTheGroupsChoice() throws {
        let rules = try builtins()
        for language in BotLanguage.allCases {
            let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: "p", section: "previews",
                inherited: true, youTubeCards: false, facebookReels: true, language: language,
                youTubeInherited: true, facebookInherited: false)
            let buttons = try uxRows(panel).flatMap { $0 }
            for preview in rules.previews {
                let button = try XCTUnwrap(buttons.first { $0["callback_data"] == "fxclip:rules:p:preview:\(preview.id):show" })
                let label = try XCTUnwrap(button["text"])
                if preview.id == "reddit" {
                    XCTAssertTrue(label.contains(language == .en ? "Video & links" : "Vidéos et liens"))
                } else {
                    XCTAssertTrue(label.contains(language == .en ? "Follow group" : "Suivre le groupe"))
                }
            }
            let youtube = try XCTUnwrap(buttons.first { $0["callback_data"] == "fxclip:rules:p:youtube:show" }?["text"])
            let facebook = try XCTUnwrap(buttons.first { $0["callback_data"] == "fxclip:rules:p:facebook:show" }?["text"])
            XCTAssertTrue(youtube.contains(language == .en ? "Follow group" : "Suivre le groupe"))
            XCTAssertFalse(facebook.contains(language == .en ? "Follow group" : "Suivre le groupe"))
            XCTAssertTrue(facebook.lowercased().contains(language == .en ? "on" : "activé"))
        }
    }

    func testServiceLeavesOfferInheritanceOnlyForExplicitPersonalAndGroupOverrides() throws {
        let rules = try builtins()
        for language in BotLanguage.allCases {
            for scope in ["p", "c:-100", "d"] {
                for inheritedService in [false, true] {
                    for service in ["youtube", "facebook"] {
                        let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: scope,
                            section: service, inherited: true, language: language,
                            youTubeInherited: inheritedService, facebookInherited: inheritedService)
                        XCTAssertEqual(try uxActions(panel).contains("fxclip:rules:\(scope):\(service):default"),
                            scope != "d" && !inheritedService, "\(scope) \(service) \(inheritedService)")
                    }
                }
            }
        }
    }

    func testPausedGroupServiceLeafDoesNotPresentSavedFacebookOnAsEffectiveCleaning() throws {
        let rules = try builtins()
        for language in BotLanguage.allCases {
            let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: "c:-100", section: "facebook",
                inherited: false, previewsEnabled: true, facebookReels: true, language: language,
                groupTitle: "Example group", facebookInherited: false, cleaningEnabled: false)
            XCTAssertTrue(panel.plainText.lowercased().contains("pause"))
            XCTAssertTrue(panel.plainText.contains("Example group"))
            XCTAssertTrue(panel.plainText.contains(language == .en ? "everyone" : "tout le monde"))
            XCTAssertTrue(panel.plainText.contains(language == .en ? "resumed" : "reprise"))
            XCTAssertTrue(try uxActions(panel).contains("fxclip:rules:c:-100:facebook:off"))
        }
    }

    func testEveryPageFitsTelegramLimitsWithEscapedGroupTitleAndLongCatalogIDs() throws {
        var rules = try builtins()
        rules.previews[0].id = String(repeating: "long", count: 20)
        let sections = ["show", "clean", "previews", "excluded", "preview:reddit", "provider:reddit", "youtube", "facebook", "customize", "reset", "info"]
        for language in BotLanguage.allCases {
            for scope in ["p", "d", "c:-1001234567890"] {
                for section in sections {
                    let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: scope, section: section,
                        inherited: scope != "d", language: language, groupTitle: "Example <group> & friends")
                    XCTAssertLessThanOrEqual(panel.plainText.utf16.count, 4096, "\(scope) \(section)")
                    XCTAssertTrue(try uxActions(panel).allSatisfy { $0.utf8.count <= 64 }, "\(scope) \(section)")
                    XCTAssertFalse(panel.text.contains("Example <group>"))
                    if scope.hasPrefix("c:") { XCTAssertTrue(panel.text.contains("Example &lt;group&gt; &amp; friends"), section) }
                }
            }
        }
    }

    func testPersonalEnginePagesIncludeSecretaryPrivateScopeButServiceLeavesKeepGroupScope() throws {
        let rules = try builtins()
        for language in BotLanguage.allCases {
            for section in ["show", "clean", "previews", "excluded", "preview:reddit", "provider:reddit", "customize", "reset", "info"] {
                let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: "p", section: section,
                    inherited: true, language: language)
                for phrase in language == .en ? ["enabled groups", "Secretary", "private"] : ["groupes activés", "Secrétaire", "privées"] {
                    XCTAssertTrue(panel.plainText.contains(phrase), "\(section) \(phrase)")
                }
            }
            for section in ["show", "clean", "previews", "excluded"] {
                let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: "p", section: section,
                    inherited: true, language: language)
                for phrase in language == .en ? ["follow each group", "Secretary private chats", "follow bot defaults"]
                    : ["suivre chaque groupe", "En privé avec Secrétaire", "suivre les réglages par défaut du bot"] {
                    XCTAssertTrue(panel.plainText.contains(phrase), "\(section) \(phrase)")
                }
            }
            let reset = SettingsUI.rules(UserSettings(), builtins: rules, scope: "p", section: "reset", inherited: true, language: language)
            XCTAssertTrue(reset.plainText.contains(language == .en ? "Secretary private chats will use bot defaults" : "Secrétaire suivra les réglages par défaut du bot"))
            for section in ["youtube", "facebook"] {
                let panel = SettingsUI.rules(UserSettings(), builtins: rules, scope: "p", section: section,
                    inherited: true, language: language)
                XCTAssertTrue(panel.plainText.contains(language == .en ? "all enabled groups" : "tous les groupes activés"))
                XCTAssertFalse(panel.plainText.contains(language == .en ? "Secretary" : "Secrétaire"))
            }
        }
    }
}

extension BotTests {
    private func uxSnapshot() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.state)
    }

    private func uxEditedPanel() throws -> SettingsUI {
        let parameters = try XCTUnwrap(api.calls.last { $0.0 == "editMessageText" }?.1)
        return SettingsUI(text: try XCTUnwrap(parameters["text"] as? String),
            markup: try XCTUnwrap(parameters["reply_markup"] as? [String: Any]))
    }

    func testScopeUXAllPrivateNavigationAndConfirmationsLeaveStateUnchanged() async throws {
        try store.setMode(.replace, userID: 8)
        try store.setPersonalFacebookReels(true, userID: 8)
        let before = try uxSnapshot()
        for action in ["personal:show", "personal:mode", "personal:about", "personal:secretary_setup",
                       "rules:p:show", "rules:p:clean", "rules:p:previews", "rules:p:preview:reddit:show",
                       "rules:p:provider:reddit", "rules:p:youtube:show", "rules:p:facebook:show",
                       "rules:p:excluded", "rules:p:customize", "rules:p:reset:show"] {
            api.calls = []
            try await callback("fxclip:\(action)")
            XCTAssertEqual(try uxSnapshot(), before, action)
            XCTAssertTrue(api.methods.contains("editMessageText"), action)
            XCTAssertTrue(api.methods.contains("answerCallbackQuery"), action)
        }
        for action in ["default:show", "default:mode", "default:about", "rules:d:show", "rules:d:clean",
                       "rules:d:previews", "rules:d:preview:reddit:show", "rules:d:youtube:show",
                       "rules:d:facebook:show", "rules:d:excluded", "rules:d:reset:show"] {
            api.calls = []
            try await callback("fxclip:\(action)", userID: 7, chatID: 7)
            XCTAssertEqual(try uxSnapshot(), before, action)
            XCTAssertTrue(api.methods.contains("editMessageText"), action)
        }
    }

    func testScopeUXGroupNavigationRechecksAdminAndRejectsForeignGroups() async throws {
        let actions = ["chat:-100:mode", "chat:-100:language", "chat:-100:about", "rules:c:-100:previews",
                       "rules:c:-100:preview:reddit:show", "rules:c:-100:youtube:show", "rules:c:-100:facebook:show",
                       "rules:c:-100:customize", "rules:c:-100:reset:show"]
        let before = try uxSnapshot()
        for action in actions {
            api.calls = []; api.admin = true; api.failMember = false
            try await callback("fxclip:\(action)", chatID: -100, chatType: "supergroup")
            XCTAssertEqual(api.methods.first, "getChatMember", action)
            XCTAssertTrue(api.methods.contains("editMessageText"), action)
            XCTAssertEqual(try uxSnapshot(), before, action)
            for failedLookup in [false, true] {
                api.calls = []; api.admin = false; api.failMember = failedLookup
                try await callback("fxclip:\(action)", chatID: -100, chatType: "supergroup")
                XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"], action)
                XCTAssertEqual(try uxSnapshot(), before, action)
            }
            api.calls = []; api.admin = true; api.failMember = false
            try await callback("fxclip:\(action)", chatID: -200, chatType: "supergroup")
            XCTAssertEqual(api.methods, ["answerCallbackQuery"], action)
            XCTAssertEqual(try uxSnapshot(), before, action)
        }
    }

    func testScopeUXNewNavigationStillRequiresExactAttachedKeyboard() async throws {
        let before = try uxSnapshot()
        for action in ["personal:mode", "personal:secretary_setup", "default:about", "chat:-100:mode",
                       "rules:p:customize:confirm", "rules:p:reset", "rules:p:facebook:on", "rules:p:preview:reddit:show"] {
            api.calls = []
            let owner = action.hasPrefix("default:")
            let group = action.hasPrefix("chat:")
            try await callback("fxclip:\(action)", userID: owner ? 7 : 8,
                chatID: group ? -100 : owner ? 7 : 8, chatType: group ? "supergroup" : "private",
                messageMarkup: ["inline_keyboard": [[[
                "text": "Different action", "callback_data": "fxclip:personal:show",
            ]]]])
            XCTAssertEqual(api.methods, ["answerCallbackQuery"], action)
            XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true, action)
            XCTAssertEqual(try uxSnapshot(), before, action)
        }
    }

    func testScopeUXPrivateNavigationRejectsAnotherPrivateChatAndNonOwnerDefaults() async throws {
        let before = try uxSnapshot()
        let attempts: [(String, Int64, String)] = [
            ("personal:mode", 7, "private"), ("personal:about", -100, "supergroup"),
            ("personal:secretary_setup", 7, "private"), ("default:mode", 8, "private"),
            ("default:about", 8, "private"), ("rules:p:customize:confirm", 7, "private"),
            ("rules:p:reset:show", -100, "supergroup"), ("rules:d:facebook:show", 8, "private"),
        ]
        for (action, chatID, type) in attempts {
            api.calls = []
            try await callback("fxclip:\(action)", chatID: chatID, chatType: type)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"], action)
            XCTAssertEqual(try uxSnapshot(), before, action)
        }
    }

    func testScopeUXPersonalWalkUsesRealIssuedButtonsBeforeCustomizationAndServiceChanges() async throws {
        try await privateCommand("/settings")
        var panel = SettingsUI(text: try XCTUnwrap(sent["text"] as? String),
            markup: try XCTUnwrap(sent["reply_markup"] as? [String: Any]))
        let before = try uxSnapshot()
        for action in ["rules:p:show", "rules:p:clean", "rules:p:customize"] {
            let data = "fxclip:\(action)"
            XCTAssertTrue(try uxActions(panel).contains(data), action)
            api.calls = []
            try await callback(data, messageText: panel.plainText, messageMarkup: panel.markup)
            XCTAssertEqual(try uxSnapshot(), before, action)
            panel = try uxEditedPanel()
        }
        XCTAssertTrue(try uxActions(panel).contains("fxclip:rules:p:customize:confirm"))
        api.calls = []
        try await callback("fxclip:rules:p:customize:confirm", messageText: panel.plainText, messageMarkup: panel.markup)
        XCTAssertEqual(store.state.personalLinkSettings["8"], store.state.defaultLinkSettings)
        panel = try uxEditedPanel()
        for action in ["rules:p:previews", "rules:p:facebook:show", "rules:p:facebook:on"] {
            let data = "fxclip:\(action)"
            XCTAssertTrue(try uxActions(panel).contains(data), action)
            api.calls = []
            try await callback(data, messageText: panel.plainText, messageMarkup: panel.markup)
            panel = try uxEditedPanel()
        }
        XCTAssertEqual(store.state.personalFacebookReels["8"], true)
        XCTAssertTrue(try uxActions(panel).contains("fxclip:rules:p:facebook:off"))
    }

    func testScopeUXPersonalCustomizeCopiesOnlyDefaultsEngineAndKeepsIndependentOverrides() async throws {
        var defaults = UserSettings()
        defaults.trackersEverywhere = false
        defaults.disabledSites = ["amazon"]
        defaults.previews["reddit"] = .init(enabled: true, apps: ["telegram"], targetHost: "default.example")
        defaults.neverClean = [.init(host: "excluded.example", subdomains: true)]
        try store.setDefaultLinks(defaults, youTubeCards: false)
        try store.setDefaultFacebookReels(false)
        try store.setPersonalLinks(nil, youTubeCards: true, userID: 8)
        try store.setPersonalFacebookReels(true, userID: 8)
        try store.setMode(.off, userID: 8)
        try store.setPersonalLinks(UserSettings(), youTubeCards: false, userID: 9)
        var group = ChatSettings(); group.engineSettings = UserSettings(); group.mode = .replace
        try store.set(group, chatID: -100)
        let before = try uxSnapshot()
        try await callback("fxclip:rules:p:customize")
        XCTAssertEqual(try uxSnapshot(), before)
        XCTAssertTrue(try uxActions(uxEditedPanel()).contains("fxclip:rules:p:customize:confirm"))
        try await callback("fxclip:rules:p:customize:confirm")
        XCTAssertEqual(store.state.personalLinkSettings["8"], defaults)
        XCTAssertEqual(store.state.personalYouTubeCards["8"], true)
        XCTAssertEqual(store.state.personalFacebookReels["8"], true)
        XCTAssertEqual(store.state.personalLinkSettings["9"], UserSettings())
        XCTAssertEqual(store.state.personalYouTubeCards["9"], false)
        XCTAssertEqual(store.state.users["8"], .off)
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings, group.engineSettings)
        XCTAssertEqual(store.state.defaultLinkSettings, defaults)
        XCTAssertEqual(try StateStore(directory: directory).state.personalLinkSettings["8"], defaults)
    }

    func testScopeUXCustomizeDoesNotMaterializeMissingCardOrFacebookOverrides() async throws {
        var defaults = UserSettings(); defaults.trackersEverywhere = false
        try store.setDefaultLinks(defaults, youTubeCards: false)
        try store.setDefaultFacebookReels(true)
        try await callback("fxclip:rules:p:customize:confirm")
        XCTAssertEqual(store.state.personalLinkSettings["8"], defaults)
        XCTAssertNil(store.state.personalYouTubeCards["8"])
        XCTAssertNil(store.state.personalFacebookReels["8"])
        try await callback("fxclip:rules:c:-100:customize:confirm", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings, defaults)
        XCTAssertNil(store.state.chats["-100"]?.youTubeCards)
        XCTAssertNil(store.state.chats["-100"]?.facebookReels)
    }

    func testScopeUXGroupCustomizePreservesExplicitCardsFacebookModeAndMasterPause() async throws {
        var defaults = UserSettings(); defaults.trackersEverywhere = false; defaults.disabledSites = ["amazon"]
        try store.setDefaultLinks(defaults, youTubeCards: false)
        try store.setDefaultFacebookReels(true)
        var group = ChatSettings(); group.mode = .off; group.previews = false
        group.youTubeCards = true; group.facebookReels = false
        try store.set(group, chatID: -100)
        try await callback("fxclip:rules:c:-100:customize:confirm", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings, defaults)
        XCTAssertEqual(store.state.chats["-100"]?.youTubeCards, true)
        XCTAssertEqual(store.state.chats["-100"]?.facebookReels, false)
        XCTAssertEqual(store.state.chats["-100"]?.mode, .off)
        XCTAssertEqual(store.state.chats["-100"]?.previews, false)
        XCTAssertTrue(store.state.personalLinkSettings.isEmpty)
        XCTAssertEqual(store.state.defaultLinkSettings, defaults)
    }

    func testScopeUXStaleCustomizeConfirmationPreservesExistingPersonalAndGroupConfiguration() async throws {
        var defaults = UserSettings(); defaults.disabledSites = ["amazon"]
        try store.setDefaultLinks(defaults, youTubeCards: true)
        var personal = UserSettings(); personal.trackersEverywhere = false
        personal.previews["reddit"] = .init(enabled: false, apps: ["telegram"], targetHost: "personal.example")
        personal.neverClean = [.init(host: "personal.example", subdomains: false)]
        try store.setPersonalLinks(personal, youTubeCards: false, userID: 8)
        try store.setPersonalFacebookReels(true, userID: 8)
        var group = ChatSettings(); group.mode = .replace; group.previews = false
        var links = UserSettings(); links.disabledSites = ["reddit"]
        links.previews["reddit"] = .init(enabled: true, apps: ["telegram"], targetHost: "group.example")
        group.engineSettings = links; group.youTubeCards = false; group.facebookReels = true
        try store.set(group, chatID: -100)
        let before = try uxSnapshot()
        for (scope, chatID, type) in [("p", Int64(8), "private"), ("c:-100", Int64(-100), "supergroup")] {
            api.calls = []
            try await callback("fxclip:rules:\(scope):customize:confirm", chatID: chatID, chatType: type)
            XCTAssertEqual(try uxSnapshot(), before, scope)
            XCTAssertTrue(api.methods.contains("editMessageText"), scope)
        }
    }

    func testScopeUXResetConfirmationIsReadOnlyThenResetOnlyLinkChoices() async throws {
        var settings = UserSettings(); settings.trackersEverywhere = false
        try store.setMode(.secretary, userID: 8)
        try store.setPersonalLinks(settings, youTubeCards: false, userID: 8)
        try store.setPersonalFacebookReels(true, userID: 8)
        var group = ChatSettings(); group.mode = .replace; group.previews = false
        group.engineSettings = settings; group.youTubeCards = false; group.facebookReels = true
        try store.set(group, chatID: -100)
        for (scope, chatID, type) in [("p", Int64(8), "private"), ("c:-100", Int64(-100), "supergroup")] {
            let before = try uxSnapshot()
            api.calls = []
            try await callback("fxclip:rules:\(scope):reset:show", chatID: chatID, chatType: type)
            XCTAssertEqual(try uxSnapshot(), before)
            XCTAssertTrue(try uxActions(uxEditedPanel()).contains("fxclip:rules:\(scope):reset"))
            try await callback("fxclip:rules:\(scope):reset", chatID: chatID, chatType: type)
        }
        XCTAssertNil(store.state.personalLinkSettings["8"])
        XCTAssertNil(store.state.personalYouTubeCards["8"])
        XCTAssertNil(store.state.personalFacebookReels["8"])
        XCTAssertNil(store.state.users["8"])
        XCTAssertTrue(store.secretaryEnabled(userID: 8))
        XCTAssertNil(store.state.chats["-100"]?.engineSettings)
        XCTAssertNil(store.state.chats["-100"]?.youTubeCards)
        XCTAssertNil(store.state.chats["-100"]?.facebookReels)
        XCTAssertEqual(store.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(store.state.chats["-100"]?.previews, false)
    }

    func testScopeUXModeActionsReturnModePageAndSecretaryReturnsSetup() async throws {
        for action in ["reply", "replace", "off", "default"] {
            api.calls = []
            try await callback("fxclip:personal:\(action)")
            let actions = try uxActions(uxEditedPanel())
            XCTAssertTrue(actions.contains("fxclip:personal:reply"), action)
            XCTAssertTrue(actions.contains("fxclip:personal:default"), action)
        }
        api.calls = []
        try await callback("fxclip:personal:secretary")
        XCTAssertNil(store.state.users["8"])
        XCTAssertTrue(store.secretaryEnabled(userID: 8))
        XCTAssertTrue(try uxEditedPanel().plainText.contains("allow replies and edits"))
        XCTAssertFalse(try uxActions(uxEditedPanel()).contains("fxclip:personal:reply"))
        for action in ["reply", "replace", "off", "secretary"] {
            api.calls = []
            try await callback("fxclip:default:\(action)", userID: 7, chatID: 7)
            XCTAssertTrue(try uxActions(uxEditedPanel()).contains("fxclip:default:reply"), action)
        }
        api.calls = []
        try await callback("fxclip:chat:-100:replace", chatID: -100, chatType: "supergroup")
        XCTAssertTrue(try uxActions(uxEditedPanel()).contains("fxclip:chat:-100:reply"))
    }

    func testScopeUXServiceActionsReturnTheirLeafAndDoNotCreateAnEngineOverride() async throws {
        for (action, expected) in [("youtube:off", "youtube:on"), ("facebook:on", "facebook:off")] {
            api.calls = []
            try await callback("fxclip:rules:p:\(action)")
            let actions = try uxActions(uxEditedPanel())
            XCTAssertTrue(actions.contains("fxclip:rules:p:\(expected)"))
            XCTAssertFalse(actions.contains("fxclip:rules:p:preview:reddit:show"))
            XCTAssertNil(store.state.personalLinkSettings["8"])
        }
        try await callback("fxclip:rules:p:customize:confirm")
        api.calls = []
        try await callback("fxclip:rules:p:preview:reddit:off")
        XCTAssertTrue(try uxActions(uxEditedPanel()).contains("fxclip:rules:p:preview:reddit:on"))
        XCTAssertTrue(try uxActions(uxEditedPanel()).contains("fxclip:rules:p:provider:reddit"))
    }

    func testScopeUXPersonalFacebookOverrideAndInheritedYouTubeLabelsStayIndependent() async throws {
        try store.setDefaultLinks(UserSettings(), youTubeCards: false)
        try store.setDefaultFacebookReels(false)
        try store.setPersonalFacebookReels(true, userID: 8)
        try await callback("fxclip:rules:p:previews")
        let buttons = try uxRows(uxEditedPanel()).flatMap { $0 }
        let youtube = try XCTUnwrap(buttons.first { $0["callback_data"] == "fxclip:rules:p:youtube:show" }?["text"])
        let facebook = try XCTUnwrap(buttons.first { $0["callback_data"] == "fxclip:rules:p:facebook:show" }?["text"])
        XCTAssertTrue(youtube.contains("Follow group"))
        XCTAssertFalse(facebook.contains("Follow group"))
        XCTAssertTrue(facebook.lowercased().contains("on"))
        XCTAssertNil(store.state.personalLinkSettings["8"])
    }

    func testScopeUXServiceInheritanceActionsClearOnlyTheirOwnScalarOverride() async throws {
        var settings = UserSettings(); settings.trackersEverywhere = false
        settings.previews["reddit"] = .init(enabled: false, apps: ["telegram"], targetHost: "custom.example")
        try store.setPersonalLinks(settings, youTubeCards: false, userID: 8)
        try store.setPersonalFacebookReels(true, userID: 8)
        try store.setMode(.off, userID: 8)
        var group = ChatSettings(); group.engineSettings = settings; group.youTubeCards = false
        group.facebookReels = true; group.mode = .replace; group.previews = false
        try store.set(group, chatID: -100)
        for (scope, chatID, type) in [("p", Int64(8), "private"), ("c:-100", Int64(-100), "supergroup")] {
            api.calls = []
            try await callback("fxclip:rules:\(scope):youtube:default", chatID: chatID, chatType: type)
            XCTAssertTrue(api.methods.contains("editMessageText"), scope)
            XCTAssertFalse(try uxActions(uxEditedPanel()).contains("fxclip:rules:\(scope):preview:reddit:show"))
            if scope == "p" {
                XCTAssertNil(store.state.personalYouTubeCards["8"])
                XCTAssertEqual(store.state.personalFacebookReels["8"], true)
                XCTAssertEqual(store.state.personalLinkSettings["8"], settings)
                XCTAssertEqual(store.state.chats["-100"]?.youTubeCards, false)
                try store.setPersonalLinks(settings, youTubeCards: false, userID: 8)
            } else {
                XCTAssertNil(store.state.chats["-100"]?.youTubeCards)
                XCTAssertEqual(store.state.chats["-100"]?.facebookReels, true)
                XCTAssertEqual(store.state.chats["-100"]?.engineSettings, settings)
                var current = try XCTUnwrap(store.state.chats["-100"])
                current.youTubeCards = false; try store.set(current, chatID: -100)
            }
            api.calls = []
            try await callback("fxclip:rules:\(scope):facebook:default", chatID: chatID, chatType: type)
            XCTAssertTrue(api.methods.contains("editMessageText"), scope)
            XCTAssertFalse(try uxActions(uxEditedPanel()).contains("fxclip:rules:\(scope):preview:reddit:show"))
            if scope == "p" {
                XCTAssertNil(store.state.personalFacebookReels["8"])
                XCTAssertEqual(store.state.personalYouTubeCards["8"], false)
                XCTAssertEqual(store.state.personalLinkSettings["8"], settings)
                XCTAssertEqual(store.state.chats["-100"]?.facebookReels, true)
            } else {
                XCTAssertNil(store.state.chats["-100"]?.facebookReels)
                XCTAssertEqual(store.state.chats["-100"]?.youTubeCards, false)
                XCTAssertEqual(store.state.chats["-100"]?.engineSettings, settings)
            }
            XCTAssertEqual(store.state.users["8"], .off)
            XCTAssertEqual(store.state.chats["-100"]?.mode, .replace)
            XCTAssertEqual(store.state.chats["-100"]?.previews, false)
        }
        let before = try uxSnapshot()
        for service in ["youtube", "facebook"] {
            api.calls = []
            try await callback("fxclip:rules:d:\(service):default", userID: 7, chatID: 7)
            XCTAssertEqual(try uxSnapshot(), before, service)
            XCTAssertEqual(api.methods, ["answerCallbackQuery"], service)
        }
    }

    func testScopeUXGroupRulesUseEscapedKnownTitleAndGroupLanguage() async throws {
        try store.discover(Chat(id: -100, type: "supergroup", title: "Example <group> & friends"))
        try store.setGroupLanguage(.fr, chatID: -100)
        for action in ["rules:c:-100:facebook:show", "chat:-100:mode"] {
            api.calls = []
            try await callback("fxclip:\(action)", chatID: -100, chatType: "supergroup")
            let panel = try uxEditedPanel()
            XCTAssertTrue(panel.text.contains("Example &lt;group&gt; &amp; friends"), action)
            XCTAssertFalse(panel.text.contains("Example <group>"), action)
            XCTAssertTrue(panel.plainText.contains("Ce groupe"), action)
        }
    }

    func testScopeUXDefaultEditsDoNotOverwriteExistingUsersOrGroups() async throws {
        var personal = UserSettings(); personal.disabledSites = ["amazon"]
        try store.setPersonalLinks(personal, youTubeCards: false, userID: 8)
        try store.setPersonalFacebookReels(true, userID: 8)
        try store.setMode(.off, userID: 8)
        var group = ChatSettings(); group.engineSettings = personal; group.youTubeCards = false; group.facebookReels = true
        try store.set(group, chatID: -100)
        try await callback("fxclip:rules:d:trackers:off", userID: 7, chatID: 7)
        try await callback("fxclip:rules:d:youtube:off", userID: 7, chatID: 7)
        try await callback("fxclip:rules:d:facebook:on", userID: 7, chatID: 7)
        XCTAssertFalse(store.state.defaultLinkSettings.trackersEverywhere)
        XCTAssertFalse(store.state.defaultYouTubeCards)
        XCTAssertTrue(store.state.defaultFacebookReels)
        XCTAssertEqual(store.state.personalLinkSettings["8"], personal)
        XCTAssertEqual(store.state.personalYouTubeCards["8"], false)
        XCTAssertEqual(store.state.personalFacebookReels["8"], true)
        XCTAssertEqual(store.state.users["8"], .off)
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings, personal)
        XCTAssertEqual(store.state.chats["-100"]?.youTubeCards, false)
        XCTAssertEqual(store.state.chats["-100"]?.facebookReels, true)
        try store.setDefault(.replace)
        let before = try uxSnapshot()
        try await callback("fxclip:rules:d:reset:show", userID: 7, chatID: 7)
        XCTAssertEqual(try uxSnapshot(), before)
        try await callback("fxclip:rules:d:reset", userID: 7, chatID: 7)
        XCTAssertEqual(store.state.defaultLinkSettings, UserSettings())
        XCTAssertTrue(store.state.defaultYouTubeCards)
        XCTAssertFalse(store.state.defaultFacebookReels)
        XCTAssertEqual(store.state.defaultMode, .replace)
        XCTAssertEqual(store.state.personalLinkSettings["8"], personal)
        XCTAssertEqual(store.state.personalYouTubeCards["8"], false)
        XCTAssertEqual(store.state.personalFacebookReels["8"], true)
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings, personal)
    }
}
