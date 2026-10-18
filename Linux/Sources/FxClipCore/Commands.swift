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
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                            executableURL: URL? = Bundle.main.executableURL) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        if name == "wl-copy" || name == "wl-paste" {
            var directories: [URL] = []
            if let executableURL {
                directories.append(executableURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("libexec"))
            }
            if let home = environment["HOME"] {
                directories.append(URL(fileURLWithPath: home).appendingPathComponent(".local/lib/fxclip"))
            }
            for directory in directories {
                let path = directory.appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        for dir in (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") {
            let path = String(dir) + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Tools communicate through pipes, never the shell; clipboard values never enter argv.
    public static func run(_ name: String, _ arguments: [String] = [], input: Data? = nil,
                           timeout: TimeInterval = 2) -> CommandResult {
        guard let command = RunningCommand(name, arguments, input: input) else {
            return CommandResult(status: 127, output: Data(), error: "Cannot start command: \(name)")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            command.pump()
            if let status = command.status, command.drained {
                return CommandResult(status: status, output: command.output, error: command.error)
            }
            usleep(5_000)
        }
        command.cancel()
        return CommandResult(status: SIGKILL, output: command.output, error: command.error)
    }
}

/// Spawn atomically into a new process group: descendants cannot retain our pipes
/// after a timeout. Nonblocking I/O also bounds draining if a child escapes it.
final class RunningCommand {
    private let pid: pid_t
    private let out = Pipe(), err = Pipe(), stdin = Pipe()
    private var outOpen = true, errOpen = true, inputOpen = true
    private let input: Data
    private var offset = 0
    private(set) var output = Data()
    private var errors = Data()
    private(set) var status: Int32?
    var error: String { String(data: errors, encoding: .utf8) ?? "" }
    var drained: Bool { !outOpen && !errOpen && !inputOpen }

    init?(_ name: String, _ arguments: [String], input: Data? = nil) {
        guard let path = Commands.find(name) else { return nil }
        self.input = input ?? Data()
        // A reader may disappear while we are supplying stdin.
        signal(SIGPIPE, SIG_IGN)
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let handles = [stdin.fileHandleForReading, stdin.fileHandleForWriting,
                       out.fileHandleForReading, out.fileHandleForWriting,
                       err.fileHandleForReading, err.fileHandleForWriting]
        for (handle, target) in [(stdin.fileHandleForReading, STDIN_FILENO),
                                 (out.fileHandleForWriting, STDOUT_FILENO),
                                 (err.fileHandleForWriting, STDERR_FILENO)] {
            posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, target)
        }
        for handle in handles {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
            posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor)
        }
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for ptr in argv + envp { free(ptr) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&child, path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { return nil }
        pid = child
        try? stdin.fileHandleForReading.close()
        try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
        for handle in [stdin.fileHandleForWriting, out.fileHandleForReading, err.fileHandleForReading] {
            _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK)
        }
    }

    func pump() {
        // Cap each pass even if a process continuously produces output.
        func drain(_ handle: FileHandle, _ open: inout Bool, _ data: inout Data) {
            guard open else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<64 {
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
                else {
                    if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        try? handle.close(); open = false
                    }
                    break
                }
            }
        }
        drain(out.fileHandleForReading, &outOpen, &output)
        drain(err.fileHandleForReading, &errOpen, &errors)
        if inputOpen {
            if offset < input.count {
                let count = input.withUnsafeBytes { bytes in
                    write(stdin.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: offset), input.count - offset)
                }
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR { offset = input.count }
            }
            if offset == input.count { try? stdin.fileHandleForWriting.close(); inputOpen = false }
        }
        if status == nil {
            var value: Int32 = 0
            if waitpid(pid, &value, WNOHANG) == pid {
                status = value & 0x7f == 0 ? (value >> 8) & 0xff : value & 0x7f
            }
        }
    }

    func cancel() {
        kill(-pid, SIGKILL)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        repeat { pump(); if status != nil { break }; usleep(1_000) } while ProcessInfo.processInfo.systemUptime < deadline
        // Never wait for EOF from an escaped descendant.
        if outOpen { try? out.fileHandleForReading.close(); outOpen = false }
        if errOpen { try? err.fileHandleForReading.close(); errOpen = false }
        if inputOpen { try? stdin.fileHandleForWriting.close(); inputOpen = false }
    }
}

public final class WaylandClipboard {
    private var owner: RunningCommand?
    private let writerLock = NSLock()
    private let copyCommand: String
    private let copyArguments: [String]
    private let readOverride: ((TimeInterval) -> ClipboardSnapshot?)?
    public convenience init() {
        self.init(copyCommand: "wl-copy", copyArguments: ["--foreground", "--type", "text/plain;charset=utf-8"])
    }
    init(copyCommand: String, copyArguments: [String], read: ((TimeInterval) -> ClipboardSnapshot?)? = nil) {
        self.copyCommand = copyCommand; self.copyArguments = copyArguments; self.readOverride = read
    }

    public func read() -> ClipboardSnapshot? { read(timeout: 2) }

    private func read(timeout: TimeInterval) -> ClipboardSnapshot? {
        if let readOverride { return readOverride(timeout) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func paste(_ arguments: [String]) -> CommandResult {
            Commands.run("wl-paste", arguments, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        }
        let types = paste(["--list-types"])
        guard types.status == 0 else { return nil }
        let offered = Set(types.text.split(whereSeparator: \.isNewline).map(String.init))
        guard ClipboardSnapshot.allows(offered) else { return nil }
        let mime = offered.contains("text/plain;charset=utf-8") ? "text/plain;charset=utf-8" :
            offered.contains("text/plain") ? "text/plain" : offered.sorted().first(where: { $0.hasPrefix("text/plain;") })!
        let text = paste(["--no-newline", "--type", mime])
        guard text.status == 0, let value = String(data: text.output, encoding: .utf8),
              !value.contains("\0") else { return nil }
        let finalTypes = paste(["--list-types"])
        guard finalTypes.status == 0, finalTypes.output == types.output else { return nil }
        return ClipboardSnapshot(types: offered, text: value)
    }

    /// A write is complete only once wl-copy serves the requested selection.
    /// Failed/pending owners are killed before another writer can start.
    public func write(_ text: String, replacing expected: ClipboardSnapshot,
                      stillValid: () -> Bool = { true }) -> Bool {
        writerLock.lock(); defer { writerLock.unlock() }
        guard read() == expected, stillValid(),
              let pending = RunningCommand(copyCommand, copyArguments, input: Data(text.utf8)) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while ProcessInfo.processInfo.systemUptime < deadline {
            pending.pump()
            if pending.status != nil { break }
            if let selection = read(timeout: min(0.1, deadline - ProcessInfo.processInfo.systemUptime)) {
                if selection.text == text && selection.types.isDisjoint(with: ["text/html", "text/rtf", "application/rtf"]) {
                    owner?.cancel()
                    owner = pending
                    return true
                }
                // A user's newer copy wins; do not leave a delayed writer alive.
                if selection != expected { break }
            }
            usleep(5_000)
        }
        pending.cancel()
        return false
    }

    public static func dataControlAvailable() -> Bool {
        // --watch requires data-control even with an empty clipboard. A supported
        // compositor keeps it waiting; an unsupported one exits with an error.
        let result = Commands.run("wl-paste", ["--watch", "true"], timeout: 0.4)
        return result.status == SIGKILL
    }
}
