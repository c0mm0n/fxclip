import FxEngine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share › fxclip: cleans the shared link and goes straight to the share sheet, where Telegram
/// gets the preview mirror and every other app (Copy included) the clean link.
final class ShareViewController: UIViewController {
    private let model = ShareModel()
    private var loaded = false
    private var appeared = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        model.done = { [weak self] in self?.finish() }
        Task {
            await model.load(sharedText())
            loaded = true
            next()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        next()
    }

    /// Both the link and the view must be ready before presenting anything.
    private func next() {
        guard loaded, appeared, presentedViewController == nil, children.isEmpty else { return }
        if model.failed {
            showFailure()
        } else {
            presentShareSheet()
        }
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
        // Sent, copied or cancelled: either way the user is done with fxclip.
        sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in self?.finish() }
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        present(sheet, animated: true)
    }

    private func showFailure() {
        view.backgroundColor = .systemBackground
        let host = UIHostingController(rootView: ShareFailedView(model: model))
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
