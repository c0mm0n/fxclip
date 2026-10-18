import Foundation
import FxClipCore
import FxEngine
#if os(Linux)
import Glibc
#else
import Darwin
#endif

func rules() throws -> Rules {
    // The tarball and installer keep this file next to the real binary, so the
    // executable works regardless of cwd, PATH lookup or a symlinked launcher.
    let executable = Bundle.main.executableURL!.resolvingSymlinksInPath()
    return try Rules.load(Data(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("fxclip.rules.json")))
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--version"] { print("fxclip \(Version.value)"); return }
    if args.first == "clean" {
        guard args.count == 2 || (args.count == 4 && args[2] == "--app") else { throw Failure("Usage: fxclip clean <text> [--app <id>]") }
        let engine = Settings(rules: try rules()).engine
        let clean = engine.clean(args[1]).text
        print(args.count == 4 ? engine.preview(clean, forBundleID: args[3]) : clean)
        return
    }
    guard args.isEmpty || args == ["check"] else { throw Failure("Usage: fxclip [check | clean <text> [--app <id>] | --version]") }
    #if !os(Linux)
    throw Failure("The clipboard daemon and check command require Linux Wayland.")
    #else
    let desktop = Desktop.detect()
    let tools = Commands.find("wl-copy") != nil && Commands.find("wl-paste") != nil
    let wayland = ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] != nil
    let available = tools && wayland && desktop != .gnome && WaylandClipboard.dataControlAvailable()
    let focus = Focus(desktop: desktop)
    if args == ["check"] {
        print("Compositor: \(desktop.rawValue)")
        for name in ["wl-paste", "wl-copy"] {
            if let path = Commands.find(name) {
                let version = Commands.run(path, ["--version"]).text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                print("\(name): \(path) (\(version.isEmpty ? "version unavailable" : version))")
            } else {
                print("\(name): missing (reinstall the fxclip tarball or install wl-clipboard)")
            }
        }
        print("Data-control: \(available ? "available" : "unavailable")")
        if tools && wayland && !available {
            let version = Commands.run("wl-paste", ["--version"]).text
            let info = Commands.find("wayland-info").map { Commands.run($0) }
            let globals = info.flatMap { $0.status == 0 ? $0.text : nil }
            if let globals {
                let protocols = ClipboardDiagnostics.advertisedProtocols(globals)
                print("Advertised data-control: \(protocols.isEmpty ? "none" : protocols.joined(separator: ", "))")
            }
            print(ClipboardDiagnostics.failure(version: version, waylandInfo: globals))
        }
        let app = focus.current()
        print("Focused app: \(app ?? "unavailable (previews disabled)")")
        if let error = focus.lastError { print("Focus adapter error: \(error)") }
        print("Config: \(Settings.configURL().path)")
        if desktop == .gnome { print("GNOME Wayland does not support background clipboard access; use Sway, Hyprland or KDE Plasma.") }
        return
    }
    guard desktop != .gnome else { throw Failure("GNOME Wayland does not support background clipboard access (data-control). Use Sway, Hyprland or KDE Plasma.") }
    guard tools else { throw Failure("Reinstall the fxclip Linux tarball, or install wl-clipboard (wl-copy and wl-paste).") }
    guard wayland else { throw Failure("A Wayland session is required (WAYLAND_DISPLAY is unset).") }
    guard available else { throw Failure("Wayland data-control is unavailable. Background clipboard access requires Sway/wlroots, Hyprland or KDE Plasma.") }
    if desktop == .unknown { log("Unknown compositor: cleaning enabled; previews disabled.") }
    if desktop == .kde && Commands.find("kdotool") == nil { log("Install kdotool for KDE previews; cleaning is enabled.") }
    if desktop == .hyprland && Commands.find("hyprctl") == nil { log("hyprctl is missing; previews disabled, cleaning is enabled.") }
    let settings = Settings(rules: try rules())
    let clipboard = WaylandClipboard(), controller = ClipboardController()
    var updating = false
    let tick = {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        settings.reload()
        let app = focus.current()
        controller.tick(engine: settings.engine, app: app, read: clipboard.read, write: { text, expected in
            clipboard.write(text, replacing: expected, stillValid: { focus.current() == app })
        })
    }
    // Ignore SIGPIPE if a clipboard owner exits while a pipe is being read/written.
    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let quit = {
        controller.tick(engine: settings.engine, app: nil, read: clipboard.read, write: { text, expected in
            clipboard.write(text, replacing: expected)
        })
        // wl-copy must outlive us to keep the restored selection available.
        focus.stop()
        exit(0)
    }
    term.setEventHandler(handler: quit); interrupt.setEventHandler(handler: quit)
    term.resume(); interrupt.resume()
    focus.start(onChange: tick)
    let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in tick() }
    tick()
    log("Running on \(desktop.rawValue); clipboard contents are never logged or stored.")
    withExtendedLifetime((timer, term, interrupt, focus)) { RunLoop.main.run() }
    #endif
}

struct Failure: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }
do { try run() } catch { log(String(describing: error)); exit(1) }
