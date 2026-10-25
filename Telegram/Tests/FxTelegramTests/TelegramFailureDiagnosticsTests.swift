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
}
