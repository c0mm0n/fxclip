import FxEngine
import SwiftUI
import UIKit

/// Home: the two ways fxclip is really used, copy in X then paste in Telegram (a Shortcuts
/// automation does the swap) and Share › Clean link, set up from here; settings one level down.
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
                AutomationSection()
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

/// The closest iOS gets to the Mac: copy anywhere, paste in Telegram, the preview shows.
private struct AutomationSection: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy in X, paste in Telegram").font(.headline)
                        Text("Set up once, then it just works").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text("When Telegram opens, the link you copied becomes its preview link. When you leave, the clean link comes back.")
                    .font(.subheadline)
                    .padding(.top, 6)
            }
            .padding(.vertical, 6)
            Step(1, "Shortcuts › Automation › **+** › App › **Telegram** › Is Opened › Run Immediately.")
            Step(2, "Add **Get Clipboard**, **Preview link** (fxclip), **Copy to Clipboard**.")
            Step(3, "Same again with **Is Closed** and **Clean link**.")
            Button {
                openURL(URL(string: "shortcuts://")!)
            } label: {
                Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
            }
        } header: {
            Text("Telegram previews")
        } footer: {
            Text("The first time, allow Shortcuts to paste: Settings › Apps › Shortcuts › Paste from Other Apps › Allow.")
        }
    }
}

private struct ShareSection: View {
    var body: some View {
        Section {
            Step(1, "On a post or a link, tap **Share** › **Clean link**. Not listed? Swipe the apps to the end › More.")
            Step(2, "**Share…** › Telegram gets the preview link, every other app the clean one. Or just **Copy**.")
        } header: {
            Text("From the share sheet")
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
