import FxEngine
import UIKit

/// Hands each share destination its own link: Telegram gets the preview mirror,
/// every other app the clean link. iOS asks per destination, once the user has picked one.
final class DestinationLink: NSObject, UIActivityItemSource {
    let clean: String
    let cleaner: LinkCleaner

    init(clean: String, cleaner: LinkCleaner) {
        self.clean = clean
        self.cleaner = cleaner
    }

    /// A bare link goes out as a URL (apps build their preview from it), anything else as text.
    static func item(_ text: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isBareURL(trimmed), let url = URL(string: trimmed) { return url }
        return text
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        Self.item(clean)
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        Self.item(cleaner.link(clean, for: activityType?.rawValue))
    }
}
