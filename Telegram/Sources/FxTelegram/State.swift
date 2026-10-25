import Foundation
import FxEngine

/// The exact original that a single explicit replacement may delete.
public struct OriginalPublication: Codable, Equatable {
    public let messageID: Int64
    public let date: Int

    public init(messageID: Int64, date: Int) {
        self.messageID = messageID
        self.date = date
    }
}

/// Ownership metadata only; publication content is never persisted here.
public struct PublicationReceipt: Codable, Equatable {
    public let posterID: Int64
    public let createdAt: TimeInterval
    public var original: OriginalPublication?
    public static let retention: TimeInterval = 172_800
    static let capacity = 20_000

    public init(posterID: Int64, createdAt: TimeInterval, original: OriginalPublication? = nil) {
        self.posterID = posterID
        self.createdAt = createdAt
        self.original = original
    }

    enum CodingKeys: String, CodingKey { case posterID, createdAt, original }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        posterID = try values.decode(Int64.self, forKey: .posterID)
        createdAt = try values.decode(TimeInterval.self, forKey: .createdAt)
        original = try values.decodeIfPresent(OriginalPublication.self, forKey: .original)
    }
}

public enum PublicationStateError: Error, Equatable {
    case invalidReceipt
    case capacityReached
}

public struct ReplyControl: Codable, Equatable {
    public let posterID: Int64
    public let createdAt: TimeInterval
    public let openButton: InlineKeyboardButton?
    public static let lifetime: TimeInterval = 5 * 60
    public static let retention: TimeInterval = 48 * 60 * 60

    public init(posterID: Int64, createdAt: TimeInterval, openButton: InlineKeyboardButton? = nil) {
        self.posterID = posterID
        self.createdAt = createdAt
        self.openButton = openButton
    }
}

/// Message bodies and media are never persisted. Only a known source Open URL
/// button's label and URL are retained while its keyboard cleanup is pending.
/// Reserve an update before side effects:
/// an interrupted/ambiguous send must never lead to deleting the original on retry.
public struct BotState: Codable {
    public var offset: Int64 = 0
    public var chats: [String: ChatSettings] = [:]
    public var users: [String: Mode] = [:]
    public var personalSecretary: [String: Bool] = [:]
    public var defaultMode: Mode = .reply
    public var lastUpdateAt: TimeInterval = Date().timeIntervalSince1970
    public var knownGroups: [String: KnownGroup] = [:]
    public var groupEnabled: [String: Bool] = [:]
    public var userLanguages: [String: BotLanguage] = [:]
    public var detectedLanguages: [String: BotLanguage] = [:]
    public var groupLanguages: [String: BotLanguage] = [:]
    public var defaultLinkSettings = UserSettings()
    public var personalLinkSettings: [String: UserSettings] = [:]
    public var defaultYouTubeCards = true
    public var personalYouTubeCards: [String: Bool] = [:]
    public var defaultFacebookReels = false
    public var personalFacebookReels: [String: Bool] = [:]
    public var defaultRedditVideos = false
    public var personalRedditVideos: [String: Bool] = [:]
    public var replyControls: [String: ReplyControl] = [:]
    public var publications: [String: PublicationReceipt] = [:]
    public init() {}

