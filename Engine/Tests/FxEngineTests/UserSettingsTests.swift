import Foundation
import XCTest
@testable import FxEngine

/// The user's choices, layered over the built-in rules.
final class UserSettingsTests: XCTestCase {
    let builtins = try! Rules.load(Data(contentsOf: VectorTests.shared.appendingPathComponent("rules.json")))
    let telegram = "ru.keepcoder.Telegram"

    func engine(_ edit: (inout UserSettings) -> Void) -> Engine {
        var s = UserSettings()
        edit(&s)
        return Engine(rules: builtins.applying(s))
    }

    func testDefaultsEqualBuiltins() {
        let e = engine { _ in }
        XCTAssertEqual(e.clean("https://x.com/a?s=1&utm_source=b").text, "https://x.com/a")
        XCTAssertEqual(e.preview("https://x.com/a", forBundleID: telegram), "https://fxtwitter.com/a")
    }

    func testEverywhereOff() {
        let e = engine { $0.trackersEverywhere = false }
        XCTAssertEqual(e.clean("https://example.com/?utm_source=a&fbclid=b").text, "https://example.com/?utm_source=a&fbclid=b")
        XCTAssertEqual(e.clean("https://youtu.be/x?si=1").text, "https://youtu.be/x")
    }

    func testSiteOff() {
        let e = engine { $0.disabledSites = ["youtube", "amazon"] }
        XCTAssertEqual(e.clean("https://youtu.be/x?si=1&utm_source=a").text, "https://youtu.be/x?si=1")
        XCTAssertEqual(e.clean("https://www.amazon.fr/dp/B0/ref=sr_1?tag=a").text, "https://www.amazon.fr/dp/B0/ref=sr_1?tag=a")
    }

    func testNeverCleanTrailingDot() {
        let e = engine { $0.neverClean = [SkipHost(host: "example.com.", subdomains: false)] }
        XCTAssertEqual(e.clean("https://example.com/?utm_source=a").text, "https://example.com/?utm_source=a")
        XCTAssertEqual(SkipHost.canonical("Example.COM."), "example.com")
    }

    /// A file missing some keys keeps what it has instead of being discarded.
    func testPartialFileDecodes() throws {
        let json = #"{"previews":{"x":{"enabled":false,"apps":[]}}}"#
        let s = try JSONDecoder().decode(UserSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.previews["x"]?.enabled, false)
        XCTAssertTrue(s.trackersEverywhere)
        XCTAssertEqual(s.addedApps, [])
    }

    func testNeverClean() {
        let e = engine { $0.neverClean = [SkipHost(host: "example.com", subdomains: false), SkipHost(host: "corp.io", subdomains: true)] }
        XCTAssertEqual(e.clean("https://example.com/?utm_source=a").text, "https://example.com/?utm_source=a")
        XCTAssertEqual(e.clean("https://www.example.com/?utm_source=a").text, "https://www.example.com/")
        XCTAssertEqual(e.clean("https://intra.corp.io/?utm_source=a").text, "https://intra.corp.io/?utm_source=a")
        XCTAssertEqual(e.clean("https://notcorp.io/?utm_source=a").text, "https://notcorp.io/")
    }

    func testPreviewOffAndPerApp() {
        let off = engine { $0.previews["x"] = .init(enabled: false, apps: ["telegram"]) }
        XCTAssertEqual(off.preview("https://x.com/a", forBundleID: telegram), "https://x.com/a")
        XCTAssertEqual(off.preview("https://instagram.com/p/a", forBundleID: telegram), "https://zzinstagram.com/p/a")

        let discord = "com.hnc.Discord"
        let moved = engine {
            $0.addedApps = [Rules.App(id: discord, name: "Discord", bundleIDs: [discord])]
            $0.previews["x"] = .init(enabled: true, apps: [discord])
        }
        XCTAssertEqual(moved.preview("https://x.com/a", forBundleID: discord), "https://fxtwitter.com/a")
        XCTAssertEqual(moved.preview("https://x.com/a", forBundleID: telegram), "https://x.com/a")
    }

    func testSettingsRoundTrip() throws {
        var s = UserSettings()
        s.disabledSites = ["reddit"]
        s.neverClean = [SkipHost(host: "a.com", subdomains: true)]
        s.previews["instagram"] = .init(enabled: false, apps: [])
        let back = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}
