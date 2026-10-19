import AppKit
import FxEngine
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication holds its delegate weakly.
    private static var shared: AppDelegate?
    private let log = Logger(subsystem: "io.github.c0mm0n.fxclip", category: "app")
    private var store: SettingsStore?
    private var watcher: ClipboardWatcher?
    private var menu: StatusMenu?
    private var window: MainWindow?
    private var updates: AppUpdater?
    private let welcome = WelcomeWindow()

    static func main() {
        let app = NSApplication.shared
        shared = AppDelegate()
        app.delegate = shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = Bundle.main.url(forResource: "rules", withExtension: "json"),
              let rules = try? Rules.load(Data(contentsOf: url)) else {
            fatalError("rules.json missing or invalid in the app bundle")
        }
        if #available(macOS 15.4, *) {
            log.notice("pasteboard accessBehavior=\(NSPasteboard.general.accessBehavior.rawValue, privacy: .public)")
        }
        #if UPDATE_TESTING
        // Only compiled into the isolated two-version update test builds.
        let updateTestDirectory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("update-test-data", isDirectory: true)
        let store = SettingsStore(builtins: rules, directory: updateTestDirectory)
        #else
        let store = SettingsStore(builtins: rules)
        #endif
        let stats = Stats()
        let watcher = ClipboardWatcher(engine: Engine(rules: store.effective), stats: stats)
        let updates = AppUpdater()
        let menu = StatusMenu(watcher: watcher, stats: stats, updates: updates)
        #if UPDATE_TESTING
        let initialPage: Page = .settings
        #else
        let initialPage: Page = .overview
        #endif
        let window = MainWindow(store: store, stats: stats, watcher: watcher, updates: updates, initialPage: initialPage)
        store.onRulesChange = { [weak watcher] in watcher?.engine = Engine(rules: $0) }
        store.onPresenceChange = { [weak self] in self?.applyPresence() }
        watcher.onChange = { [weak menu] in menu?.refreshIcon() }
        menu.openSettings = { [weak window] in window?.show() }
        (self.store, self.watcher, self.menu, self.window) = (store, watcher, menu, window)
        self.updates = updates
        NSApp.mainMenu = mainMenu()
        applyPresence()

        #if UPDATE_TESTING
        // Test builds always stay isolated, including after Sparkle relaunches them.
        // No clipboard watching or production settings writes; normal first-run setup is skipped.
        updates.start()
        if CommandLine.arguments.contains("--welcome-test") {
            // Screenshot only: do not click Start or enable a login item in this mode.
            welcome.show(store: store, login: LoginItem()) { window.show() }
        } else {
            window.show()
        }
        #else
        if store.isFirstRun {
            welcome.show(store: store, login: LoginItem()) { [weak watcher, weak updates] in
                watcher?.start()
                updates?.start()
            }
        } else {
            watcher.start()
            updates.start()
        }
        #endif
    }

    /// Opening fxclip again (Spotlight, Finder, Dock) shows its window: the way back when icons are hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.restoreClean()
    }

    private func applyPresence() {
        guard let store else { return }
        menu?.setVisible(store.showMenuBarIcon)
        NSApp.setActivationPolicy(store.showDock ? .regular : .accessory)
    }

    /// Needed even without a Dock icon: text fields only get ⌘C/⌘V/⌘A through the Edit menu.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About fxclip", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if let updates { appMenu.addItem(updates.menuItem()) }
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit fxclip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for submenu in [appMenu, edit] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    @objc private func showSettings() {
        window?.show()
    }
}
