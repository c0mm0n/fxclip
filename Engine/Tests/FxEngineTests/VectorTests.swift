import Foundation
import XCTest
@testable import FxEngine

/// Shared/vectors.json comes from the legacy fxclip binary: the engine must match it byte for byte.
final class VectorTests: XCTestCase {
    static let shared = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Shared")

    struct Vector: Decodable { let input, clean, telegram: String }
    struct File: Decodable { let vectors: [Vector] }

    let engine = Engine(rules: try! Rules.load(Data(contentsOf: shared.appendingPathComponent("rules.json"))))
    let vectors = try! JSONDecoder().decode(File.self, from: Data(contentsOf: shared.appendingPathComponent("vectors.json"))).vectors

    func testCleanMatchesLegacy() {
        XCTAssertGreaterThan(vectors.count, 30)
        for v in vectors {
            XCTAssertEqual(engine.clean(v.input).text, v.clean, "input: \(v.input)")
        }
    }

    func testTelegramPreviewMatchesLegacy() {
        for bundleID in ["ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram"] {
            for v in vectors {
                XCTAssertEqual(engine.preview(engine.clean(v.input).text, forBundleID: bundleID), v.telegram, "input: \(v.input)")
            }
        }
    }

    func testOtherAppsGetNoPreview() {
        for v in vectors {
            let cleaned = engine.clean(v.input).text
            XCTAssertEqual(engine.preview(cleaned, forBundleID: "com.apple.Safari"), cleaned)
        }
    }

    func testRemovedCount() {
        XCTAssertEqual(engine.clean("https://x.com/a?s=1&t=2&keep=3").removed, 2)
        XCTAssertEqual(engine.clean("https://www.amazon.fr/dp/B0/ref=sr_1?tag=a&th=1").removed, 2)
        XCTAssertEqual(engine.clean("https://github.com/a?ref=main").removed, 0)
        XCTAssertEqual(engine.clean("a https://x.com/a?s=1 b https://youtu.be/x?si=1").removed, 2)
    }

    func testBareURL() {
        XCTAssertTrue(isBareURL("  https://x.com/a?s=1\n"))
        XCTAssertFalse(isBareURL("see https://x.com/a"))
    }
}
