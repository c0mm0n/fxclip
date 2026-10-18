import AppKit
import FxEngine
import SwiftUI

/// Chat apps offered in "Choose apps…" when installed. Never enabled on their own.
let suggestedApps: [Rules.App] = [
    .init(id: "com.hnc.Discord", name: "Discord", bundleIDs: ["com.hnc.Discord"]),
    .init(id: "net.whatsapp.WhatsApp", name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
    .init(id: "com.tinyspeck.slackmacgap", name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
    .init(id: "org.whispersystems.signal-desktop", name: "Signal", bundleIDs: ["org.whispersystems.signal-desktop"]),
    .init(id: "com.apple.MobileSMS", name: "Messages", bundleIDs: ["com.apple.MobileSMS"]),
]

func installedURL(_ app: Rules.App) -> URL? {
    app.bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
}

/// The app's own icon, or a generic one when it isn't installed.
struct AppIcon: View {
    let app: Rules.App
    var size: CGFloat = 16

    var body: some View {
        let image = installedURL(app).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        Image(nsImage: image).resizable().frame(width: size, height: size)
    }
}
