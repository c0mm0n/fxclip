import Foundation
import XCTest
@testable import FxTelegram

final class PendingPreviewTests: XCTestCase {
    private let parameters: [String: Any] = ["chat_id": Int64(-100), "text": "Preparing preview…"]
    private let shortDelay: UInt64 = 20_000_000

    func testFastSuccessReturnsWithoutWaitingForDelayOrSendingPlaceholder() async throws {
        let api = PendingPreviewAPI(response: .success(["message_id": 42]))
        let finished = expectation(description: "Fast fetch returns before the two-second delay")
        let task = Task {
            let outcome = try await fetchWithPendingPreview(
                api: api, parameters: parameters, originalMessageID: 5,
                delayNanoseconds: 2_000_000_000, fetch: { "preview" })
            finished.fulfill()
            return outcome
        }
        await fulfillment(of: [finished], timeout: 1)
        let (result, pendingID) = try await task.value
        XCTAssertEqual(try result.get(), "preview")
        XCTAssertNil(pendingID)
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testFastFailureReturnsAsResultWithoutWaitingOrSendingPlaceholder() async throws {
        let api = PendingPreviewAPI(response: .success(["message_id": 42]))
        let finished = expectation(description: "Fast error returns before the two-second delay")
        let task = Task {
            let outcome = try await fetchWithPendingPreview(
                api: api, parameters: parameters, originalMessageID: 5,
                delayNanoseconds: 2_000_000_000, fetch: { () throws -> String in
                    throw PendingPreviewFailure.provider
                })
            finished.fulfill()
            return outcome
        }
        await fulfillment(of: [finished], timeout: 1)
        let (result, pendingID) = try await task.value
        assertProviderFailure(result)
        XCTAssertNil(pendingID)
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testFastFetchLeavesNoPendingSendAfterDelayWouldHaveElapsed() async throws {
        let api = PendingPreviewAPI(response: .success(["message_id": 42]))
        _ = try await fetchWithPendingPreview(
            api: api, parameters: parameters, originalMessageID: 5,
            delayNanoseconds: shortDelay, fetch: { "preview" })
        try await Task.sleep(nanoseconds: 80_000_000)
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSlowSuccessSendsProvidedPlaceholderOnceAndReturnsConfirmedID() async throws {
        let gate = PendingPreviewGate()
        let api = PendingPreviewAPI(response: .success(["message_id": Int64(42)]), onSend: { await gate.open() })
        let (result, pendingID) = try await fetchWithPendingPreview(
            api: api, parameters: parameters, originalMessageID: 5,
            delayNanoseconds: shortDelay, fetch: { await gate.wait(); return "preview" })
        XCTAssertEqual(try result.get(), "preview")
        XCTAssertEqual(pendingID, 42)
        await assertSinglePlaceholder(api)
    }

    func testSlowFailurePreservesConfirmedIDForCallerCleanup() async throws {
        let gate = PendingPreviewGate()
        let api = PendingPreviewAPI(response: .success(["message_id": 42]), onSend: { await gate.open() })
        let (result, pendingID) = try await fetchWithPendingPreview(
            api: api, parameters: parameters, originalMessageID: 5,
            delayNanoseconds: shortDelay, fetch: { () async throws -> String in
                await gate.wait()
                throw PendingPreviewFailure.provider
            })
        assertProviderFailure(result)
        XCTAssertEqual(pendingID, 42)
        await assertSinglePlaceholder(api)
    }

    func testParentCancellationBeforeDelayLeavesNoPlaceholderOrLaterSend() async throws {
        let start = PendingPreviewGate()
        let cancelled = PendingPreviewFlag()
        let api = PendingPreviewAPI(response: .success(["message_id": 42]))
        let task = Task {
            await start.wait()
            return try await fetchWithPendingPreview(
                api: api, parameters: parameters, originalMessageID: 5,
                delayNanoseconds: shortDelay, fetch: { () async throws -> String in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000); return "unexpected" }
                    catch { await cancelled.set(); throw error }
                })
        }
        // Cancel before allowing either child to start, independent of scheduler timing.
        task.cancel()
        await start.open()
        do {
            let (result, pendingID) = try await task.value
            guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
            XCTAssertTrue(error is CancellationError)
            XCTAssertNil(pendingID)
        } catch {
            // Either cancelled child can win the initial race.
            XCTAssertTrue(error is CancellationError)
        }
        let fetchWasCancelled = await cancelled.value
        XCTAssertTrue(fetchWasCancelled, "The cancelled provider must be joined before returning")
        try await Task.sleep(nanoseconds: 80_000_000)
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testParentCancellationAfterPlaceholderReturnsCancellationAndKnownIDForCleanup() async throws {
        let sent = PendingPreviewGate()
        let started = PendingPreviewGate()
        let cancelled = PendingPreviewFlag()
        let api = PendingPreviewAPI(response: .success(["message_id": 42]), onSend: {
            await started.wait()
            await sent.open()
        })
        let task = Task {
            try await fetchWithPendingPreview(
                api: api, parameters: parameters, originalMessageID: 5,
                delayNanoseconds: shortDelay, fetch: { () async throws -> String in
                    await started.open()
                    do { try await Task.sleep(nanoseconds: 5_000_000_000); return "unexpected" }
                    catch { await cancelled.set(); throw error }
                })
        }
        await sent.wait()
        task.cancel()
        let (result, pendingID) = try await task.value
        guard case .failure(let error) = result else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(pendingID, 42)
        let fetchWasCancelled = await cancelled.value
        XCTAssertTrue(fetchWasCancelled, "The cancelled provider must be joined before returning")
        try await Task.sleep(nanoseconds: 80_000_000)
        await assertSinglePlaceholder(api)
    }

    func testExplicitPlaceholderRejectionsContinueFetchWithNoPendingID() async throws {
        for code in [400, 403] {
            let gate = PendingPreviewGate()
            let api = PendingPreviewAPI(response: .failure(BotError.telegram(code)), onSend: { await gate.open() })
            let (result, pendingID) = try await fetchWithPendingPreview(
                api: api, parameters: parameters, originalMessageID: 5,
                delayNanoseconds: shortDelay, fetch: { await gate.wait(); return "preview" })
            XCTAssertEqual(try result.get(), "preview")
            XCTAssertNil(pendingID)
            await assertSinglePlaceholder(api)
        }
    }

    func testExplicitRejectionStillReturnsProviderFailure() async throws {
        let gate = PendingPreviewGate()
        let api = PendingPreviewAPI(response: .failure(BotError.telegram(400)), onSend: { await gate.open() })
        let (result, pendingID) = try await fetchWithPendingPreview(
            api: api, parameters: parameters, originalMessageID: 5,
            delayNanoseconds: shortDelay, fetch: { () async throws -> String in
                await gate.wait()
                throw PendingPreviewFailure.provider
            })
        assertProviderFailure(result)
        XCTAssertNil(pendingID)
        await assertSinglePlaceholder(api)
    }

    func testUncertainPlaceholderFailuresThrowAndCancelAndJoinFetch() async throws {
        let failures: [Error] = [URLError(.timedOut), BotError.invalidResponse,
                                 BotError.telegram(429), BotError.telegram(500)]
        for failure in failures {
            let api = PendingPreviewAPI(response: .failure(failure))
            let cancelled = PendingPreviewFlag()
            do {
                _ = try await fetchWithPendingPreview(
                    api: api, parameters: parameters, originalMessageID: 5,
                    delayNanoseconds: shortDelay, fetch: { () async throws -> String in
                        do { try await Task.sleep(nanoseconds: 5_000_000_000); return "unexpected" }
                        catch { await cancelled.set(); throw error }
                    })
                XCTFail("An uncertain send must throw")
            } catch {
                XCTAssertEqual(String(reflecting: error), String(reflecting: failure))
            }
            let fetchWasCancelled = await cancelled.value
            XCTAssertTrue(fetchWasCancelled, "The provider task must be joined before returning")
            await assertSinglePlaceholder(api)
        }
    }

    func testMalformedPlaceholderSuccessThrowsWithoutReturningUnsafeID() async throws {
        let responses = [
            #"{}"#, #"null"#, #"true"#, #"[]"#, #"{"message_id":null}"#,
            #"{"message_id":"42"}"#, #"{"message_id":0}"#, #"{"message_id":-1}"#,
            #"{"message_id":true}"#, #"{"message_id":false}"#, #"{"message_id":42.5}"#,
            #"{"message_id":9223372036854775808}"#, #"{"message_id":5}"#,
        ]
        for json in responses {
            let response = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
            let api = PendingPreviewAPI(response: .success(response))
            let cancelled = PendingPreviewFlag()
            do {
                _ = try await fetchWithPendingPreview(
                    api: api, parameters: parameters, originalMessageID: 5,
                    delayNanoseconds: shortDelay, fetch: { () async throws -> String in
                        do { try await Task.sleep(nanoseconds: 5_000_000_000); return "unexpected" }
                        catch { await cancelled.set(); throw error }
                    })
                XCTFail("Expected invalid response for \(json)")
            } catch BotError.invalidResponse {} catch { XCTFail("Unexpected error for \(json): \(error)") }
            let fetchWasCancelled = await cancelled.value
            XCTAssertTrue(fetchWasCancelled, json)
            await assertSinglePlaceholder(api)
        }
    }

    private func assertProviderFailure(_ result: Result<String, Error>, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else {
            return XCTFail("Expected provider error", file: file, line: line)
        }
        XCTAssertEqual(error as? PendingPreviewFailure, .provider, file: file, line: line)
    }

    private func assertSinglePlaceholder(_ api: PendingPreviewAPI, file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await api.calls
        XCTAssertEqual(calls.map(\.0), ["sendMessage"], file: file, line: line)
        XCTAssertEqual(calls.first?.1["chat_id"] as? Int64, -100, file: file, line: line)
        XCTAssertEqual(calls.first?.1["text"] as? String, "Preparing preview…", file: file, line: line)
        XCTAssertEqual(calls.first?.1.count, parameters.count, file: file, line: line)
    }
}

private enum PendingPreviewFailure: Error { case provider }

private actor PendingPreviewAPI: BotAPI {
    private let response: Result<Any, Error>
    private let onSend: () async -> Void
    private(set) var calls: [(String, [String: Any])] = []

    init(response: Result<Any, Error>, onSend: @escaping () async -> Void = {}) {
        self.response = response
        self.onSend = onSend
    }

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        calls.append((method, parameters))
        await onSend()
        return try response.get()
    }
}

private actor PendingPreviewGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private actor PendingPreviewFlag {
    private(set) var value = false
    func set() { value = true }
}
