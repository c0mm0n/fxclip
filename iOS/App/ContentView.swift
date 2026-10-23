import FxEngine
import SwiftUI

/// Home: the one gesture (Paste), its result and the counter; settings one level down,
/// the way the Mac app keeps them on their own pages.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if model.settingsWereUnreadable {
                    Section {
                        Label("settings.json could not be read. It was kept as settings.unreadable.json and the defaults are in use.",
                              systemImage: "exclamationmark.triangle")
                    }
                }
                PasteSection()
                if let r = model.result { ResultSection(result: r) }
                CounterSection()
                Section {
                    NavigationLink { CleaningPage() } label: {
                        IconRow(title: "Link cleaning", icon: "eye.slash.fill", color: .red, value: model.cleaningSummary)
                    }
                    NavigationLink { PreviewsPage() } label: {
                        IconRow(title: "App previews", icon: "link", color: .blue, value: model.previewsSummary)
                    }
                    NavigationLink { HowToPage() } label: {
                        IconRow(title: "Clean from any app", icon: "square.and.arrow.up", color: .orange)
                    }
                } footer: {
                    Text("Links are cleaned on this iPhone. No account, no analytics, no network access.")
                }
            }
            .navigationTitle("fxclip")
        }
        .onAppear { model.checkClipboard() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.checkClipboard() }
        }
    }
}

private struct PasteSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            if model.result != nil {
                // After a paste the result says it all; Paste stays at hand for the next link.
                HStack {
                    Text("Another link?").foregroundStyle(.secondary)
                    Spacer()
                    pasteButton
                }
            } else {
                hero
            }
        }
    }

    private var hero: some View {
            VStack(spacing: 14) {
                Image(systemName: model.clipboardHasLink ? "link" : "doc.on.clipboard")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(spacing: 4) {
                    Text(model.clipboardHasLink ? "A link is on your clipboard" : "Copy a link, then come back")
                        .font(.headline)
                    Text("Paste cleans it and puts the clean link back on the clipboard.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                pasteButton
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first else { return }
            Task { @MainActor in model.cleanPasted(text) }
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
    }
}

private struct ResultSection: View {
    @EnvironmentObject private var model: AppModel
    let result: AppModel.CleanResult

    var body: some View {
        Section {
            LinkResultView(clean: result.clean, removed: result.removed, removedNames: result.removedNames)
            if result.telegram != result.clean {
                Button {
                    model.copy(result.telegram)
                } label: {
                    Label("Copy for Telegram", systemImage: "paperplane")
                }
            }
        } header: {
            Text("On your clipboard")
        }
    }
}

private struct CounterSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.trackersRemoved)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(model.trackersRemoved == 1 ? "tracker removed" : "trackers removed")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

/// A settings row with a colored icon tile, as in the Mac sidebar and iOS Settings.
private struct IconRow: View {
    let title: String
    let icon: String
    let color: Color
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer()
            if let value {
                Text(value).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: pages

struct CleaningPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section {
                Toggle(isOn: $model.user.trackersEverywhere) {
                    SettingLabel(title: "All websites", detail: "utm_*, fbclid, gclid…")
                }
            } footer: {
                Text("Common trackers, removed from every link.")
            }
            Section {
                ForEach(model.builtins.trackers.sites, id: \.id) { site in
                    Toggle(isOn: Binding(get: { model.siteEnabled(site) },
                                         set: { model.setSite(site, enabled: $0) })) {
                        SettingLabel(title: site.name, detail: site.params.joined(separator: ", "))
                    }
                }
            } header: {
                Text("Per site")
            } footer: {
                Text("Useful parts of a link, such as a YouTube timestamp, are always kept.")
            }
            Section {
                LabeledContent("Trackers removed", value: "\(model.trackersRemoved)")
                Button("Reset counter", role: .destructive) { model.resetCounter() }
            }
        }
        .navigationTitle("Link cleaning")
    }
}

struct PreviewsPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(model.builtins.previews, id: \.id) { p in
                    Toggle(isOn: Binding(get: { model.previewEnabled(p) },
                                         set: { model.setPreview(p, enabled: $0) })) {
                        SettingLabel(title: p.name, detail: "→ \(p.to) in \(model.appNames(p))")
                    }
                }
            } footer: {
                Text("Chats show a real preview of X and Instagram posts when the link goes through these mirrors. Only the apps named get the preview link; every other app gets the clean original. The mirrors are run by third parties and see a link only when someone opens it.")
            }
        }
        .navigationTitle("App previews")
    }
}

struct HowToPage: View {
    var body: some View {
        List {
            Section {
                Step(1, "In Safari, X or any app, tap Share on a link.")
                Step(2, "Tap **Clean link**. The first time, swipe the row of apps to the end, tap More and add it.")
                Step(3, "**Copy**, **Copy for Telegram**, or **Share…**: Telegram gets the preview link, every other app the clean one.")
            } header: {
                Label("Share sheet", systemImage: "square.and.arrow.up")
            }
            Section {
                Step(1, "In Shortcuts, search the actions for **fxclip**.")
                Step(2, "**Clean link** and **Preview link** take text and return the result.")
            } header: {
                Label("Shortcuts", systemImage: "square.2.layers.3d")
            }
            Section {
                Step(1, "Shortcuts › Automation › New › App › **Telegram** › Is Opened, Run Immediately.")
                Step(2, "Actions: Get Clipboard › **Preview link** › Copy to Clipboard.")
                Step(3, "A second automation for **Is Closed**, with **Clean link**.")
            } header: {
                Label("Telegram previews, automatically", systemImage: "paperplane")
            } footer: {
                Text("iOS lets no app watch the clipboard. These automations are the closest to the Mac, where Telegram gets the preview link on its own. Allow Shortcuts to paste once: Settings › Apps › Shortcuts › Paste from Other Apps.")
            }
        }
        .navigationTitle("Clean from any app")
    }
}

private struct SettingLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    init(_ number: Int, _ text: LocalizedStringKey) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
