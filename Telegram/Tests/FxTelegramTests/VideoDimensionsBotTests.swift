import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import FxEngine
@testable import FxTelegram

private final class DimensionsRedditProvider: RedditVideoProviding {
    var video = Data()
    var delay: UInt64 = 0
    var requestedIDs: [String] = []

    func fetch(postID: String) async throws -> Data {
        requestedIDs.append(postID)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return video
    }
}

private final class DimensionsFacebookProvider: FacebookReelProviding {
    var video = Data()
    var delay: UInt64 = 0

    func fetch(reelID: String) async throws -> FacebookReel {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return FacebookReel(author: "Fixture creator", caption: "Fixture caption", video: video)
    }
}

private final class DimensionsYouTubeProvider: YouTubeMetadataProviding {
    var delay: UInt64 = 0

    func fetch(videoID: String) async throws -> YouTubeMetadata {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return YouTubeMetadata(title: "Fixture video", thumbnailURL: URL(string: "https://example.invalid/thumbnail.jpg")!)
    }
}

private final class DimensionsBotAPI: BotAPI {
    var calls: [(String, [String: Any])] = []
    var beforeCall: ((String, [String: Any]) -> Void)?
    var outcomes: [String: Result<Any, Error>] = [:]
    let sentID: Int64 = 8_123_456_789
    var methods: [String] { calls.map(\.0) }

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters))
        beforeCall?(method, parameters)
        if let outcome = outcomes[method] { return try outcome.get() }
        switch method {
        case "getChatMember": return ["status": "administrator", "can_delete_messages": true]
        case "sendMessage", "sendVideo", "sendPhoto": return ["message_id": sentID]
        case "editMessageMedia": return ["message_id": parameters["message_id"] ?? NSNull()]
        default: return true
        }
    }
}

