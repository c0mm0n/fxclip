import XCTest
import Foundation
@testable import FxClipCore

final class ClipboardToolsTests: XCTestCase {
    func testBundledToolsWinOverOlderPathToolsAndResolveLauncherSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func executable(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let binary = try executable("release/fxclip")
        let launcher = root.appendingPathComponent("launcher")
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: binary)
        let pathPaste = try executable("path/wl-paste")
        let pathCopy = try executable("path/wl-copy")
        let home = root.appendingPathComponent("home")
        let env = ["HOME": home.path, "PATH": pathPaste.deletingLastPathComponent().path]
        XCTAssertEqual(Commands.find("wl-paste", environment: env, executableURL: launcher), pathPaste.path)
        let installed = try executable("home/.local/lib/fxclip/wl-paste")
        XCTAssertEqual(Commands.find("wl-paste", environment: env, executableURL: launcher), installed.path)
        let bundled = try executable("release/libexec/wl-paste")
        let bundledCopy = try executable("release/libexec/wl-copy")
        XCTAssertEqual(Commands.find("wl-paste", environment: env, executableURL: launcher), bundled.path)
        XCTAssertEqual(Commands.find("wl-copy", environment: env, executableURL: launcher), bundledCopy.path)
        XCTAssertEqual(Commands.find(bundled.path, environment: env), bundled.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bundled.path)
        XCTAssertEqual(Commands.find("wl-paste", environment: env, executableURL: launcher), installed.path)
        try FileManager.default.removeItem(at: installed)
        XCTAssertEqual(Commands.find("wl-paste", environment: env, executableURL: launcher), pathPaste.path)
        try FileManager.default.removeItem(at: bundledCopy)
        XCTAssertEqual(Commands.find("wl-copy", environment: env, executableURL: launcher), pathCopy.path)
        _ = try executable("release/libexec/swaymsg")
        XCTAssertNil(Commands.find("swaymsg", environment: env, executableURL: launcher))
    }

    func testExtSupportVersionsAndFailedProbeDiagnosis() {
        for version in ["2.3.0", "2.3.0-1ubuntu1", "2.4.0", "3.0.0"] {
            XCTAssertEqual(ClipboardDiagnostics.supportsExtDataControl(version: "wl-clipboard \(version)\n"), true)
        }
        for version in ["2.2.1", "2.1.9", "1.9.9"] {
            XCTAssertEqual(ClipboardDiagnostics.supportsExtDataControl(version: "wl-clipboard \(version)"), false)
        }
        XCTAssertNil(ClipboardDiagnostics.supportsExtDataControl(version: "unavailable"))
        let ext = "interface: 'ext_data_control_manager_v1', version: 1, name: 42"
        XCTAssertEqual(ClipboardDiagnostics.advertisedProtocols(ext), ["ext_data_control_manager_v1"])
        let old = ClipboardDiagnostics.failure(version: "wl-clipboard 2.2.1", waylandInfo: ext)
        XCTAssertTrue(old.contains("needs wl-clipboard 2.3.0 or later"))
        XCTAssertTrue(old.contains("Reinstall"))
        XCTAssertTrue(old.contains("wayland-protocols >= 1.39"))
        XCTAssertTrue(ClipboardDiagnostics.failure(version: "wl-clipboard 2.2.1", waylandInfo: nil).contains("needs wl-clipboard 2.3.0"))
        XCTAssertTrue(ClipboardDiagnostics.failure(version: "wl-clipboard 2.3.0", waylandInfo: ext).contains("advertises data-control"))
        XCTAssertTrue(ClipboardDiagnostics.failure(version: "wl-clipboard 2.3.0", waylandInfo: "interface: 'wl_seat'").contains("offers neither"))
        XCTAssertTrue(ClipboardDiagnostics.failure(version: "wl-clipboard 2.3.0", waylandInfo: nil).contains("may offer neither"))
    }
}
