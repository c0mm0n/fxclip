import Foundation
import FxEngine
import FxTelegram

@main struct Main {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch {
            // Errors may embed the token-bearing request URL or message contents.
            print("fxclip stopped: check token file, configuration, state volume, and Telegram connectivity.")
            exit(1)
        }
    }
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let rules = try Rules.load(Data(contentsOf: URL(fileURLWithPath: env["FXCLIP_RULES"] ?? "/app/rules.json")))
        if CommandLine.arguments.contains("--check") {
            guard !rules.apps.isEmpty else { throw BotError.configuration("Empty rules") }
            print("fxclip Telegram: engine and rules OK")
            return
        }
        let token = try String(contentsOfFile: env["TELEGRAM_TOKEN_FILE"] ?? "/run/secrets/telegram_token", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: #"^[0-9]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw BotError.configuration("Invalid token")
        }
        let rawChats = (env["TELEGRAM_ALLOWED_CHATS"] ?? "").split(separator: ",")
        let chats = try Set(rawChats.map { raw -> Int64 in
            guard let id = Int64(raw.trimmingCharacters(in: .whitespaces)) else {
                throw BotError.configuration("Invalid chat ID")
            }
            return id
        })
        let owners = try Set((env["TELEGRAM_OWNER_IDS"] ?? "").split(separator: ",").map { raw -> Int64 in
            guard let id = Int64(raw.trimmingCharacters(in: .whitespaces)) else {
                throw BotError.configuration("Invalid owner ID")
            }
            return id
        })
        let store = try StateStore(directory: URL(fileURLWithPath: env["FXCLIP_DATA"] ?? "/data"))
        try store.checkWritable()
        if CommandLine.arguments.contains("--check-config") {
            print("fxclip Telegram: token readable, rules/configuration valid, state writable")
            return
        }
        let diagnostics = env["FXCLIP_DIAGNOSTICS"] == "1"
        let api = TelegramAPI(token: token, diagnostics: diagnostics)
        let me = try decode(TelegramUser.self, from: await api.call("getMe"))
        let webhook = try await api.call("getWebhookInfo") as? [String: Any]
        guard (webhook?["url"] as? String) == "" else {
            throw BotError.configuration("Remove existing webhook before polling")
        }
        do {
            try await BotProfile.configure(api: api, ownerIDs: owners, userLanguages: store.state.userLanguages)
        } catch {
            // A temporary profile failure must not stop link cleaning or expose the token.
            print("Telegram profile localization could not be refreshed; continuing with saved settings.")
        }
        let bot = Bot(api: api, store: store, engine: Engine(rules: rules), allowedChats: chats, allowedOwners: owners,
                      botID: me.id, username: me.username ?? "", youTubeMetadata: YouTubeMetadataFetcher(),
                      facebookReels: FacebookReelFetcher(), redditVideos: RedditVideoFetcher())
        print("fxclip Telegram ready; \(store.state.knownGroups.count) group(s) discovered; default mode: \(store.state.defaultMode.rawValue).")
        print("Group cleaning follows admin activation settings. Secretary separately handles opted-in connected private chats.")
        var failures = 0
        while !Task.isCancelled {
            try store.resetIdleEpoch()
            try await bot.expireReplyControls()
            let updates: [Update]
            do {
                updates = try decode([Update].self, from: await api.call("getUpdates", [
                    "offset": store.state.offset, "timeout": store.replyControlPollingTimeout(now: Date().timeIntervalSince1970),
                    "allowed_updates": ["message", "edited_message", "callback_query", "my_chat_member", "business_message", "edited_business_message"],
                ]))
                failures = 0
            } catch BotError.telegram(let code) where code == 401 || code == 409 {
                print("Polling stopped: invalid credential or another bot instance/webhook is active.")
                throw BotError.telegram(code)
            } catch {
                failures = min(failures + 1, 5)
                print("Telegram polling failed; reconnecting.")
                try await Task.sleep(nanoseconds: UInt64(1 << failures) * 1_000_000_000)
                continue
            }
            for update in coalesced(updates) {
                // A state write failure is fatal, before any Telegram side effect.
                guard try store.reserve(update.update_id) else { continue }
                try await bot.expireReplyControls()
                if diagnostics {
                    let scope = update.message?.chat.type == "private" ? "private"
                        : update.business_message != nil ? "business" : "other"
                    print("Update handling started: \(scope).")
                }
                do { try await bot.handle(update) }
                catch {
                    let category: String
                    if let error = error as? BotError {
                        switch error {
                        case .telegram(let code): category = "telegram_\((100...599).contains(code) ? code : 0)"
                        case .invalidResponse: category = "invalid_response"
                        case .configuration: category = "configuration"
                        }
                    } else if let error = error as? URLError { category = "url_\(error.code.rawValue)" }
                    else { category = "processing" }
                    print("Update skipped after an error (\(category)); original message retained.")
                }
            }
        }
    }
}
