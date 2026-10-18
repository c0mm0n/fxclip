import Foundation

/// Tracker removal and preview rewriting, driven by a rule set. Pure functions, no clipboard.
public struct Engine: Sendable {
    public let rules: Rules
    private let everywhere: Set<String>
    private let prefixes: [String]

    public init(rules: Rules) {
        self.rules = rules
        everywhere = Set(rules.trackers.everywhere.params)
        prefixes = rules.trackers.everywhere.prefixes.map { $0.lowercased() }
    }

    // MARK: tracker removal

    /// Cleans every URL in text. `removed` counts the trackers taken out.
    public func clean(_ text: String) -> (text: String, removed: Int) {
        var removed = 0
        let out = mapURLs(text) { cleanURL($0, removed: &removed) }
        return (out, removed)
    }

    /// Works on the raw string: kept parameters stay byte-for-byte (no re-encoding of %2B, ==…).
    func cleanURL(_ s: String, removed: inout Int) -> String {
        guard let host = URLComponents(string: s)?.host?.lowercased(),
              !(rules.neverClean ?? []).contains(where: { $0.covers(host) }) else { return s }
        let hash = s.firstIndex(of: "#")
        let fragment = hash.map { String(s[$0...]) } ?? ""
        let beforeHash = hash.map { String(s[..<$0]) } ?? s
        let q = beforeHash.firstIndex(of: "?")
        var base = q.map { String(beforeHash[..<$0]) } ?? beforeHash
        let segments = q.map { beforeHash[beforeHash.index(after: $0)...].split(separator: "&", omittingEmptySubsequences: false) } ?? []

        let sites = rules.trackers.sites.filter { $0.hosts.contains { matches(host, $0) } }
        var pathChanged = false
        if sites.contains(where: { $0.stripRefPath == true }),
           let r = base.range(of: #"/ref=[^/]*$"#, options: .regularExpression) {
            base.removeSubrange(r)
            pathChanged = true
        }
        let local = Set(sites.flatMap(\.params))
        let kept = segments.filter { seg in
            let raw = String(seg[..<(seg.firstIndex(of: "=") ?? seg.endIndex)])
            let n = raw.removingPercentEncoding ?? raw
            return !everywhere.contains(n) && !local.contains(n)
                && !prefixes.contains { n.lowercased().hasPrefix($0) }
        }
        guard kept.count != segments.count || pathChanged else { return s }
        removed += segments.count - kept.count + (pathChanged ? 1 : 0)
        return base + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + fragment
    }

    // MARK: preview links

    /// The rewrites that apply in the app with this bundle ID.
    public func previews(forBundleID bundleID: String) -> [Rules.Preview] {
        let appIDs = Set(rules.apps.filter { $0.bundleIDs.contains(bundleID) }.map(\.id))
        return rules.previews.filter { !appIDs.isDisjoint(with: $0.apps) }
    }

    /// Rewrites every URL in text to its embed mirror for that app; text is assumed already cleaned.
    public func preview(_ text: String, forBundleID bundleID: String) -> String {
        let active = previews(forBundleID: bundleID)
        guard !active.isEmpty else { return text }
        return mapURLs(text) { previewURL($0, active) }
    }

    /// Anchored on the URL start: a link nested in another link's query is left alone.
    /// Only an exact listed host followed by "/" matches, so http://x.com (no path) is kept.
    func previewURL(_ u: String, _ active: [Rules.Preview]) -> String {
        let lower = u.lowercased()
        guard let scheme = ["https://", "http://"].first(where: { lower.hasPrefix($0) }) else { return u }
        let afterScheme = u.index(u.startIndex, offsetBy: scheme.count)
        guard let slash = u[afterScheme...].firstIndex(of: "/") else { return u }
        let host = u[afterScheme..<slash].lowercased()
        guard let rule = active.first(where: { $0.from.contains(host) }) else { return u }
        return "https://" + rule.to + u[slash...]
    }
}
