import Foundation
import XCTest
import FxEngine
@testable import FxTelegram

/// Keep pending-message receipts independent of FakeAPI's legacy send/edit defaults.
private final class PendingPreviewAPI: BotAPI {
    var calls: [(String, [String: Any])] = []
    var outcomes: [String: [Result<Any, Error>]] = [:]
    var nextMessageID: Int64 = 7301
    var beforeCall: ((String, [String: Any]) -> Void)?
    var completedAt: [String: TimeInterval] = [:]
    var canDelete = true

    var methods: [String] { calls.map(\.0) }

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        if ["sendMessage", "sendPhoto", "sendVideo"].contains(method),
           let chatID = parameters["chat_id"] as? Int64, chatID < 0 {
            XCTAssertEqual(parameters["protect_content"] as? Bool, true,
                           "Even the placeholder must already be protected")
        }
        if ["editMessageText", "editMessageMedia"].contains(method) {
            XCTAssertNil(parameters["protect_content"], "Telegram edits cannot set content protection")
        }
        calls.append((method, parameters))
        beforeCall?(method, parameters)
        if var queued = outcomes[method], !queued.isEmpty {
            let outcome = queued.removeFirst()
            outcomes[method] = queued
            let value = try outcome.get()
            completedAt[method] = Date().timeIntervalSince1970
            return value
        }
        let result: Any
        switch method {
        case "sendMessage", "sendPhoto", "sendVideo":
            result = ["message_id": nextMessageID]
            nextMessageID += 1
        case "editMessageText", "editMessageMedia", "editMessageReplyMarkup":
            result = ["message_id": parameters["message_id"] ?? NSNull()]
        case "getChatMember":
            result = ["status": "administrator", "can_delete_messages": canDelete]
        default:
            result = true
        }
        completedAt[method] = Date().timeIntervalSince1970
        return result
    }
}

private final class PendingFacebookProvider: FacebookReelProviding {
    var delayNanoseconds: UInt64 = 25_000_000
    var error: Error?
    var requests = 0
    let author = "Example creator 😀"
    let caption = "A public video."
    let video = Data([0, 0, 0, 16, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0])

    func fetch(reelID: String) async throws -> FacebookReel { try await result() }
    func fetch(sourceURL: String) async throws -> FacebookReel { try await result() }

    private func result() async throws -> FacebookReel {
        requests += 1
        try await Task.sleep(nanoseconds: delayNanoseconds)
        if let error { throw error }
        return FacebookReel(author: author, caption: caption, video: video)
    }
}

private final class PendingYouTubeProvider: YouTubeMetadataProviding {
    var delayNanoseconds: UInt64 = 25_000_000
    var error: Error?
    var requests = 0
    let title = "🎬 Example video 😀"
    let thumbnailURL = URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")!

    func fetch(videoID: String) async throws -> YouTubeMetadata {
        requests += 1
        try await Task.sleep(nanoseconds: delayNanoseconds)
        if let error { throw error }
        return YouTubeMetadata(title: title, thumbnailURL: thumbnailURL)
    }
}

