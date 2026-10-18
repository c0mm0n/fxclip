import Foundation

/// The rule set, as stored in Shared/rules.json (built-ins) — shared with any other platform.
public struct Rules: Codable, Sendable {
    public var version: Int
    public var trackers: Trackers
    public var previews: [Preview]
    public var apps: [App]
    /// Hosts whose links are never cleaned (user setting, absent from the built-ins).
    public var neverClean: [SkipHost]?

    public struct Trackers: Codable, Sendable {
        /// Removed from every link.
        public var everywhere: ParamSet
        public var sites: [Site]
    }

    /// Exact names are case-sensitive; prefixes are matched case-insensitively.
    public struct ParamSet: Codable, Sendable {
        public var params: [String]
        public var prefixes: [String]
    }

    /// Parameters removed only on these hosts and their subdomains
    /// (the same name is meaningful elsewhere, e.g. ?ref= on GitHub).
    public struct Site: Codable, Sendable {
        public var id: String
        public var name: String
        public var hosts: [String]
        public var params: [String]
        /// Amazon puts its referral in the path: /dp/B0XXXX/ref=sr_1_1
        public var stripRefPath: Bool?
    }

    /// Embed-friendly mirror: links whose host is exactly one of `from` get host `to`,
    /// only in the listed apps.
    public struct Preview: Codable, Sendable {
        public var id: String
        public var name: String
        public var from: [String]
        public var to: String
        public var apps: [String]
    }

    /// One user-facing app, possibly several bundle IDs (Telegram has three).
    public struct App: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// macOS bundle IDs, matched exactly.
        public var bundleIDs: [String]
        /// Linux Wayland app_id / X11 WM_CLASS, matched ignoring case.
        public var linux: [String]?
        /// Windows exe names ("Telegram.exe"), matched ignoring case.
        public var windows: [String]?

        public init(id: String, name: String, bundleIDs: [String], linux: [String]? = nil, windows: [String]? = nil) {
            self.id = id
            self.name = name
            self.bundleIDs = bundleIDs
            self.linux = linux
            self.windows = windows
        }

        /// The front app's identifier on any platform: bundle ID, app_id/WM class or exe name.
        public func matches(_ identifier: String) -> Bool {
            bundleIDs.contains(identifier)
                || ((linux ?? []) + (windows ?? [])).contains { $0.caseInsensitiveCompare(identifier) == .orderedSame }
        }
    }

    public static func load(_ data: Data) throws -> Rules {
        try JSONDecoder().decode(Rules.self, from: data)
    }
}
