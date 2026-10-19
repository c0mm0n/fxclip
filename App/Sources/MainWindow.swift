import AppKit
import SwiftUI

/// The app window: sidebar of pages, one page at a time.
@MainActor
final class MainWindow {
    private var window: NSWindow?
    private let store: SettingsStore
    private let stats: Stats
    private let watcher: ClipboardWatcher
    private let updates: AppUpdater
    private let initialPage: Page

    init(store: SettingsStore, stats: Stats, watcher: ClipboardWatcher, updates: AppUpdater, initialPage: Page = .overview) {
        self.store = store
        self.stats = stats
        self.watcher = watcher
        self.updates = updates
        self.initialPage = initialPage
    }

    func show() {
        if window == nil {
            let root = MainView(page: initialPage)
                .environmentObject(store).environmentObject(stats).environmentObject(watcher)
                .environmentObject(updates)
                .frame(width: 950).frame(minHeight: 620)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "fxclip"
            w.setContentSize(NSSize(width: 950, height: 700))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Open with nothing focused: no ring on the first button of the page.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview, trackers, previews, neverClean, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .previews: "App previews"
        case .trackers: "Link cleaning"
        case .neverClean: "Never clean"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .previews: "link"
        case .trackers: "eye.slash.fill"
        case .neverClean: "hand.raised.fill"
        case .settings: "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .overview: Color(nsColor: .systemOrange)
        case .previews: Color(nsColor: .systemBlue)
        case .trackers: Color(nsColor: .systemRed)
        case .neverClean: Color(nsColor: .systemIndigo)
        case .settings: Color(nsColor: .systemGray)
        }
    }
}

struct MainView: View {
    @State private var page: Page = .overview

    init(page: Page = .overview) { _page = State(initialValue: page) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().ignoresSafeArea()
            ScrollView {
                Group {
                    switch page {
                    case .overview: OverviewPage()
                    case .previews: PreviewsPage()
                    case .trackers: TrackersPage()
                    case .neverClean: NeverCleanPage()
                    case .settings: SettingsPage()
                    }
                }
                .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebar: some View {
        VStack(spacing: 3) {
            ForEach([Page.overview, .trackers, .previews, .neverClean]) { row($0) }
            Spacer()
            row(.settings)
        }
        .padding(.horizontal, 10).padding(.top, 52).padding(.bottom, 14)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(VisualEffect().ignoresSafeArea())
    }

    private func row(_ p: Page) -> some View {
        let selected = page == p
        return Button { page = p } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.color)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 1.2, y: 1)
                    Image(systemName: p.symbol).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)
                Text(p.title).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
            .padding(.leading, 8).padding(.trailing, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // The selection is the indicator; no keyboard focus ring on top of it.
        .focusable(false)
    }
}
