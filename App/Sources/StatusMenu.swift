import AppKit

/// The menu bar icon and its menu, rebuilt each time it opens.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let watcher: ClipboardWatcher
    private let stats: Stats
    /// Opens the Settings window.
    var openSettings: () -> Void = {}
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(watcher: ClipboardWatcher, stats: Stats) {
        self.watcher = watcher
        self.stats = stats
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let image = NSImage(systemSymbolName: "link", accessibilityDescription: "fxclip")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.appearsDisabled = watcher.paused || accessDenied
    }

    private var accessDenied: Bool {
        if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior == .alwaysDeny }
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = accessDenied ? "Clipboard access needed"
            : watcher.paused ? "Paused" : "Cleaning links"
        menu.addItem(info(status))
        if accessDenied {
            menu.addItem(info("Allow fxclip in System Settings › Privacy & Security"))
        }
        if let last = stats.lastClean {
            let ago = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
            menu.addItem(info("Link cleaned · \(ago)"))
        }
        menu.addItem(info("\(stats.total.formatted()) trackers removed"))
        menu.addItem(.separator())
        menu.addItem(action(watcher.paused ? "Resume" : "Pause", #selector(togglePause)))
        let skip = action("Skip next clean", #selector(toggleSkip))
        skip.state = watcher.skipNext ? .on : .off
        menu.addItem(skip)
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(settings), key: ","))
        menu.addItem(action("About fxclip", #selector(about)))
        menu.addItem(action("Quit fxclip", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    func setVisible(_ visible: Bool) {
        item.isVisible = visible
    }

    @objc private func settings() {
        openSettings()
    }

    @objc private func togglePause() {
        watcher.paused.toggle()
    }

    @objc private func toggleSkip() {
        watcher.skipNext.toggle()
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
