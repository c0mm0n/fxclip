import Foundation
import FxEngine
import FxTelegram

@main struct Main {
    static func main() async {
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
        let api = TelegramAPI(token: token)
        let me = try decode(TelegramUser.self, from: await api.call("getMe"))
        let webhook = try await api.call("getWebhookInfo") as? [String: Any]
        guard (webhook?["url"] as? String) == "" else {
            throw BotError.configuration("Remove existing webhook before polling")
        }
        let bot = Bot(api: api, store: store, engine: Engine(rules: rules), allowedChats: chats, allowedOwners: owners,
                      botID: me.id, username: me.username ?? "")
        print("fxclip Telegram ready; \(chats.count) group(s) allowed; default mode: \(store.state.defaultMode.rawValue).")
        print("Group cleaning requires the allowlist. Secretary separately handles opted-in connected private chats.")
        var failures = 0
        while !Task.isCancelled {
            try store.resetIdleEpoch()
            let updates: [Update]
            do {
                updates = try decode([Update].self, from: await api.call("getUpdates", [
                    "offset": store.state.offset, "timeout": 30,
                    "allowed_updates": ["message", "edited_message", "callback_query", "business_message", "edited_business_message"],
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
                do { try await bot.handle(update) }
                catch { print("Update skipped after an error; original message retained.") }
            }
        }
    }
}
