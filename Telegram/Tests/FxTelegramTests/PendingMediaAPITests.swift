import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FxTelegram

final class PendingMediaAPITests: XCTestCase {
    private var session: URLSession!
    private var api: TelegramAPI!

    override func setUp() {
        super.setUp()
        PendingMediaURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingMediaURLProtocol.self]
        session = URLSession(configuration: configuration)
        api = TelegramAPI(token: "fixture", session: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        api = nil
        PendingMediaURLProtocol.requests = []
        super.tearDown()
    }

    func testProtectedTextAndPhotoSendFlagsReachJSONWireAsTrue() async throws {
        for method in ["sendMessage", "sendPhoto"] {
            PendingMediaURLProtocol.requests = []
            let parameters: [String: Any] = ["chat_id": -100, "protect_content": true,
                method == "sendPhoto" ? "photo" : "text": method == "sendPhoto" ? "https://example.com/image.jpg" : "Posted by Example"]
            _ = try await api.call(method, parameters)
            let (_, body) = try onlyRequest()
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(fields["protect_content"] as? Bool, true)
            XCTAssertEqual(fields["chat_id"] as? Int, -100)
        }
    }

    func testProtectedVideoSendFlagReachesMultipartWithoutChangingBytes() async throws {
        let video = mp4()
        _ = try await api.call("sendVideo", ["chat_id": -100, "protect_content": true,
            "video": VideoUpload(data: video), "caption": "Posted by Example"])
        let (request, body) = try onlyRequest()
        let (boundary, text) = try multipart(request, body)
        XCTAssertEqual(try field("protect_content", in: text, boundary: boundary), "true")
        XCTAssertNotNil(body.range(of: video))
    }

    func testVideoEditUploadsAttachmentAndPreservesNestedCaptionEntitiesAndMarkup() async throws {
        let caption = "😀 A <caption> & \"quote\"\nSecond line"
        let entities: [[String: Any]] = [
            ["type": "bold", "offset": 3, "length": 1],
            ["type": "text_link", "offset": 5, "length": 9, "url": "https://example.com/watch"],
        ]
        let markup = ["inline_keyboard": [[["text": "Open", "url": "https://example.com/watch"]]]]
        let clip = mp4()
        let result = try await api.call("editMessageMedia", [
            "chat_id": 123, "message_id": 456,
            "media": ["type": "video", "media": VideoUpload(data: clip), "supports_streaming": true,
                      "caption": caption, "caption_entities": entities] as [String: Any],
            "reply_markup": markup,
        ]) as? [String: Any]

        XCTAssertEqual(result?["message_id"] as? Int, 456)
        let (request, body) = try onlyRequest()
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.telegram.org/botfixture/editMessageMedia")
        let (boundary, text) = try multipart(request, body)
        XCTAssertEqual(try field("chat_id", in: text, boundary: boundary), "123")
        XCTAssertEqual(try field("message_id", in: text, boundary: boundary), "456")
        let media = try XCTUnwrap(jsonField("media", in: text, boundary: boundary) as? [String: Any])
        XCTAssertEqual(media["type"] as? String, "video")
        XCTAssertEqual(media["media"] as? String, "attach://video")
        XCTAssertEqual(media["supports_streaming"] as? Bool, true)
        XCTAssertEqual(media["caption"] as? String, caption)
        try assertJSONEqual(media["caption_entities"], entities)
        try assertJSONEqual(jsonField("reply_markup", in: text, boundary: boundary), markup)
        XCTAssertEqual(text.components(separatedBy: "name=\"video\"; filename=\"reel.mp4\"").count - 1, 1)
        XCTAssertTrue(text.contains("name=\"video\"; filename=\"reel.mp4\"\r\nContent-Type: video/mp4\r\n\r\n"))
        XCTAssertNotNil(body.range(of: clip))
        XCTAssertTrue(text.hasSuffix("\r\n--\(boundary)--\r\n"))
        XCTAssertFalse(text.contains("VideoUpload"))
        XCTAssertFalse(text.contains("name=\"caption\""))
        XCTAssertFalse(text.contains("name=\"caption_entities\""))
        XCTAssertFalse(text.contains("name=\"supports_streaming\""))
    }

    func testVideoEditAllowsOmittedCaptionEntitiesAndMarkupAtExactSizeLimit() async throws {
        let clip = mp4(size: 20 * 1024 * 1024)
        _ = try await api.call("editMessageMedia", [
            "chat_id": 123, "message_id": 456,
            "media": ["type": "video", "media": VideoUpload(data: clip), "supports_streaming": true] as [String: Any],
        ])
        let (request, body) = try onlyRequest()
        let (boundary, text) = try multipart(request, body)
        let media = try XCTUnwrap(jsonField("media", in: text, boundary: boundary) as? [String: Any])
        XCTAssertEqual(Set(media.keys), ["type", "media", "supports_streaming"])
        XCTAssertEqual(media["media"] as? String, "attach://video")
        XCTAssertFalse(text.contains("name=\"reply_markup\""))
        XCTAssertNotNil(body.range(of: clip))
    }

