import FxEngine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share › Clean link: cleans the shared link, then copies it or hands it on,
/// with the preview mirror for Telegram and the clean link everywhere else.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.copy = { [weak self] text in
            UIPasteboard.general.string = text
            self?.finish()
        }
        model.share = { [weak self] in self?.presentShareSheet() }
        model.cancel = { [weak self] in self?.finish() }

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task { await model.load(sharedText()) }
    }

    /// The first link (or text) the host app shared.
    private func sharedText() async -> String? {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let url = await p.load(URL.self), !url.isFileURL {
            return url.absoluteString
        }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
           let text = await p.load(String.self) {
            return text
        }
        return items.lazy.compactMap { $0.attributedContentText?.string }.first
    }

    private func presentShareSheet() {
        guard let cleaner = model.cleaner else { return }
        let sheet = UIActivityViewController(activityItems: [DestinationLink(clean: model.clean, cleaner: cleaner)],
                                             applicationActivities: nil)
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            if completed { self?.finish() }
        }
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        present(sheet, animated: true)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private extension NSItemProvider {
    func load<T: _ObjectiveCBridgeable>(_ type: T.Type) async -> T? where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }
}
