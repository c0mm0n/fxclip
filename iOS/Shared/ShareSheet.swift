import FxEngine
import SwiftUI

/// Share › fxclip: the shared link, cleaned. In Shared/ so the app's tests can drive it.
@MainActor
final class ShareModel: ObservableObject {
    @Published private(set) var clean = ""
    @Published private(set) var removed = 0
    @Published private(set) var telegram = ""
    @Published private(set) var failed = false

    private(set) var cleaner: LinkCleaner?
    var done: () -> Void = {}

    func load(_ text: String?) {
        let store = SharedStore()
        guard let text, let rules = try? LinkCleaner.bundledRules() else {
            failed = true
            return
        }
        let cleaner = store.cleaner(rules: rules)
        let result = cleaner.clean(text)
        store.record(result.removed)
        self.cleaner = cleaner
        clean = result.text
        removed = result.removed
        telegram = cleaner.telegramPreview(result.text)
    }
}

/// Shown only when there is nothing to share; otherwise the extension goes straight to the
/// share sheet.
struct ShareFailedView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Image(systemName: "link.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No link to share").font(.headline)
                Text("Share a post or a link from X, Instagram, Safari or any app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("fxclip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { model.done() }
                }
            }
        }
    }
}
