import Foundation

public enum Desktop: String {
    case hyprland = "Hyprland", sway = "Sway", kde = "KDE Plasma", gnome = "GNOME Wayland", unknown = "Unknown Wayland compositor"
    public static func detect(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Desktop {
        if env["HYPRLAND_INSTANCE_SIGNATURE"] != nil { return .hyprland }
        if env["SWAYSOCK"] != nil { return .sway }
        let desktop = ((env["XDG_CURRENT_DESKTOP"] ?? "") + ":" + (env["XDG_SESSION_DESKTOP"] ?? "")).lowercased()
        if desktop.contains("gnome") { return .gnome }
        if desktop.contains("kde") || desktop.contains("plasma") { return .kde }
        if desktop.contains("hyprland") { return .hyprland }
        if desktop.contains("sway") { return .sway }
        return .unknown
    }
}

public final class Focus {
    public let desktop: Desktop
    private var subscription: Process?
    public init(desktop: Desktop) { self.desktop = desktop }

    /// Subscribe so focus changes trigger the next run-loop turn immediately;
    /// polling also covers reconnects, missing tools and settings changes.
    public func start(onChange: @escaping () -> Void) {
        guard desktop == .sway, let path = Commands.find("swaymsg") else { return }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-m", "-t", "subscribe", "[\"window\"]"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async(execute: onChange)
        }
        do { try p.run(); subscription = p } catch { pipe.fileHandleForReading.readabilityHandler = nil }
    }

    public func stop() { if let p = subscription, p.isRunning { p.terminate() }; subscription = nil }

    public func current() -> String? {
        switch desktop {
        case .hyprland:
            let r = Commands.run("hyprctl", ["-j", "activewindow"])
            guard r.status == 0, let object = try? JSONSerialization.jsonObject(with: r.output) as? [String: Any] else { return nil }
            return object["class"] as? String
        case .sway:
            let r = Commands.run("swaymsg", ["-r", "-t", "get_tree"])
            guard r.status == 0, let object = try? JSONSerialization.jsonObject(with: r.output) as? [String: Any] else { return nil }
            return Self.swayApp(object)
        case .kde:
            let window = Commands.run("kdotool", ["getactivewindow"])
            guard window.status == 0, !window.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let r = Commands.run("kdotool", ["getwindowclassname", window.text.trimmingCharacters(in: .whitespacesAndNewlines)])
            return r.status == 0 ? r.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        case .gnome, .unknown: return nil
        }
    }

    public static func swayApp(_ node: [String: Any]) -> String? {
        if node["focused"] as? Bool == true {
            if let app = node["app_id"] as? String, !app.isEmpty { return app }
            return (node["window_properties"] as? [String: Any])?["class"] as? String
        }
        for child in (node["nodes"] as? [[String: Any]] ?? []) + (node["floating_nodes"] as? [[String: Any]] ?? []) {
            if let app = swayApp(child) { return app }
        }
        return nil
    }
}
