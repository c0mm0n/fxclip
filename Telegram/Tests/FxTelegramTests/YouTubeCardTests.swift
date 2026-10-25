import Foundation
import XCTest
@testable import FxTelegram

private final class AlternateYouTubeMetadata: YouTubeMetadataProviding {
    func fetch(videoID: String) async throws -> YouTubeMetadata {
        YouTubeMetadata(title: "Example video", thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg")!,
            fallbackThumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!)
    }
}

private final class ThumbnailFallbackAPI: BotAPI {
    var calls: [(String, [String: Any])] = []
    var photoResults: [Result<Any, Error>] = []
    var textError: Error?
    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters))
        switch method {
        case "sendPhoto": return try photoResults.removeFirst().get()
        case "sendMessage":
            if let textError { throw textError }
            return ["message_id": Int64(43)]
        case "getChatMember": return ["status": "administrator", "can_delete_messages": true]
        default: return true
        }
    }
}

final class YouTubeCardTests: XCTestCase {
    let url = "https://youtu.be/aB3_dE-fG09?t=42"

    func testLegacyOpeningButtonsDecodeWithoutAStyle() throws {
        let old = try JSONDecoder().decode(InlineKeyboardButton.self,
            from: Data(#"{"text":"Open","url":"https://example.com/watch"}"#.utf8))
        XCTAssertNil(old.style)
        XCTAssertEqual(old.url, "https://example.com/watch")
    }

    func testCompactCaptionKeepsTimestampInLinkedHeadingWithoutPrintingRawURL() throws {
        let title = "😀 A video title"
        let card = try XCTUnwrap(YouTubePreview.caption(title: title, url: url, credit: nil))
        XCTAssertEqual(card.text, "YouTube\n" + title)
        XCTAssertEqual(card.previewURL, url)
        XCTAssertEqual(card.entities.first?.url, url)
        XCTAssertEqual(card.entities.first?.offset, 0)
        XCTAssertEqual(card.entities.last?.offset, "YouTube\n".utf16.count)
        XCTAssertEqual(card.entities.last?.length, title.utf16.count)
    }

    func testAutomaticCreditPreservesMentionAndDropsOnlyTheKnownSourceSuffix() throws {
        let name = "Alice 😀"
        let prefix = "Publié par \(name)\n\n"
        let mention = Entity(type: "text_mention", offset: "Publié par ".utf16.count,
            length: name.utf16.count, user: TelegramUser(id: 7, first_name: name))
        let link = Entity(type: "url", offset: prefix.utf16.count, length: url.utf16.count)
        let credit = RenderedMessage(text: prefix + url, entities: [mention, link], previewURL: url)
        let card = try XCTUnwrap(YouTubePreview.caption(title: "🎬 Title", url: url, credit: credit))
        XCTAssertEqual(card.text, prefix + "YouTube\n🎬 Title")
        XCTAssertEqual(card.entities.first, mention)
        XCTAssertEqual(card.entities.first { $0.type == "text_link" }?.offset, prefix.utf16.count)
        XCTAssertEqual(card.entities.first { $0.type == "text_link" }?.url, url)
        XCTAssertFalse(card.entities.contains { $0.type == "url" })
    }

    func testUnmatchedSourceAndOversizedCaptionFallBackWithoutDroppingContent() throws {
        let malformed = RenderedMessage(text: "Posted by Someone\n\nhttps://example.com/extra content",
            entities: [], previewURL: url)
        XCTAssertNil(YouTubePreview.caption(title: "Title", url: url, credit: malformed))
        XCTAssertNil(YouTubePreview.caption(title: "", url: url, credit: nil))
        XCTAssertNil(YouTubePreview.caption(title: String(repeating: "😀", count: 257), url: url, credit: nil))
        let title = String(repeating: "😀", count: 256)
        let prefix = String(repeating: "x", count: 502) + "\n\n"
        let exact = RenderedMessage(text: prefix + url, entities: [], previewURL: url)
        XCTAssertEqual(YouTubePreview.caption(title: title, url: url, credit: exact)?.text.utf16.count, 1024)
        let overflow = RenderedMessage(text: "x" + prefix + url, entities: [], previewURL: url)
        XCTAssertNil(YouTubePreview.caption(title: title, url: url, credit: overflow))
    }
}

extension BotTests {
    func testRejectedHDImageRetriesOriginalOnceBeforeRecordingOrDeleting() async throws {
        try replaceMode()
        let transport = ThumbnailFallbackAPI()
        transport.photoResults = [.failure(BotError.telegram(400)), .success(["message_id": Int64(42)])]
        bot = Bot(api: transport, store: store, engine: engine, allowedChats: [-100], botID: 99,
                  username: "fxclipbot", youTubeMetadata: AlternateYouTubeMetadata())
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?is=tracking&t=42"])
        XCTAssertEqual(transport.calls.map(\.0), ["getChatMember", "sendPhoto", "sendPhoto", "deleteMessage"])
        let photos = transport.calls.filter { $0.0 == "sendPhoto" }.map(\.1)
        XCTAssertTrue((photos[0]["photo"] as? String)?.hasSuffix("maxresdefault.jpg") == true)
        XCTAssertTrue((photos[1]["photo"] as? String)?.hasSuffix("hqdefault.jpg") == true)
        XCTAssertTrue(photos.allSatisfy { $0["protect_content"] as? Bool == true && $0["show_caption_above_media"] as? Bool == true })
        XCTAssertEqual(store.state.publications["-100:42"]?.posterID, 7)
    }

    func testAmbiguousHDImageNeverRetriesOrDeletesOriginal() async throws {
        try replaceMode()
        for result: Result<Any, Error> in [.failure(URLError(.timedOut)), .success(["message_id": true])] {
            let transport = ThumbnailFallbackAPI(); transport.photoResults = [result]
            bot = Bot(api: transport, store: store, engine: engine, allowedChats: [-100], botID: 99,
                      username: "fxclipbot", youTubeMetadata: AlternateYouTubeMetadata())
            do { try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?is=tracking"]); XCTFail("Expected ambiguity") }
            catch { }
            XCTAssertEqual(transport.calls.map(\.0), ["getChatMember", "sendPhoto"])
            XCTAssertTrue(store.state.publications.isEmpty)
        }
    }

    func testRejectedFallbackAndAmbiguousTextNeverDeleteOriginal() async throws {
        try replaceMode()
        let transport = ThumbnailFallbackAPI()
        transport.photoResults = [.failure(BotError.telegram(400)), .failure(BotError.telegram(400))]
        transport.textError = URLError(.timedOut)
        bot = Bot(api: transport, store: store, engine: engine, allowedChats: [-100], botID: 99,
                  username: "fxclipbot", youTubeMetadata: AlternateYouTubeMetadata())
        do { try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?is=tracking"]); XCTFail("Expected ambiguity") }
        catch { }
        XCTAssertEqual(transport.calls.map(\.0), ["getChatMember", "sendPhoto", "sendPhoto", "sendMessage"])
        XCTAssertTrue(store.state.publications.isEmpty)
    }

    func testForbiddenPhotoSkipsImageRetryAndUsesConfirmedTextFallback() async throws {
        try replaceMode()
        let transport = ThumbnailFallbackAPI(); transport.photoResults = [.failure(BotError.telegram(403))]
        bot = Bot(api: transport, store: store, engine: engine, allowedChats: [-100], botID: 99,
                  username: "fxclipbot", youTubeMetadata: AlternateYouTubeMetadata())
        try await handle(["text": "https://youtu.be/dQw4w9WgXcQ?is=tracking"])
        XCTAssertEqual(transport.calls.map(\.0), ["getChatMember", "sendPhoto", "sendMessage", "deleteMessage"])
        XCTAssertEqual(store.state.publications["-100:43"]?.posterID, 7)
    }

    func testYouTubeLinkedHeadingSurvivesCleanupWithoutAnOpenButtonOrStoredURL() async throws {
        _ = enableYouTubeCards()
        let url = "https://youtu.be/dQw4w9WgXcQ?t=42"
        try await handle(["text": url])
        let photo = try XCTUnwrap(api.calls.first { $0.0 == "sendPhoto" }?.1)
        XCTAssertEqual(photo["show_caption_above_media"] as? Bool, true)
        XCTAssertEqual(photo["protect_content"] as? Bool, true)
        let restarted = try StateStore(directory: directory)
        XCTAssertNil(restarted.state.replyControls["-100:42"]?.openButton)
        let entities = try decode([Entity].self, from: XCTUnwrap(photo["caption_entities"]))
        XCTAssertEqual(entities.first { $0.type == "text_link" }?.url, url)
        let persisted = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains(url))
        bot = Bot(api: api, store: restarted, engine: engine, allowedChats: [-100], botID: 99, username: "fxclipbot")
        api.calls = []
        try await bot.expireReplyControls(now: 1400)
        let edit = try XCTUnwrap(api.calls.first { $0.0 == "editMessageReplyMarkup" }?.1)
        let buttons = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(edit["reply_markup"])).inline_keyboard.flatMap { $0 }
        XCTAssertTrue(buttons.isEmpty)
        XCTAssertNil(edit["protect_content"])
    }

    func testLegacyYouTubeOpenButtonStillSurvivesRestartAndCleanup() async throws {
        let url = "https://youtu.be/aB3_dE-fG09?t=42"
        try store.recordReplyControl(chatID: -100, messageID: 42, posterID: 7, now: 1100,
            openButton: InlineKeyboardButton(text: "▶ Open YouTube", url: url, style: "danger"))
        let restarted = try StateStore(directory: directory)
        bot = Bot(api: api, store: restarted, engine: engine, allowedChats: [-100], botID: 99, username: "fxclipbot")
        try await bot.expireReplyControls(now: 1400)
        let edit = try XCTUnwrap(api.calls.first { $0.0 == "editMessageReplyMarkup" }?.1)
        let buttons = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(edit["reply_markup"])).inline_keyboard.flatMap { $0 }
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons.first?.url, url)
        XCTAssertEqual(buttons.first?.style, "danger")
    }
}
