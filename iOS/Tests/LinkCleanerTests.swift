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
