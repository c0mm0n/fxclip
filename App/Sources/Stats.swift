import Foundation

/// What the menu shows as proof of work. Only a total is stored, never a link or a site.
@MainActor
final class Stats: ObservableObject {
    private let key = "trackersRemoved"
    @Published private(set) var total: Int
    /// In memory only.
    private(set) var lastClean: Date?

    init() {
        total = UserDefaults.standard.integer(forKey: key)
    }

    func record(_ removed: Int) {
        total += removed
        lastClean = Date()
        UserDefaults.standard.set(total, forKey: key)
    }

    func reset() {
        total = 0
        UserDefaults.standard.set(0, forKey: key)
    }
}
