import FxEngine
import SwiftUI

/// Home: the one gesture, Share › fxclip, then the counter; settings one level down.
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
                ShareSection()
                CounterSection()
                Section {
                    NavigationLink { CleaningPage() } label: {
                        IconRow(title: "Link cleaning", icon: "eye.slash.fill", color: .red, value: model.cleaningSummary)
                    }
                    NavigationLink { PreviewsPage() } label: {
                        IconRow(title: "App previews", icon: "link", color: .blue, value: model.previewsSummary)
                    }
                } footer: {
                    Text("Links are cleaned on this iPhone. No account, no analytics, no network access.")
                }
            }
            .navigationTitle("fxclip")
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refresh() }
        }
    }
}

private struct ShareSection: View {
    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share › fxclip").font(.headline)
                    Text("Clean links, real previews in Telegram").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            Step(1, "In X, Instagram or any app, tap **Share** on a post or a link.")
            Step(2, "Tap **fxclip**. Not in the row? Swipe to the end › More.")
            Step(3, "Pick your **Telegram** chat: it gets the preview link. Every other app, and Copy, get the clean link.")
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