final class PendingPreviewBotTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!
    private var engine: Engine!
    private var api: PendingPreviewAPI!
    private var facebook: PendingFacebookProvider!
    private var youtube: PendingYouTubeProvider!
    private var bot: Bot!
    private let facebookURL = "https://www.facebook.com/reel/123456"
    private let youtubeURL = "https://youtu.be/dQw4w9WgXcQ?t=42"
    private var dirtyFacebookURL: String { facebookURL + "?utm_source=share&mibextid=tracking" }
    private var dirtyYouTubeURL: String { youtubeURL + "&si=tracking" }

    override func setUpWithError() throws {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared")
        engine = Engine(rules: try Rules.load(Data(contentsOf: shared.appendingPathComponent("rules.json"))))
        try reset()
    }

    override func tearDownWithError() throws {
        api.beforeCall = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func reset(language: BotLanguage = .en, replace: Bool = false,
                       pendingDelay: UInt64 = 0, providerDelay: UInt64 = 25_000_000) throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try StateStore(directory: directory)
        api?.beforeCall = nil
        api = PendingPreviewAPI()
        facebook = PendingFacebookProvider()
        youtube = PendingYouTubeProvider()
        facebook.delayNanoseconds = providerDelay
        youtube.delayNanoseconds = providerDelay
        try store.setDefaultFacebookReels(true)
        try store.setGroupLanguage(language, chatID: -100)
        if replace {
            var settings = ChatSettings()
            settings.mode = .replace
            try store.set(settings, chatID: -100)
        }
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", youTubeMetadata: youtube, facebookReels: facebook,
                  pendingPreviewDelayNanoseconds: pendingDelay)
    }

    private func handle(_ text: String, extra: [String: Any] = [:], now: Int? = 1100) async throws {
        var message: [String: Any] = ["message_id": 5, "date": now == nil ? Int(Date().timeIntervalSince1970) : 1000,
            "chat": ["id": -100, "type": "supergroup"],
            "from": ["id": 7, "first_name": "Member 😀", "is_bot": false], "text": text]
        message.merge(extra) { _, new in new }
        let update = try decode(Update.self, from: ["update_id": 1, "message": message])
        try await bot.handle(update, now: now)
    }

    private func parameters(_ method: String) throws -> [String: Any] {
        try XCTUnwrap(api.calls.first { $0.0 == method }?.1)
    }

    private func rows(_ parameters: [String: Any]) throws -> [[InlineKeyboardButton]] {
        try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(parameters["reply_markup"])).inline_keyboard
    }

    private func deletedIDs() -> [Int64] {
        api.calls.filter { $0.0 == "deleteMessage" }.compactMap { $0.1["message_id"] as? Int64 }
    }

    private func assertPending(_ parameters: [String: Any], language: BotLanguage = .en,
                               replyTo: Int64? = 5, thread: Int64? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parameters["text"] as? String,
                       language == .fr ? "Préparation de l’aperçu…" : "Preparing preview…", file: file, line: line)
        XCTAssertEqual(parameters["chat_id"] as? Int64, -100, file: file, line: line)
        XCTAssertEqual(parameters["disable_notification"] as? Bool, true, file: file, line: line)
        XCTAssertEqual((parameters["link_preview_options"] as? [String: Any])?["is_disabled"] as? Bool,
                       true, file: file, line: line)
        XCTAssertEqual((parameters["reply_parameters"] as? [String: Any])?["message_id"] as? Int64,
                       replyTo, file: file, line: line)
        XCTAssertEqual(parameters["message_thread_id"] as? Int64, thread, file: file, line: line)
        XCTAssertNil(parameters["reply_markup"], file: file, line: line)
    }

    private func assertSameIDEdit(_ parameters: [String: Any], id: Int64 = 7301,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parameters["chat_id"] as? Int64, -100, file: file, line: line)
        XCTAssertEqual(parameters["message_id"] as? Int64, id, file: file, line: line)
        XCTAssertNil(parameters["reply_parameters"], file: file, line: line)
        XCTAssertNil(parameters["message_thread_id"], file: file, line: line)
    }

    private func assertInvalidReceipt(_ text: String, file: StaticString = #filePath,
                                      line: UInt = #line) async {
        do {
            try await handle(text)
            XCTFail("Expected unconfirmed Telegram receipt to fail", file: file, line: line)
        } catch BotError.invalidResponse {
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func testSlowFacebookLocalizesPendingAndEditsItToBareUploadedVideo() async throws {
        for language in [BotLanguage.en, .fr] {
            try reset(language: language)
            api.beforeCall = { method, _ in
                if method == "sendMessage" || method == "editMessageMedia" {
                    XCTAssertTrue(self.store.state.replyControls.isEmpty)
                    XCTAssertTrue(self.deletedIDs().isEmpty)
                }
            }
            try await handle(facebookURL, extra: ["message_thread_id": 123])
            XCTAssertEqual(api.methods, ["sendMessage", "editMessageMedia"])
            assertPending(try parameters("sendMessage"), language: language, thread: 123)
            let edit = try parameters("editMessageMedia")
            assertSameIDEdit(edit)
            let media = try XCTUnwrap(edit["media"] as? [String: Any])
            XCTAssertEqual(media["type"] as? String, "video")
            XCTAssertEqual((media["media"] as? VideoUpload)?.data, facebook.video)
            XCTAssertEqual(media["supports_streaming"] as? Bool, true)
            XCTAssertNil(media["caption"])
            XCTAssertNil(media["caption_entities"])
            XCTAssertNil(edit["video"])
            let buttons = try rows(edit).flatMap { $0 }
            XCTAssertEqual(buttons.map(\.callback_data), ["fxclip:preview:delete", "fxclip:preview:replace"])
            XCTAssertEqual(try rows(edit).map(\.count), [2])
            XCTAssertEqual(buttons.map(\.text), language == .fr ? ["🗑 Retirer", "🔁 Remplacer"] : ["🗑 Remove", "🔁 Replace"])
            XCTAssertNil(buttons.first?.url)
            XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:7301"])
            XCTAssertEqual(store.state.replyControls["-100:7301"]?.posterID, 7)
            XCTAssertNil(store.state.replyControls["-100:7301"]?.openButton)
        }
    }

    func testSlowYouTubePreservesCaptionEntitiesAndLocalizedOpenButton() async throws {
        for language in [BotLanguage.en, .fr] {
            try reset(language: language)
            try await handle(dirtyYouTubeURL, extra: ["message_thread_id": 123,
                "entities": [["type": "url", "offset": 0, "length": dirtyYouTubeURL.utf16.count]]])
            XCTAssertEqual(api.methods, ["sendMessage", "editMessageMedia"])
            assertPending(try parameters("sendMessage"), language: language, thread: 123)
            let edit = try parameters("editMessageMedia")
            assertSameIDEdit(edit)
            let media = try XCTUnwrap(edit["media"] as? [String: Any])
            XCTAssertEqual(media["type"] as? String, "photo")
            XCTAssertEqual(media["media"] as? String, youtube.thumbnailURL.absoluteString)
            let caption = try XCTUnwrap(media["caption"] as? String)
            XCTAssertEqual(caption, "YouTube\n" + youtube.title)
            let entities = try decode([Entity].self, from: XCTUnwrap(media["caption_entities"]))
            let heading = try XCTUnwrap(entities.first { $0.type == "text_link" })
            XCTAssertEqual(heading.url, youtubeURL)
            XCTAssertEqual((caption as NSString).substring(with: NSRange(location: heading.offset, length: heading.length)), "YouTube")
            let title = try XCTUnwrap(entities.first { $0.type == "bold" })
            XCTAssertEqual((caption as NSString).substring(with: NSRange(location: title.offset, length: title.length)), youtube.title)
            XCTAssertFalse(entities.contains { $0.type == "url" })
            XCTAssertFalse(caption.contains(youtubeURL))
            XCTAssertEqual(media["show_caption_above_media"] as? Bool, true)
            let buttons = try rows(edit)
            XCTAssertEqual(buttons.count, 2)
            XCTAssertEqual(buttons.first?.first?.text, language == .fr ? "▶ Ouvrir YouTube" : "▶ Open YouTube")
            XCTAssertEqual(buttons.first?.first?.url, youtubeURL)
            XCTAssertEqual(buttons.first?.first?.style, "danger")
            XCTAssertEqual(buttons.last?.first?.callback_data, "fxclip:preview:delete")
            XCTAssertEqual(store.state.replyControls["-100:7301"]?.openButton, buttons.first?.first)
            XCTAssertTrue(deletedIDs().isEmpty)
        }
    }

    func testFastProvidersSkipPlaceholderAndKeepExistingDirectSendPaths() async throws {
        for isFacebook in [true, false] {
            try reset(pendingDelay: 5_000_000_000, providerDelay: 1_000_000)
            try await handle(isFacebook ? facebookURL : youtubeURL)
            XCTAssertEqual(api.methods, [isFacebook ? "sendVideo" : "sendPhoto"])
            XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:7301"])
        }
    }

    func testDisabledPreviewsOffModeAndProtectedMessagesNeverSendPlaceholder() async throws {
        for isFacebook in [true, false] {
            let source = isFacebook ? facebookURL : youtubeURL
            for gate in ["previews", "feature", "off", "disabled", "protected", "suppressed"] {
                try reset()
                var extra: [String: Any] = [:]
                switch gate {
                case "previews":
                    var settings = ChatSettings(); settings.previews = false
                    try store.set(settings, chatID: -100)
                case "feature":
                    if isFacebook { try store.setDefaultFacebookReels(false) }
                    else { try store.setPersonalLinks(nil, youTubeCards: false, userID: 7) }
                case "off": try store.setMode(.off, userID: 7)
                case "disabled": try store.setGroupEnabled(false, chatID: -100)
                case "protected": extra["has_protected_content"] = true
                default: extra["link_preview_options"] = ["is_disabled": true]
                }
                try await handle(source, extra: extra)
                XCTAssertTrue(api.calls.isEmpty, gate)
                XCTAssertEqual(facebook.requests, 0, gate)
                XCTAssertEqual(youtube.requests, 0, gate)
            }
        }
    }

    func testReplacementUsesExpectedTopologyAndWaitsForConfirmedFinalBeforeDeletingOriginal() async throws {
        for isFacebook in [true, false] {
            for parent: Int64? in [nil, 3] {
                try reset(replace: true)
                var observedFinal = false
                api.beforeCall = { method, parameters in
                    if method == (isFacebook ? "sendVideo" : "editMessageMedia") {
                        observedFinal = true
                        XCTAssertTrue(self.deletedIDs().isEmpty)
                        XCTAssertTrue(self.store.state.replyControls.isEmpty)
                        if !isFacebook { self.assertSameIDEdit(parameters) }
                    }
                    if method == "deleteMessage" { XCTAssertTrue(observedFinal) }
                }
                let extra: [String: Any] = parent.map { ["reply_to_message": ["message_id": $0], "message_thread_id": 123] }
                    ?? ["message_thread_id": 123]
                try await handle(isFacebook ? dirtyFacebookURL : dirtyYouTubeURL, extra: extra)
                XCTAssertEqual(api.methods, isFacebook ? ["getChatMember", "sendVideo", "deleteMessage"]
                    : ["getChatMember", "sendMessage", "editMessageMedia", "deleteMessage"])
                let media: [String: Any]
                if isFacebook {
                    media = try parameters("sendVideo")
                    XCTAssertEqual((media["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, parent)
                    XCTAssertEqual(media["message_thread_id"] as? Int64, 123)
                    XCTAssertEqual((media["video"] as? VideoUpload)?.data, facebook.video)
                } else {
                    assertPending(try parameters("sendMessage"), replyTo: parent, thread: 123)
                    media = try XCTUnwrap(parameters("editMessageMedia")["media"] as? [String: Any])
                }
                XCTAssertEqual(deletedIDs(), [5])
                XCTAssertEqual(store.state.replyControls["-100:7301"]?.posterID, 7)
                XCTAssertEqual(store.state.publications["-100:7301"]?.posterID, 7)
                let caption = try XCTUnwrap(media["caption"] as? String)
                let entities = try decode([Entity].self, from: XCTUnwrap(media["caption_entities"]))
                let credit = try XCTUnwrap(entities.first { $0.type == "text_mention" })
                XCTAssertEqual(credit.user?.id, 7)
                XCTAssertEqual((caption as NSString).substring(with: NSRange(location: credit.offset, length: credit.length)), "Member 😀")
            }
        }
    }

    func testCleanFacebookUnderPersonalReplaceStillUsesPendingReplyOnOriginal() async throws {
        try store.setMode(.replace, userID: 7)
        try await handle(facebookURL, extra: ["reply_to_message": ["message_id": 3], "message_thread_id": 123])
        XCTAssertEqual(api.methods, ["sendMessage", "editMessageMedia"])
        assertPending(try parameters("sendMessage"), thread: 123)
        XCTAssertNotNil(store.state.replyControls["-100:7301"])
        XCTAssertTrue(deletedIDs().isEmpty)
    }

    func testFacebookReplacementAmbiguousOrUnconfirmedVideoSendNeverDeletesOriginal() async throws {
        let outcomes: [Result<Any, Error>] = [.failure(URLError(.timedOut)), .failure(BotError.telegram(500)),
            .success(true), .success(["message_id": true]), .success(["message_id": Int64(0)])]
        for outcome in outcomes {
            try reset(replace: true)
            api.outcomes["sendVideo"] = [outcome]
            do { try await handle(dirtyFacebookURL); XCTFail("Expected unconfirmed replacement send") } catch {}
            XCTAssertEqual(api.methods, ["getChatMember", "sendVideo"])
            XCTAssertTrue(deletedIDs().isEmpty)
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testMissingReplacementPermissionKeepsPendingReplyOnOriginal() async throws {
        try reset(replace: true)
        api.canDelete = false
        try await handle(dirtyFacebookURL, extra: ["reply_to_message": ["message_id": 3]])
        XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "editMessageMedia"])
        assertPending(try parameters("sendMessage"))
        XCTAssertTrue(deletedIDs().isEmpty)
        XCTAssertNotNil(store.state.replyControls["-100:7301"])
    }

    func testFetchFailureUsesExpectedDirtyFallbackPathAndDeletesOnlyAfterConfirmation() async throws {
        for isFacebook in [true, false] {
            for replace in [false, true] {
                try reset(replace: replace)
                facebook.error = URLError(.timedOut)
                youtube.error = URLError(.timedOut)
                api.beforeCall = { method, _ in
                    if method == "editMessageText" || (isFacebook && replace && method == "sendMessage") {
                        XCTAssertTrue(self.deletedIDs().isEmpty)
                        XCTAssertTrue(self.store.state.replyControls.isEmpty)
                    }
                }
                let clean = isFacebook ? facebookURL : youtubeURL
                try await handle(isFacebook ? dirtyFacebookURL : dirtyYouTubeURL)
                let direct = isFacebook && replace
                XCTAssertEqual(api.methods, direct ? ["getChatMember", "sendMessage", "deleteMessage"] : replace
                    ? ["getChatMember", "sendMessage", "editMessageText", "deleteMessage"] : ["sendMessage", "editMessageText"])
                let edit = try parameters(direct ? "sendMessage" : "editMessageText")
                if !direct { assertSameIDEdit(edit) }
                XCTAssertTrue((edit["text"] as? String ?? "").hasSuffix(clean))
                XCTAssertNotNil(edit["entities"])
                XCTAssertEqual(deletedIDs(), replace ? [5] : [])
                XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:7301"])
                XCTAssertEqual(store.state.publications["-100:7301"]?.posterID, 7)
            }
        }
    }

    func testCleanFetchFailureDeletesOnlyItsPendingMessageAndDoesNotCreateReceipt() async throws {
        for isFacebook in [true, false] {
            try reset(replace: true)
            facebook.error = URLError(.timedOut)
            youtube.error = URLError(.timedOut)
            try await handle(isFacebook ? facebookURL : youtubeURL)
            XCTAssertEqual(api.methods, ["sendMessage", "deleteMessage"])
            XCTAssertEqual(deletedIDs(), [7301])
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testOversizeNoticeEditsSamePendingIDAndKeepsOpenAndRemovalControls() async throws {
        for language in [BotLanguage.en, .fr] {
            try reset(language: language)
            facebook.error = FacebookReelError.videoTooLarge(author: facebook.author, caption: facebook.caption)
            try await handle(dirtyFacebookURL, extra: ["reply_to_message": ["message_id": 3], "message_thread_id": 123])
            XCTAssertEqual(api.methods, ["sendMessage", "editMessageText"])
            assertPending(try parameters("sendMessage"), language: language, thread: 123)
            let edit = try parameters("editMessageText")
            assertSameIDEdit(edit)
            XCTAssertTrue((edit["text"] as? String ?? "").contains(language == .fr ? "20 Mio" : "20 MiB"))
            let buttons = try rows(edit)
            XCTAssertEqual(buttons.count, 2)
            XCTAssertEqual(buttons.first?.first?.url, facebookURL)
            XCTAssertEqual(buttons.first?.first?.text, language == .fr ? "▶ Ouvrir Facebook" : "▶ Open Facebook")
            XCTAssertEqual(buttons.last?.first?.callback_data, "fxclip:preview:delete")
            XCTAssertEqual(store.state.replyControls["-100:7301"]?.openButton, buttons.first?.first)
            XCTAssertTrue(deletedIDs().isEmpty)
        }
    }

    func testFastAndSlowOversizeFacebookReplacementBothSendNoticeReplyingToOriginal() async throws {
        for language in [BotLanguage.en, .fr] {
            for parent: Int64? in [nil, 3] {
                var notices: [Data] = []
                for slow in [false, true] {
                    try reset(language: language, replace: true, pendingDelay: slow ? 0 : 5_000_000_000,
                              providerDelay: slow ? 25_000_000 : 1_000_000)
                    facebook.error = FacebookReelError.videoTooLarge(author: facebook.author, caption: facebook.caption)
                    var extra: [String: Any] = ["message_thread_id": 123]
                    if let parent { extra["reply_to_message"] = ["message_id": parent] }
                    try await handle(dirtyFacebookURL, extra: extra)
                    XCTAssertEqual(api.methods, ["getChatMember", "sendMessage"])
                    let notice = try parameters("sendMessage")
                    XCTAssertEqual((notice["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5)
                    XCTAssertEqual(notice["message_thread_id"] as? Int64, 123)
                    XCTAssertTrue((notice["text"] as? String ?? "").contains(language == .fr ? "20 Mio" : "20 MiB"))
                    let buttons = try rows(notice)
                    XCTAssertEqual(buttons.first?.first?.url, facebookURL)
                    XCTAssertEqual(buttons.last?.first?.callback_data, "fxclip:preview:delete")
                    XCTAssertEqual(store.state.replyControls["-100:7301"]?.openButton, buttons.first?.first)
                    XCTAssertTrue(deletedIDs().isEmpty)
                    notices.append(try JSONSerialization.data(withJSONObject: notice, options: [.sortedKeys]))
                }
                XCTAssertEqual(notices.first, notices.last)
            }
        }
    }

    func testPendingExplicit400Or403RejectionUsesRegularFinalSend() async throws {
        for isFacebook in [true, false] {
            for code in [400, 403] {
                try reset(replace: !isFacebook)
                api.outcomes["sendMessage"] = [.failure(BotError.telegram(code))]
                try await handle(isFacebook ? dirtyFacebookURL : dirtyYouTubeURL)
                XCTAssertEqual(api.methods, isFacebook ? ["sendMessage", "sendVideo"]
                    : ["getChatMember", "sendMessage", "sendPhoto", "deleteMessage"])
                XCTAssertEqual(deletedIDs(), isFacebook ? [] : [5])
                XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:7301"])
                XCTAssertEqual(store.state.publications["-100:7301"]?.posterID, 7)
            }
        }
    }

    func testAmbiguousPendingSendNeverDuplicatesOrDeletesOriginal() async throws {
        for failure in [URLError(.timedOut) as Error, BotError.invalidResponse, BotError.telegram(500)] {
            try reset(replace: true)
            api.outcomes["sendMessage"] = [.failure(failure)]
            do { try await handle(dirtyYouTubeURL); XCTFail("Expected ambiguous pending send to fail") } catch {}
            XCTAssertEqual(api.methods, ["getChatMember", "sendMessage"])
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testMalformedPendingSendReceiptNeverEditsOrDeletesAnyMessage() async throws {
        let receipts: [Any] = [true, ["message_id": true], ["message_id": Int64(0)],
            ["message_id": Int64(-1)], ["message_id": Int64(5)], ["message_id": "7301"], ["message_id": 7301.5]]
        for receipt in receipts {
            try reset(replace: true)
            api.outcomes["sendMessage"] = [.success(receipt)]
            await assertInvalidReceipt(dirtyYouTubeURL)
            XCTAssertEqual(api.methods, ["getChatMember", "sendMessage"])
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testFinalEditBooleanOrMismatchedMessageIDNeverConfirmsReplacementOrReceipt() async throws {
        let receipts: [Any] = [true, ["message_id": true], ["message_id": Int64(7302)],
            ["message_id": Int64(5)], ["message_id": Int64(0)], ["message_id": "7301"]]
        for isFacebook in [true, false] {
            for replace in (isFacebook ? [false] : [false, true]) {
                for receipt in receipts {
                    try reset(replace: replace)
                    api.outcomes["editMessageMedia"] = [.success(receipt)]
                    await assertInvalidReceipt(isFacebook ? dirtyFacebookURL : dirtyYouTubeURL)
                    XCTAssertEqual(api.methods, replace
                        ? ["getChatMember", "sendMessage", "editMessageMedia"] : ["sendMessage", "editMessageMedia"])
                    XCTAssertTrue(deletedIDs().isEmpty)
                    XCTAssertTrue(store.state.replyControls.isEmpty)
                }
            }
        }
    }

    func testAmbiguousFinalMediaEditNeverResendsFallsBackOrDeletesOriginal() async throws {
        for isFacebook in [true, false] {
            for failure in [URLError(.timedOut) as Error, BotError.invalidResponse, BotError.telegram(500)] {
                try reset(replace: !isFacebook)
                api.outcomes["editMessageMedia"] = [.failure(failure)]
                do { try await handle(isFacebook ? dirtyFacebookURL : dirtyYouTubeURL); XCTFail("Expected final edit failure") } catch {}
                XCTAssertEqual(api.methods, isFacebook ? ["sendMessage", "editMessageMedia"]
                    : ["getChatMember", "sendMessage", "editMessageMedia"])
                XCTAssertTrue(deletedIDs().isEmpty)
                XCTAssertTrue(store.state.replyControls.isEmpty)
            }
        }
    }

    func testExplicitFinalMediaRejectionCanOnlyFallbackByEditingSamePendingID() async throws {
        for isFacebook in [true, false] {
            for code in [400, 403] {
                try reset(replace: !isFacebook)
                api.outcomes["editMessageMedia"] = [.failure(BotError.telegram(code))]
                try await handle(isFacebook ? dirtyFacebookURL : dirtyYouTubeURL)
                XCTAssertEqual(api.methods, isFacebook ? ["sendMessage", "editMessageMedia", "editMessageText"]
                    : ["getChatMember", "sendMessage", "editMessageMedia", "editMessageText", "deleteMessage"])
                assertSameIDEdit(try parameters("editMessageText"))
                XCTAssertEqual(deletedIDs(), isFacebook ? [] : [5])
            }
        }
    }

    func testExplicitFinalRejectionWithoutFallbackDiscardsOnlyKnownPending() async throws {
        for isFacebook in [true, false] {
            for code in [400, 403] {
                try reset(replace: true)
                api.outcomes["editMessageMedia"] = [.failure(BotError.telegram(code))]
                try await handle(isFacebook ? facebookURL : youtubeURL)
                XCTAssertEqual(api.methods, ["sendMessage", "editMessageMedia", "deleteMessage"])
                XCTAssertEqual(deletedIDs(), [7301])
                XCTAssertTrue(store.state.replyControls.isEmpty)
            }
        }
    }

    func testRejectedTextFallbackCleansPendingWithoutResurrectingReplyOrDeletingOriginal() async throws {
        for code in [400, 403] {
            try reset(replace: true)
            youtube.error = URLError(.timedOut)
            api.outcomes["editMessageText"] = [.failure(BotError.telegram(code))]
            do { try await handle(dirtyYouTubeURL); XCTFail("Expected text edit rejection") } catch {}
            XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "editMessageText", "deleteMessage"])
            XCTAssertEqual(deletedIDs(), [7301])
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testUnconfirmedOrAmbiguousTextFallbackNeverDeletesOriginalOrDuplicates() async throws {
        for outcome in [Result<Any, Error>.success(true), .success(["message_id": Int64(7302)]),
                        .failure(URLError(.timedOut)), .failure(BotError.telegram(500))] {
            try reset(replace: true)
            youtube.error = URLError(.timedOut)
            api.outcomes["editMessageText"] = [outcome]
            do { try await handle(dirtyYouTubeURL); XCTFail("Expected unconfirmed text edit") } catch {}
            XCTAssertEqual(api.methods, ["getChatMember", "sendMessage", "editMessageText"])
            XCTAssertTrue(deletedIDs().isEmpty)
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testFailedPendingCleanupBestEffortReplacesStatusWithLocalizedUnavailableText() async throws {
        for language in [BotLanguage.en, .fr] {
            try reset(language: language)
            facebook.error = URLError(.timedOut)
            api.outcomes["deleteMessage"] = [.failure(BotError.telegram(403))]
            try await handle(facebookURL)
            XCTAssertEqual(api.methods, ["sendMessage", "deleteMessage", "editMessageText"])
            XCTAssertEqual(deletedIDs(), [7301])
            let edit = try parameters("editMessageText")
            assertSameIDEdit(edit)
            XCTAssertEqual(edit["text"] as? String, language == .fr ? "Aperçu indisponible." : "Preview unavailable.")
            XCTAssertTrue(try rows(edit).isEmpty)
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testFinalReceiptUsesPendingIDAndClockStartsAfterFinalEditWithFiveMinuteExpiry() async throws {
        for isFacebook in [true, false] {
            try reset()
            try await handle(isFacebook ? facebookURL : youtubeURL, now: nil)
            let sentAt = try XCTUnwrap(api.completedAt["sendMessage"])
            let readyAt = try XCTUnwrap(api.completedAt["editMessageMedia"])
            let receipt = try XCTUnwrap(store.state.replyControls["-100:7301"])
            XCTAssertGreaterThan(readyAt, sentAt)
            XCTAssertGreaterThanOrEqual(receipt.createdAt, readyAt)
            XCTAssertEqual(try StateStore(directory: directory).state.replyControls["-100:7301"], receipt)
            api.calls = []
            try await bot.expireReplyControls(now: receipt.createdAt + 299)
            XCTAssertTrue(api.calls.isEmpty)
            try await bot.expireReplyControls(now: receipt.createdAt + 300)
            XCTAssertEqual(api.methods, ["editMessageReplyMarkup"])
            let edit = try parameters("editMessageReplyMarkup")
            assertSameIDEdit(edit)
            XCTAssertEqual(try rows(edit), receipt.openButton.map { [[$0]] } ?? [])
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testRemovePendingPreviewUsesFinalReceiptAndExpiresAtFiveMinutes() async throws {
        for elapsed in [299, 300] {
            try reset()
            try await handle(youtubeURL)
            let markup = try XCTUnwrap(parameters("editMessageMedia")["reply_markup"])
            api.calls = []
            let callback = try decode(Update.self, from: ["update_id": 2, "callback_query": [
                "id": "pending-remove", "from": ["id": 7, "first_name": "Member 😀", "is_bot": false],
                "data": "fxclip:preview:delete", "message": ["message_id": 7301, "date": 1100,
                    "chat": ["id": -100, "type": "supergroup"],
                    "from": ["id": 99, "first_name": "fxclip", "is_bot": true], "reply_markup": markup],
            ]])
            try await bot.handle(callback, now: 1100 + elapsed)
            XCTAssertEqual(api.methods, elapsed == 299 ? ["deleteMessage", "answerCallbackQuery"] : ["answerCallbackQuery"])
            XCTAssertEqual(deletedIDs(), elapsed == 299 ? [7301] : [])
            if elapsed == 299 { XCTAssertTrue(store.state.replyControls.isEmpty) }
            else { XCTAssertEqual(api.calls.last?.1["show_alert"] as? Bool, true) }
        }
    }
}
