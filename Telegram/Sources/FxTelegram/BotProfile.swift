/// Native Telegram profile and command menus. English is the fallback for every locale.
public enum BotProfile {
    public static func configure(api: BotAPI, ownerIDs: Set<Int64>,
                                 userLanguages: [String: BotLanguage]) async throws {
        for (code, language): (String, BotLanguage) in [("", .en), ("fr", .fr)] {
            _ = try await api.call("setMyName", ["language_code": code, "name": "fxclip"])
            _ = try await api.call("setMyDescription", [
                "language_code": code,
                "description": language.text(
                    "fxclip cleans tracking from links and improves previews in Telegram. Open /settings to choose your preferences.",
                    "fxclip retire les paramètres de suivi des liens et améliore leurs aperçus dans Telegram. Ouvrez /settings pour choisir vos réglages.")
            ])
            _ = try await api.call("setMyShortDescription", [
                "language_code": code,
                "short_description": language.text(
                    "Clean links and better previews in Telegram.",
                    "Des liens nettoyés et de meilleurs aperçus dans Telegram.")
            ])
            try await setCommands(api: api, scope: ["type": "default"], code: code,
                                  commands: privateCommands(language: language, owner: false))
            try await setCommands(api: api, scope: ["type": "all_group_chats"], code: code,
                                  commands: groupCommands(language: language))
        }

        var preferences: [Int64: BotLanguage] = [:]
        for (key, language) in userLanguages {
            guard let id = Int64(key), id > 0, String(id) == key else { continue }
            preferences[id] = language
        }
        for id in ownerIDs.union(preferences.keys).filter({ $0 > 0 }).sorted() {
            try await configureUser(api: api, userID: id, language: preferences[id], owner: ownerIDs.contains(id))
        }
    }

    public static func configureUser(api: BotAPI, userID: Int64,
                                     language: BotLanguage?, owner: Bool) async throws {
        guard userID > 0 else { return }
        // Both slots must agree for an explicit preference, regardless of Telegram's locale.
        // Automatic mode restores each locale in the same chat scope, without deleting it.
        for (code, automatic): (String, BotLanguage) in [("", .en), ("fr", .fr)] {
            try await setCommands(api: api, scope: ["type": "chat", "chat_id": userID], code: code,
                                  commands: privateCommands(language: language ?? automatic, owner: owner))
        }
    }

    private static func setCommands(api: BotAPI, scope: [String: Any], code: String,
                                    commands: [[String: String]]) async throws {
        _ = try await api.call("setMyCommands", ["scope": scope, "language_code": code, "commands": commands])
    }

    private static func privateCommands(language: BotLanguage, owner: Bool) -> [[String: String]] {
        var commands = [
            ["command": "settings", "description": language.text("Choose your settings", "Choisir vos réglages")],
            ["command": "publications", "description": language.text("View and remove your recent publications", "Voir et retirer vos publications récentes")],
            ["command": "language", "description": language.text("Choose your language", "Choisir votre langue")],
            ["command": "help", "description": language.text("How fxclip works", "Comprendre fxclip")],
            ["command": "chatid", "description": language.text("Show this chat's ID", "Afficher l’identifiant de cette conversation")]
        ]
        if owner {
            commands += [
                ["command": "default", "description": language.text("Choose the general setting", "Choisir le réglage général")],
                ["command": "groups", "description": language.text("Manage connected groups", "Gérer les groupes connectés")]
            ]
        }
        return commands
    }

    private static func groupCommands(language: BotLanguage) -> [[String: String]] {
        [
            ["command": "setup", "description": language.text("Configure this group", "Configurer ce groupe")],
            ["command": "delete", "description": language.text("Reply to your fxclip message to delete it (under 48 h)", "Répondre à votre message fxclip pour le supprimer (moins de 48 h)")],
            ["command": "supprimer", "description": language.text("Same as /delete: remove your fxclip message", "Comme /delete : retirer votre message fxclip")],
            ["command": "fxclip", "description": language.text("Choose this group's link settings", "Choisir les réglages des liens de ce groupe")],
            ["command": "help", "description": language.text("How fxclip works", "Comprendre fxclip")],
            ["command": "chatid", "description": language.text("Show this chat's ID", "Afficher l’identifiant de cette conversation")]
        ]
    }
}
