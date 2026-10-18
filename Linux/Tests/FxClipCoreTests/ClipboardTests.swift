import XCTest
import Foundation
import FxEngine
@testable import FxClipCore

final class ClipboardTests: XCTestCase {
    func engine(_ user: UserSettings = UserSettings()) throws -> Engine {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Engine(rules: try Rules.load(Data(contentsOf: root.appendingPathComponent("Shared/rules.json"))).applying(user))
    }
    func plain(_ text: String) -> ClipboardSnapshot { ClipboardSnapshot(types: ["text/plain"], text: text) }

    func testCleanPreviewRestoreAndOwnWrites() throws {
        let e = try engine(), controller = ClipboardController()
        var clip = plain("https://x.com/example/status/123?utm_source=test")
        var writes: [String] = []
        let read = { clip }
        let write: (String) -> Bool = { value in
            writes.append(value)
            clip = ClipboardSnapshot(types: ["text/plain", "text/plain;charset=utf-8", "UTF8_STRING"], text: value)
            return true
        }
        controller.tick(engine: e, app: nil, read: read, write: write)
        controller.tick(engine: e, app: "ORG.TELEGRAM.DESKTOP", read: read, write: write)
        for _ in 0..<5 { controller.tick(engine: e, app: "org.telegram.desktop", read: read, write: write) }
        controller.tick(engine: e, app: "other", read: read, write: write)
        XCTAssertEqual(writes, ["https://x.com/example/status/123", "https://fxtwitter.com/example/status/123", "https://x.com/example/status/123"])
    }

    func testUnsafeTypesAndRichProseRemainUntouched() throws {
        let e = try engine()
        for types: Set<String> in [["text/plain", "image/png"], ["text/plain", "text/uri-list"], ["text/plain", "application/octet-stream"], ["text/plain", "text/html"], ["text/plain", "application/rtf"]] {
            let controller = ClipboardController()
            let clip = ClipboardSnapshot(types: types, text: "Look https://x.com/example?utm_source=test")
            controller.tick(engine: e, app: "org.telegram.desktop", read: { clip }, write: { _ in XCTFail("Must preserve non-text/rich prose"); return true })
        }
        XCTAssertFalse(ClipboardSnapshot.allows(["image/png"]))
    }

    func testRichBareURLCanBeCleaned() throws {
        let controller = ClipboardController()
        let clip = ClipboardSnapshot(types: ["text/html", "text/plain"], text: "https://instagram.com/p/123/?utm_source=test")
        var written: String?
        controller.tick(engine: try engine(), app: "TelegramDesktop", read: { clip }, write: { written = $0; return true })
        XCTAssertEqual(written, "https://zzinstagram.com/p/123/")
    }

    func testRichTextUsesTheSharedBareURLPolicy() throws {
        let e = try engine()
        for text in ["https://example.org/<tag>?utm_source=test", "https://example.org/'quoted'?utm_source=test", "See https://example.org/?utm_source=test"] {
            let clip = ClipboardSnapshot(types: ["text/plain", "text/html"], text: text)
            ClipboardController().tick(engine: e, app: nil, read: { clip }, write: { _ in XCTFail("Must preserve rich text"); return true })
        }
    }

    func testNewerCopyWinsImmediatelyBeforeWrite() throws {
        let controller = ClipboardController()
        let first = plain("https://x.com/example?utm_source=test")
        var reads = 0
        controller.tick(engine: try engine(), app: nil, read: {
            reads += 1
            return reads == 1 ? first : self.plain("new copy")
        }, write: { _ in XCTFail("Must not overwrite a newer copy"); return true })
        XCTAssertEqual(reads, 2)
    }

    func testImageClearsPreviouslyHeldPreview() throws {
        let controller = ClipboardController(), e = try engine()
        var clip: ClipboardSnapshot? = plain("https://x.com/example")
        controller.tick(engine: e, app: "org.telegram.desktop", read: { clip }, write: { clip = self.plain($0); return true })
        clip = nil
        controller.tick(engine: e, app: nil, read: { clip }, write: { _ in XCTFail(); return true })
        clip = plain("new copy")
        controller.tick(engine: e, app: nil, read: { clip }, write: { _ in XCTFail(); return true })
    }

    func testSettingsChangeRestoresActivePreview() throws {
        let controller = ClipboardController()
        var clip = plain("https://x.com/example")
        let write: (String) -> Bool = { clip = self.plain($0); return true }
        controller.tick(engine: try engine(), app: "org.telegram.desktop", read: { clip }, write: write)
        var user = UserSettings()
        user.previews["x"] = .init(enabled: false, apps: [])
        controller.tick(engine: try engine(user), app: "org.telegram.desktop", read: { clip }, write: write)
        XCTAssertEqual(clip.text, "https://x.com/example")
    }

    func testSettingsReloadMissingInvalidAndReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.json")
        let settings = Settings(rules: try engine().rules, path: path)
        let input = "https://example.org/?utm_source=test"
        XCTAssertEqual(settings.engine.clean(input).text, "https://example.org/")
        try Data("{\"trackersEverywhere\":false}".utf8).write(to: path, options: .atomic)
        settings.reload()
        XCTAssertEqual(settings.engine.clean(input).text, input)
        try Data("invalid".utf8).write(to: path, options: .atomic)
        settings.reload()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.unreadable.json").path))
        XCTAssertEqual(settings.engine.clean(input).text, "https://example.org/")
        try Data("{\"trackersEverywhere\":false}".utf8).write(to: path)
        settings.reload()
        try FileManager.default.removeItem(at: path)
        settings.reload()
        XCTAssertEqual(settings.engine.clean(input).text, "https://example.org/")
    }

    func testDesktopAndFocusedSwayNodes() {
        XCTAssertEqual(Desktop.detect(["SWAYSOCK": "socket"]), .sway)
        XCTAssertEqual(Desktop.detect(["HYPRLAND_INSTANCE_SIGNATURE": "instance"]), .hyprland)
        XCTAssertEqual(Desktop.detect(["XDG_CURRENT_DESKTOP": "ubuntu:GNOME"]), .gnome)
        XCTAssertEqual(Desktop.detect(["XDG_CURRENT_DESKTOP": "KDE"]), .kde)
        XCTAssertEqual(Focus.swayApp(["floating_nodes": [["focused": true, "app_id": "org.telegram.desktop"]]]), "org.telegram.desktop")
        XCTAssertEqual(Focus.swayApp(["nodes": [["focused": true, "window_properties": ["class": "TelegramDesktop"]]]]), "TelegramDesktop")
        XCTAssertNil(Focus.swayApp(["focused": false, "app_id": "other"]))
    }

    func testCommandTimeoutAndLargeOutput() {
        let result = Commands.run("sh", ["-c", "exec sleep 5"], timeout: 0.05)
        XCTAssertNotEqual(result.status, 0)
        let large = Commands.run("sh", ["-c", "head -c 100000 /dev/zero"], timeout: 2)
        XCTAssertEqual(large.status, 0)
        XCTAssertEqual(large.output.count, 100000)
    }
}
