import AppIntents
import FxEngine

/// Shortcuts actions. They take text and return text: Shortcuts' own Get/Copy Clipboard
/// actions do the clipboard, under Shortcuts' paste permission.
struct CleanLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Clean link"
    static var description = IntentDescription("Removes trackers from every link in the text.")
    static var openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Clean links in \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try IntentCleaner.run(text).clean)
    }
}

struct PreviewLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Preview link"
    static var description = IntentDescription("Cleans the links, then rewrites them to the preview mirrors Telegram uses (fxtwitter, zzinstagram).")
    static var openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Preview links in \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try IntentCleaner.run(text).telegram)
    }
}

enum IntentCleaner {
    static func run(_ text: String) throws -> (clean: String, telegram: String) {
        let store = SharedStore()
        let cleaner = store.cleaner(rules: try LinkCleaner.bundledRules())
        let out = cleaner.clean(text)
        store.record(out.removed)
        return (out.text, cleaner.telegramPreview(out.text))
    }
}

struct FxClipShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CleanLinkIntent(), phrases: ["Clean link with \(.applicationName)"])
        AppShortcut(intent: PreviewLinkIntent(), phrases: ["Preview link with \(.applicationName)"])
    }
}
