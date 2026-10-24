import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

extension BotTests {
    private func sharedSettingsSnapshot() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.state)
    }

    private func sharedSettingsSentText() throws -> String {
        try XCTUnwrap(api.calls.first { $0.0 == "sendMessage" }?.1["text"] as? String)
    }

    private func sharedSettingsReddit(_ host: String) -> UserSettings {
        var settings = UserSettings()
        settings.previews["reddit"] = .init(enabled: true, apps: ["telegram"], targetHost: host)
        return settings
    }

    private func sharedSettingsMessage(_ text: String, userID: Int64 = 8) async throws {
        try await handle(["text": text, "from": fixtureUser(userID, languageCode: nil)])
    }

    func testSharedSettingsActualRewriteUsesPersonalThenGroupThenDefault() async throws {
        let source = "https://www.reddit.com/r/example/comments/abc/title/?utm_source=share&share_id=sample"
        try store.setDefaultLinks(sharedSettingsReddit("default.example"), youTubeCards: true)
        try await sharedSettingsMessage(source)
        XCTAssertEqual(try sharedSettingsSentText(), "https://default.example/r/example/comments/abc/title/")

        var group = ChatSettings()
        group.engineSettings = sharedSettingsReddit("group.example")
        try store.set(group, chatID: -100)
        api.calls = []
        try await sharedSettingsMessage(source)
        XCTAssertEqual(try sharedSettingsSentText(), "https://group.example/r/example/comments/abc/title/")

        try store.setPersonalLinks(sharedSettingsReddit("personal.example"), youTubeCards: nil, userID: 8)
        api.calls = []
        try await sharedSettingsMessage(source)
        XCTAssertEqual(try sharedSettingsSentText(), "https://personal.example/r/example/comments/abc/title/")
        api.calls = []
        try await sharedSettingsMessage(source, userID: 7)
        XCTAssertEqual(try sharedSettingsSentText(), "https://group.example/r/example/comments/abc/title/")
    }

    func testSharedSettingsPersonalConfigReplacesWholeGroupConfig() async throws {
        var group = ChatSettings()
        var links = sharedSettingsReddit("group.example")
        links.trackersEverywhere = false
        links.disabledSites = ["reddit"]
        group.engineSettings = links
        try store.set(group, chatID: -100)
        try store.setPersonalLinks(UserSettings(), youTubeCards: nil, userID: 8)
        try await sharedSettingsMessage("https://reddit.com/r/example/?utm_source=share&share_id=sample")
        XCTAssertEqual(try sharedSettingsSentText(), "https://vxreddit.com/r/example/")
    }

    func testSharedSettingsSecretaryUsesPersonalConfigurationWithoutRecipientGroupSettings() async throws {
        try store.setMode(.secretary, userID: 7)
        try store.setDefaultLinks(sharedSettingsReddit("default.example"), youTubeCards: true)
        var recipient = ChatSettings()
        recipient.engineSettings = sharedSettingsReddit("recipient.example")
        try store.set(recipient, chatID: 123)
        let fixture: [String: Any] = ["text": "https://reddit.com/r/example/?utm_source=share",
            "chat": ["id": 123, "type": "private"], "business_connection_id": "connection",
            "from": fixtureUser(7, languageCode: nil)]
        try await handle(fixture, business: true)
        XCTAssertEqual(api.calls.last?.1["text"] as? String, "https://default.example/r/example/")
        try store.setPersonalLinks(sharedSettingsReddit("personal.example"), youTubeCards: nil, userID: 7)
        api.calls = []
        try await handle(fixture, business: true)
        XCTAssertEqual(api.methods, ["getBusinessConnection", "editMessageText"])
        XCTAssertEqual(api.calls.last?.1["text"] as? String, "https://personal.example/r/example/")
    }

    func testSharedSettingsFirstPersonalEditRequiresConfirmationThenCopiesGlobalDefaultsWithoutGroupContext() async throws {
        var defaults = sharedSettingsReddit("default.example")
        defaults.disabledSites = ["amazon"]
        defaults.neverClean = [.init(host: "excluded.example", subdomains: true)]
        try store.setDefaultLinks(defaults, youTubeCards: false)
        var group = ChatSettings()
        group.engineSettings = sharedSettingsReddit("group.example")
        try store.set(group, chatID: -100)

        let before = try sharedSettingsSnapshot()
        try await callback("fxclip:rules:p:trackers:off")
        XCTAssertEqual(try sharedSettingsSnapshot(), before)
        try await callback("fxclip:rules:p:customize:confirm")
        try await callback("fxclip:rules:p:trackers:off")
        var expected = defaults
        expected.trackersEverywhere = false
        XCTAssertEqual(store.state.personalLinkSettings["8"], expected)
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings, group.engineSettings)

        try store.setDefaultLinks(UserSettings(), youTubeCards: true)
        XCTAssertEqual(store.state.personalLinkSettings["8"], expected)
    }

    func testSharedSettingsFirstGroupEditRequiresConfirmationThenCopiesDefaultsAndPreservesLegacyMaster() async throws {
        var defaults = sharedSettingsReddit("default.example")
        defaults.neverClean = [.init(host: "excluded.example", subdomains: false)]
        try store.setDefaultLinks(defaults, youTubeCards: false)
        var group = ChatSettings()
        group.mode = .replace
        group.previews = false
        try store.set(group, chatID: -100)
        let before = try sharedSettingsSnapshot()
        try await callback("fxclip:rules:c:-100:site:reddit:off", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(try sharedSettingsSnapshot(), before)
        try await callback("fxclip:rules:c:-100:customize:confirm", chatID: -100, chatType: "supergroup")
        try await callback("fxclip:rules:c:-100:site:reddit:off", chatID: -100, chatType: "supergroup")
        var expected = defaults
        expected.disabledSites.insert("reddit")
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings, expected)
        XCTAssertEqual(store.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(store.state.chats["-100"]?.previews, false)
        XCTAssertNil(store.state.personalLinkSettings["8"])
    }

    func testSharedSettingsTrackingAndPerSiteCallbacksAffectActualQueryCleaning() async throws {
        try store.setPersonalLinks(UserSettings(), youTubeCards: nil, userID: 8)
        try await callback("fxclip:rules:p:trackers:off")
        try await callback("fxclip:rules:p:site:x:off")
        api.calls = []
        try await sharedSettingsMessage("https://x.com/example/status/1?utm_source=share&s=20&keep=yes")
        XCTAssertEqual(try sharedSettingsSentText(), "https://fxtwitter.com/example/status/1?utm_source=share&s=20&keep=yes")
        try await callback("fxclip:rules:p:site:x:on")
        api.calls = []
        try await sharedSettingsMessage("https://x.com/example/status/1?utm_source=share&s=20&keep=yes")
        XCTAssertEqual(try sharedSettingsSentText(), "https://fxtwitter.com/example/status/1?utm_source=share&keep=yes")
        try await callback("fxclip:rules:p:trackers:on")
        api.calls = []
        try await sharedSettingsMessage("https://x.com/example/status/1?utm_source=share&s=20&keep=yes")
        XCTAssertEqual(try sharedSettingsSentText(), "https://fxtwitter.com/example/status/1?keep=yes")
    }

    func testSharedSettingsPreviewSiteToggleDoesNotDisableOtherSitesOrCleaning() async throws {
        try store.setPersonalLinks(UserSettings(), youTubeCards: nil, userID: 8)
        try await callback("fxclip:rules:p:preview:reddit:off")
        api.calls = []
        try await sharedSettingsMessage("https://reddit.com/r/example/?utm_source=share")
        XCTAssertEqual(try sharedSettingsSentText(), "https://reddit.com/r/example/")
        api.calls = []
        try await sharedSettingsMessage("https://x.com/example/status/1?s=20")
        XCTAssertEqual(try sharedSettingsSentText(), "https://fxtwitter.com/example/status/1")
        try await callback("fxclip:rules:p:preview:reddit:on")
        api.calls = []
        try await sharedSettingsMessage("https://reddit.com/r/example/?utm_source=share")
        XCTAssertEqual(try sharedSettingsSentText(), "https://vxreddit.com/r/example/")
    }

    func testSharedSettingsProviderCommandCanonicalizesHostAndRewritesReddit() async throws {
        try store.setPersonalLinks(UserSettings(), youTubeCards: nil, userID: 8)
        try await privateCommand("/provider reddit Mirror.Example.")
        XCTAssertEqual(store.state.personalLinkSettings["8"]?.previews["reddit"]?.targetHost, "mirror.example")
        api.calls = []
        try await sharedSettingsMessage("https://old.reddit.com/r/example/?share_id=sample")
        XCTAssertEqual(try sharedSettingsSentText(), "https://mirror.example/r/example/")
        try await privateCommand("/provider reddit default")
        XCTAssertNil(store.state.personalLinkSettings["8"]?.previews["reddit"]?.targetHost)
        api.calls = []
        try await sharedSettingsMessage("https://reddit.com/r/example/")
        XCTAssertEqual(try sharedSettingsSentText(), "https://vxreddit.com/r/example/")
    }

    func testSharedSettingsDefaultAndGroupProviderCommandsUseTheirOwnScope() async throws {
        try await privateCommand("/default provider reddit default.example", userID: 7)
        XCTAssertEqual(store.state.defaultLinkSettings.previews["reddit"]?.targetHost, "default.example")
        try await callback("fxclip:rules:c:-100:customize:confirm", chatID: -100, chatType: "supergroup")
        try await sharedSettingsMessage("/fxclip provider reddit group.example")
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings?.previews["reddit"]?.targetHost, "group.example")
        XCTAssertNil(store.state.personalLinkSettings["8"])
        api.calls = []
        try await sharedSettingsMessage("https://reddit.com/r/example/")
        XCTAssertEqual(try sharedSettingsSentText(), "https://group.example/r/example/")
    }

    func testSharedSettingsInvalidProviderCommandsLeaveEntireStateUnchanged() async throws {
        try store.discover(message().chat)
        try store.setDefaultLinks(sharedSettingsReddit("default.example"), youTubeCards: false)
        try store.setPersonalLinks(sharedSettingsReddit("personal.example"), youTubeCards: true, userID: 8)
        let before = try sharedSettingsSnapshot()
        for invalid in ["https://mirror.example", "mirror.example:443", "mirror.example/path", "user@mirror.example",
                        "localhost", "-bad.example", "mirror..example", "mirror.example?query=yes"] {
            try await privateCommand("/provider reddit \(invalid)")
            XCTAssertEqual(try sharedSettingsSnapshot(), before, invalid)
            try await privateCommand("/default provider reddit \(invalid)", userID: 7)
            XCTAssertEqual(try sharedSettingsSnapshot(), before, invalid)
            try await sharedSettingsMessage("/fxclip provider reddit \(invalid)")
            XCTAssertEqual(try sharedSettingsSnapshot(), before, invalid)
        }
        try await privateCommand("/provider nonexistent mirror.example")
        XCTAssertEqual(try sharedSettingsSnapshot(), before)
    }

    func testSharedSettingsExclusionsCoverSubdomainsByDefaultAndCanBeRemoved() async throws {
        try store.setPersonalLinks(UserSettings(), youTubeCards: nil, userID: 8)
        try await privateCommand("/exclude add Example.COM.")
        XCTAssertEqual(store.state.personalLinkSettings["8"]?.neverClean, [.init(host: "example.com", subdomains: true)])
        api.calls = []
        try await sharedSettingsMessage("https://sub.example.com/path?utm_source=share")
        XCTAssertFalse(api.methods.contains("sendMessage"))
        try await privateCommand("/exclude remove example.com")
        XCTAssertEqual(store.state.personalLinkSettings["8"]?.neverClean, [])
        api.calls = []
        try await sharedSettingsMessage("https://sub.example.com/path?utm_source=share")
        XCTAssertEqual(try sharedSettingsSentText(), "https://sub.example.com/path")
    }

    func testSharedSettingsExactGroupExclusionLeavesSubdomainsEligible() async throws {
        var group = ChatSettings(); group.engineSettings = UserSettings()
        try store.set(group, chatID: -100)
        try await sharedSettingsMessage("/fxclip exclude add example.com exact")
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings?.neverClean,
                       [.init(host: "example.com", subdomains: false)])
        api.calls = []
        try await sharedSettingsMessage("https://example.com/path?utm_source=share")
        XCTAssertFalse(api.methods.contains("sendMessage"))
        try await sharedSettingsMessage("https://sub.example.com/path?utm_source=share")
        XCTAssertEqual(try sharedSettingsSentText(), "https://sub.example.com/path")
        try await sharedSettingsMessage("/fxclip exclude remove example.com")
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings?.neverClean, [])
    }

    func testSharedSettingsYouTubeOffSkipsMetadataWhileOtherPreviewsStillWork() async throws {
        let metadata = enableYouTubeCards()
        try await callback("fxclip:rules:p:youtube:off")
        api.calls = []
        try await sharedSettingsMessage("https://youtu.be/dQw4w9WgXcQ?si=sample")
        XCTAssertTrue(metadata.requestedIDs.isEmpty)
        XCTAssertEqual(api.methods, ["sendMessage"])
        XCTAssertEqual(try sharedSettingsSentText(), "https://youtu.be/dQw4w9WgXcQ")
        api.calls = []
        try await sharedSettingsMessage("https://reddit.com/r/example/")
        XCTAssertEqual(try sharedSettingsSentText(), "https://vxreddit.com/r/example/")
    }

    func testSharedSettingsYouTubePersonalChoiceOverridesGroupAndDefaultIndependently() async throws {
        let metadata = enableYouTubeCards()
        try store.setDefaultLinks(UserSettings(), youTubeCards: false)
        var group = ChatSettings()
        group.youTubeCards = true
        try store.set(group, chatID: -100)
        try await sharedSettingsMessage("https://youtu.be/dQw4w9WgXcQ")
        XCTAssertEqual(metadata.requestedIDs, ["dQw4w9WgXcQ"])
        metadata.requestedIDs = []
        try store.setPersonalLinks(nil, youTubeCards: false, userID: 8)
        api.calls = []
        try await sharedSettingsMessage("https://youtu.be/dQw4w9WgXcQ")
        XCTAssertTrue(metadata.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testSharedSettingsLegacyPreviewMasterBlocksPersonalMirrorsAndYouTubeCards() async throws {
        let metadata = enableYouTubeCards()
        var group = ChatSettings()
        group.previews = false
        group.youTubeCards = true
        try store.set(group, chatID: -100)
        try store.setPersonalLinks(sharedSettingsReddit("personal.example"), youTubeCards: true, userID: 8)
        try await sharedSettingsMessage("https://youtu.be/dQw4w9WgXcQ")
        XCTAssertTrue(metadata.requestedIDs.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
        try await sharedSettingsMessage("https://reddit.com/r/example/?utm_source=share")
        XCTAssertEqual(try sharedSettingsSentText(), "https://reddit.com/r/example/")
    }

    func testSharedSettingsOffAndDisabledGroupPreventConfiguredRewritesAndMetadata() async throws {
        let metadata = enableYouTubeCards()
        try store.setPersonalLinks(sharedSettingsReddit("personal.example"), youTubeCards: true, userID: 8)
        try store.setMode(.off, userID: 8)
        for source in ["https://reddit.com/r/example/?utm_source=share", "https://youtu.be/dQw4w9WgXcQ"] {
            try await sharedSettingsMessage(source)
        }
        XCTAssertTrue(api.calls.isEmpty)
        try store.setMode(.reply, userID: 8)
        try store.setGroupEnabled(false, chatID: -100)
        for source in ["https://reddit.com/r/example/?utm_source=share", "https://youtu.be/dQw4w9WgXcQ"] {
            try await sharedSettingsMessage(source)
        }
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertTrue(metadata.requestedIDs.isEmpty)
    }

    func testSharedSettingsNavigationDoesNotCreateOverrides() async throws {
        let before = try sharedSettingsSnapshot()
        for action in ["show", "clean", "previews", "excluded", "provider:reddit"] {
            api.calls = []
            try await callback("fxclip:rules:p:\(action)")
            XCTAssertEqual(try sharedSettingsSnapshot(), before, action)
            XCTAssertTrue(api.methods.contains("answerCallbackQuery"), action)
            XCTAssertTrue(api.methods.contains("editMessageText"), action)
        }
    }

    func testSharedSettingsProviderResetPreservesOtherPersonalChoices() async throws {
        var settings = sharedSettingsReddit("personal.example")
        settings.trackersEverywhere = false
        try store.setPersonalLinks(settings, youTubeCards: false, userID: 8)
        try await callback("fxclip:rules:p:providerreset:reddit")
        settings.previews["reddit"]?.targetHost = nil
        XCTAssertEqual(store.state.personalLinkSettings["8"], settings)
        XCTAssertEqual(store.state.personalYouTubeCards["8"], false)
    }

    func testSharedSettingsPersonalAndGroupResetResumeInheritanceWithoutChangingLegacyMaster() async throws {
        try store.setDefaultLinks(sharedSettingsReddit("default.example"), youTubeCards: false)
        try store.setPersonalLinks(sharedSettingsReddit("personal.example"), youTubeCards: true, userID: 8)
        var group = ChatSettings()
        group.mode = .replace
        group.previews = false
        group.engineSettings = sharedSettingsReddit("group.example")
        group.youTubeCards = true
        try store.set(group, chatID: -100)
        try await callback("fxclip:rules:p:reset")
        XCTAssertNil(store.state.personalLinkSettings["8"])
        XCTAssertNil(store.state.personalYouTubeCards["8"])
        try await callback("fxclip:rules:c:-100:reset", chatID: -100, chatType: "supergroup")
        XCTAssertNil(store.state.chats["-100"]?.engineSettings)
        XCTAssertNil(store.state.chats["-100"]?.youTubeCards)
        XCTAssertEqual(store.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(store.state.chats["-100"]?.previews, false)
        XCTAssertEqual(store.state.defaultLinkSettings, sharedSettingsReddit("default.example"))
    }

    func testSharedSettingsOwnerDefaultCallbacksAndResetRestoreBuiltIns() async throws {
        try await callback("fxclip:rules:d:trackers:off", userID: 7, chatID: 7)
        XCTAssertFalse(store.state.defaultLinkSettings.trackersEverywhere)
        try await callback("fxclip:rules:d:youtube:off", userID: 7, chatID: 7)
        XCTAssertFalse(store.state.defaultYouTubeCards)
        try await callback("fxclip:rules:d:reset", userID: 7, chatID: 7)
        XCTAssertEqual(store.state.defaultLinkSettings, UserSettings())
        XCTAssertTrue(store.state.defaultYouTubeCards)
    }

    func testSharedSettingsCallbacksRejectCrossScopeAndUnauthorizedMutations() async throws {
        let before = try sharedSettingsSnapshot()
        let attempts: [(String, Int64, Int64, String)] = [
            ("fxclip:rules:p:trackers:off", 8, 7, "private"),
            ("fxclip:rules:p:trackers:off", 8, -100, "supergroup"),
            ("fxclip:rules:d:trackers:off", 8, 8, "private"),
            ("fxclip:rules:d:trackers:off", 7, 8, "private"),
            ("fxclip:rules:d:trackers:off", 7, -100, "supergroup"),
            ("fxclip:rules:c:-100:trackers:off", 8, -200, "supergroup"),
            ("fxclip:rules:c:-100:trackers:off", 7, 7, "private"),
        ]
        for (data, userID, chatID, type) in attempts {
            api.calls = []
            try await callback(data, userID: userID, chatID: chatID, chatType: type)
            XCTAssertEqual(try sharedSettingsSnapshot(), before, data)
            XCTAssertTrue(api.methods.contains("answerCallbackQuery"), data)
            XCTAssertFalse(api.methods.contains("editMessageText"), data)
        }
    }

    func testSharedSettingsGroupCallbacksRecheckRevokedAndUnavailableAdminRights() async throws {
        var group = ChatSettings(); group.engineSettings = UserSettings()
        try store.set(group, chatID: -100)
        try await callback("fxclip:rules:c:-100:trackers:off", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings?.trackersEverywhere, false)
        let before = try sharedSettingsSnapshot()
        api.calls = []
        api.admin = false
        try await callback("fxclip:rules:c:-100:trackers:on", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
        XCTAssertEqual(try sharedSettingsSnapshot(), before)
        api.calls = []
        api.failMember = true
        try await callback("fxclip:rules:c:-100:reset", chatID: -100, chatType: "supergroup")
        XCTAssertEqual(api.methods, ["getChatMember", "answerCallbackQuery"])
        XCTAssertEqual(try sharedSettingsSnapshot(), before)
    }

    func testSharedSettingsOwnerGroupExceptionWorksWhenMemberLookupUnavailable() async throws {
        var group = ChatSettings(); group.engineSettings = UserSettings()
        try store.set(group, chatID: -100)
        api.failMember = true
        try await callback("fxclip:rules:c:-100:trackers:off", userID: 7, chatID: -100, chatType: "supergroup")
        XCTAssertEqual(store.state.chats["-100"]?.engineSettings?.trackersEverywhere, false)
        XCTAssertFalse(api.methods.contains("getChatMember"))
    }

    func testSharedSettingsStaleRuleCallbacksLeaveStateUnchanged() async throws {
        try store.setPersonalLinks(UserSettings(), youTubeCards: nil, userID: 8)
        let before = try sharedSettingsSnapshot()
        for action in ["site:missing:off", "preview:missing:on", "provider:missing", "providerreset:missing",
                       "trackers:maybe", "youtube:maybe", "preview:reddit:off:extra", "unknown", "reset:extra"] {
            api.calls = []
            try await callback("fxclip:rules:p:\(action)")
            XCTAssertEqual(try sharedSettingsSnapshot(), before, action)
            XCTAssertTrue(api.methods.contains("answerCallbackQuery"), action)
            XCTAssertFalse(api.methods.contains("editMessageText"), action)
        }
    }

    func testSharedSettingsCommandsRejectNonOwnerDefaultAndRevokedGroupAdmin() async throws {
        try store.discover(message().chat)
        let before = try sharedSettingsSnapshot()
        try await privateCommand("/default provider reddit mirror.example")
        XCTAssertEqual(try sharedSettingsSnapshot(), before)
        api.admin = false
        try await sharedSettingsMessage("/fxclip provider reddit mirror.example")
        XCTAssertEqual(try sharedSettingsSnapshot(), before)
        try await sharedSettingsMessage("/fxclip exclude add example.com")
        XCTAssertEqual(try sharedSettingsSnapshot(), before)
        try await handle(["text": "/provider reddit mirror.example", "chat": ["id": 7, "type": "private"],
                          "from": fixtureUser(8, languageCode: nil)])
        XCTAssertEqual(try sharedSettingsSnapshot(), before)
    }

    func testSharedSettingsLegacyJSONMigratesWithInheritanceAndPreservedPreviewMaster() throws {
        let legacy = #"{"offset":23,"chats":{"-100":{"mode":"replace","previews":false}},"users":{"8":"off"},"defaultMode":"reply","lastUpdateAt":1000}"#
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("state.json"))
        let restored = try StateStore(directory: directory)
        XCTAssertEqual(restored.state.offset, 23)
        XCTAssertEqual(restored.state.users["8"], .off)
        XCTAssertEqual(restored.state.chats["-100"]?.mode, .replace)
        XCTAssertEqual(restored.state.chats["-100"]?.previews, false)
        XCTAssertNil(restored.state.chats["-100"]?.engineSettings)
        XCTAssertNil(restored.state.chats["-100"]?.youTubeCards)
        XCTAssertEqual(restored.state.defaultLinkSettings, UserSettings())
        XCTAssertTrue(restored.state.defaultYouTubeCards)
        XCTAssertTrue(restored.state.personalLinkSettings.isEmpty)
        XCTAssertTrue(restored.state.personalYouTubeCards.isEmpty)
    }

    func testSharedSettingsNewStateRoundTripPreservesAllScopesAndOptionalInheritance() throws {
        var defaults = sharedSettingsReddit("default.example")
        defaults.trackersEverywhere = false
        defaults.disabledSites = ["amazon"]
        defaults.neverClean = [.init(host: "excluded.example", subdomains: true)]
        try store.setDefaultLinks(defaults, youTubeCards: false)
        let personal = sharedSettingsReddit("personal.example")
        try store.setPersonalLinks(personal, youTubeCards: true, userID: 8)
        try store.setPersonalLinks(nil, youTubeCards: false, userID: 7)
        var group = ChatSettings()
        group.mode = .replace
        group.previews = false
        group.engineSettings = sharedSettingsReddit("group.example")
        group.youTubeCards = false
        try store.set(group, chatID: -100)
        try store.set(ChatSettings(), chatID: -200)
        let restored = try StateStore(directory: directory).state
        XCTAssertEqual(restored.defaultLinkSettings, defaults)
        XCTAssertFalse(restored.defaultYouTubeCards)
        XCTAssertEqual(restored.personalLinkSettings["8"], personal)
        XCTAssertEqual(restored.personalYouTubeCards["8"], true)
        XCTAssertNil(restored.personalLinkSettings["7"])
        XCTAssertEqual(restored.personalYouTubeCards["7"], false)
        XCTAssertEqual(restored.chats["-100"]?.engineSettings, group.engineSettings)
        XCTAssertEqual(restored.chats["-100"]?.youTubeCards, false)
        XCTAssertEqual(restored.chats["-100"]?.previews, false)
        XCTAssertEqual(restored.chats["-100"]?.mode, .replace)
        XCTAssertNil(restored.chats["-200"]?.engineSettings)
        XCTAssertNil(restored.chats["-200"]?.youTubeCards)
    }
}
