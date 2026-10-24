import Foundation

/// Prefer the latest revision already delivered in this poll, before side effects.
/// Edit-only group updates do not cause another repost. Telegram has no atomic
/// compare-and-edit/delete API, so edits arriving during a request can still race.
public func coalesced(_ updates: [Update]) -> [Update] {
    func key(_ message: Message) -> String {
        "\(message.business_connection_id ?? "group"):\(message.chat.id):\(message.message_id)"
    }
    var latest: [String: Message] = [:]
    var lastBusiness: [String: Int64] = [:]
    for update in updates {
        if let message = update.message ?? update.edited_message { latest[key(message)] = message }
        if let message = update.business_message ?? update.edited_business_message {
            latest[key(message)] = message
            lastBusiness[key(message)] = update.update_id
        }
    }
    return updates.map { original in
        var update = original
        if let message = update.message { update.message = latest[key(message)] }
        if let message = update.business_message ?? update.edited_business_message {
            update.business_message = nil
            update.edited_business_message = nil
            if lastBusiness[key(message)] == update.update_id { update.business_message = latest[key(message)] }
        }
        return update
    }
}
