import Foundation

/// What the user changed on top of the built-in rules. Stored as JSON; anything
/// absent falls back to the built-in default, so app updates never overwrite a choice.
public struct UserSettings: Codable, Equatable, Sendable {
    public var version = 1
    /// "All websites" trackers (utm_*, fbclid…).
    public var trackersEverywhere = true
    /// Default for preview rules without an explicit user choice, including new built-in rules.
    public var previewDefaultsEnabled = true
    /// Tracker sites switched off, by site id.
    public var disabledSites: Set<String> = []
    /// Links from these hosts are left exactly as copied.
    public var neverClean: [SkipHost] = []
    /// Per preview link (by id): on/off, apps and optional provider host. Missing = built-in default.
    public var previews: [String: PreviewSetting] = [:]
    /// Apps the user added through "Choose apps…" (id = bundle ID).
    public var addedApps: [Rules.App] = []

    public struct PreviewSetting: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var apps: [String]
        public var targetHost: String?
        public init(enabled: Bool, apps: [String], targetHost: String? = nil) {
            self.enabled = enabled
            self.apps = apps
            self.targetHost = targetHost
        }
    }

    public init() {}

    /// Missing keys keep their default instead of failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserSettings()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        trackersEverywhere = try c.decodeIfPresent(Bool.self, forKey: .trackersEverywhere) ?? d.trackersEverywhere
        disabledSites = try c.decodeIfPresent(Set<String>.self, forKey: .disabledSites) ?? d.disabledSites
        neverClean = try c.decodeIfPresent([SkipHost].self, forKey: .neverClean) ?? d.neverClean
        previews = try c.decodeIfPresent([String: PreviewSetting].self, forKey: .previews) ?? d.previews
        previewDefaultsEnabled = c.contains(.previewDefaultsEnabled)
            ? try c.decodeIfPresent(Bool.self, forKey: .previewDefaultsEnabled) ?? d.previewDefaultsEnabled
            : !(previews["x"]?.enabled == false && previews["instagram"]?.enabled == false)
        addedApps = try c.decodeIfPresent([Rules.App].self, forKey: .addedApps) ?? d.addedApps
    }
}

public struct SkipHost: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var subdomains: Bool

    public init(host: String, subdomains: Bool) {
        self.host = host
        self.subdomains = subdomains
    }

    func covers(_ h: String) -> Bool {
        let h = Self.canonical(h), host = Self.canonical(host)
        return h == host || (subdomains && h.hasSuffix("." + host))
    }

    /// Lowercased, without the DNS root dot ("Example.COM." → "example.com").
    public static func canonical(_ h: String) -> String {
        var h = h.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}

extension Rules {
    /// The rules actually in force: built-ins with the user's choices applied.
    public func applying(_ user: UserSettings) -> Rules {
        var r = self
        if !user.trackersEverywhere {
            r.trackers.everywhere = ParamSet(params: [], prefixes: [])
        }
        r.trackers.sites.removeAll { user.disabledSites.contains($0.id) }
        r.neverClean = user.neverClean
        r.apps += user.addedApps.filter { added in !apps.contains { $0.id == added.id } }
        r.previews = previews.compactMap { p in
            guard let s = user.previews[p.id] else { return user.previewDefaultsEnabled ? p : nil }
            guard s.enabled else { return nil }
            var p = p
            p.apps = s.apps
            if let raw = s.targetHost, let host = Self.canonicalPreviewHost(raw) { p.to = host }
            return p
        }
        return r
    }
}
