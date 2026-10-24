import FxEngine
import ServiceManagement
import SwiftUI

// MARK: Overview

struct OverviewPage: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var stats: Stats
    @EnvironmentObject var watcher: ClipboardWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Overview", info: "fxclip cleans the links you copy, removing tracking parameters while keeping useful details. Optionally, adapt links for better previews in the destination apps you choose. Nothing leaves your Mac.")
            Card {
                CardRow(first: true) {
                    Circle().fill(watcher.paused ? Color.orange : Color.green).frame(width: 8, height: 8)
                    Text(watcher.paused ? "Paused" : "Cleaning links").fontWeight(.semibold)
                    if watcher.skipNext {
                        Text("· the next copy will be left as is").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(watcher.skipNext ? "Don't skip" : "Skip next copy") { watcher.skipNext.toggle() }
                    Button(watcher.paused ? "Resume" : "Pause") { watcher.paused.toggle() }
                }
            }
            HStack(spacing: 12) {
                stat(stats.total.formatted(), "trackers removed")
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let last = stats.lastClean {
                        stat(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: context.date),
                             "last link cleaned")
                    } else {
                        stat("—", "no link cleaned since fxclip started")
                    }
                }
            }
            SectionTitle("Optional app previews")
            let active = store.effective.previews.filter { !$0.apps.isEmpty }
            Card {
                if active.isEmpty {
                    CardRow(first: true) { Text("App previews are off. Link cleaning works independently.").foregroundStyle(.secondary) }
                }
                ForEach(Array(active.enumerated()), id: \.element.id) { i, p in
                    CardRow(first: i == 0) {
                        Text(p.name).fontWeight(.semibold)
                        Text("→ \(p.to)").foregroundStyle(.secondary)
                        Spacer()
                        ForEach(p.apps, id: \.self) { id in
                            if let app = store.app(id) { AppChip(app: app) }
                        }
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 28, weight: .bold))
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
    }
}

// MARK: Preview links

struct PreviewsPage: View {
    @EnvironmentObject var store: SettingsStore
    @State private var choosing: Choosing?
    @State private var editing: Choosing?

