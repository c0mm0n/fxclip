import SwiftUI

/// The query parameters of `original` that are gone from `clean`, in order, for display only.
/// Path trackers (Amazon `/ref=`) aren't query items, so they're counted but not named here.
func removedParameters(original: String, clean: String) -> [String] {
    let before = URLComponents(string: original.trimmingCharacters(in: .whitespacesAndNewlines))?.queryItems ?? []
    let after = Set((URLComponents(string: clean)?.queryItems ?? []).map(\.name))
    var seen = Set<String>()
    return before.map(\.name).filter { !after.contains($0) && seen.insert($0).inserted }
}

/// A cleaned link as the app and the share sheet show it: the link, then what was taken out.
struct LinkResultView: View {
    let clean: String
    let removed: Int
    let removedNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clean)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(5)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: removed == 0 ? "checkmark.circle.fill" : "scissors")
                    .foregroundStyle(removed == 0 ? .green : .red)
                    .imageScale(.small)
                summary
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: Text {
        if removed == 0 { return Text("Already clean") }
        let count = Text(removed == 1 ? "1 tracker removed" : "\(removed) trackers removed")
        guard !removedNames.isEmpty else { return count }
        return removedNames.enumerated().reduce(count + Text(": ")) { text, item in
            text + Text(item.offset == 0 ? "" : ", ") + Text(item.element).font(.footnote.monospaced()).strikethrough()
        }
    }
}
