import FxEngine
import SwiftUI
import XCTest
@testable import FxClipiOS

/// Drives the share sheet's model and snapshots both screens, light and dark, into
/// $FXCLIP_SCREENS when set (CI passes TEST_RUNNER_FXCLIP_SCREENS). Nothing is compared:
/// the pictures are for a person to look at.
@MainActor
final class ScreenTests: XCTestCase {
    private let link = "https://x.com/CerfiaFR/status/2103787353680851028?s=20&t=abc"

    func testShareSheetCleansAndOffersThePreview() throws {
        let model = ShareModel()
        model.load(link)
        XCTAssertEqual(model.clean, "https://x.com/CerfiaFR/status/2103787353680851028")
        XCTAssertEqual(model.telegram, "https://fxtwitter.com/CerfiaFR/status/2103787353680851028")
        XCTAssertEqual(model.removed, 2)
        XCTAssertFalse(model.failed)
        try snapshot(ShareView(model: model), "share")

        let empty = ShareModel()
        empty.load(nil)
        XCTAssertTrue(empty.failed)
    }

    func testAppAfterPaste() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SharedStore(directory: dir, defaults: UserDefaults(suiteName: "fxclip-screens-\(UUID().uuidString)"))
        let model = AppModel(store: store)
        model.cleanPasted(link)
        XCTAssertEqual(model.result?.removed, 2)
        XCTAssertEqual(UIPasteboard.general.string, "https://x.com/CerfiaFR/status/2103787353680851028")
        XCTAssertEqual(model.trackersRemoved, 2)
        try snapshot(ContentView().environmentObject(model), "app-pasted")
    }

    private func snapshot<V: View>(_ view: V, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["FXCLIP_SCREENS"], !dir.isEmpty else { return }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (style, suffix) in [(UIUserInterfaceStyle.light, ""), (.dark, "-dark")] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView: view)
            window.isHidden = false
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(suffix).png"))
        }
    }
}