    enum CodingKeys: String, CodingKey {
        case offset, chats, users, personalSecretary, defaultMode, lastUpdateAt, knownGroups, groupEnabled
        case userLanguages, detectedLanguages, groupLanguages
        case defaultLinkSettings, personalLinkSettings, defaultYouTubeCards, personalYouTubeCards
        case defaultFacebookReels, personalFacebookReels
        case defaultRedditVideos, personalRedditVideos
        case replyControls, publications
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        offset = try values.decode(Int64.self, forKey: .offset)
        chats = try values.decode([String: ChatSettings].self, forKey: .chats)
        users = try values.decode([String: Mode].self, forKey: .users)
        personalSecretary = try values.decodeIfPresent([String: Bool].self, forKey: .personalSecretary) ?? [:]
        defaultMode = try values.decode(Mode.self, forKey: .defaultMode)
        lastUpdateAt = try values.decode(TimeInterval.self, forKey: .lastUpdateAt)
        knownGroups = try values.decodeIfPresent([String: KnownGroup].self, forKey: .knownGroups) ?? [:]
        groupEnabled = try values.decodeIfPresent([String: Bool].self, forKey: .groupEnabled) ?? [:]
        userLanguages = try values.decodeIfPresent([String: BotLanguage].self, forKey: .userLanguages) ?? [:]
        detectedLanguages = try values.decodeIfPresent([String: BotLanguage].self, forKey: .detectedLanguages) ?? [:]
        groupLanguages = try values.decodeIfPresent([String: BotLanguage].self, forKey: .groupLanguages) ?? [:]
        defaultLinkSettings = try values.decodeIfPresent(UserSettings.self, forKey: .defaultLinkSettings) ?? UserSettings()
        personalLinkSettings = try values.decodeIfPresent([String: UserSettings].self, forKey: .personalLinkSettings) ?? [:]
        defaultYouTubeCards = try values.decodeIfPresent(Bool.self, forKey: .defaultYouTubeCards) ?? true
        personalYouTubeCards = try values.decodeIfPresent([String: Bool].self, forKey: .personalYouTubeCards) ?? [:]
        defaultFacebookReels = try values.decodeIfPresent(Bool.self, forKey: .defaultFacebookReels) ?? false
        personalFacebookReels = try values.decodeIfPresent([String: Bool].self, forKey: .personalFacebookReels) ?? [:]
        defaultRedditVideos = try values.decodeIfPresent(Bool.self, forKey: .defaultRedditVideos) ?? false
        personalRedditVideos = try values.decodeIfPresent([String: Bool].self, forKey: .personalRedditVideos) ?? [:]
        replyControls = try values.decodeIfPresent([String: ReplyControl].self, forKey: .replyControls) ?? [:]
        publications = try values.decodeIfPresent([String: PublicationReceipt].self, forKey: .publications) ?? [:]
        for (key, control) in replyControls.sorted(by: { $0.key < $1.key }) where !values.contains(.publications) {
            guard publications.count < PublicationReceipt.capacity else { break }
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let chatID = Int64(parts[0]), chatID != 0,
                  let messageID = Int64(parts[1]), messageID > 0,
                  key == "\(chatID):\(messageID)",
                  control.posterID > 0, control.createdAt.isFinite else { continue }
            publications[key] = PublicationReceipt(posterID: control.posterID, createdAt: control.createdAt)
        }
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
        if mode == .secretary {
            try setSecretary(true, userID: userID)
            return
        }
        let key = String(userID)
        var next = state
        // Retain legacy private-chat consent before changing the group choice.
        if next.personalSecretary[key] == nil {
            next.personalSecretary[key] = secretaryEnabled(userID: userID)
        }
        next.users[key] = mode
        try save(next)
    }
    public func secretaryEnabled(userID: Int64) -> Bool {
        let key = String(userID)
        return state.personalSecretary[key] ?? ((state.users[key] ?? state.defaultMode) == .secretary)
    }
    public func setSecretary(_ enabled: Bool, userID: Int64) throws {
        let key = String(userID)
        var next = state
        next.personalSecretary[key] = enabled
        if next.users[key] == .secretary {
            next.users.removeValue(forKey: key)
        }
        try save(next)
    }
    public func setDefault(_ mode: Mode) throws {
        var next = state
        next.defaultMode = mode
        try save(next)
    }
    public func setDefaultLinks(_ settings: UserSettings, youTubeCards: Bool) throws {
        var next = state
        next.defaultLinkSettings = settings
        next.defaultYouTubeCards = youTubeCards
        try save(next)
    }
    public func setPersonalLinks(_ settings: UserSettings?, youTubeCards: Bool?, userID: Int64) throws {
        var next = state
        next.personalLinkSettings[String(userID)] = settings
        next.personalYouTubeCards[String(userID)] = youTubeCards
        try save(next)
    }
    public func setDefaultFacebookReels(_ enabled: Bool) throws {
        var next = state
        next.defaultFacebookReels = enabled
        try save(next)
    }
    /// Nil restores inheritance; unrelated link-settings writes preserve this override.
    public func setPersonalFacebookReels(_ enabled: Bool?, userID: Int64) throws {
        var next = state
        next.personalFacebookReels[String(userID)] = enabled
        try save(next)
    }
    public func setDefaultRedditVideos(_ enabled: Bool) throws {
        var next = state
        next.defaultRedditVideos = enabled
        try save(next)
    }
    /// Nil restores inheritance; link-mirror settings remain independent.
    public func setPersonalRedditVideos(_ enabled: Bool?, userID: Int64) throws {
        var next = state
        next.personalRedditVideos[String(userID)] = enabled
        try save(next)
    }
    private static let publicationCapacity = PublicationReceipt.capacity

