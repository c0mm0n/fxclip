import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FxTelegram

final class VideoUploadTests: XCTestCase {
    func testMultipartUploadContainsVideoAndJSONFieldsWithoutRemoteMediaURL() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        let clip = Data([0, 0, 0, 16]) + Data("ftypmp42".utf8)
        UploadURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "api.telegram.org")
            XCTAssertTrue(request.url?.path.hasSuffix("/sendVideo") == true)
            let type = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary=fxclip-"))
            let boundary = String(type.split(separator: "=").last!)
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream, body.isEmpty {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertNotNil(body.range(of: clip))
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"video\"; filename=\"reel.mp4\"\r\nContent-Type: video/mp4"))
            XCTAssertTrue(text.contains("name=\"chat_id\"\r\n\r\n-100\r\n"))
            XCTAssertTrue(text.contains("name=\"caption\"\r\n\r\n😀 <caption>\r\n"))
            XCTAssertTrue(text.contains("name=\"supports_streaming\"\r\n\r\ntrue\r\n"))
            func field(_ name: String) throws -> Any {
                let start = try XCTUnwrap(text.range(of: "name=\"\(name)\"\r\n\r\n")).upperBound
                let end = try XCTUnwrap(text.range(of: "\r\n--\(boundary)", range: start..<text.endIndex)).lowerBound
                return try JSONSerialization.jsonObject(with: Data(text[start..<end].utf8))
            }
            let markup = try decode(InlineKeyboardMarkup.self, from: field("reply_markup"))
            XCTAssertEqual(markup.inline_keyboard.first?.first?.url, "https://facebook.com/reel/123")
            let reply = try XCTUnwrap(field("reply_parameters") as? [String: Any])
            XCTAssertEqual(reply["message_id"] as? Int, 5)
            XCTAssertEqual(reply["allow_sending_without_reply"] as? Bool, true)
            XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
            return Data("{\"ok\":true,\"result\":{\"message_id\":42}}".utf8)
        }
        let api = TelegramAPI(token: "fixture", session: session)
        let result = try await api.call("sendVideo", [
            "chat_id": Int64(-100), "video": VideoUpload(data: clip), "caption": "😀 <caption>",
            "supports_streaming": true,
            "reply_parameters": ["message_id": 5, "allow_sending_without_reply": true] as [String: Any],
            "reply_markup": ["inline_keyboard": [[["text": "Open", "url": "https://facebook.com/reel/123"]]]],
        ]) as? [String: Any]
        XCTAssertEqual(confirmedMessageID(result?["message_id"]), 42)
    }

    func testUploadRejectsEmptyOversizedAndWrongMethodBeforeNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        UploadURLProtocol.handler = { _ in XCTFail("Invalid uploads must not reach the network"); return Data() }
        let api = TelegramAPI(token: "fixture", session: session)
        for (method, data) in [("sendVideo", Data()), ("sendVideo", Data(count: 20 * 1024 * 1024 + 1)),
                               ("sendMessage", Data([1]))] {
            do { _ = try await api.call(method, ["video": VideoUpload(data: data)]); XCTFail("Expected invalid upload") }
            catch BotError.invalidResponse {} catch { XCTFail("Unexpected error") }
        }
    }

    func testUploadTransportFailureIsNotRetried() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        var requests = 0
        UploadURLProtocol.handler = { _ in requests += 1; throw URLError(.timedOut) }
        do {
            _ = try await TelegramAPI(token: "fixture", session: session)
                .call("sendVideo", ["video": VideoUpload(data: Data([1]))])
            XCTFail("Expected timeout")
        } catch {}
        XCTAssertEqual(requests, 1)
    }
}

private final class UploadURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