final class VideoDimensionsBotTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!
    private var engine: Engine!
    private var api: DimensionsBotAPI!
    private var reddit: DimensionsRedditProvider!
    private var facebook: DimensionsFacebookProvider!
    private var youtube: DimensionsYouTubeProvider!
    private var bot: Bot!
    private let source = "https://www.reddit.com/r/example/comments/abc123/example/"

    override func setUpWithError() throws {
        let shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared/rules.json")
        engine = Engine(rules: try Rules.load(Data(contentsOf: shared)))
        try reset()
    }

    override func tearDownWithError() throws {
        api.beforeCall = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func reset(slow: Bool = false, replace: Bool = false) throws {
        api?.beforeCall = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("fxclip-video-dimensions-" + UUID().uuidString)
        store = try StateStore(directory: directory)
        try store.setDefaultRedditVideos(true)
        try store.setDefaultFacebookReels(true)
        try store.setGroupLanguage(.en, chatID: -100)
        var settings = ChatSettings()
        settings.mode = replace ? .replace : .reply
        try store.set(settings, chatID: -100)
        api = DimensionsBotAPI()
        reddit = DimensionsRedditProvider()
        facebook = DimensionsFacebookProvider()
        youtube = DimensionsYouTubeProvider()
        reddit.delay = slow ? 25_000_000 : 0
        facebook.delay = reddit.delay
        youtube.delay = reddit.delay
        bot = Bot(api: api, store: store, engine: engine, allowedChats: [-100], allowedOwners: [7],
                  botID: 99, username: "fxclipbot", youTubeMetadata: youtube, facebookReels: facebook,
                  pendingPreviewDelayNanoseconds: slow ? 0 : 5_000_000_000, redditVideos: reddit)
    }

    private func handle(_ text: String? = nil) async throws {
        let update = try decode(Update.self, from: ["update_id": 1, "message": [
            "message_id": 5, "date": 1000, "message_thread_id": 123,
            "chat": ["id": -100, "type": "supergroup"],
            "from": ["id": 7, "first_name": "Member 😀", "is_bot": false],
            "text": text ?? source, "reply_to_message": ["message_id": 3],
        ]])
        try await bot.handle(update, now: 1100)
    }

    private func parameters(_ method: String) throws -> [String: Any] {
        try XCTUnwrap(api.calls.first { $0.0 == method }?.1)
    }

    private func videoParameters(slow: Bool) throws -> [String: Any] {
        if slow { return try XCTUnwrap(parameters("editMessageMedia")["media"] as? [String: Any]) }
        return try parameters("sendVideo")
    }

    private func assertDimensions(_ fields: [String: Any], width: Int?, height: Int?,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fields["width"] as? Int, width, file: file, line: line)
        XCTAssertEqual(fields["height"] as? Int, height, file: file, line: line)
        if width == nil { XCTAssertNil(fields["width"], file: file, line: line) }
        if height == nil { XCTAssertNil(fields["height"], file: file, line: line) }
    }

    private func assertBareReply(slow: Bool, data: Data, file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        XCTAssertEqual(api.methods, slow ? ["sendMessage", "editMessageMedia"] : ["sendVideo"], file: file, line: line)
        let envelope = try parameters(slow ? "editMessageMedia" : "sendVideo")
        let video = try videoParameters(slow: slow)
        XCTAssertEqual((video[slow ? "media" : "video"] as? VideoUpload)?.data, data, file: file, line: line)
        XCTAssertEqual(video["supports_streaming"] as? Bool, true, file: file, line: line)
        XCTAssertNil(video["caption"], file: file, line: line)
        XCTAssertNil(video["caption_entities"], file: file, line: line)
        let markup = try decode(InlineKeyboardMarkup.self, from: XCTUnwrap(envelope["reply_markup"]))
        XCTAssertEqual(markup.inline_keyboard.flatMap { $0 }.map(\.callback_data), ["fxclip:preview:delete"], file: file, line: line)
        XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:\(api.sentID)"], file: file, line: line)
        XCTAssertEqual(store.state.replyControls["-100:\(api.sentID)"]?.posterID, 7, file: file, line: line)
        if slow {
            XCTAssertEqual(envelope["message_id"] as? Int64, api.sentID, file: file, line: line)
            XCTAssertEqual(video["type"] as? String, "video", file: file, line: line)
            assertDimensions(envelope, width: nil, height: nil, file: file, line: line)
            XCTAssertNil(envelope["reply_parameters"], file: file, line: line)
            XCTAssertNil(envelope["message_thread_id"], file: file, line: line)
        }
        let sent = try parameters(slow ? "sendMessage" : "sendVideo")
        XCTAssertEqual((sent["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 5, file: file, line: line)
        XCTAssertEqual(sent["message_thread_id"] as? Int64, 123, file: file, line: line)
    }

    func testFastRedditVideoSendsLandscapeDimensionsAndKeepsBareReplyReceipt() async throws {
        reddit.video = Self.mp4(width: 1920, height: 1080)
        try await handle()
        assertDimensions(try videoParameters(slow: false), width: 1920, height: 1080)
        XCTAssertEqual(reddit.requestedIDs, ["abc123"])
        try assertBareReply(slow: false, data: reddit.video)
    }

    func testSlowRedditVideoEditsPendingWithNestedLandscapeDimensions() async throws {
        try reset(slow: true)
        reddit.video = Self.mp4(width: 1920, height: 1080)
        api.beforeCall = { [unowned self] method, _ in
            if method == "editMessageMedia" { XCTAssertTrue(self.store.state.replyControls.isEmpty) }
        }
        try await handle()
        assertDimensions(try videoParameters(slow: true), width: 1920, height: 1080)
        try assertBareReply(slow: true, data: reddit.video)
    }

    func testPortraitAndQuarterTurnGeometryReachBothRedditDeliveryPaths() async throws {
        for slow in [false, true] {
            for rotated in [false, true] {
                try reset(slow: slow)
                reddit.video = Self.mp4(width: rotated ? 1920 : 1080, height: rotated ? 1080 : 1920,
                                        rotated: rotated)
                try await handle()
                assertDimensions(try videoParameters(slow: slow), width: 1080, height: 1920)
                try assertBareReply(slow: slow, data: reddit.video)
            }
        }
    }

    func testUnusableGeometryOmitsDimensionsWithoutRejectingOriginalBytes() async throws {
        let fixtures = [Self.ftyp, Self.ftyp + Self.box("moov", Data([0, 0, 0, 40]) + Data("trak".utf8)),
                        Self.mp4(width: 1920, height: 1080, handler: "soun"), Self.mp4(width: 0, height: 1080)]
        for slow in [false, true] {
            for data in fixtures {
                try reset(slow: slow)
                reddit.video = data
                try await handle()
                assertDimensions(try videoParameters(slow: slow), width: nil, height: nil)
                try assertBareReply(slow: slow, data: data)
            }
        }
    }

    func testReplacementPreservesCreditAndWaitsForConfirmedSendBeforeDeleting() async throws {
        for usable in [true, false] {
            try reset(replace: true)
            reddit.video = usable ? Self.mp4(width: 1920, height: 1080) : Self.ftyp
            api.beforeCall = { [unowned self] method, _ in
                if method == "sendVideo" {
                    XCTAssertFalse(self.api.methods.contains("deleteMessage"))
                    XCTAssertTrue(self.store.state.replyControls.isEmpty)
                }
            }
            try await handle(source + "?utm_source=fixture")
            XCTAssertEqual(api.methods, ["getChatMember", "sendVideo", "deleteMessage"])
            let video = try parameters("sendVideo")
            assertDimensions(video, width: usable ? 1920 : nil, height: usable ? 1080 : nil)
            XCTAssertEqual((video["video"] as? VideoUpload)?.data, reddit.video)
            XCTAssertEqual(video["caption"] as? String, "Posted by Member 😀")
            let entities = try decode([Entity].self, from: XCTUnwrap(video["caption_entities"]))
            XCTAssertEqual(entities.count, 1)
            XCTAssertEqual(entities.first?.type, "text_mention")
            XCTAssertEqual(entities.first?.user?.id, 7)
            XCTAssertEqual(entities.first?.offset, "Posted by ".utf16.count)
            XCTAssertEqual(entities.first?.length, "Member 😀".utf16.count)
            XCTAssertEqual((video["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 3)
            XCTAssertEqual(try parameters("deleteMessage")["message_id"] as? Int64, 5)
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testUnconfirmedVideoSendOrPendingEditNeverDeletesOriginalOrRecordsReceipt() async throws {
        for slow in [false, true] {
            try reset(slow: slow, replace: !slow)
            reddit.video = Self.mp4(width: 1920, height: 1080)
            api.outcomes[slow ? "editMessageMedia" : "sendVideo"] = .success(
                slow ? ["message_id": api.sentID + 1] : ["message_id": true])
            do {
                try await handle(slow ? source : source + "?utm_source=fixture")
                XCTFail("Expected an unconfirmed video receipt to fail")
            } catch BotError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(api.methods, slow ? ["sendMessage", "editMessageMedia"] : ["getChatMember", "sendVideo"])
            assertDimensions(try videoParameters(slow: slow), width: 1920, height: 1080)
            XCTAssertTrue(store.state.replyControls.isEmpty)
        }
    }

    func testFacebookUsesSameDimensionsForFastAndPendingNativeVideos() async throws {
        for slow in [false, true] {
            try reset(slow: slow)
            facebook.video = Self.mp4(width: 1920, height: 1080, rotated: true)
            try await handle("https://www.facebook.com/reel/123456")
            assertDimensions(try videoParameters(slow: slow), width: 1080, height: 1920)
            try assertBareReply(slow: slow, data: facebook.video)
        }
    }

    func testYouTubePhotosKeepCaptionsAndHaveNoVideoDimensions() async throws {
        for slow in [false, true] {
            try reset(slow: slow)
            try await handle("https://youtu.be/AAAAAAAAAAA")
            XCTAssertEqual(api.methods, slow ? ["sendMessage", "editMessageMedia"] : ["sendPhoto"])
            let envelope = try parameters(slow ? "editMessageMedia" : "sendPhoto")
            let media = slow ? try XCTUnwrap(envelope["media"] as? [String: Any]) : envelope
            assertDimensions(media, width: nil, height: nil)
            XCTAssertNil(media["supports_streaming"])
            XCTAssertTrue((media["caption"] as? String)?.hasPrefix("YouTube\nFixture video\n\n") == true)
            XCTAssertNotNil(media["caption_entities"])
            XCTAssertEqual(media[slow ? "media" : "photo"] as? String, "https://example.invalid/thumbnail.jpg")
            if slow { XCTAssertEqual(media["type"] as? String, "photo") }
            XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:\(api.sentID)"])
        }
    }

    func testMultipartTransportsSendVideoAndNestedEditDimensionsWithoutNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DimensionsUploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); DimensionsUploadURLProtocol.handler = nil }
        let clip = Self.mp4(width: 1920, height: 1080)
        var methods: [String] = []
        DimensionsUploadURLProtocol.handler = { request in
            let method = try XCTUnwrap(request.url?.lastPathComponent)
            methods.append(method)
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=fxclip-"))
            let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
            let body = try Self.requestBody(request)
            XCTAssertNotNil(body.range(of: clip))
            let text = String(decoding: body, as: UTF8.self)
            func field(_ name: String) throws -> Any {
                let start = try XCTUnwrap(text.range(of: "name=\"\(name)\"\r\n\r\n")).upperBound
                let end = try XCTUnwrap(text.range(of: "\r\n--\(boundary)", range: start..<text.endIndex)).lowerBound
                return try JSONSerialization.jsonObject(with: Data(text[start..<end].utf8), options: .fragmentsAllowed)
            }
            if method == "sendVideo" {
                XCTAssertEqual(try field("width") as? Int, 1920)
                XCTAssertEqual(try field("height") as? Int, 1080)
            } else {
                XCTAssertEqual(method, "editMessageMedia")
                let media = try XCTUnwrap(field("media") as? [String: Any])
                self.assertDimensions(media, width: 1920, height: 1080)
                XCTAssertEqual(media["media"] as? String, "attach://video")
                XCTAssertEqual(media["type"] as? String, "video")
                XCTAssertEqual(media["supports_streaming"] as? Bool, true)
                XCTAssertFalse(text.contains("name=\"width\""))
                XCTAssertFalse(text.contains("name=\"height\""))
            }
            return Data(#"{"ok":true,"result":{"message_id":42}}"#.utf8)
        }
        let client = TelegramAPI(token: "fixture", session: session)
        _ = try await client.call("sendVideo", ["chat_id": Int64(-100), "video": VideoUpload(data: clip),
                                                "width": 1920, "height": 1080, "supports_streaming": true])
        _ = try await client.call("editMessageMedia", ["chat_id": Int64(-100), "message_id": Int64(42),
            "media": ["type": "video", "media": VideoUpload(data: clip), "width": 1920, "height": 1080,
                      "supports_streaming": true] as [String: Any]])
        XCTAssertEqual(methods, ["sendVideo", "editMessageMedia"])
    }

    // Synthetic ISO BMFF metadata only: no downloaded media, account data or real post metadata.
    private static var ftyp: Data { box("ftyp", Data("isom".utf8) + word(0) + Data("isommp42".utf8)) }

    private static func mp4(width: UInt32, height: UInt32, rotated: Bool = false, handler: String = "vide") -> Data {
        var header = word(7) // version 0, enabled/in-movie/in-preview track flags
        for value: UInt32 in [0, 0, 1, 0, 1000, 0, 0, 0, 0] { header.append(word(value)) }
        let matrix: [Int32] = rotated
            ? [0, 65_536, 0, -65_536, 0, 0, 0, 0, 1_073_741_824]
            : [65_536, 0, 0, 0, 65_536, 0, 0, 0, 1_073_741_824]
        for value in matrix { header.append(word(UInt32(bitPattern: value))) }
        header.append(word(width << 16))
        header.append(word(height << 16))
        let handlerBox = box("hdlr", word(0) + word(0) + Data(handler.utf8) + Data(repeating: 0, count: 13))
        return ftyp + box("moov", box("trak", box("tkhd", header) + box("mdia", handlerBox)))
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        word(UInt32(payload.count + 8)) + Data(type.utf8) + payload
    }

    private static func word(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? BotError.invalidResponse }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}

private final class DimensionsUploadURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let data = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
