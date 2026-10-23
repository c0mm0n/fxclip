import FxEngine
import SwiftUI

/// What Share › Clean link shows. In Shared/ so the app's tests can drive and snapshot it.
@MainActor
final class ShareModel: ObservableObject {
    @Published private(set) var original = ""
    @Published private(set) var clean = ""
    @Published private(set) var removed = 0
    @Published private(set) var removedNames: [String] = []
    @Published private(set) var telegram = ""
    @Published private(set) var failed = false
    /// False until the shared item has been read: nothing to copy or share before.
    @Published private(set) var loaded = false

    private(set) var cleaner: LinkCleaner?
    var copy: (String) -> Void = { _ in }
    var share: () -> Void = {}
    var cancel: () -> Void = {}

    func load(_ text: String?) {
        let store = SharedStore()
        defer { loaded = true }
        guard let text, let rules = try? LinkCleaner.bundledRules() else {
            failed = true
            return
        }
        let cleaner = store.cleaner(rules: rules)
        let result = cleaner.clean(text)
        store.record(result.removed)
        self.cleaner = cleaner
        original = text
        clean = result.text
        removed = result.removed
        removedNames = removedParameters(original: text, clean: result.text)
        telegram = cleaner.telegramPreview(result.text)
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if !model.loaded {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if model.failed {
                    Text("No link to clean.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        LinkResultView(clean: model.clean, removed: model.removed, removedNames: model.removedNames)
                    } header: {
                        Text("Clean link")
                    }
                    Section {
                        Button {
                            model.copy(model.clean)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        if model.telegram != model.clean {
                            Button {
                                model.copy(model.telegram)
                            } label: {
                                Label("Copy for Telegram", systemImage: "paperplane")
                            }
                        }
                        Button {
                            model.share()
                        } label: {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                    } footer: {
                        if model.telegram != model.clean {
                            Text("Share… gives Telegram the preview link and every other app the clean link.")
                        }
                    }
                }
            }
            .navigationTitle("fxclip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { model.cancel() }
                }
            }
        }
    }
}