    struct Choosing: Identifiable { let id: String }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "App previews", info: "An optional extra to link cleaning: adapt supported links for better previews in the destination apps you choose. Other apps get the clean original. Mirrors are run by third parties: they can receive links when previews are generated or when someone opens them.")
            ForEach(store.builtins.previews, id: \.id) { card($0) }
        }
        .sheet(item: $choosing) { c in
            if let p = store.builtins.previews.first(where: { $0.id == c.id }) {
                ChooseAppsSheet(preview: p).environmentObject(store)
            }
        }
        .sheet(item: $editing) { c in
            if let p = store.builtins.previews.first(where: { $0.id == c.id }) {
                PreviewProviderSheet(preview: p, target: store.previewTargetHost(for: p)) {
                    store.setPreview(p, targetHost: $0)
                }
            }
        }
    }

    private func card(_ p: Rules.Preview) -> some View {
        let s = store.setting(for: p)
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.15))
                    Text(String(p.name.prefix(1))).font(.system(size: 17, weight: .semibold))
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 16, weight: .semibold))
                    Text(sources(p) + " → " + store.previewTargetHost(for: p)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit domain…") { editing = Choosing(id: p.id) }
                    .font(.system(size: 12))
                Toggle("", isOn: Binding(get: { s.enabled }, set: { store.setPreview(p, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            .padding(14)
            Divider()
            HStack(spacing: 8) {
                ForEach(s.apps, id: \.self) { id in
                    if let app = store.app(id) { AppChip(app: app) }
                }
                Button { choosing = Choosing(id: p.id) } label: {
                    Label(s.apps.isEmpty ? "Choose apps" : "Change apps", systemImage: "plus")
                        .font(.system(size: 12))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.black.opacity(0.10))
        }
        .opacity(s.enabled ? 1 : 0.6)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
    }

    /// "x.com, twitter.com": the bare domains, without www./mobile. aliases.
    private func sources(_ p: Rules.Preview) -> String {
        p.from.filter { !$0.hasPrefix("www.") && !$0.hasPrefix("mobile.") }.joined(separator: ", ")
    }
}

private struct PreviewProviderSheet: View {
    let preview: Rules.Preview
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var domain: String
    @State private var error = false

    init(preview: Rules.Preview, target: String, save: @escaping (String?) -> Void) {
        self.preview = preview
        self.save = save
        _domain = State(initialValue: target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(preview.name) preview domain").font(.headline)
            TextField("Domain", text: $domain, prompt: Text(preview.to))
                .textFieldStyle(.roundedBorder).onSubmit(apply)
            Text("Default: \(preview.to)").font(.caption).foregroundStyle(.secondary)
            if error { Text("Enter a domain only, such as preview.example.").foregroundStyle(.red) }
            HStack {
                Button("Use Default") { save(nil); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: apply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func apply() {
        let raw = domain.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{000B}\u{000C}"))
        guard raw.isEmpty || Rules.canonicalPreviewHost(raw) != nil else { error = true; return }
        save(raw.isEmpty ? nil : Rules.canonicalPreviewHost(raw))
        dismiss()
    }
}

// MARK: Trackers

struct TrackersPage: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        let t = store.builtins.trackers
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Link cleaning", info: "What fxclip removes from the links you copy. Useful parts of a link (a YouTube timestamp, an Amazon size or colour, a search) are always kept.")
            Card {
                CardRow(first: true) {
                    Text("All websites").fontWeight(.semibold)
                    Spacer()
                    count(t.everywhere.params.count + t.everywhere.prefixes.count,
                          (t.everywhere.prefixes.map { $0 + "*" } + t.everywhere.params).joined(separator: ", "))
                    Toggle("", isOn: $store.user.trackersEverywhere).labelsHidden().toggleStyle(.switch)
                }
                ForEach(t.sites, id: \.id) { site in
                    CardRow {
                        Text(site.name)
                        Spacer()
                        count(site.params.count + (site.stripRefPath == true ? 1 : 0),
                              site.params.joined(separator: ", ") + (site.stripRefPath == true ? ", and the /ref=… end of the address" : ""))
                        Toggle("", isOn: siteBinding(site)).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }

    private func count(_ n: Int, _ list: String) -> some View {
        HStack(spacing: 6) {
            Text("\(n) trackers").foregroundStyle(.secondary)
            InfoTip(list)
        }
    }

    private func siteBinding(_ site: Rules.Site) -> Binding<Bool> {
        Binding(
            get: { !store.user.disabledSites.contains(site.id) },
            set: { on in
                if on { store.user.disabledSites.remove(site.id) } else { store.user.disabledSites.insert(site.id) }
            }
        )
    }
}

// MARK: Never clean

struct NeverCleanPage: View {
    @EnvironmentObject var store: SettingsStore
    @State private var newHost = ""
    @State private var subdomains = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Never clean", info: "Links from these websites are left exactly as you copied them. Preview links are set separately.")
            Card {
                ForEach(Array(store.user.neverClean.enumerated()), id: \.element) { i, skip in
                    CardRow(first: i == 0) {
                        Text(skip.host).font(.system(.body, design: .monospaced))
                        if skip.subdomains { Text("and its subdomains").foregroundStyle(.secondary) }
                        Spacer()
                        Button { store.user.neverClean.removeAll { $0 == skip } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless).help("Remove")
                    }
                }
                CardRow(first: store.user.neverClean.isEmpty) {
                    TextField("Add a website", text: $newHost, prompt: Text("Add a website, e.g. mycompany.com"))
                        .textFieldStyle(.roundedBorder).onSubmit(add)
                    Toggle("Include subdomains", isOn: $subdomains).toggleStyle(.checkbox)
                    Button("Add", action: add).disabled(host(newHost) == nil)
                }
            }
        }
    }

    /// Accepts "example.com" or a whole pasted link.
    private func host(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        let h = URLComponents(string: s.contains("://") ? s : "https://" + s)?.host.map(SkipHost.canonical)
        return h.flatMap { $0.contains(".") ? $0 : nil }
    }

    private func add() {
        guard let h = host(newHost) else { return }
        let skip = SkipHost(host: h, subdomains: subdomains)
        if !store.user.neverClean.contains(skip) { store.user.neverClean.append(skip) }
        newHost = ""
    }
}

// MARK: Settings

struct SettingsPage: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var updates: AppUpdater
    @EnvironmentObject var stats: Stats
    @StateObject private var login = LoginItem()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings", info: "Where fxclip shows up, and what it keeps.")
            SectionTitle("Where fxclip shows up")
            Card {
                CardRow(first: true) {
                    Text("Icon in the menu bar"); Spacer()
                    Toggle("", isOn: $store.showMenuBarIcon).labelsHidden().toggleStyle(.switch)
                }
                CardRow {
                    Text("Icon in the Dock"); Spacer()
                    Toggle("", isOn: $store.showDock).labelsHidden().toggleStyle(.switch)
                }
                CardRow {
                    Text("Open at login")
                    if let note = login.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            if !store.showMenuBarIcon && !store.showDock {
                Text("Both icons hidden: open fxclip again from Spotlight or Finder to come back here.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 4).padding(.top, 6)
            }
            SectionTitle("Privacy")
            Card {
                CardRow(first: true) {
                    Text("Links are cleaned on this Mac and are never sent. Only the tracker count and your settings are saved. Update checks contact GitHub only when you ask or enable automatic checks.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                CardRow {
                    Text("\(stats.total.formatted()) trackers removed"); Spacer()
                    Button("Reset counter") { stats.reset() }
                }
            }
            SectionTitle("Updates")
            Card {
                CardRow(first: true) {
                    Text("Version"); Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                        .foregroundStyle(.secondary)
                    Button("Check for Updates…", action: updates.checkForUpdates)
                        .disabled(!updates.canCheckForUpdates)
                }
                CardRow {
                    Text("Automatically check for updates")
                    Spacer()
                    Toggle("", isOn: Binding(get: { updates.automaticallyChecksForUpdates }, set: updates.setAutomaticChecks))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Automatically check for updates")
                }
                CardRow {
                    Text("Optional: check GitHub once a day. Downloads and installation always ask for your confirmation.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let lastCheck = updates.lastCheck {
                    CardRow {
                        Text("Last checked"); Spacer()
                        Text(lastCheck, style: .relative).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { login.refresh() }
    }
}

/// Open at login through SMAppService, showing the system's real state.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var note: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        note = status == .requiresApproval ? "Waiting for your approval." : nil
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            refresh()
            note = "Couldn't change it: \(error.localizedDescription)"
        }
    }
}
