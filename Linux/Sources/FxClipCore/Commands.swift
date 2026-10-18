import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct CommandResult {
    public let status: Int32
    public let output: Data
    public let error: String
    public var text: String { String(data: output, encoding: .utf8) ?? "" }
}

public enum Commands {
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for dir in (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") {
            let path = String(dir) + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Tools communicate through pipes, never the shell; clipboard values never enter argv.
    public static func run(_ name: String, _ arguments: [String] = [], input: Data? = nil,
                           timeout: TimeInterval = 2) -> CommandResult {
        guard let path = find(name) else { return CommandResult(status: 127, output: Data(), error: "Missing command: \(name)") }
        let p = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = out; p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try p.run() } catch { return CommandResult(status: 126, output: Data(), error: "Cannot start \(name)") }
        // Drain both outputs concurrently, and bound unresponsive clipboard owners.
        let output = DataBox(), errors = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { output.value = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errors.value = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if let input {
            group.enter()
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
                group.leave()
            }
        }
        let timeoutTask = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
        p.waitUntilExit()
        timeoutTask.cancel()
        // wl-copy backgrounds an owner process; it inherits stdout/stderr. Do not
        // wait for that owner: --foreground is managed separately below instead.
        group.wait()
        return CommandResult(status: p.terminationStatus, output: output.value,
                             error: String(data: errors.value, encoding: .utf8) ?? "")
    }
}

private final class DataBox: @unchecked Sendable { var value = Data() }

public final class WaylandClipboard {
    private var owner: Process?
    public init() {}

    public func read() -> ClipboardSnapshot? {
        let types = Commands.run("wl-paste", ["--list-types"])
        guard types.status == 0 else { return nil }
        let offered = Set(types.text.split(whereSeparator: \.isNewline).map(String.init))
        guard ClipboardSnapshot.allows(offered) else { return nil }
        let mime = offered.contains("text/plain;charset=utf-8") ? "text/plain;charset=utf-8" :
            offered.contains("text/plain") ? "text/plain" : offered.sorted().first(where: { $0.hasPrefix("text/plain;") })!
        let text = Commands.run("wl-paste", ["--no-newline", "--type", mime])
        guard text.status == 0, let value = String(data: text.output, encoding: .utf8),
              !value.contains("\0"), Commands.run("wl-paste", ["--list-types"]).output == types.output else { return nil }
        return ClipboardSnapshot(types: offered, text: value)
    }

    public func write(_ text: String) -> Bool {
        guard let path = Commands.find("wl-copy") else { return false }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--foreground", "--type", "text/plain;charset=utf-8"]
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try pipe.fileHandleForWriting.close()
        } catch { if p.isRunning { p.terminate() }; return false }
        // A new wl-copy owner replaces the old one, which then exits itself.
        owner = p
        return true
    }

    public static func dataControlAvailable() -> Bool {
        // --watch requires data-control even with an empty clipboard. A supported
        // compositor keeps it waiting; an unsupported one exits with an error.
        let result = Commands.run("wl-paste", ["--watch", "true"], timeout: 0.4)
        return result.status == SIGKILL
    }
}
