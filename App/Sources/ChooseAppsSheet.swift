import AppKit
import FxEngine
import SwiftUI

/// Picks the apps a preview link applies in.
struct ChooseAppsSheet: View {
    let preview: Rules.Preview
    @EnvironmentObject var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    /// Known apps first, then installed suggestions not added yet.
    private var candidates: [Rules.App] {
        store.knownApps + suggestedApps.filter { s in store.app(s.id) == nil && installedURL(s) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(preview.name) → \(store.previewTargetHost(for: preview))").font(.headline)
            Text("Apply in these apps:").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(candidates, id: \.id) { app in
                    Toggle(isOn: binding(app)) {
                        HStack(spacing: 6) {
                            AppIcon(app: app)
                            Text(app.name)
                            if app.bundleIDs.count > 1 {
                                Text("(all versions)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Button("Add another app…", action: pickApp)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func binding(_ app: Rules.App) -> Binding<Bool> {
        Binding(
            get: { store.setting(for: preview).apps.contains(app.id) },
            set: { on in
                store.addApp(app)
                var apps = store.setting(for: preview).apps.filter { $0 != app.id }
                if on { apps.append(app.id) }
                store.setPreview(preview, apps: apps)
            }
        )
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        // Telegram.app picked by hand is the known "telegram" entry, not a second one.
        let app = (store.knownApps + suggestedApps).first { $0.bundleIDs.contains(id) }
            ?? Rules.App(id: id, name: name, bundleIDs: [id])
        store.addApp(app)
        store.setPreview(preview, apps: store.setting(for: preview).apps.filter { $0 != app.id } + [app.id])
    }
}
