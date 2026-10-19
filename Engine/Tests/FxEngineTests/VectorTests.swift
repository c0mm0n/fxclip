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

    func testKDETelegramWindowTokenGetsPreviewButSimilarIdentifiersDoNot() {
        let link = "https://x.com/CerfiaFR/status/2103787353680851028"
        let tokenizedTelegram = "org.telegram.desktop._bf9659469f87789ad9ca692ee16de825"
        XCTAssertEqual(engine.preview(engine.clean(link).text, forBundleID: tokenizedTelegram),
                       "https://fxtwitter.com/CerfiaFR/status/2103787353680851028")

        for identifier in [
            "org.telegram.desktop._bf9659469f87789ad9ca692ee16de82", // token too short
            "org.telegram.desktop._bf9659469f87789ad9ca692ee16de8250", // token too long
            "org.telegram.desktop.fake_bf9659469f87789ad9ca692ee16de825", // wrong separator
            "org.telegram.desktop._bf9659469f87789ad9ca692ee16de82zz", // non-hex token
            "org.telegram.desktop.evil._bf9659469f87789ad9ca692ee16de825",
            "org.telegram.desktop._bf9659469f87789ad9ca692ee16de825.other",
            "other.desktop._bf9659469f87789ad9ca692ee16de825",
        ] {
            XCTAssertEqual(engine.preview(engine.clean(link).text, forBundleID: identifier), link, identifier)
        }
    }

    func testKDETelegramTokenMatchingIsCaseInsensitiveAndRequiresLinuxRule() {
        let canonicalLink = "https://x.com/CerfiaFR/status/2103787353680851028"
        let mixedCaseToken = "ORG.TELEGRAM.DESKTOP._BF9659469F87789AD9CA692EE16DE825"
        XCTAssertEqual(engine.preview(canonicalLink, forBundleID: mixedCaseToken),
                       "https://fxtwitter.com/CerfiaFR/status/2103787353680851028")

        let telegram = try! XCTUnwrap(engine.rules.apps.first { $0.id == "telegram" })
        let withoutLinuxRule = Rules.App(id: telegram.id, name: telegram.name,
                                         bundleIDs: telegram.bundleIDs + ["org.telegram.desktop"],
                                         linux: [], windows: ["org.telegram.desktop"])
        let customRules = Rules(version: engine.rules.version,
                                trackers: engine.rules.trackers,
                                previews: engine.rules.previews,
                                apps: [withoutLinuxRule])
        let customEngine = Engine(rules: customRules)
        XCTAssertEqual(customEngine.preview(canonicalLink, forBundleID: mixedCaseToken), canonicalLink)
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