    /// Future-dated receipts still occupy a slot, but callers must reject them
    /// for authorization until now >= createdAt. Ownership expires at exact 48 h.
    public func canRecordPublication(now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        return state.publications.values.lazy.filter {
            now - $0.createdAt < PublicationReceipt.retention
        }.prefix(Self.publicationCapacity).count < Self.publicationCapacity
    }
    public func recordPublication(chatID: Int64, messageID: Int64, posterID: Int64,
                                  now: TimeInterval, original: OriginalPublication? = nil) throws {
        guard chatID != 0, messageID > 0, posterID > 0, now.isFinite else {
            throw PublicationStateError.invalidReceipt
        }
        var next = state
        next.publications = state.publications.filter { now - $0.value.createdAt < PublicationReceipt.retention }
        guard next.publications.count < Self.publicationCapacity else {
            if next.publications != state.publications { try save(next) }
            throw PublicationStateError.capacityReached
        }
        next.publications["\(chatID):\(messageID)"] = PublicationReceipt(posterID: posterID, createdAt: now,
                                                                    original: original)
        try save(next)
    }
    /// Persist consumption before crediting through Telegram. An ambiguous edit
    /// or restart must never authorize a second attempt to delete the original.
    public func consumePublicationOriginal(chatID: Int64, messageID: Int64, posterID: Int64,
                                           now: TimeInterval) throws -> OriginalPublication? {
        let key = "\(chatID):\(messageID)"
        guard chatID != 0, messageID > 0, posterID > 0, now.isFinite,
              let receipt = state.publications[key], receipt.posterID == posterID,
              receipt.createdAt.isFinite,
              now >= receipt.createdAt, now - receipt.createdAt < ReplyControl.lifetime,
              let original = receipt.original,
              Self.validOriginal(original, botMessageID: messageID, now: now) else { return nil }
        var next = state
        next.publications[key]?.original = nil
        try save(next)
        return original
    }
    /// An observed original edit retires only its replacement authority. The
    /// poster can still remove the bot publication through the existing paths.
    public func invalidatePublicationOriginal(chatID: Int64, originalMessageID: Int64) throws {
        let keys = state.publications.keys.filter {
            $0.hasPrefix("\(chatID):") && state.publications[$0]?.original?.messageID == originalMessageID
        }
        guard !keys.isEmpty else { return }
        var next = state
        for key in keys { next.publications[key]?.original = nil }
        try save(next)
    }
    private static func validOriginal(_ original: OriginalPublication, botMessageID: Int64,
                                      now: TimeInterval) -> Bool {
        original.messageID > 0 && original.messageID != botMessageID && original.date > 0 &&
            TimeInterval(original.date) <= now && now - TimeInterval(original.date) < PublicationReceipt.retention
    }
    public func removePublication(chatID: Int64, messageID: Int64) throws {
        let key = "\(chatID):\(messageID)"
        guard state.publications[key] != nil || state.replyControls[key] != nil else { return }
        var next = state
        next.publications.removeValue(forKey: key)
        next.replyControls.removeValue(forKey: key)
        try save(next)
    }
    public func prunePublications(now: TimeInterval) throws {
        guard now.isFinite else { throw PublicationStateError.invalidReceipt }
        let retained = state.publications.filter { now - $0.value.createdAt < PublicationReceipt.retention }
            .mapValues { receipt in
                var receipt = receipt
                // Expire deletion metadata even if no keyboard cleanup was
                // recorded, or Telegram keeps failing to remove its buttons.
                if now - receipt.createdAt >= ReplyControl.lifetime { receipt.original = nil }
                return receipt
            }
        guard retained != state.publications else { return }
        var next = state
        next.publications = retained
        try save(next)
    }
    public func recordReplyControl(chatID: Int64, messageID: Int64, posterID: Int64, now: TimeInterval,
                                   openButton: InlineKeyboardButton? = nil) throws {
        var next = state
        next.replyControls = state.replyControls.filter { now - $0.value.createdAt < ReplyControl.retention }
        if next.replyControls.count >= 4096,
           let oldest = next.replyControls.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            next.replyControls.removeValue(forKey: oldest)
        }
        next.replyControls["\(chatID):\(messageID)"] = ReplyControl(posterID: posterID, createdAt: now,
                                                                 openButton: openButton)
        try save(next)
    }
    public func removeReplyControl(chatID: Int64, messageID: Int64) throws {
        try removeReplyControl(key: "\(chatID):\(messageID)")
    }
    func removeReplyControl(key: String) throws {
        guard state.replyControls[key] != nil || state.publications[key]?.original != nil else { return }
        var next = state
        next.replyControls.removeValue(forKey: key)
        next.publications[key]?.original = nil
        try save(next)
    }
    public func pruneReplyControls(now: TimeInterval = Date().timeIntervalSince1970) throws {
        let retained = state.replyControls.filter { now - $0.value.createdAt < ReplyControl.retention }
        guard retained != state.replyControls else { return }
        var next = state
        next.replyControls = retained
        try save(next)
    }
    /// Wake polling for the next authorization deadline. Expired entries are
    /// retried by maintenance and must not force polling to spin every second.
    public func replyControlPollingTimeout(now: TimeInterval, max: Int = 30) -> Int {
        let limit = Swift.max(1, max)
        let nextDeadline = state.replyControls.values.lazy
            .map { $0.createdAt + ReplyControl.lifetime }
            .filter { $0 > now }
            .min()
        guard let nextDeadline else { return limit }
        let remaining = ceil(nextDeadline - now)
        guard remaining < Double(limit) else { return limit }
        return Swift.max(1, Int(remaining))
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
