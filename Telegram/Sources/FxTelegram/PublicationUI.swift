import Foundation

/// Transient presentation data. Only receipt IDs, author and date are persisted.
struct PublicationEntry {
    let chatID: Int64
    let messageID: Int64
    let createdAt: TimeInterval
    let title: String?

    var messageURL: String? {
        let id = String(chatID)
        guard id.hasPrefix("-100") else { return nil }
        let channel = id.dropFirst(4)
        guard !channel.isEmpty, channel.first != "0" else { return nil }
        return "https://t.me/c/\(channel)/\(messageID)"
    }
}

extension SettingsUI {
    static func publications(_ entries: [PublicationEntry], page requestedPage: Int, language: BotLanguage) -> SettingsUI {
        let pageCount = max(1, (entries.count + 4) / 5)
        let page = min(max(0, requestedPage), pageCount - 1)
        let visible = entries.dropFirst(page * 5).prefix(5)
        var text = language.text("<b>🗂 My recent publications</b>\nOnly messages fxclip posted for you, in groups.",
                                 "<b>🗂 Mes publications récentes</b>\nUniquement les messages publiés par fxclip pour vous, en groupe.")
        text += "\n\n" + language.text(
            "Removal is available for less than 48 hours, including replacements. Only you can request it. No link or message content is saved in this list.",
            "Le retrait est possible pendant moins de 48 heures, y compris pour les remplacements. Vous seul pouvez le demander. Cette liste ne conserve aucun lien ni contenu de message.")
        var rows: [[[String: String]]] = []
        if visible.isEmpty {
            text += "\n\n" + language.text("No recent publication available. Older untracked messages are not included.",
                                            "Aucune publication récente disponible. Les anciens messages non suivis ne sont pas inclus.")
        }
        for (index, entry) in visible.enumerated() {
            let number = page * 5 + index + 1
            text += "\n\n<b>\(number). \(publicationEscape(String((entry.title ?? language.text("Group", "Groupe")).prefix(120))))</b>"
            text += "\n\(publicationDate(entry.createdAt)) UTC · \(language.text("message", "message")) #\(entry.messageID)"
            var actions: [[String: String]] = []
            if let url = entry.messageURL {
                actions.append(["text": language.text("↗ View \(number)", "↗ Voir \(number)"), "url": url])
            }
            actions.append(["text": language.text("🗑 Delete \(number)…", "🗑 Supprimer \(number)…"),
                            "callback_data": "fxclip:posts:ask:\(entry.chatID):\(entry.messageID):\(page)"])
            rows.append(actions)
        }
        if pageCount > 1 {
            text += "\n\n\(language.text("Page", "Page")) \(page + 1)/\(pageCount)"
            var navigation: [[String: String]] = []
            if page > 0 { navigation.append(["text": language.text("← Previous", "← Précédent"), "callback_data": "fxclip:posts:show:\(page - 1)"]) }
            if page + 1 < pageCount { navigation.append(["text": language.text("Next →", "Suivant →"), "callback_data": "fxclip:posts:show:\(page + 1)"]) }
            rows.append(navigation)
        }
        rows.append([["text": language.text("↻ Refresh", "↻ Actualiser"), "callback_data": "fxclip:posts:show:\(page)"]])
        rows.append([["text": language.text("← My settings", "← Mes réglages"), "callback_data": "fxclip:personal:show"],
                     ["text": language.text("✕ Close", "✕ Fermer"), "callback_data": "fxclip:panel:close"]])
        return SettingsUI(text: text, markup: ["inline_keyboard": rows])
    }

    static func publicationConfirmation(_ entry: PublicationEntry, page: Int, language: BotLanguage) -> SettingsUI {
        let text = language.text("<b>🗑 Delete my publication?</b>", "<b>🗑 Supprimer ma publication ?</b>")
            + "\n\n" + publicationEscape(String((entry.title ?? language.text("Group", "Groupe")).prefix(120)))
            + "\n\(publicationDate(entry.createdAt)) UTC · #\(entry.messageID)\n\n"
            + language.text("This deletes fxclip’s message for everyone. If it replaced your original, no copy will be restored. The original website post is unaffected.",
                            "Le message fxclip sera supprimé pour tout le monde. S’il remplaçait votre original, aucune copie ne sera restaurée. La publication sur le site d’origine reste intacte.")
        return SettingsUI(text: text, markup: ["inline_keyboard": [
            [["text": language.text("🗑 Confirm deletion", "🗑 Confirmer la suppression"),
              "callback_data": "fxclip:posts:del:\(entry.chatID):\(entry.messageID):\(page)"]],
            [["text": language.text("← Cancel", "← Annuler"), "callback_data": "fxclip:posts:show:\(page)"],
             ["text": language.text("✕ Close", "✕ Fermer"), "callback_data": "fxclip:panel:close"]]
        ]])
    }

    private static func publicationEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func publicationDate(_ time: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }
}
