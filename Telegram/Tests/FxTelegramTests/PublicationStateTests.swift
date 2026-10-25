import Foundation
import XCTest
@testable import FxTelegram

final class PublicationStateTests: XCTestCase {
    private var directory: URL!
    private var store: StateStore!
    private var path: URL { directory.appendingPathComponent("state.json") }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("fxclip-publications-\(UUID().uuidString)")
        store = try StateStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
    }

    private func load(_ state: BotState) throws {
        try JSONEncoder().encode(state).write(to: path)
        store = try StateStore(directory: directory)
    }

    private func legacyData(_ state: BotState, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        json.removeValue(forKey: "publications")
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func record(_ messageID: Int64 = 42, at now: TimeInterval = 1000) throws {
        try store.recordPublication(chatID: -100, messageID: messageID, posterID: 7, now: now)
    }

    func testMissingFieldDefaultsEmptyAndRoundTripRetainsOwnership() throws {
        let legacy = Data(#"{"offset":4,"chats":{},"users":{},"defaultMode":"reply","lastUpdateAt":1000}"#.utf8)
        try legacy.write(to: path)
        store = try StateStore(directory: directory)
        XCTAssertTrue(store.state.publications.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), legacy)

        try record()
        XCTAssertEqual(store.state.publications["-100:42"], PublicationReceipt(posterID: 7, createdAt: 1000))
        let reloaded = try StateStore(directory: directory)
        XCTAssertEqual(reloaded.state.publications, store.state.publications)
        XCTAssertEqual(reloaded.state.offset, 4)
        XCTAssertTrue(reloaded.state.replyControls.isEmpty)
    }

    func testModernStatePreservesExplicitEntriesAndDoesNotImportUnmatchedControls() throws {
        var state = BotState()
        state.replyControls = [
            "-100:41": ReplyControl(posterID: 7, createdAt: 1000),
            "-100:42": ReplyControl(posterID: 8, createdAt: 1001),
        ]
        state.publications["-100:42"] = PublicationReceipt(posterID: 9, createdAt: 1002)
        let data = try JSONEncoder().encode(state)
        try data.write(to: path)
        store = try StateStore(directory: directory)
        XCTAssertNil(store.state.publications["-100:41"])
        XCTAssertEqual(store.state.publications["-100:42"], PublicationReceipt(posterID: 9, createdAt: 1002))
        XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertEqual(store.state.replyControls, state.replyControls)
    }

    func testLegacyMigrationImportsControlsWithoutRewritingOnLoad() throws {
        var state = BotState()
        state.replyControls = [
            "-100:41": ReplyControl(posterID: 7, createdAt: 1000),
            "-100:42": ReplyControl(posterID: 8, createdAt: 1001),
        ]
        let data = try legacyData(state)
        try data.write(to: path)
        store = try StateStore(directory: directory)
        XCTAssertEqual(store.state.publications, [
            "-100:41": PublicationReceipt(posterID: 7, createdAt: 1000),
            "-100:42": PublicationReceipt(posterID: 8, createdAt: 1001),
        ])
        XCTAssertEqual(store.state.replyControls, state.replyControls)
        XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertTrue(try store.reserve(0, now: 1002))
        XCTAssertEqual(try StateStore(directory: directory).state.publications, store.state.publications)
    }

    func testExplicitEmptyPublicationsDoNotImportReplyControlsOnReload() throws {
        var state = BotState()
        state.replyControls["-100:42"] = ReplyControl(posterID: 7, createdAt: 1000)
        try load(state)
        let data = try Data(contentsOf: path)
        XCTAssertTrue(store.state.publications.isEmpty)
        XCTAssertTrue(try StateStore(directory: directory).state.publications.isEmpty)
        XCTAssertEqual(store.state.replyControls, state.replyControls)
        XCTAssertEqual(try Data(contentsOf: path), data)
    }

    func testModernStateAtCapacityDoesNotImportUnmatchedReplyControlsOnReload() throws {
        var state = BotState()
        for id in 1...20_000 {
            state.publications["-100:\(id)"] = PublicationReceipt(posterID: 7, createdAt: 1000)
        }
        state.replyControls["-100:20001"] = ReplyControl(posterID: 8, createdAt: 1001)
        state.replyControls["-101:42"] = ReplyControl(posterID: 9, createdAt: 1002)
        try load(state)
        let data = try Data(contentsOf: path)
        XCTAssertEqual(store.state.publications.count, 20_000)
        XCTAssertEqual(store.state.publications, state.publications)
        XCTAssertEqual(try StateStore(directory: directory).state.publications, state.publications)
        XCTAssertEqual(store.state.replyControls, state.replyControls)
        XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertTrue(try store.reserve(0, now: 1003))
        let reloaded = try StateStore(directory: directory)
        XCTAssertEqual(reloaded.state.publications, state.publications)
        XCTAssertEqual(reloaded.state.replyControls, state.replyControls)
    }

    func testGenuinelyLegacyMigrationIsBoundedAndStableAboveCapacity() throws {
        var state = BotState()
        for id in 1...20_005 {
            state.replyControls["-100:\(id)"] = ReplyControl(posterID: 7, createdAt: 1000)
        }
        let data = try legacyData(state)
        try data.write(to: path)
        store = try StateStore(directory: directory)
        XCTAssertEqual(PublicationReceipt.capacity, 20_000)
        XCTAssertEqual(store.state.publications.count, 20_000)
        XCTAssertEqual(store.state.replyControls, state.replyControls)
        for (key, receipt) in store.state.publications {
            let control = try XCTUnwrap(state.replyControls[key])
            XCTAssertEqual(receipt, PublicationReceipt(posterID: control.posterID, createdAt: control.createdAt))
        }
        XCTAssertEqual(try StateStore(directory: directory).state.publications, store.state.publications)
        XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertTrue(try store.reserve(0, now: 1001))
        XCTAssertEqual(try StateStore(directory: directory).state.publications, store.state.publications)
    }

    func testMalformedLegacyReceiptsAreNotImported() throws {
        var state = BotState()
        let valid = ReplyControl(posterID: 7, createdAt: 1000)
        for key in ["", "-100", "-100:42:1", ":42", "-100:", "0:42", "-100:0",
                    "-100:-1", "oops:42", "-100:abc", "-0100:42", "-100:+42",
                    "9223372036854775808:42", "-100:9223372036854775808"] {
            state.replyControls[key] = valid
        }
        state.replyControls["-100:43"] = ReplyControl(posterID: 0, createdAt: 1000)
        state.replyControls["-100:44"] = ReplyControl(posterID: -7, createdAt: 1000)
        state.replyControls["-100:45"] = ReplyControl(posterID: 7, createdAt: .infinity)
        state.replyControls["-100:46"] = ReplyControl(posterID: 7, createdAt: .nan)
        state.replyControls["-100:42"] = valid
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
        let decoded = try decoder.decode(BotState.self, from: legacyData(state, encoder: encoder))
        XCTAssertEqual(decoded.publications, ["-100:42": PublicationReceipt(posterID: 7, createdAt: 1000)])
        XCTAssertEqual(decoded.replyControls.count, state.replyControls.count)
    }

    func testOwnershipOutlivesFiveMinuteButtonAndExpiresAtExact48Hours() throws {
        XCTAssertEqual(PublicationReceipt.retention, 172_800)
        XCTAssertEqual(ReplyControl.lifetime, 300)
        try record()
        try store.recordReplyControl(chatID: -100, messageID: 42, posterID: 7, now: 1000)
        try store.removeReplyControl(chatID: -100, messageID: 42)
        try store.prunePublications(now: 1000 + ReplyControl.lifetime)
        XCTAssertEqual(store.state.publications["-100:42"]?.posterID, 7)
        try store.prunePublications(now: 1000 + PublicationReceipt.retention - 0.001)
        XCTAssertNotNil(store.state.publications["-100:42"])
        try store.prunePublications(now: 1000 + PublicationReceipt.retention)
        XCTAssertTrue(store.state.publications.isEmpty)
        XCTAssertTrue(try StateStore(directory: directory).state.publications.isEmpty)
    }

    func testFutureOwnershipDateIsPreservedForCallerAuthorizationCheck() throws {
        try record(at: 2000)
        try store.prunePublications(now: 1000)
        let receipt = try XCTUnwrap(store.state.publications["-100:42"])
        XCTAssertGreaterThan(receipt.createdAt, 1000)
        XCTAssertEqual(try StateStore(directory: directory).state.publications["-100:42"], receipt)
    }

    func testRemovalDeletesBothRecordsAndLeavesOtherChatsAndMessagesAlone() throws {
        for (chatID, messageID) in [(Int64(-100), Int64(42)), (-100, 43), (-101, 42)] {
            try store.recordPublication(chatID: chatID, messageID: messageID, posterID: 7, now: 1000)
            try store.recordReplyControl(chatID: chatID, messageID: messageID, posterID: 7, now: 1000)
        }
        try store.removePublication(chatID: -100, messageID: 42)
        let remaining: Set<String> = ["-100:43", "-101:42"]
        XCTAssertEqual(Set(store.state.publications.keys), remaining)
        XCTAssertEqual(Set(store.state.replyControls.keys), remaining)
        let reloaded = try StateStore(directory: directory)
        XCTAssertEqual(reloaded.state.publications, store.state.publications)
        XCTAssertEqual(reloaded.state.replyControls, store.state.replyControls)
        try store.removePublication(chatID: -100, messageID: 42)
        XCTAssertEqual(Set(store.state.publications.keys), remaining)
    }

    func testRemovalAlsoDeletesOrphanedReplyControl() throws {
        try store.recordReplyControl(chatID: -100, messageID: 42, posterID: 7, now: 1000)
        XCTAssertTrue(store.state.publications.isEmpty)
        try store.removePublication(chatID: -100, messageID: 42)
        XCTAssertTrue(try StateStore(directory: directory).state.replyControls.isEmpty)
        XCTAssertTrue(store.state.publications.isEmpty)
    }

    func testRemovalDoesNotPartiallyMutateMemoryWhenSavingFails() throws {
        try record()
        try store.recordReplyControl(chatID: -100, messageID: 42, posterID: 7, now: 1000)
        let publications = store.state.publications
        let controls = store.state.replyControls
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.removePublication(chatID: -100, messageID: 42))
        XCTAssertEqual(store.state.publications, publications)
        XCTAssertEqual(store.state.replyControls, controls)
    }

    func testCapacityNeverEvictsLiveOrFutureReceiptsAndDoesNotWriteDuringPreflight() throws {
        var state = BotState()
        for id in 1...20_000 {
            state.publications["-100:\(id)"] = PublicationReceipt(posterID: 7, createdAt: id == 1 ? 2000 : 1000)
        }
        try load(state)
        let data = try Data(contentsOf: path)
        XCTAssertFalse(store.canRecordPublication(now: 1000))
        XCTAssertEqual(try Data(contentsOf: path), data)
        XCTAssertThrowsError(try record(20_001)) {
            XCTAssertEqual($0 as? PublicationStateError, .capacityReached)
        }
        XCTAssertEqual(store.state.publications, state.publications)
        XCTAssertEqual(try Data(contentsOf: path), data)

        let boundary = 1000 + PublicationReceipt.retention
        XCTAssertTrue(store.canRecordPublication(now: boundary))
        XCTAssertEqual(store.state.publications.count, 20_000)
        try record(20_001, at: boundary)
        XCTAssertEqual(Set(store.state.publications.keys), ["-100:1", "-100:20001"])
        XCTAssertEqual(store.state.publications["-100:1"], state.publications["-100:1"])
        XCTAssertEqual(try StateStore(directory: directory).state.publications, store.state.publications)
    }

    func testRecordPrunesExpiredEntriesWithoutChangingReplyControls() throws {
        try record(41)
        try store.recordReplyControl(chatID: -100, messageID: 41, posterID: 7, now: 1000)
        try record(42, at: 1000 + PublicationReceipt.retention)
        XCTAssertEqual(Set(store.state.publications.keys), ["-100:42"])
        XCTAssertNotNil(store.state.replyControls["-100:41"])
    }

    func testInvalidReceiptInputsAndNonfiniteClockAreRejectedWithoutMutation() throws {
        try record()
        let data = try Data(contentsOf: path)
        for (chatID, messageID, posterID, now) in [
            (Int64(0), Int64(42), Int64(7), TimeInterval(1000)),
            (-100, 0, 7, 1000), (-100, -1, 7, 1000),
            (-100, 42, 0, 1000), (-100, 42, -1, 1000),
            (-100, 42, 7, .infinity), (-100, 42, 7, -.infinity), (-100, 42, 7, .nan),
        ] {
            XCTAssertThrowsError(try store.recordPublication(chatID: chatID, messageID: messageID,
                                                            posterID: posterID, now: now)) {
                XCTAssertEqual($0 as? PublicationStateError, .invalidReceipt)
            }
        }
        for now in [TimeInterval.infinity, -.infinity, .nan] {
            XCTAssertFalse(store.canRecordPublication(now: now))
            XCTAssertThrowsError(try store.prunePublications(now: now)) {
                XCTAssertEqual($0 as? PublicationStateError, .invalidReceipt)
            }
        }
        XCTAssertEqual(try Data(contentsOf: path), data)
    }

    func testPublicationSerializationContainsOnlyOwnershipMetadataEvenAfterMigration() throws {
        let button = InlineKeyboardButton(text: "Private video title", url: "https://example.com/private?secret=123")
        var state = BotState()
        state.replyControls["-100:42"] = ReplyControl(posterID: 7, createdAt: 1000, openButton: button)
        try legacyData(state).write(to: path)
        store = try StateStore(directory: directory)
        try store.removeReplyControl(chatID: -100, messageID: 42)
        let data = try Data(contentsOf: path)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let publications = try XCTUnwrap(json["publications"] as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(publications["-100:42"]).keys), ["posterID", "createdAt"])
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("https:"))
        XCTAssertFalse(encoded.contains("Private video title"))
        XCTAssertFalse(encoded.contains("secret=123"))
    }
}
