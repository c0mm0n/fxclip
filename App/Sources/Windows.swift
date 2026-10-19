import AppKit
import SwiftUI

/// The one-screen welcome, shown until it has been completed once.
@MainActor
final class WelcomeWindow {
    private var window: NSWindow?

    func show(store: SettingsStore, login: LoginItem, done: @escaping () -> Void) {
        let view = WelcomeView(store: store, login: login) { [weak self] in
            self?.window?.close()
            done()
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        // No close button: cleaning starts from Start, never from a dismissed window.
        w.styleMask = [.titled]
        w.title = "Welcome to fxclip"
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    let store: SettingsStore
    let login: LoginItem
    let done: () -> Void
    @State private var previews = true
    @State private var openAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clean links, ready to share").font(.title2.bold())
            Text("fxclip removes trackers (utm_*, fbclid, YouTube si…) from every link you copy. Links stay on this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $previews) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also adapt links for Telegram previews")
                    Text("Optional: use preview-friendly versions of X and Instagram links in Telegram. Other apps get the clean original. Choose other destination apps in App previews. Preview mirrors are run by third parties.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Toggle("Open fxclip at login", isOn: $openAtLogin).toggleStyle(.checkbox)
            Text("You can change all of this later in Settings. Update checks are optional and contact GitHub only when you ask or enable them.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Start", action: start).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func start() {
        var user = store.user
        for p in store.builtins.previews {
            user.previews[p.id] = .init(enabled: previews, apps: store.setting(for: p).apps)
        }
        store.user = user
        store.save()  // also when nothing changed: completes the first run
        if openAtLogin { login.set(true) }
        done()
    }
}
