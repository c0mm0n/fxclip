import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FxTelegram

private final class RejectedTelegramProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":false,"error_code":400,"description":"Bad Request: can't parse entities; private text must never be logged"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class LimitedTelegramProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var bodies: [Data?] = []
    private static var retryDelay = 1
    static func reset(delay: Int) { lock.lock(); defer { lock.unlock() }; bodies = []; retryDelay = delay }
    static var requests: [Data?] { lock.lock(); defer { lock.unlock() }; return bodies }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.bodies.append(request.httpBody)
        let limited = Self.bodies.count == 1
        let delay = Self.retryDelay
        Self.lock.unlock()
        let payload: [String: Any] = limited
            ? ["ok": false, "error_code": 429, "description": "Too many requests", "parameters": ["retry_after": delay]]
            : ["ok": true, "result": ["message_id": 42]]
        let response = HTTPURLResponse(url: request.url!, statusCode: limited ? 429 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class TelegramFailureDiagnosticsTests: XCTestCase {
    func testKnownFailuresEmitOnlyClosedMethodCodeAndReasonLabels() {
        let description = "Bad Request: can't parse entities: secret https://example.invalid/private name@example.invalid"
        XCTAssertEqual(TelegramAPI.failureSummary(method: "sendMessage", code: 400, description: description),
                       "Telegram sendMessage rejected: code=400, reason=entities.")
        XCTAssertEqual(TelegramAPI.failureSummary(method: "sendPhoto", code: 400, description: "Failed to get HTTP URL content"),
                       "Telegram sendPhoto rejected: code=400, reason=media_fetch.")
        XCTAssertEqual(TelegramAPI.failureSummary(method: "editMessageText", code: 400, description: "message to edit not found"),
                       "Telegram editMessageText rejected: code=400, reason=edit_missing.")
    }

    func testUnknownMethodsDescriptionsAndOutOfRangeCodesCannotLeakPayloads() {
        let secret = "synthetic-private-value"
        XCTAssertEqual(TelegramAPI.failureSummary(method: secret, code: 123456789, description: secret),
                       "Telegram other rejected: code=0, reason=other.")
        XCTAssertEqual(TelegramAPI.failureSummary(method: "sendMessage", code: 500, description: nil),
                       "Telegram sendMessage rejected: code=500, reason=other.")
    }

    func testRateLimitDiagnosticOnlyIncludesBoundedStructuredDelay() {
        XCTAssertEqual(TelegramAPI.failureSummary(method: "sendMessage", code: 429, description: "Too many requests", retryAfter: 23),
                       "Telegram sendMessage rejected: code=429, reason=rate_limit, retry_seconds=23.")
        for invalid in [-1, 0, 86_401, Int.max] {
            XCTAssertEqual(TelegramAPI.failureSummary(method: "sendMessage", code: 429, description: "Too many requests", retryAfter: invalid),
                           "Telegram sendMessage rejected: code=429, reason=rate_limit.")
        }
        XCTAssertEqual(TelegramAPI.failureSummary(method: "sendMessage", code: 400, description: nil, retryAfter: 23),
                       "Telegram sendMessage rejected: code=400, reason=other.")
    }

    func testDiagnosticsDoNotChangeTheRejectionErrorOrRetryTheSend() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RejectedTelegramProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for diagnostics in [false, true] {
            let api = TelegramAPI(token: "123:synthetic-token", session: session, diagnostics: diagnostics)
            do {
                _ = try await api.call("sendMessage", ["chat_id": 7, "text": "example"])
                XCTFail("Expected the original Telegram rejection")
            } catch BotError.telegram(let code) { XCTAssertEqual(code, 400) }
        }
    }

    func testExplicitShortRateLimitRetriesTheIdenticalSendOnce() async throws {
        LimitedTelegramProtocol.reset(delay: 1)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LimitedTelegramProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = TelegramAPI(token: "123:synthetic-token", session: session)
        let response = try await api.call("sendMessage", ["chat_id": 7, "text": "example"])
        XCTAssertEqual((response as? [String: Any])?["message_id"] as? Int, 42)
        let requests = LimitedTelegramProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
    }

    func testLongRateLimitIsReportedWithoutAnImmediateRepeat() async throws {
        LimitedTelegramProtocol.reset(delay: 61)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LimitedTelegramProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = TelegramAPI(token: "123:synthetic-token", session: session)
        do {
            _ = try await api.call("sendMessage", ["chat_id": 7, "text": "example"])
            XCTFail("Expected rate limit")
        } catch BotError.telegram(429) {}
        XCTAssertEqual(LimitedTelegramProtocol.requests.count, 1)
    }
}
