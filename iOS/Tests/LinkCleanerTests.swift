import FxEngine
import UIKit
import XCTest
@testable import FxClipiOS

final class LinkCleanerTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults = UserDefaults(suiteName: "fxclip-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func rules() throws -> Rules {
        try LinkCleaner.bundledRules(Bundle(for: AppModel.self))
    }

    /// Whatever Preview link produced, Clean link restores (for anyone chaining the two in Shortcuts).
    func testCleanLinkUndoesPreviewLink() throws {
        let cleaner = LinkCleaner(rules: try rules(), user: UserSettings())
        for original in ["https://x.com/a/status/1", "https://instagram.com/p/abc/"] {
            let preview = cleaner.telegramPreview(original)
            XCTAssertNotEqual(preview, original)
            XCTAssertEqual(cleaner.clean(preview).text, original)
        }
        XCTAssertEqual(cleaner.clean("see https://FXTWITTER.com/a/status/1?s=20 and https://fxtwitter.com.evil/x").text,
                       "see https://x.com/a/status/1 and https://fxtwitter.com.evil/x")
        XCTAssertEqual(cleaner.clean("http://fxtwitter.com/a/status/1?s=20").text, "https://x.com/a/status/1")
        XCTAssertEqual(cleaner.clean("(https://zzinstagram.com/p/abc/)").text, "(https://instagram.com/p/abc/)")
        for nested in ["https://example.com/?next=https://fxtwitter.com/a&sig=abc",
                       "https://example.com/?next=(https://fxtwitter.com/a)&sig=abc"] {
            XCTAssertEqual(cleaner.clean(nested).text, nested)
        }
        // Whatever Preview link rewrites, Clean link undoes.
        for text in ["link:https://x.com/a/status/1", "`https://x.com/a/status/1`", "see (https://instagram.com/p/abc/)."] {
            XCTAssertEqual(cleaner.clean(cleaner.telegramPreview(text)).text, text)
        }
    }

    func testSettingsMovedAsideByAnotherProcessStillWarn() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("settings.json"))
        let ext = SharedStore(directory: dir, defaults: defaults)   // the extension reads first
        _ = ext.load()
        XCTAssertTrue(ext.movedAside)
        let app = SharedStore(directory: dir, defaults: defaults)
        _ = app.load()
        XCTAssertTrue(app.movedAside)
        try app.save(UserSettings())
        let later = SharedStore(directory: dir, defaults: defaults)
        _ = later.load()
        XCTAssertFalse(later.movedAside)
    }

    func testCustomPreviewRoundTripsToPrimarySourceAndShareDestinations() throws {
        let rules = try rules()
        var user = UserSettings()
        for preview in rules.previews {
            let host = "custom-\(preview.id).example"
            user.previews[preview.id] = .init(enabled: true, apps: ["telegram"],
                                             targetHost: " \t\(host.uppercased()).\n")
            let cleaner = LinkCleaner(rules: rules, user: user)
            // Source aliases restore to the built-in rule's primary source, not a guessed alias.
            let original = "https://\(try XCTUnwrap(preview.from.last))/a/1"
            let native = "https://\(try XCTUnwrap(preview.from.first))/a/1"
            let mirrored = cleaner.telegramPreview(original)
            XCTAssertEqual(mirrored, "https://\(host)/a/1")
            let clean = cleaner.clean(mirrored + "?utm_source=share").text
            XCTAssertEqual(clean, native)

            let item = DestinationLink(clean: clean, cleaner: cleaner)
            let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            for destination: UIActivity.ActivityType? in [nil, .mail, .copyToPasteboard] {
                XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: destination) as? URL,
                               URL(string: native))
            }
            XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: .init("ph.telegra.Telegraph.Share")) as? URL,
                           URL(string: mirrored))
        }
    }

    func testCustomPreviewStillRestoresAfterDisablingOrRemovingApps() throws {
        let rules = try rules()
        var user = UserSettings()
        user.previews["x"] = .init(enabled: true, apps: ["telegram"], targetHost: "Custom.Example.")
        let native = "https://x.com/a/status/1"
        let mirrored = LinkCleaner(rules: rules, user: user).telegramPreview(native)
        XCTAssertEqual(mirrored, "https://custom.example/a/status/1")

        for (enabled, apps) in [(false, ["telegram"]), (true, []), (false, [])] {
            user.previews["x"] = .init(enabled: enabled, apps: apps, targetHost: "Custom.Example.")
            let cleaner = LinkCleaner(rules: rules, user: user)
            XCTAssertEqual(cleaner.telegramPreview(native), native)
            XCTAssertEqual(cleaner.clean(mirrored).text, native)
            XCTAssertEqual(cleaner.clean("http://CUSTOM.example/a/status/1?s=20").text, native)
            XCTAssertEqual(cleaner.clean("https://fxtwitter.com/a/status/1").text, native)
        }
    }

    func testInvalidAndUnknownCustomProvidersAreIgnored() throws {
        let rules = try rules()
        for invalid in ["https://custom.example", "custom.example/path", "custom.example:8443", "custom.example.."] {
            var user = UserSettings()
            user.previews["x"] = .init(enabled: true, apps: ["telegram"], targetHost: invalid)
            user.previews["unknown"] = .init(enabled: true, apps: ["telegram"], targetHost: "unknown.example")
            let cleaner = LinkCleaner(rules: rules, user: user)
            XCTAssertEqual(cleaner.clean("https://custom.example/a").text, "https://custom.example/a")
            XCTAssertEqual(cleaner.clean("https://unknown.example/a").text, "https://unknown.example/a")
            XCTAssertEqual(cleaner.telegramPreview("https://x.com/a"), "https://fxtwitter.com/a")
            XCTAssertEqual(cleaner.clean("https://fxtwitter.com/a").text, "https://x.com/a")
        }
    }

    func testAmbiguousCustomProviderIsNotRestoredToAnArbitrarySource() throws {
        var user = UserSettings()
        user.previews["x"] = .init(enabled: true, apps: ["telegram"], targetHost: "shared.example")
        // Disabled rules still count: an old preview could have come from either website.
        user.previews["instagram"] = .init(enabled: false, apps: [], targetHost: " SHARED.Example. ")
        let rules = try rules()
        for ordered in [rules, { var reversed = rules; reversed.previews.reverse(); return reversed }()] {
            let cleaner = LinkCleaner(rules: ordered, user: user)
            XCTAssertEqual(cleaner.clean("https://shared.example/a?utm_source=share").text, "https://shared.example/a")
            XCTAssertEqual(cleaner.clean("https://fxtwitter.com/a").text, "https://x.com/a")
            XCTAssertEqual(cleaner.clean("https://zzinstagram.com/a").text, "https://instagram.com/a")
        }
    }

    func testCustomProviderCannotRewriteAnOriginalSiteIntoAnotherSite() throws {
        var user = UserSettings()
        user.previews["instagram"] = .init(enabled: true, apps: ["telegram"], targetHost: "x.com")
        let cleaner = LinkCleaner(rules: try rules(), user: user)
        XCTAssertEqual(cleaner.clean("https://x.com/a/status/1").text, "https://x.com/a/status/1")
    }

    func testCustomProviderCannotOverrideBuiltInProviderIdentity() throws {
        var user = UserSettings()
        user.previews["x"] = .init(enabled: true, apps: ["telegram"], targetHost: "ZZINSTAGRAM.com.")
        let cleaner = LinkCleaner(rules: try rules(), user: user)
        XCTAssertEqual(cleaner.clean("https://zzinstagram.com/p/abc/").text, "https://instagram.com/p/abc/")
        XCTAssertEqual(cleaner.clean("https://fxtwitter.com/a").text, "https://x.com/a")
    }

    func testTelegramShareGetsThePreviewOtherDestinationsTheCleanLink() throws {
        let cleaner = LinkCleaner(rules: try rules(), user: UserSettings())
        let clean = cleaner.clean("https://x.com/a/status/1?s=20&t=abc").text
        XCTAssertEqual(clean, "https://x.com/a/status/1")

        let item = DestinationLink(clean: clean, cleaner: cleaner)
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        let telegram = UIActivity.ActivityType("ph.telegra.Telegraph.Share")
        XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: telegram) as? URL,
                       URL(string: "https://fxtwitter.com/a/status/1"))
        for other in [UIActivity.ActivityType.mail, .copyToPasteboard, .message] {
            XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: other) as? URL, URL(string: clean))
        }
        XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: nil) as? URL, URL(string: clean))
    }

    func testTextWithALinkIsSharedAsText() throws {
        let cleaner = LinkCleaner(rules: try rules(), user: UserSettings())
        let text = cleaner.clean("look https://x.com/a?s=1").text
        let item = DestinationLink(clean: text, cleaner: cleaner)
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        XCTAssertEqual(item.activityViewController(sheet, itemForActivityType: .init("ph.telegra.Telegraph.Share")) as? String,
                       "look https://fxtwitter.com/a")
    }

    func testDisabledPreviewIsRespected() throws {
        var user = UserSettings()
        user.previews["x"] = .init(enabled: false, apps: ["telegram"])
        let cleaner = LinkCleaner(rules: try rules(), user: user)
        XCTAssertEqual(cleaner.telegramPreview("https://x.com/a"), "https://x.com/a")
        XCTAssertEqual(cleaner.telegramPreview("https://instagram.com/p/a"), "https://zzinstagram.com/p/a")
    }

    func testSettingsRoundTripAndCounter() throws {
        let store = SharedStore(directory: dir, defaults: defaults)
        var user = store.load()
        XCTAssertEqual(user, UserSettings())
        user.disabledSites.insert("youtube")
        try store.save(user)
        XCTAssertEqual(SharedStore(directory: dir, defaults: defaults).load(), user)

        store.record(2)
        store.record(0)
        store.record(3)
        XCTAssertEqual(store.trackersRemoved, 5)
        store.resetCounter()
        XCTAssertEqual(store.trackersRemoved, 0)
    }

    func testUnreadableSettingsAreMovedAside() throws {
        let store = SharedStore(directory: dir, defaults: defaults)
        try Data("{ not json".utf8).write(to: store.file)
        XCTAssertEqual(store.load(), UserSettings())
        XCTAssertTrue(store.movedAside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.unreadable.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
    }
}
