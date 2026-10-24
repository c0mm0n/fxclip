import Foundation

/// No message bodies or links are persisted. Reserve an update before side effects:
/// an interrupted/ambiguous send must never lead to deleting the original on retry.
public struct BotState: Codable {
    public var offset: Int64 = 0
    public var chats: [String: ChatSettings] = [:]
    public var users: [String: Mode] = [:]
    public var defaultMode: Mode = .reply
    public var lastUpdateAt: TimeInterval = Date().timeIntervalSince1970
    public init() {}
}

public final class StateStore {
    public private(set) var state: BotState
    private let path: URL
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: path.path) {
            state = try JSONDecoder().decode(BotState.self, from: Data(contentsOf: path))
        } else { state = BotState() }
    }
    public func reserve(_ updateID: Int64, now: TimeInterval = Date().timeIntervalSince1970) throws -> Bool {
        guard updateID >= state.offset else { return false }
        var next = state
        next.offset = updateID + 1
        next.lastUpdateAt = now
        try save(next)
        return true
    }
    /// Telegram may randomize IDs after seven idle days. Re-open the polling epoch;
    /// old queued messages remain harmless because the handler rejects stale dates.
    public func resetIdleEpoch(now: TimeInterval = Date().timeIntervalSince1970) throws {
        guard now - state.lastUpdateAt >= 7 * 24 * 60 * 60 else { return }
        var next = state
        next.offset = 0
        next.lastUpdateAt = now
        try save(next)
    }
    public func set(_ settings: ChatSettings, chatID: Int64) throws {
        var next = state
        next.chats[String(chatID)] = settings
        try save(next)
    }
    public func setMode(_ mode: Mode?, userID: Int64) throws {
        var next = state
        next.users[String(userID)] = mode
        try save(next)
    }
    public func setDefault(_ mode: Mode) throws {
        var next = state
        next.defaultMode = mode
        try save(next)
    }
    public func checkWritable() throws {
        let probe = path.deletingLastPathComponent().appendingPathComponent(".write-check-\(UUID().uuidString)")
        try Data().write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)
    }
    private func save(_ next: BotState) throws {
        try JSONEncoder().encode(next).write(to: path, options: .atomic)
        state = next
    }
}