    func testPhotoEditKeepsExistingJSONRequestWithCaptionEntitiesAndMarkup() async throws {
        let parameters: [String: Any] = [
            "chat_id": 123, "message_id": 456,
            "media": ["type": "photo", "media": "https://images.example/thumbnail.jpg",
                      "caption": "😀 A title", "show_caption_above_media": true,
                      "caption_entities": [["type": "bold", "offset": 3, "length": 7]]] as [String: Any],
            "reply_markup": ["inline_keyboard": [[["text": "Watch", "url": "https://example.com/watch", "style": "danger"]]]],
        ]
        _ = try await api.call("editMessageMedia", parameters)
        let (request, body) = try onlyRequest()
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.telegram.org/botfixture/editMessageMedia")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        try assertJSONEqual(JSONSerialization.jsonObject(with: body), parameters)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("attach://"))
        XCTAssertFalse(text.contains("VideoUpload"))
        XCTAssertFalse(text.contains("multipart/form-data"))
    }

    func testInvalidVideoBytesAreRejectedBeforeNetwork() async throws {
        var undersizedBox = mp4()
        undersizedBox[3] = 8
        var truncatedBox = mp4()
        truncatedBox[3] = 32
        let invalid = [Data(), Data([1]), Data("not an mp4!!".utf8),
                       Data([0, 0, 0, 12]) + Data("moovmp42".utf8), undersizedBox, truncatedBox,
                       mp4(size: 20 * 1024 * 1024 + 1)]
        for bytes in invalid {
            await assertRejected("editMessageMedia", [
                "chat_id": 123, "message_id": 456,
                "media": ["type": "video", "media": VideoUpload(data: bytes), "supports_streaming": true] as [String: Any],
            ])
        }
        XCTAssertTrue(PendingMediaURLProtocol.requests.isEmpty)
    }

    func testUnsupportedUploadMethodsAndShapesAreRejectedBeforeNetwork() async {
        let upload = VideoUpload(data: mp4())
        let video: [String: Any] = ["type": "video", "media": upload, "supports_streaming": true]
        for method in ["sendMessage", "sendPhoto", "sendVideo", "sendMediaGroup", "editMessageCaption"] {
            await assertRejected(method, ["chat_id": 123, "message_id": 456, "media": video])
        }
        let invalid: [[String: Any]] = [
            ["video": upload],
            ["media": upload],
            ["media": [video]],
            ["media": ["type": "photo", "media": upload]],
            ["media": ["media": upload]],
            ["media": ["type": "video", "video": upload]],
            ["media": ["type": "video", "media": "https://example.com/video.mp4", "thumbnail": upload]],
            ["media": video, "reply_markup": ["unexpected": upload]],
            ["media": video, "video": upload],
            ["media": video, "bad\r\nfield": "value"],
        ]
        for shape in invalid {
            await assertRejected("editMessageMedia", shape)
        }
        // A second upload must also be rejected when the supported sendVideo path is selected.
        await assertRejected("sendVideo", ["video": upload, "media": video])
        XCTAssertTrue(PendingMediaURLProtocol.requests.isEmpty)
    }

    private func mp4(size: Int = 12) -> Data {
        Data([0, 0, 0, 12]) + Data("ftypmp42".utf8) + Data(count: size - 12)
    }

    private func assertRejected(_ method: String, _ parameters: [String: Any],
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await api.call(method, parameters)
            XCTFail("Expected invalid upload", file: file, line: line)
        } catch BotError.invalidResponse {} catch {
            XCTFail("Expected BotError.invalidResponse", file: file, line: line)
        }
    }

    private func onlyRequest() throws -> (URLRequest, Data) {
        XCTAssertEqual(PendingMediaURLProtocol.requests.count, 1)
        return try XCTUnwrap(PendingMediaURLProtocol.requests.first)
    }

    private func multipart(_ request: URLRequest, _ body: Data) throws -> (String, String) {
        let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary=fxclip-"))
        let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--\(boundary)\r\n"))
        return (boundary, text)
    }

    private func field(_ name: String, in text: String, boundary: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "name=\"\(name)\"\r\n\r\n")).upperBound
        let end = try XCTUnwrap(text.range(of: "\r\n--\(boundary)", range: start..<text.endIndex)).lowerBound
        return String(text[start..<end])
    }

    private func jsonField(_ name: String, in text: String, boundary: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(field(name, in: text, boundary: boundary).utf8))
    }

    private func assertJSONEqual(_ actual: Any?, _ expected: Any,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(actual, file: file, line: line)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]), file: file, line: line)
    }
}

private final class PendingMediaURLProtocol: URLProtocol {
    static var requests: [(URLRequest, Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, body.isEmpty {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.requests.append((request, body))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true,\"result\":{\"message_id\":456}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
