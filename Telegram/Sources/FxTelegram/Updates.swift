import Foundation

/// Prefer the latest revision already delivered in this poll, before side effects.
/// Edit-only group updates do not cause another repost. Telegram has no atomic
/// compare-and-edit/delete API, so edits arriving during a request can still race.
public func coalesced(_ updates: [Update]) -> [Update] {
    func key(_ message: Message) -> String {
        "\(message.business_connection_id ?? "group"):\(message.chat.id):\(message.message_id)"
    }
    var latest: [String: Message] = [:]
    var edited: Set<String> = []
    var lastBusiness: [String: Int64] = [:]
    for update in updates {
        if let message = update.message ?? update.edited_message { latest[key(message)] = message }
        if let message = update.edited_message { edited.insert(key(message)) }
        if let message = update.business_message ?? update.edited_business_message {
            latest[key(message)] = message
            lastBusiness[key(message)] = update.update_id
        }
    }
    return updates.map { original in
        var update = original
        if let message = update.message { update.message = latest[key(message)] }
        if var callback = update.callback_query, var message = callback.message,
           let source = message.reply_to_message {
            let sourceKey = "group:\(message.chat.id):\(source.message_id)"
            if let revision = latest[sourceKey] {
                // A callback may precede an original edit in the same poll. Use
                // the complete batch before any explicit replacement can delete it.
                message.reply_to_message = ReplyTarget(message_id: revision.message_id, date: revision.date,
                    from: revision.from, sender_chat: revision.sender_chat, text: revision.text,
                    edit_date: revision.edit_date ?? (edited.contains(sourceKey) ? revision.date : nil),
                    forward_origin: revision.forward_origin, has_protected_content: revision.has_protected_content,
                    is_paid_post: revision.is_paid_post, is_automatic_forward: revision.is_automatic_forward)
                callback.message = message
                update.callback_query = callback
            }
        }
        if let message = update.business_message ?? update.edited_business_message {
            update.business_message = nil
            update.edited_business_message = nil
            if lastBusiness[key(message)] == update.update_id { update.business_message = latest[key(message)] }
        }
        return update
    }
}
