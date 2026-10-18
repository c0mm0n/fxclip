import Foundation
import FxEngine

public struct ClipboardSnapshot: Equatable {
    public let types: Set<String>
    public let text: String
    public init(types: Set<String>, text: String) { self.types = types; self.text = text }

    public static func allows(_ types: Set<String>) -> Bool {
        guard types.contains(where: { $0 == "text/plain" || $0.hasPrefix("text/plain;") }) else { return false }
        return types.allSatisfy {
            $0 == "text/plain" || $0.hasPrefix("text/plain;") ||
            ["UTF8_STRING", "STRING", "TEXT", "text/html", "text/rtf", "application/rtf"].contains($0)
        }
    }

    public var eligible: Bool {
        guard Self.allows(types) else { return false }
        let rich = !types.isDisjoint(with: ["text/html", "text/rtf", "application/rtf"])
        return !rich || FxEngine.isBareURL(text)
    }

}

/// Only holds the current selection in memory. No clipboard history or logging.
public final class ClipboardController {
    private var seen: ClipboardSnapshot?
    private var original: String?
    private var ownWrite: String?

    public init() {}

    public func tick(engine: Engine, app: String?,
                     read: () -> ClipboardSnapshot?, write: (String, ClipboardSnapshot) -> Bool) {
        guard let current = read(), current.eligible else { reset(); return }
        if current != seen {
            // wl-copy offers plain text under several compatible MIME aliases.
            // Recognize its value without feeding our mirror back into the engine.
            if current.text != ownWrite || !current.types.isDisjoint(with: ["text/html", "text/rtf", "application/rtf"]) {
                original = current.text
            }
            ownWrite = nil
            seen = current
        }
        guard let original else { return }
        let clean = engine.clean(original).text
        let desired = app.map { engine.preview(clean, forBundleID: $0) } ?? clean
        guard desired != current.text else { return }
        // A fresh type + text read protects newer copies, including images/files.
        guard read() == current else { reset(); return }
        // A rejected write (for example a focus change during the final read)
        // leaves the current selection alone. Keep its original for the next tick.
        if write(desired, current) { ownWrite = desired }
    }

    private func reset() { seen = nil; original = nil; ownWrite = nil }
}
