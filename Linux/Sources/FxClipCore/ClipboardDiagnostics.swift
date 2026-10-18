import Foundation

public enum ClipboardDiagnostics {
    /// wl-paste prints "wl-clipboard 2.3.0"; distro suffixes do not change support.
    public static func supportsExtDataControl(version: String) -> Bool? {
        guard let value = version.split(whereSeparator: \.isWhitespace).dropFirst().first else { return nil }
        let parts = value.split(separator: ".")
        guard parts.count >= 3, let major = Int(parts[0]), let minor = Int(parts[1]),
              let patch = Int(parts[2].prefix(while: \.isNumber)), !parts[2].prefix(while: \.isNumber).isEmpty else { return nil }
        return [major, minor, patch].lexicographicallyPrecedes([2, 3, 0]) == false
    }

    public static func advertisedProtocols(_ info: String) -> [String] {
        let words = Set(info.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
        return ["ext_data_control_manager_v1", "zwlr_data_control_manager_v1"].filter { words.contains($0) }
    }

    public static func failure(version: String, waylandInfo: String?) -> String {
        let buildNote = "Building wl-clipboard 2.3.0 yourself requires wayland-protocols >= 1.39 at build time; older definitions silently omit ext-data-control support."
        let upgrade = "The desktop may only offer ext-data-control, which needs wl-clipboard 2.3.0 or later. Reinstall the latest fxclip Linux tarball (includes wl-clipboard), or upgrade wl-clipboard on PATH. \(buildNote)"
        if let waylandInfo {
            let protocols = advertisedProtocols(waylandInfo)
            if protocols.isEmpty {
                return "The compositor offers neither ext-data-control nor wlr-data-control (as on GNOME Wayland); background clipboard access is unavailable."
            }
            if supportsExtDataControl(version: version) == false && !protocols.contains("zwlr_data_control_manager_v1") { return upgrade }
            return "The compositor advertises data-control, but the probe failed. Check the wl-clipboard tools and Wayland session environment. \(buildNote)"
        }
        if supportsExtDataControl(version: version) == false { return upgrade }
        if supportsExtDataControl(version: version) == true {
            return "Neither ext-data-control nor wlr-data-control is usable. The compositor may offer neither protocol (as on GNOME Wayland); install wayland-info to confirm the advertised globals and check the Wayland session environment. \(buildNote)"
        }
        return "Could not determine wl-clipboard's version. \(upgrade)"
    }
}
