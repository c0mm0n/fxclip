import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import FxEngine
@testable import FxTelegram

private final class KoutubeURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class KoutubePreviewTests: XCTestCase {
    private let id = "aB3_dE-fG09"
    private var requestedHosts: [String] = []
    private var page: String {
        """
        <meta property="og:url" content="https://youtu.be/\(id)">
        <meta name="twitter:title" content="A title &amp; more">
        <meta property="og:image" content="https://images.example/thumbnail.jpg">
        <meta property="og:video" content="https://video.example/play?id=\(id)&amp;itag=18">
        """
    }

    private func fetch(page: String? = nil, status: Int = 200, type: String = "text/html",
                       length: Int? = nil, error: Error? = nil, nativePreview: Bool = true) async throws -> YouTubeMetadata {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KoutubeURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); KoutubeURLProtocol.handler = nil }
        let html = page ?? self.page
        requestedHosts = []
        KoutubeURLProtocol.handler = { request in
            self.requestedHosts.append(request.url!.host!)
            if request.url?.host == "www.youtube.com" {
                return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: [
                    "title": "A title", "thumbnail_url": "https://i.ytimg.com/vi/\(self.id)/hqdefault.jpg"
                ]))
            }
            XCTAssertTrue(nativePreview, "Photo choice must never contact the public mirror")
            XCTAssertEqual(request.url?.absoluteString, "https://koutu.be/\(self.id)")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 3)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "TelegramBot (like TwitterBot)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
            if let error { throw error }
            var headers = ["Content-Type": type]
            if let length { headers["Content-Length"] = String(length) }
            return (status, headers, Data(html.utf8))
        }
        // Exercise the production default, including its bounded mirror check.
        return try await YouTubeMetadataFetcher(session: session).fetch(videoID: id, nativePreview: nativePreview)
    }

    func testProductionDefaultChecksNativeCardWithoutFetchingMetadataMediaURLs() async throws {
        let metadata = try await fetch()
        XCTAssertTrue(metadata.nativePreviewAvailable)
        XCTAssertEqual(metadata.title, "A title & more")
        XCTAssertEqual(metadata.thumbnailURL.absoluteString, "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
        XCTAssertEqual(requestedHosts, ["koutu.be"], "A working mirror must not depend on YouTube oEmbed")
    }

    func testRealWorldRawAmpersandsInKoutubeMetadataDoNotForcePhotoFallback() async throws {
        let metadata = try await fetch(page: page.replacingOccurrences(of: "&amp;itag=18", with: "&itag=18&local=false"))
        XCTAssertTrue(metadata.nativePreviewAvailable)
    }

    func testPortraitVideoWithEmptyOrMissingThumbnailRemainsNative() async throws {
        for html in [page.replacingOccurrences(of: "https://images.example/thumbnail.jpg", with: ""),
                     page.replacingOccurrences(of: "<meta property=\"og:image\" content=\"https://images.example/thumbnail.jpg\">", with: "")] {
            let video = html + "<meta property='og:video:type' content='video/mp4'>"
                + "<meta property='og:video:width' content='360'><meta property='og:video:height' content='640'>"
            let metadata = try await fetch(page: video)
            XCTAssertTrue(metadata.nativePreviewAvailable)
            XCTAssertEqual(requestedHosts, ["koutu.be"])
        }
    }

    func testMissingThumbnailStillRejectsUntypedOrUnsafeVideo() async throws {
        let noImage = page.replacingOccurrences(of: "https://images.example/thumbnail.jpg", with: "")
        for html in [noImage, noImage + "<meta property='og:video:type' content='text/html'>",
                     (noImage + "<meta property='og:video:type' content='video/mp4'>")
                        .replacingOccurrences(of: "https://video.example", with: "http://video.example")] {
            let metadata = try await fetch(page: html)
            XCTAssertFalse(metadata.nativePreviewAvailable)
            XCTAssertEqual(requestedHosts, ["koutu.be", "www.youtube.com"])
        }
    }

    func testUnavailableWrongMIMEAndRedirectResponsesRetainPhotoFallback() async throws {
        for status in [301, 302, 403, 404, 429, 500, 503] {
            let metadata = try await fetch(status: status)
            XCTAssertFalse(metadata.nativePreviewAvailable, "\(status)")
        }
        for type in ["application/json", "video/mp4", "image/jpeg"] {
            let metadata = try await fetch(type: type)
            XCTAssertFalse(metadata.nativePreviewAvailable, type)
        }
    }

    func testHTMLCheckRejectsWrongVideoMissingDuplicateOrScriptMetadata() async throws {
        for html in ["<h1>Service unavailable</h1>", page.replacingOccurrences(of: id, with: "bB3_dE-fG09"),
                     page.replacingOccurrences(of: "og:image", with: "irrelevant"),
                     page + "<meta property='og:url' content='https://youtu.be/\(id)'>",
                     "<script>" + page + "</script>",
                     page.replacingOccurrences(of: "https://images.example", with: "http://images.example")] {
            let metadata = try await fetch(page: html)
            XCTAssertFalse(metadata.nativePreviewAvailable)
        }
    }

    func testDeclaredAndStreamingBodyBoundsFallBackToPhoto() async throws {
        let declared = try await fetch(length: 128 * 1024 + 1)
        XCTAssertFalse(declared.nativePreviewAvailable)
        let streamed = try await fetch(page: page + String(repeating: "x", count: 128 * 1024))
        XCTAssertFalse(streamed.nativePreviewAvailable)
    }

    func testTimeoutFallsBackButCancellationPropagates() async throws {
        let metadata = try await fetch(error: URLError(.timedOut))
        XCTAssertFalse(metadata.nativePreviewAvailable)
        do { _ = try await fetch(error: URLError(.cancelled)); XCTFail("Expected cancellation") }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
    }

    func testPhotoChoiceNeverContactsKoutube() async throws {
        let metadata = try await fetch(nativePreview: false)
        XCTAssertFalse(metadata.nativePreviewAvailable)
        XCTAssertEqual(requestedHosts, ["www.youtube.com"])
    }

    func testMirrorURLForwardsOnlyBoundedUniqueTimecodes() {
        let source = "https://youtube.com/watch?v=\(id)&si=secret&utm_source=share&t=1h2m3s&start=42&end=99&list=private#chapter"
        XCTAssertEqual(YouTubePreview.koutubeURL(for: source), "https://koutu.be/\(id)?t=1h2m3s&start=42&end=99")
        XCTAssertEqual(YouTubePreview.koutubeURL(for: "https://youtu.be/\(id)?t=4&t=5&start=bad&end=\(String(repeating: "1", count: 25))"), "https://koutu.be/\(id)")
        for source in ["https://youtube.com.evil/watch?v=\(id)", "https://user@youtu.be/\(id)", "https://youtu.be/wrong"] {
            XCTAssertNil(YouTubePreview.koutubeURL(for: source))
        }
    }

    func testEnableAndResumePagesDisclosePublicCacheInBothLanguages() throws {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/rules.json")
        let rules = try Rules.load(Data(contentsOf: shared))
        for language in [BotLanguage.en, .fr] {
            for scope in ["p", "d", "c:-100"] {
                let page = SettingsUI.rules(UserSettings(), builtins: rules, scope: scope, section: "youtube",
                    inherited: true, language: language).text.lowercased()
                XCTAssertTrue(page.contains("koutube")); XCTAssertTrue(page.contains("public"))
                XCTAssertTrue(page.contains("cache")); XCTAssertLessThanOrEqual(page.utf16.count, 4096)
            }
            let paused = SettingsUI.rules(UserSettings(), builtins: rules, scope: "c:-100", section: "previews",
                inherited: true, previewsEnabled: false, language: language).text.lowercased()
            XCTAssertTrue(paused.contains("koutube")); XCTAssertTrue(paused.contains("cache"))
            let chat = Chat(id: -100, type: "supergroup", title: "Test group")
            let activation = SettingsUI.chat(chat, settings: ChatSettings(), enabled: false, inherited: true,
                username: "examplebot", language: language).text.lowercased()
            XCTAssertTrue(activation.contains("koutube")); XCTAssertTrue(activation.contains("cache"))
        }
    }
}

