import Foundation

/// No message bodies or links are persisted. Reserve an update before side effects:
/// an interrupted/ambiguous send must never lead to deleting the original on retry.
public struct BotState: Codable {
    public var offset: Int64 = 0
    public var chats: [String: ChatSettings] = [:]
    public var users: [String: Mode] = [:]
    public var defaultMode: Mode = .reply
    public var lastUpdateAt: TimeInterval = Date().timeIntervalSince1970
    public var knownGroups: [String: KnownGroup] = [:]
    public var groupEnabled: [String: Bool] = [:]
    public var userLanguages: [String: BotLanguage] = [:]
    public var detectedLanguages: [String: BotLanguage] = [:]
    public var groupLanguages: [String: BotLanguage] = [:]
    public init() {}

    enum CodingKeys: String, CodingKey {
        case offset, chats, users, defaultMode, lastUpdateAt, knownGroups, groupEnabled
        case userLanguages, detectedLanguages, groupLanguages
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        offset = try values.decode(Int64.self, forKey: .offset)
        chats = try values.decode([String: ChatSettings].self, forKey: .chats)
        users = try values.decode([String: Mode].self, forKey: .users)
        defaultMode = try values.decode(Mode.self, forKey: .defaultMode)
        lastUpdateAt = try values.decode(TimeInterval.self, forKey: .lastUpdateAt)
        knownGroups = try values.decodeIfPresent([String: KnownGroup].self, forKey: .knownGroups) ?? [:]
        groupEnabled = try values.decodeIfPresent([String: Bool].self, forKey: .groupEnabled) ?? [:]
        userLanguages = try values.decodeIfPresent([String: BotLanguage].self, forKey: .userLanguages) ?? [:]
        detectedLanguages = try values.decodeIfPresent([String: BotLanguage].self, forKey: .detectedLanguages) ?? [:]
        groupLanguages = try values.decodeIfPresent([String: BotLanguage].self, forKey: .groupLanguages) ?? [:]
    }
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
    public func discover(_ chat: Chat, member: ChatMember? = nil) throws {
        guard chat.isGroup else { return }
        let key = String(chat.id)
        var next = state
        if member?.isAbsent == true {
            next.knownGroups.removeValue(forKey: key)
            // Override even an environment default, including after restart/re-addition.
            next.groupEnabled[key] = false
        } else {
            var group = next.knownGroups[key] ?? KnownGroup(chat: chat)
            group.chat = Chat(id: chat.id, type: chat.type, title: chat.title ?? group.chat.title)
            if let member { group.member = member }
            next.knownGroups[key] = group
        }
        guard next.knownGroups != state.knownGroups || next.groupEnabled != state.groupEnabled else { return }
        try save(next)
    }
    public func setGroupEnabled(_ enabled: Bool, chatID: Int64) throws {
        let key = String(chatID)
        guard state.groupEnabled[key] != enabled else { return }
        var next = state
        next.groupEnabled[key] = enabled
        try save(next)
    }
    public func observeLanguage(_ user: TelegramUser?) throws {
        guard let user, user.is_bot != true, let language = BotLanguage.telegram(user.language_code),
              state.detectedLanguages[String(user.id)] != language else { return }
        var next = state
        next.detectedLanguages[String(user.id)] = language
        try save(next)
    }
    public func userLanguage(_ userID: Int64) -> BotLanguage {
        state.userLanguages[String(userID)] ?? state.detectedLanguages[String(userID)] ?? .en
    }
    public func groupLanguage(_ chatID: Int64) -> BotLanguage {
        state.groupLanguages[String(chatID)] ?? .en
    }
    public func setUserLanguage(_ language: BotLanguage?, userID: Int64) throws {
        guard state.userLanguages[String(userID)] != language else { return }
        var next = state
        next.userLanguages[String(userID)] = language
        try save(next)
    }
    public func setGroupLanguage(_ language: BotLanguage, chatID: Int64) throws {
        guard state.groupLanguages[String(chatID)] != language else { return }
        var next = state
        next.groupLanguages[String(chatID)] = language
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
