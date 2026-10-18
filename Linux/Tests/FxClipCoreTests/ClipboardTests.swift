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
        let write: (String, ClipboardSnapshot) -> Bool = { value, _ in
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
            controller.tick(engine: e, app: "org.telegram.desktop", read: { clip }, write: { _, _ in XCTFail("Must preserve non-text/rich prose"); return true })
        }
        XCTAssertFalse(ClipboardSnapshot.allows(["image/png"]))
    }

    func testRichBareURLCanBeCleaned() throws {
        let controller = ClipboardController()
        let clip = ClipboardSnapshot(types: ["text/html", "text/plain"], text: "https://instagram.com/p/123/?utm_source=test")
        var written: String?
        controller.tick(engine: try engine(), app: "TelegramDesktop", read: { clip }, write: { value, _ in written = value; return true })
        XCTAssertEqual(written, "https://zzinstagram.com/p/123/")
    }

    func testRichTextUsesTheSharedBareURLPolicy() throws {
        let e = try engine()
        for text in ["https://example.org/<tag>?utm_source=test", "https://example.org/'quoted'?utm_source=test", "See https://example.org/?utm_source=test"] {
            let clip = ClipboardSnapshot(types: ["text/plain", "text/html"], text: text)
            ClipboardController().tick(engine: e, app: nil, read: { clip }, write: { _, _ in XCTFail("Must preserve rich text"); return true })
        }
    }

    func testNewerCopyWinsImmediatelyBeforeWrite() throws {
        let controller = ClipboardController()
        let first = plain("https://x.com/example?utm_source=test")
        var reads = 0
        controller.tick(engine: try engine(), app: nil, read: {
            reads += 1
            return reads == 1 ? first : self.plain("new copy")
        }, write: { _, _ in XCTFail("Must not overwrite a newer copy"); return true })
        XCTAssertEqual(reads, 2)
    }

    func testImageClearsPreviouslyHeldPreview() throws {
        let controller = ClipboardController(), e = try engine()
        var clip: ClipboardSnapshot? = plain("https://x.com/example")
        controller.tick(engine: e, app: "org.telegram.desktop", read: { clip }, write: { value, _ in clip = self.plain(value); return true })
        clip = nil
        controller.tick(engine: e, app: nil, read: { clip }, write: { _, _ in XCTFail(); return true })
        clip = plain("new copy")
        controller.tick(engine: e, app: nil, read: { clip }, write: { _, _ in XCTFail(); return true })
    }

    func testSettingsChangeRestoresActivePreview() throws {
        let controller = ClipboardController()
        var clip = plain("https://x.com/example")
        let write: (String, ClipboardSnapshot) -> Bool = { value, _ in clip = self.plain(value); return true }
        controller.tick(engine: try engine(), app: "org.telegram.desktop", read: { clip }, write: write)
        var user = UserSettings()
        user.previews["x"] = .init(enabled: false, apps: [])
        controller.tick(engine: try engine(user), app: "org.telegram.desktop", read: { clip }, write: write)
        XCTAssertEqual(clip.text, "https://x.com/example")
    }

    func testRejectedFocusWriteKeepsOriginalForNextTick() throws {
        let controller = ClipboardController(), e = try engine()
        var clip = plain("https://x.com/example?utm_source=test")
        let write: (String, ClipboardSnapshot) -> Bool = { text, _ in clip = self.plain(text); return true }
        controller.tick(engine: e, app: "org.telegram.desktop", read: { clip }, write: write)
        XCTAssertEqual(clip.text, "https://fxtwitter.com/example")
        // Focus returned to Telegram during the final read: reject the restore.
        controller.tick(engine: e, app: "other", read: { clip }, write: { _, _ in false })
        controller.tick(engine: e, app: "org.telegram.desktop", read: { clip }, write: { _, _ in XCTFail("Preview already selected"); return false })
        // Leaving again must still restore the original clean link.
        controller.tick(engine: e, app: "other", read: { clip }, write: write)
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.unreadable.json").path))
        XCTAssertEqual(try String(contentsOf: path), "invalid")
        XCTAssertEqual(settings.engine.clean(input).text, input)
        // A partially written file must also survive and keep the last good rules.
        try Data("{".utf8).write(to: path)
        settings.reload()
        XCTAssertEqual(settings.engine.clean(input).text, input)
        try Data("{}".utf8).write(to: path)
        settings.reload()
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

    func testInvalidStartupPreservesExistingBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.json")
        let backup = dir.appendingPathComponent("settings.unreadable.json")
        try Data("first invalid save".utf8).write(to: path)
        _ = Settings(rules: try engine().rules, path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try String(contentsOf: backup), "first invalid save")
        try Data("second invalid save".utf8).write(to: path)
        let settings = Settings(rules: try engine().rules, path: path)
        XCTAssertEqual(try String(contentsOf: backup), "first invalid save")
        let timestamped = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("settings.unreadable-") }
        XCTAssertEqual(timestamped.count, 1)
        XCTAssertTrue(timestamped[0].lastPathComponent.hasPrefix("settings.unreadable-"))
        XCTAssertEqual(try String(contentsOf: timestamped[0]), "second invalid save")
        XCTAssertEqual(settings.engine.clean("https://example.org/?utm_source=test").text, "https://example.org/")
    }

    func testFocusAdapterFailureIsVisibleAndRateLimited() {
        var time: TimeInterval = 0, messages: [String] = [], status: Int32 = 127
        let focus = Focus(desktop: .kde, command: { _, _ in
            CommandResult(status: status, output: Data("123".utf8), error: "private desktop details")
        }, warning: { messages.append($0) }, now: { time })
        XCTAssertNil(focus.current())
        XCTAssertTrue(focus.lastError?.contains("kdotool getactivewindow failed (exit 127)") == true)
        for _ in 0..<10 { XCTAssertNil(focus.current()) }
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(messages[0].contains("private desktop details"))
        time = 61
        XCTAssertNil(focus.current())
        XCTAssertEqual(messages.count, 2)
        status = 0
        XCTAssertEqual(focus.current(), "123")
        XCTAssertNil(focus.lastError)
    }

    func testCommandTimeoutKillsGrandchildrenHoldingPipes() throws {
        for script in ["sleep 30 & wait", "sleep 30 & exit 0"] {
            let start = ProcessInfo.processInfo.systemUptime
            let result = Commands.run("sh", ["-c", script], timeout: 0.05)
            XCTAssertEqual(result.status, 9)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        }
        // Prove descendants were killed, rather than merely abandoning their pipes.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        _ = Commands.run("sh", ["-c", "(sleep 0.3; echo survived > \"$1\") & wait", "sh", marker.path], timeout: 0.05)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        // A blocked stdin writer must be bounded too.
        let start = ProcessInfo.processInfo.systemUptime
        _ = Commands.run("sh", ["-c", "sleep 30"], input: Data(repeating: 42, count: 1_000_000), timeout: 0.05)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testEscapedDescendantCannotBlockPipeDraining() throws {
        #if os(Linux)
        guard Commands.find("setsid") != nil else { throw XCTSkip("setsid unavailable") }
        let start = ProcessInfo.processInfo.systemUptime
        _ = Commands.run("sh", ["-c", "setsid sleep 1 & wait"], timeout: 0.05)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        #endif
    }

    func testWriterConfirmsOwnershipAndCancelsDelayedPredecessor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let selection = dir.appendingPathComponent("selection")
        try Data("original".utf8).write(to: selection)
        let clipboard = WaylandClipboard(copyCommand: "sh", copyArguments: ["-c",
            "value=$(cat); if [ \"$value\" = first ]; then sleep 0.8; else sleep 0.05; fi; printf '%s' \"$value\" > \"$1\"; sleep 1", "sh", selection.path], read: { _ in
                guard let text = try? String(contentsOf: selection) else { return nil }
                return self.plain(text)
            })
        XCTAssertFalse(clipboard.write("first", replacing: plain("original")))
        XCTAssertTrue(clipboard.write("second", replacing: plain("original")))
        // Success is synchronous: the new selection is already readable.
        XCTAssertEqual(try String(contentsOf: selection), "second")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(try String(contentsOf: selection), "second", "Timed-out predecessor must never publish late")
    }

    func testWriterRejectsNewCopyAndChangedFocusAtFinalRead() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        var focused = "telegram", changed = true
        let clipboard = WaylandClipboard(copyCommand: "sh", copyArguments: ["-c", "echo started > \"$1\"", "sh", marker.path], read: { _ in
            focused = "other"
            return self.plain(changed ? "newer copy" : "original")
        })
        XCTAssertFalse(clipboard.write("preview", replacing: plain("original")))
        changed = false; focused = "telegram"
        XCTAssertFalse(clipboard.write("preview", replacing: plain("original"), stillValid: { focused == "telegram" }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "No owner may start after copy/focus changed")
    }

    func testCommandTimeoutAndLargeOutput() {
        let result = Commands.run("sh", ["-c", "exec sleep 5"], timeout: 0.05)
        XCTAssertNotEqual(result.status, 0)
        let large = Commands.run("sh", ["-c", "head -c 100000 /dev/zero"], timeout: 2)
        XCTAssertEqual(large.status, 0)
        XCTAssertEqual(large.output.count, 100000)
    }
}
