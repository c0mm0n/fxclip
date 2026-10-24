import Foundation
import XCTest
@testable import FxTelegram

final class ReplyExpiryStateTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fxclip-reply-expiry-\(UUID().uuidString)")
        store = try StateStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
    }

    private func record(_ messageID: Int64, at now: TimeInterval,
                        openButton: InlineKeyboardButton? = nil) throws {
        try store.recordReplyControl(chatID: -100, messageID: messageID, posterID: 7,
                                     now: now, openButton: openButton)
    }

    func testAuthorizationLastsFiveMinutesAndCleanupRetentionLasts48Hours() {
        XCTAssertEqual(ReplyControl.lifetime, 300)
        XCTAssertEqual(ReplyControl.retention, 172_800)
        XCTAssertNil(ReplyControl(posterID: 7, createdAt: 1000).openButton)
    }

    func testPruningKeepsExpiredCleanupUntilExact48HourBoundary() throws {
        try record(41, at: 1000)
        try record(42, at: 1001)
        try store.pruneReplyControls(now: 1301)
        XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:41", "-100:42"])

        try store.pruneReplyControls(now: 1000 + ReplyControl.retention - 1)
        XCTAssertEqual(store.state.replyControls.count, 2)
        try store.pruneReplyControls(now: 1000 + ReplyControl.retention)
        XCTAssertEqual(Set(store.state.replyControls.keys), ["-100:42"])
        XCTAssertEqual(try StateStore(directory: directory).state.replyControls, store.state.replyControls)

        try store.pruneReplyControls(now: 1001 + ReplyControl.retention)
        XCTAssertTrue(try StateStore(directory: directory).state.replyControls.isEmpty)
    }

    func testOpenButtonRoundTripPersistsOnlyReceiptAndSourceButton() throws {
        let button = InlineKeyboardButton(text: "▶ Open YouTube", url: "https://youtu.be/example?t=42")
        try record(42, at: 1000, openButton: button)
        let reloaded = try StateStore(directory: directory)
        let control = try XCTUnwrap(reloaded.state.replyControls["-100:42"])
        XCTAssertEqual(control, ReplyControl(posterID: 7, createdAt: 1000, openButton: button))
        XCTAssertNil(control.openButton?.callback_data)

        let data = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let controls = try XCTUnwrap(json["replyControls"] as? [String: [String: Any]])
        let receipt = try XCTUnwrap(controls["-100:42"])
        XCTAssertEqual(Set(receipt.keys), ["posterID", "createdAt", "openButton"])
        let persistedButton = try XCTUnwrap(receipt["openButton"] as? [String: Any])
        XCTAssertEqual(Set(persistedButton.keys), ["text", "url"])
        XCTAssertEqual(persistedButton["text"] as? String, button.text)
        XCTAssertEqual(persistedButton["url"] as? String, button.url)
    }

    func testOrdinaryReplyPersistsNoOpenButtonOrMessageContent() throws {
        try record(42, at: 1000)
        let data = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let controls = try XCTUnwrap(json["replyControls"] as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(controls["-100:42"]).keys), ["posterID", "createdAt"])
        XCTAssertNil(try StateStore(directory: directory).state.replyControls["-100:42"]?.openButton)
    }

    func testLegacyStateWithReceiptMissingOpenButtonStillLoads() throws {
        let data = Data(#"{"offset":4,"chats":{},"users":{},"defaultMode":"reply","lastUpdateAt":1000,"replyControls":{"-100:42":{"posterID":7,"createdAt":1000}},"futureField":true}"#.utf8)
        try data.write(to: directory.appendingPathComponent("state.json"))
        store = try StateStore(directory: directory)
        XCTAssertEqual(store.state.offset, 4)
        XCTAssertEqual(store.state.replyControls["-100:42"], ReplyControl(posterID: 7, createdAt: 1000))
        try record(43, at: 1300)
        XCTAssertNotNil(try StateStore(directory: directory).state.replyControls["-100:42"])
    }

    func testCreatingNewReceiptKeepsExpiredPendingCleanup() throws {
        let button = InlineKeyboardButton(text: "▶ Open YouTube", url: "https://youtu.be/example")
        try record(41, at: 1000, openButton: button)
        try record(42, at: 1000 + ReplyControl.lifetime)
        let reloaded = try StateStore(directory: directory)
        XCTAssertEqual(Set(reloaded.state.replyControls.keys), ["-100:41", "-100:42"])
        XCTAssertEqual(reloaded.state.replyControls["-100:41"]?.openButton, button)
        try record(43, at: 1000 + ReplyControl.retention)
        XCTAssertNil(store.state.replyControls["-100:41"])
        XCTAssertNotNil(store.state.replyControls["-100:42"])
    }

    func testPollingWithoutFutureDeadlineUsesRequestedMaximum() throws {
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1000), 30)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1000, max: 12), 12)
        try record(42, at: 1000)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1300), 30)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1400, max: 12), 12)
    }

    func testPollingUsesEarliestFutureDeadlineRoundsUpAndStaysBounded() throws {
        try record(41, at: 1000)
        try record(42, at: 1005)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1005), 30)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1270), 30)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1279.75), 21)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1279.75, max: 10), 10)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1299.75), 1)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1300), 5)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1305), 30)
        XCTAssertEqual(store.replyControlPollingTimeout(now: 1305, max: 1), 1)
    }
}
