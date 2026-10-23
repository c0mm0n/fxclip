import Foundation

let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#, options: [.caseInsensitive])

/// True when the whole (trimmed) text is a single URL.
public func isBareURL(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let all = NSRange(trimmed.startIndex..., in: trimmed)
    return urlPattern.firstMatch(in: trimmed, range: all)?.range == all
}

/// Applies f to each URL in text, leaving prose punctuation around it untouched:
/// "see (https://x.com/a)." → f("https://x.com/a").
public func mapURLs(_ text: String, _ f: (String) -> String) -> String {
    var out = text
    // Replace from the end so earlier ranges stay valid.
    for m in urlPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard var r = Range(m.range, in: out) else { continue }
        // Bracket balance counted once, updated as we trim.
        var parens = 0, brackets = 0
        for ch in out[r] {
            switch ch {
            case "(": parens += 1
            case ")": parens -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            default: break
            }
        }
        while let last = out[r].last {
            if last == ")" && parens < 0 { parens += 1 }
            else if last == "]" && brackets < 0 { brackets += 1 }
            else if !".,;:!?".contains(last) { break }
            r = r.lowerBound..<out.index(before: r.upperBound)
        }
        out.replaceSubrange(r, with: f(String(out[r])))
    }
    return out
}

func matches(_ host: String, _ domain: String) -> Bool {
    host == domain || host.hasSuffix("." + domain)
}
