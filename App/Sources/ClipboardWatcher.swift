import AppKit
import Combine
import FxEngine
import os

/// Watches the general pasteboard: cleans copied links everywhere, swaps in preview
/// mirrors while a chosen app is in front, and puts the clean link back elsewhere.
@MainActor
final class ClipboardWatcher: ObservableObject {
    /// Replaced when the user changes a setting; the next apply uses it.
    var engine: Engine
    let stats: Stats
    /// Called when something shown in the menu changed.
    var onChange: () -> Void = {}

    @Published var paused = false {
        didSet { if paused { restoreClean() }; onChange() }
    }
    /// One-shot: the next copy is left exactly as copied.
    @Published var skipNext = false

    private let pb = NSPasteboard.general
    private let log = Logger(subsystem: "io.github.c0mm0n.fxclip", category: "clipboard")
    /// The current clipboard generation as we know it: its text and that text cleaned.
    /// Any newer generation (someone copied) makes it stale.
    private var clip: (count: Int, text: String, clean: String)?
    /// Last generation we looked at, ours included.
    private var seen: Int
    private var timer: Timer?

    init(engine: Engine, stats: Stats) {
        self.engine = engine
        self.stats = stats
        // -1: the clipboard found at launch is handled like a fresh copy.
        seen = -1
    }

    /// Act at once on app switch; poll for copies.
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Puts the clean link back if the clipboard still holds our preview (pause, quit).
    func restoreClean() {
        apply(for: nil)
    }

    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private var frontBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func tick() {
        let count = pb.changeCount
        if count != seen {
            // A new copy supersedes whatever we were holding.
            seen = count
            clip = nil
            guard !paused else { return }
            if skipNext {
                skipNext = false
                onChange()
                return
            }
            inspect(count)
        } else if !paused {
            apply(for: frontBundleID)
        }
    }

    /// Looks at the clipboard's metadata first and reads its text only when it holds a link,
    /// so ordinary copies never trigger macOS's paste-access alert.
    private func inspect(_ count: Int) {
        // Leave images and files alone.
        guard let types = pb.types, types.contains(.string), !types.contains(.fileURL),
              !pb.canReadObject(forClasses: [NSImage.self]) else { return }
        if #available(macOS 15.4, *) {
            Task { @MainActor in
                let found: Set<PartialKeyPath<NSPasteboard.DetectedValues>>
                do { found = try await pb.detectedPatterns(for: [\.links, \.probableWebURL]) } catch {
                    log.error("link detection failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                log.debug("detected \(found.count) pattern(s)")
                guard !found.isEmpty else { return }
                read(count)
            }
        } else {
            read(count)
        }
    }

    private func read(_ count: Int) {
        // Detection is async: the user may have paused, or copied again, meanwhile.
        guard !paused, pb.changeCount == count, let text = pb.string(forType: .string) else { return }
        // Rich text (copied from a page) is only rewritten when it is a bare link:
        // flattening anything longer would lose its formatting.
        let rich = pb.types?.contains(where: [.html, .rtf, .rtfd].contains) ?? false
        if rich && !isBareURL(text) { return }
        let (clean, removed) = engine.clean(text)
        clip = (count, text, clean)
        if removed > 0 { stats.record(removed) }
        apply(for: frontBundleID)
        onChange()
    }

    /// Makes the clipboard hold what the app in front should get: the clean text,
    /// or its preview version. Always derived from the clean text, never from a previous preview.
    private func apply(for bundleID: String?) {
        // Someone copied again since: drop ours, the next tick handles theirs.
        guard let c = clip, pb.changeCount == c.count else { return }
        let want = bundleID.map { engine.preview(c.clean, forBundleID: $0) } ?? c.clean
        // Re-checked after computing: another app may have copied in the meantime.
        guard want != c.text, pb.changeCount == c.count else { return }
        // clearContents() returns our own generation; reading changeCount afterwards
        // could pick up a copy made in between.
        let ours = pb.clearContents()
        pb.setString(want, forType: .string)
        // A preview link is temporary: tell clipboard histories (nspasteboard.org convention) to skip it.
        if want != c.clean { pb.setString("", forType: Self.transient) }
        clip = (ours, want, c.clean)
        seen = ours
    }
}
