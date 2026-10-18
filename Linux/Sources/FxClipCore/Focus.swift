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
    public private(set) var lastError: String?
    private var lastWarning: TimeInterval = -.infinity
    private let command: (String, [String]) -> CommandResult
    private let warning: (String) -> Void
    private let now: () -> TimeInterval
    public convenience init(desktop: Desktop) {
        self.init(desktop: desktop, command: { Commands.run($0, $1) }, warning: log)
    }
    init(desktop: Desktop, command: @escaping (String, [String]) -> CommandResult,
         warning: @escaping (String) -> Void, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.desktop = desktop; self.command = command; self.warning = warning; self.now = now
    }

    private func adapter(_ name: String, _ arguments: [String]) -> CommandResult? {
        let result = command(name, arguments)
        guard result.status == 0 else {
            // Do not include command output: it can contain window titles or other
            // private desktop content. The command and exit status are sufficient.
            lastError = "\(name) \(arguments.first ?? "") failed (exit \(result.status)); check the tool and graphical-session environment."
            if now() - lastWarning >= 60 { warning(lastError!); lastWarning = now() }
            return nil
        }
        return result
    }

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
        lastError = nil
        switch desktop {
        case .hyprland:
            guard let r = adapter("hyprctl", ["-j", "activewindow"]), let object = try? JSONSerialization.jsonObject(with: r.output) as? [String: Any] else { return nil }
            return object["class"] as? String
        case .sway:
            guard let r = adapter("swaymsg", ["-r", "-t", "get_tree"]), let object = try? JSONSerialization.jsonObject(with: r.output) as? [String: Any] else { return nil }
            return Self.swayApp(object)
        case .kde:
            guard let window = adapter("kdotool", ["getactivewindow"]),
                  !window.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let r = adapter("kdotool", ["getwindowclassname", window.text.trimmingCharacters(in: .whitespacesAndNewlines)]) else { return nil }
            return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