private final class NativeYouTubeProvider: YouTubeMetadataProviding {
    var requests = 0
    var delay: UInt64 = 0
    var available = true
    var nativeChoices: [Bool] = []
    func fetch(videoID: String, nativePreview: Bool) async throws -> YouTubeMetadata {
        nativeChoices.append(nativePreview)
        return try await fetch(videoID: videoID)
    }
    func fetch(videoID: String) async throws -> YouTubeMetadata {
        requests += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return YouTubeMetadata(title: "A title", thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg")!,
            fallbackThumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!, nativePreviewAvailable: available)
    }
}

private final class NativeCardAPI: BotAPI {
    var calls: [(String, [String: Any])] = []
    var outcomes: [String: [Result<Any, Error>]] = [:]
    var before: ((String, [String: Any]) -> Void)?
    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters)); before?(method, parameters)
        if let next = outcomes[method]?.first { outcomes[method]!.removeFirst(); return try next.get() }
        switch method {
        case "sendMessage", "sendPhoto": return ["message_id": Int64(42)]
        case "editMessageText", "editMessageMedia": return ["message_id": parameters["message_id"]!]
        case "getChatMember": return ["status": "administrator", "can_delete_messages": true]
        default: return true
        }
    }
}

extension BotTests {
    private func nativeBot(_ transport: NativeCardAPI, provider: NativeYouTubeProvider) {
        bot = Bot(api: transport, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7], botID: 99,
            username: "examplebot", youTubeMetadata: provider, pendingPreviewDelayNanoseconds: 0)
    }

    func testKoutubeCardUsesCleanVisibleYouTubeURLAndFixedNativePreview() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
        try await handle(["text": "https://youtu.be/aB3_dE-fG09?si=tracking&t=42"])
        XCTAssertEqual(transport.calls.map(\.0), ["sendMessage"])
        let card = try XCTUnwrap(transport.calls.first?.1)
        XCTAssertEqual(card["text"] as? String, "https://youtu.be/aB3_dE-fG09?t=42")
        let options = try XCTUnwrap(card["link_preview_options"] as? [String: Any])
        XCTAssertEqual(options["url"] as? String, "https://koutu.be/aB3_dE-fG09?t=42")
        XCTAssertEqual(options["prefer_large_media"] as? Bool, true)
        XCTAssertEqual(card["protect_content"] as? Bool, true)
        XCTAssertEqual(store.state.publications["-100:42"]?.posterID, 7)
        XCTAssertEqual(store.state.replyControls["-100:42"]?.openButton?.url, "https://youtu.be/aB3_dE-fG09?t=42")
    }

    func testCleanShortsLinkGetsNativeReplyWithoutDeletingOrLookingUpRights() async throws {
        try replaceMode()
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
        let source = "https://www.youtube.com/shorts/aB3_dE-fG09"
        try await handle(["text": source])
        XCTAssertEqual(transport.calls.map(\.0), ["sendMessage"])
        let card = try XCTUnwrap(transport.calls.first?.1)
        XCTAssertEqual(card["text"] as? String, source)
        XCTAssertEqual((card["link_preview_options"] as? [String: Any])?["url"] as? String, "https://koutu.be/aB3_dE-fG09")
        XCTAssertEqual(card["protect_content"] as? Bool, true)
    }

    func testNativeReplacementPersistsOwnershipBeforeDeletingAndKeepsCredit() async throws {
        try replaceMode()
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
        transport.before = { method, _ in
            if method == "deleteMessage" {
                XCTAssertEqual(self.store.state.publications["-100:42"]?.posterID, 7)
                XCTAssertEqual(try? StateStore(directory: self.directory).state.publications["-100:42"]?.posterID, 7)
            }
        }
        try await handle(["text": "https://youtu.be/aB3_dE-fG09?si=tracking"])
        XCTAssertEqual(transport.calls.map(\.0), ["getChatMember", "sendMessage", "deleteMessage"])
        let text = try XCTUnwrap(transport.calls.first { $0.0 == "sendMessage" }?.1["text"] as? String)
        XCTAssertTrue(text.contains("Alice")); XCTAssertTrue(text.contains("https://youtu.be/aB3_dE-fG09"))
    }

    func testCleanNativeYouTubeInReplaceModeKeepsOriginalWithoutRightsLookup() async throws {
        try replaceMode()
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
        try await handle(["text": "https://youtu.be/aB3_dE-fG09"])
        XCTAssertEqual(transport.calls.map(\.0), ["sendMessage"])
    }

    func testExplicitNativeRejectionUsesCompactPhotoFallbackOnce() async throws {
        for code in [400, 403] {
            let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
            transport.outcomes["sendMessage"] = [.failure(BotError.telegram(code))]
            try await handle(["text": "https://youtu.be/aB3_dE-fG09"])
            XCTAssertEqual(transport.calls.map(\.0), ["sendMessage", "sendPhoto"])
            let photo = try XCTUnwrap(transport.calls.last?.1)
            XCTAssertEqual(photo["caption"] as? String, "YouTube\nA title")
            XCTAssertEqual(photo["show_caption_above_media"] as? Bool, true)
            XCTAssertEqual(photo["protect_content"] as? Bool, true)
        }
    }

    func testNativeAmbiguityNeverSendsFallbackOrDeletesOriginal() async throws {
        try replaceMode()
        for outcome: Result<Any, Error> in [.failure(URLError(.timedOut)), .success(["message_id": true]), .success(["message_id": 0])] {
            let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
            transport.outcomes["sendMessage"] = [outcome]
            do { try await handle(["text": "https://youtu.be/aB3_dE-fG09?si=tracking"]); XCTFail("Expected ambiguity") } catch {}
            XCTAssertEqual(transport.calls.map(\.0), ["getChatMember", "sendMessage"])
            XCTAssertTrue(store.state.publications.isEmpty)
        }
    }

    func testSlowNativeCardEditsSamePlaceholderAndRecordsCompletionClock() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); provider.delay = 25_000_000
        nativeBot(transport, provider: provider)
        try await handle(["text": "https://youtu.be/aB3_dE-fG09"])
        XCTAssertEqual(transport.calls.map(\.0), ["sendMessage", "editMessageText"])
        XCTAssertEqual(transport.calls.last?.1["message_id"] as? Int64, 42)
        XCTAssertEqual(store.state.replyControls["-100:42"]?.createdAt, 1100)
        XCTAssertNil(transport.calls.last?.1["protect_content"])
    }

    func testRejectedPendingNativeEditUsesPhotoInSameMessage() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); provider.delay = 25_000_000
        nativeBot(transport, provider: provider)
        transport.outcomes["editMessageText"] = [.failure(BotError.telegram(400))]
        try await handle(["text": "https://youtu.be/aB3_dE-fG09"])
        XCTAssertEqual(transport.calls.map(\.0), ["sendMessage", "editMessageText", "editMessageMedia"])
        XCTAssertEqual(transport.calls.last?.1["message_id"] as? Int64, 42)
        XCTAssertEqual((transport.calls.last?.1["media"] as? [String: Any])?["show_caption_above_media"] as? Bool, true)
    }

    func testNativeEditWrongReceiptNeverSendsPhotoOrDeletesOriginal() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); provider.delay = 25_000_000
        nativeBot(transport, provider: provider)
        transport.outcomes["editMessageText"] = [.success(["message_id": 999])]
        do { try await handle(["text": "https://youtu.be/aB3_dE-fG09"]); XCTFail("Expected wrong receipt rejection") } catch {}
        XCTAssertEqual(transport.calls.map(\.0), ["sendMessage", "editMessageText"])
        XCTAssertTrue(store.state.publications.isEmpty)
    }

    func testUnavailableMirrorUsesPhotoAndDisabledCardsNeverFetchProvider() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); provider.available = false
        nativeBot(transport, provider: provider)
        try await handle(["text": "https://youtu.be/aB3_dE-fG09"])
        XCTAssertEqual(transport.calls.map(\.0), ["sendPhoto"])
        try store.setPersonalLinks(nil, youTubeCards: false, userID: 7)
        transport.calls = []; provider.requests = 0
        try await handle(["text": "https://youtu.be/aB3_dE-fG09"])
        XCTAssertEqual(provider.requests, 0); XCTAssertTrue(transport.calls.isEmpty)
    }

    func testDirectNativeReplyRemainsShareableAndNeverDeletesSource() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
        try await handle(["text": "https://youtu.be/aB3_dE-fG09", "chat": ["id": 7, "type": "private"]])
        XCTAssertEqual(transport.calls.map(\.0), ["sendMessage"])
        XCTAssertNil(transport.calls.first?.1["protect_content"])
        XCTAssertTrue(store.state.publications.isEmpty)
    }

    func testManualReplacePreservesNativePreviewAndCleanOpeningLink() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
        let url = "https://youtu.be/aB3_dE-fG09?t=42"
        try await handle(["text": url])
        var reply = try XCTUnwrap(transport.calls.first?.1)
        let source: [String: Any] = ["message_id": 5, "date": 1000, "chat": ["id": -100, "type": "supergroup"],
            "from": ["id": 7, "is_bot": false, "first_name": "Alice"], "text": url]
        reply["message_id"] = 42; reply["date"] = 1100
        reply["chat"] = ["id": -100, "type": "supergroup"]
        reply["from"] = ["id": 99, "is_bot": true, "first_name": "fxclip"]
        reply["reply_to_message"] = source
        for data in ["fxclip:preview:replace", "fxclip:preview:replace:confirm"] {
            try await bot.handle(decode(Update.self, from: ["update_id": 2, "callback_query": ["id": "click", "data": data,
                "from": ["id": 7, "is_bot": false, "first_name": "Alice"], "message": reply]]), now: 1101)
            if let markup = transport.calls.last(where: { $0.0 == "editMessageReplyMarkup" })?.1["reply_markup"] {
                reply["reply_markup"] = markup
            }
        }
        let edit = try XCTUnwrap(transport.calls.last { $0.0 == "editMessageText" }?.1)
        XCTAssertTrue((edit["text"] as? String)?.contains("Alice") == true)
        let options = try XCTUnwrap(edit["link_preview_options"] as? [String: Any])
        XCTAssertEqual(options["url"] as? String, "https://koutu.be/aB3_dE-fG09?t=42")
        XCTAssertEqual(options["prefer_large_media"] as? Bool, true)
        XCTAssertEqual(transport.calls.last { $0.0 == "deleteMessage" }?.1["message_id"] as? Int64, 5)
        XCTAssertNil(store.state.publications["-100:42"]?.original)
    }

    func testNativeExpiryAfterRestartKeepsOnlyTheRedYouTubeOpenButton() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
        try await handle(["text": "https://youtu.be/aB3_dE-fG09"])
        store = try StateStore(directory: directory); nativeBot(transport, provider: provider)
        transport.calls = []
        try await bot.expireReplyControls(now: 1400)
        XCTAssertEqual(transport.calls.map(\.0), ["editMessageReplyMarkup"])
        let markup = try XCTUnwrap(transport.calls.first?.1["reply_markup"] as? [String: Any])
        let rows = try XCTUnwrap(markup["inline_keyboard"] as? [[[String: String]]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][0]["url"], "https://youtu.be/aB3_dE-fG09")
        XCTAssertEqual(rows[0][0]["style"], "danger")
        XCTAssertNil(rows[0][0]["callback_data"])
        XCTAssertNil(store.state.publications["-100:42"]?.original)
        XCTAssertEqual(store.state.publications["-100:42"]?.posterID, 7)
        XCTAssertEqual(provider.requests, 1)
    }

    func testStyleChoiceResolvesPersonalThenGroupThenDefaultWithoutChangingOnOff() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
        try await callback("fxclip:rules:d:youtube:style:photo", userID: 7, chatID: 7)
        XCTAssertEqual(store.state.defaultYouTubeStyle, .photo)
        XCTAssertTrue(store.state.defaultYouTubeCards)
        var group = ChatSettings(); group.youTubeStyle = .koutube
        try store.set(group, chatID: -100)
        transport.calls = []
        try await handle(["text": "https://youtu.be/aB3_dE-fG09"])
        XCTAssertEqual(transport.calls.map(\.0), ["sendMessage"])
        XCTAssertEqual(provider.nativeChoices.last, true)

        try await callback("fxclip:rules:p:youtube:style:photo", userID: 7, chatID: 7)
        transport.calls = []
        try await handle(["text": "https://youtu.be/aB3_dE-fG09"])
        XCTAssertEqual(transport.calls.map(\.0), ["sendPhoto"])
        XCTAssertEqual(provider.nativeChoices.last, false)
        XCTAssertNil(store.state.personalYouTubeCards["7"])
        try await callback("fxclip:rules:p:youtube:style:default", userID: 7, chatID: 7)
        XCTAssertNil(store.state.personalYouTubeStyle["7"])
        XCTAssertEqual(store.state.chats["-100"]?.youTubeStyle, .koutube)
        XCTAssertEqual(try StateStore(directory: directory).state.defaultYouTubeStyle, .photo)
    }

    func testDirectPhotoChoiceUsesBotDefaultsRatherThanUnrelatedGroupStyle() async throws {
        let transport = NativeCardAPI(), provider = NativeYouTubeProvider(); nativeBot(transport, provider: provider)
        try store.setDefaultYouTubeStyle(.photo)
        var group = ChatSettings(); group.youTubeStyle = .koutube
        try store.set(group, chatID: -100)
        try await handle(["text": "https://youtu.be/aB3_dE-fG09", "chat": ["id": 7, "type": "private"]])
        XCTAssertEqual(transport.calls.map(\.0), ["sendPhoto"])
        XCTAssertEqual(provider.nativeChoices, [false])
    }

    func testStyleCallbacksRetainScopeAndExactKeyboardAuthorization() async throws {
        try await callback("fxclip:rules:d:youtube:style:photo", userID: 8, chatID: 8)
        XCTAssertEqual(store.state.defaultYouTubeStyle, .koutube)
        try await callback("fxclip:rules:c:-100:youtube:style:photo", userID: 8, chatID: -200, chatType: "supergroup")
        XCTAssertNil(store.state.chats["-100"]?.youTubeStyle)
        api.admin = false
        try await callback("fxclip:rules:c:-100:youtube:style:photo", userID: 8, chatID: -100, chatType: "supergroup")
        XCTAssertNil(store.state.chats["-100"]?.youTubeStyle)
        try await callback("fxclip:rules:p:youtube:style:photo", userID: 8, chatID: 8,
            messageMarkup: ["inline_keyboard": [[["text": "Other", "callback_data": "fxclip:rules:p:youtube:show"]]]])
        XCTAssertNil(store.state.personalYouTubeStyle["8"])
    }

    func testLegacyStyleDefaultsAndIndependentSettersAndResets() async throws {
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.state)) as? [String: Any])
        json.removeValue(forKey: "defaultYouTubeStyle"); json.removeValue(forKey: "personalYouTubeStyle")
        let legacy = try JSONDecoder().decode(BotState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.defaultYouTubeStyle, .koutube)
        XCTAssertTrue(legacy.personalYouTubeStyle.isEmpty)
        XCTAssertNil(try JSONDecoder().decode(ChatSettings.self, from: Data("{}".utf8)).youTubeStyle)
        try store.setDefaultYouTubeStyle(.photo)
        try store.setPersonalYouTubeStyle(.photo, userID: 8)
        try store.setPersonalLinks(nil, youTubeCards: false, userID: 8)
        try store.setDefaultLinks(UserSettings(), youTubeCards: false)
        XCTAssertEqual(store.state.defaultYouTubeStyle, .photo)
        XCTAssertEqual(store.state.personalYouTubeStyle["8"], .photo)
        try await callback("fxclip:rules:p:reset", userID: 8, chatID: 8)
        XCTAssertNil(store.state.personalYouTubeStyle["8"])
        try await callback("fxclip:rules:d:reset", userID: 7, chatID: 7)
        XCTAssertEqual(store.state.defaultYouTubeStyle, .koutube)
        XCTAssertTrue(store.state.defaultYouTubeCards)
    }
}
