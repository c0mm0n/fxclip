import Foundation
import XCTest
@testable import FxTelegram

final class ManualReplacementStateTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!
    private var path: URL { directory.appendingPathComponent("state.json") }
    private let original = OriginalPublication(messageID: 41, date: 999)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("fxclip-manual-replacement-\(UUID().uuidString)")
        store = try StateStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
    }

    private func record() throws {
        try store.recordPublication(chatID: -100, messageID: 42, posterID: 7, now: 1000, original: original)
    }

    private func consume(now: TimeInterval = 1001) throws -> OriginalPublication? {
        try store.consumePublicationOriginal(chatID: -100, messageID: 42, posterID: 7, now: now)
    }

    private func load(_ receipt: PublicationReceipt) throws {
        var state = BotState()
        state.publications["-100:42"] = receipt
        try JSONEncoder().encode(state).write(to: path)
        store = try StateStore(directory: directory)
    }

    func testLegacyReceiptDecodesMissingOrNullOriginalAndKeepsOldEncoding() throws {
        for json in [#"{"posterID":7,"createdAt":1000}"#,
                     #"{"posterID":7,"createdAt":1000,"original":null}"#] {
            let receipt = try JSONDecoder().decode(PublicationReceipt.self, from: Data(json.utf8))
            XCTAssertEqual(receipt, PublicationReceipt(posterID: 7, createdAt: 1000))
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
            XCTAssertEqual(Set(encoded.keys), ["posterID", "createdAt"])
        }
    }

    func testOriginalPersistsOnlyExactIDAndDate() throws {
        try record()
        let reloaded = try StateStore(directory: directory)
        XCTAssertEqual(reloaded.state.publications["-100:42"]?.original, original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let publications = try XCTUnwrap(json["publications"] as? [String: [String: Any]])
        let receipt = try XCTUnwrap(publications["-100:42"])
        XCTAssertEqual(Set(receipt.keys), ["posterID", "createdAt", "original"])
        let source = try XCTUnwrap(receipt["original"] as? [String: Int])
        XCTAssertEqual(source, ["messageID": 41, "date": 999])
    }

    func testConsumeIsDurablyOneShotAndPreservesPublicationAndControls() throws {
        try record()
        try store.recordReplyControl(chatID: -100, messageID: 42, posterID: 7, now: 1000)
        XCTAssertEqual(try consume(), original)
        XCTAssertEqual(store.state.publications["-100:42"], PublicationReceipt(posterID: 7, createdAt: 1000))
        XCTAssertNotNil(store.state.replyControls["-100:42"])
        XCTAssertNil(try consume())
        store = try StateStore(directory: directory)
        XCTAssertNil(try consume())
        XCTAssertEqual(store.state.publications["-100:42"]?.posterID, 7)
    }

    func testWrongPosterChatMessageAndInvalidClockCannotConsumeOrWrite() throws {
        try record()
        let before = try Data(contentsOf: path)
        for (chatID, messageID, posterID) in [(Int64(-100), Int64(42), Int64(8)),
                                             (-101, 42, 7), (-100, 43, 7), (0, 42, 7),
                                             (-100, 0, 7), (-100, 42, 0)] {
            XCTAssertNil(try store.consumePublicationOriginal(chatID: chatID, messageID: messageID,
                                                              posterID: posterID, now: 1001))
        }
        for now in [TimeInterval(999.999), 1300, 1301, .nan, .infinity, -.infinity] {
            XCTAssertNil(try consume(now: now))
        }
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(store.state.publications["-100:42"]?.original, original)
        XCTAssertEqual(try consume(now: 1000), original)
    }

    func testFiveMinuteBoundaryAndOriginal48HourBoundaryAreExclusive() throws {
        try record()
        XCTAssertEqual(try consume(now: 1299.999), original)
        try record()
        XCTAssertNil(try consume(now: 1300))
        let source = OriginalPublication(messageID: 41, date: 1)
        let boundary = TimeInterval(source.date) + PublicationReceipt.retention
        try load(PublicationReceipt(posterID: 7, createdAt: boundary - 100, original: source))
        XCTAssertNil(try consume(now: boundary))
        XCTAssertEqual(try consume(now: boundary - 0.001), source)
    }

    func testConsumeRevalidatesCorruptOrFutureOriginalsWithoutClearingThem() throws {
        for source in [OriginalPublication(messageID: 0, date: 999),
                       OriginalPublication(messageID: -1, date: 999),
                       OriginalPublication(messageID: 42, date: 999),
                       OriginalPublication(messageID: 41, date: 0),
                       OriginalPublication(messageID: 41, date: -1),
                       OriginalPublication(messageID: 41, date: 1002)] {
            try load(PublicationReceipt(posterID: 7, createdAt: 1000, original: source))
            XCTAssertNil(try consume())
            XCTAssertEqual(store.state.publications["-100:42"]?.original, source)
        }
        try load(PublicationReceipt(posterID: 7, createdAt: 1002, original: original))
        XCTAssertNil(try consume())
        XCTAssertEqual(store.state.publications["-100:42"]?.original, original)
    }

    func testIneligibleOriginalDoesNotPreventRecordingPublicationOwnership() throws {
        for source in [OriginalPublication(messageID: 0, date: 999),
                       OriginalPublication(messageID: -1, date: 999),
                       OriginalPublication(messageID: 42, date: 999),
                       OriginalPublication(messageID: 41, date: 0),
                       OriginalPublication(messageID: 41, date: -1),
                       OriginalPublication(messageID: 41, date: 1002)] {
            try store.recordPublication(chatID: -100, messageID: 42, posterID: 7, now: 1000, original: source)
            XCTAssertEqual(store.state.publications["-100:42"]?.posterID, 7)
            XCTAssertNil(try consume())
        }
        let now = 999 + PublicationReceipt.retention
        try store.recordPublication(chatID: -100, messageID: 42, posterID: 7, now: now, original: original)
        XCTAssertEqual(store.state.publications["-100:42"]?.posterID, 7)
        XCTAssertNil(try consume(now: now))
    }

    func testStateWriteFailureThrowsBeforeConsumptionAndLeavesMemoryIntact() throws {
        try record()
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try consume())
        XCTAssertEqual(store.state.publications["-100:42"]?.original, original)
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(try consume(), original)
        XCTAssertNil(try StateStore(directory: directory).state.publications["-100:42"]?.original)
    }

    func testFiveMinuteCleanupClearsOriginalAndRetains48HourOwnershipAtomically() throws {
        try record()
        try store.recordReplyControl(chatID: -100, messageID: 42, posterID: 7, now: 1000)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.removeReplyControl(key: "-100:42"))
        XCTAssertNotNil(store.state.replyControls["-100:42"])
        XCTAssertEqual(store.state.publications["-100:42"]?.original, original)
        try FileManager.default.removeItem(at: path)
        try store.removeReplyControl(key: "-100:42")
        let reloaded = try StateStore(directory: directory)
        XCTAssertNil(reloaded.state.replyControls["-100:42"])
        XCTAssertEqual(reloaded.state.publications["-100:42"], PublicationReceipt(posterID: 7, createdAt: 1000))
        try store.prunePublications(now: 1000 + PublicationReceipt.retention - 0.001)
        XCTAssertNotNil(store.state.publications["-100:42"])
        try store.prunePublications(now: 1000 + PublicationReceipt.retention)
        XCTAssertNil(store.state.publications["-100:42"])
    }

    func testCleanupAlsoClearsOriginalWithNoQueuedControlAndDoesNotAffectOtherMessages() throws {
        try record()
        try store.recordPublication(chatID: -100, messageID: 43, posterID: 8, now: 1000, original: original)
        try store.removeReplyControl(key: "-100:42")
        XCTAssertEqual(store.state.publications["-100:42"], PublicationReceipt(posterID: 7, createdAt: 1000))
        XCTAssertEqual(store.state.publications["-100:43"]?.original, original)
        XCTAssertNil(try consume())
        try store.removeReplyControl(key: "-100:42")
        XCTAssertEqual(try StateStore(directory: directory).state.publications, store.state.publications)
    }

    func testOrphanOriginalExpiresAt300SecondsAcrossRestartButOwnershipLasts48Hours() throws {
        try record()
        try store.recordPublication(chatID: -100, messageID: 43, posterID: 8, now: 1000)
        XCTAssertTrue(store.state.replyControls.isEmpty)
        let before = try Data(contentsOf: path)
        try store.prunePublications(now: 1299)
        XCTAssertEqual(store.state.publications["-100:42"]?.original, original)
        XCTAssertEqual(try Data(contentsOf: path), before)
        store = try StateStore(directory: directory)
        XCTAssertEqual(store.state.publications["-100:42"]?.original, original)

        try store.prunePublications(now: 1300)
        let expected = ["-100:42": PublicationReceipt(posterID: 7, createdAt: 1000),
                        "-100:43": PublicationReceipt(posterID: 8, createdAt: 1000)]
        XCTAssertEqual(store.state.publications, expected)
        XCTAssertTrue(store.state.replyControls.isEmpty)
        store = try StateStore(directory: directory)
        XCTAssertEqual(store.state.publications, expected)
        XCTAssertNil(try consume(now: 1299)) // A later clock rollback cannot revive the original.
        try store.prunePublications(now: 1000 + PublicationReceipt.retention - 1)
        XCTAssertEqual(store.state.publications, expected)
        try store.prunePublications(now: 1000 + PublicationReceipt.retention)
        XCTAssertTrue(store.state.publications.isEmpty)
    }

    func testOriginalExpiresWhileExpiredKeyboardCleanupStillNeedsRetries() throws {
        try record()
        let button = InlineKeyboardButton(text: "Open", url: "https://example.com")
        try store.recordReplyControl(chatID: -100, messageID: 42, posterID: 7, now: 1000, openButton: button)
        let controls = store.state.replyControls
        try store.prunePublications(now: 1300)
        XCTAssertNil(store.state.publications["-100:42"]?.original)
        XCTAssertEqual(store.state.publications["-100:42"]?.posterID, 7)
        XCTAssertEqual(store.state.replyControls, controls)
        store = try StateStore(directory: directory)
        XCTAssertNil(store.state.publications["-100:42"]?.original)
        XCTAssertEqual(store.state.replyControls, controls)

        try store.prunePublications(now: 1330)
        XCTAssertNil(store.state.publications["-100:42"]?.original)
        XCTAssertEqual(store.state.replyControls, controls)
    }

    func testPruningPreservesFutureReceiptButItCannotAuthorizeReplacementYet() throws {
        let receipt = PublicationReceipt(posterID: 7, createdAt: 2000, original: original)
        try load(receipt)
        let before = try Data(contentsOf: path)
        try store.prunePublications(now: 1000)
        XCTAssertEqual(store.state.publications["-100:42"], receipt)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertNil(try consume(now: 1000))
        store = try StateStore(directory: directory)
        try store.prunePublications(now: 2299)
        XCTAssertEqual(store.state.publications["-100:42"], receipt)
        try store.prunePublications(now: 2300)
        XCTAssertEqual(store.state.publications["-100:42"], PublicationReceipt(posterID: 7, createdAt: 2000))
    }

    func testOriginalPruningFailureDoesNotPartiallyMutateMemoryAndCanBeRetried() throws {
        try record()
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.prunePublications(now: 1300))
        XCTAssertEqual(store.state.publications["-100:42"]?.original, original)
        try FileManager.default.removeItem(at: path)
        try store.prunePublications(now: 1300)
        XCTAssertEqual(try StateStore(directory: directory).state.publications["-100:42"],
                       PublicationReceipt(posterID: 7, createdAt: 1000))
    }
}
