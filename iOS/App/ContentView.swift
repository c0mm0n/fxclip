import FxEngine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                if model.settingsWereUnreadable {
                    Section {
                        Label("settings.json could not be read. It was kept as settings.unreadable.json and the defaults are in use.",
                              systemImage: "exclamationmark.triangle")
                    }
                }
                ClipboardSection()
                CleaningSection()
                PreviewsSection()
                HowToSection()
                AboutSection()
            }
            .navigationTitle("fxclip")
        }
        .onAppear { model.checkClipboard() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.checkClipboard() }
        }
    }
}

private struct ClipboardSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in model.cleanPasted(text) }
            }
            .labelStyle(.titleAndIcon)
            if let r = model.result {
                Text(r.clean)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
                if r.telegram != r.clean {
                    Button {
                        model.copy(r.telegram)
                    } label: {
                        Label("Copy for Telegram", systemImage: "paperplane")
                    }
                }
            }
        } header: {
            Text("Clipboard")
        } footer: {
            if let r = model.result {
                Text(r.removed == 0 ? "Already clean, back on the clipboard." :
                     r.removed == 1 ? "1 tracker removed. The clean link is on the clipboard." :
                     "\(r.removed) trackers removed. The clean link is on the clipboard.")
            } else if model.clipboardHasLink {
                Text("There is a link on the clipboard. Paste cleans it and puts it back.")
            } else {
                Text("Copy a link, then come back and tap Paste.")
            }
        }
    }
}

private struct CleaningSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            Toggle(isOn: $model.user.trackersEverywhere) {
                VStack(alignment: .leading) {
                    Text("All websites")
                    Text("utm_*, fbclid, gclid…").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.builtins.trackers.sites, id: \.id) { site in
                Toggle(isOn: Binding(get: { model.siteEnabled(site) },
                                     set: { model.setSite(site, enabled: $0) })) {
                    VStack(alignment: .leading) {
                        Text(site.name)
                        Text(site.params.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        } header: {
            Text("Link cleaning")
        }
    }
}

private struct PreviewsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            ForEach(model.builtins.previews, id: \.id) { p in
                Toggle(isOn: Binding(get: { model.previewEnabled(p) },
                                     set: { model.setPreview(p, enabled: $0) })) {
                    VStack(alignment: .leading) {
                        Text(p.name)
                        Text(model.appNames(p)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("App previews")
        } footer: {
            Text("Preview links go through third-party mirrors so chats show the post. Only the app shown gets them.")
        }
    }
}

private struct HowToSection: View {
    var body: some View {
        Section {
            Label("Share a link › Clean link: copy it, or share it on. Telegram gets the preview link, every other app the clean link.",
                  systemImage: "square.and.arrow.up")
            Label("Shortcuts: “Clean link” and “Preview link” take text and return the result.",
                  systemImage: "square.2.layers.3d")
            Label("Automation: When Telegram is opened, Get Clipboard › Preview link › Copy to Clipboard. When Telegram is closed, the same with Clean link.",
                  systemImage: "gearshape.2")
        } header: {
            Text("How to use")
        } footer: {
            Text("iOS lets no app watch the clipboard, so cleaning happens when you ask for it.")
        }
        .font(.callout)
    }
}

private struct AboutSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            LabeledContent("Trackers removed", value: "\(model.trackersRemoved)")
            Button("Reset counter", role: .destructive) { model.resetCounter() }
        } footer: {
            Text("Links are cleaned on this device. No account, no analytics, no network access.")
        }
    }
}
