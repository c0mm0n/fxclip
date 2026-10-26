import Foundation
import FxEngine

/// Uses the reference engine; Telegram entity positions are UTF-16, not Swift character counts.
public struct Rewriter {
    public let engine: Engine
    public init(engine: Engine) { self.engine = engine }

    public func rewrite(_ message: Message, previews: Bool, attribution: Bool = true,
                        language: BotLanguage = .en, includeUnchangedLinks: Bool = false) -> RenderedMessage? {
        guard let text = message.text ?? message.caption else { return nil }
        let entities = message.text == nil ? (message.caption_entities ?? []) : (message.entities ?? [])
        let source = text as NSString
        func clean(_ url: String) -> String {
            let clean = engine.clean(url).text
            return previews ? engine.preview(clean, forBundleID: "org.telegram.desktop") : clean
        }
        struct Edit { let range: NSRange; let value: String }
        var edits: [Edit] = []
        var cursor = source.length
        var preview: String?
        _ = mapURLs(text) { url in
            // mapURLs visits links from the end, matching its safe replacement order.
            let range = source.range(of: url, options: [.literal, .backwards],
                                     range: NSRange(location: 0, length: cursor))
            guard range.location != NSNotFound else { return url }
            cursor = range.location
            guard !entities.contains(where: {
                ["code", "pre", "text_link"].contains($0.type) &&
                NSIntersectionRange(range, NSRange(location: $0.offset, length: $0.length)).length > 0
            }) else { return url }
            let value = clean(url)
            if includeUnchangedLinks, preview == nil { preview = value }
            if value != url {
                edits.append(Edit(range: range, value: value))
                if preview == nil { preview = value }
            }
            return url
        }
        edits.sort { $0.range.location < $1.range.location }
        var outputEntities: [Entity] = []
        for var entity in entities {
            if entity.type == "text_link", let url = entity.url {
                let value = clean(url)
                if value != url || includeUnchangedLinks { preview = preview ?? value; entity.url = value }
            }
            let start = entity.offset, end = start + entity.length
            // Drop formatting with a boundary inside a rewritten URL, where no exact mapping exists.
            if edits.contains(where: {
                (start > $0.range.location && start < NSMaxRange($0.range)) ||
                (end > $0.range.location && end < NSMaxRange($0.range))
            }) { continue }
            func shifted(_ position: Int) -> Int {
                position + edits.filter { NSMaxRange($0.range) <= position }
                    .reduce(0) { $0 + $1.value.utf16.count - $1.range.length }
            }
            entity.offset = shifted(start)
            entity.length = shifted(end) - entity.offset
            outputEntities.append(entity)
        }
        guard let preview else { return nil }
        let output = NSMutableString(string: text)
        for edit in edits.reversed() { output.replaceCharacters(in: edit.range, with: edit.value) }
        let author: String
        let authorLabel = language.text("Posted by ", "Publié par ")
        if let chat = message.sender_chat {
            author = chat.title ?? language.text("Anonymous sender", "Auteur anonyme")
        } else if let user = message.from {
            author = user.name
        } else { author = language.text("Unknown sender", "Auteur inconnu") }
        let prefix = attribution ? "\(authorLabel)\(author)\n\n" : ""
        for index in outputEntities.indices { outputEntities[index].offset += prefix.utf16.count }
        if attribution {
            outputEntities.insert(contentsOf: PreviewAttribution.unlinkedLabelEntities(author, offset: authorLabel.utf16.count), at: 0)
        }
        let result = prefix + (output as String)
        // Never truncate somebody's message to make replacement fit.
        let limit = !attribution && message.text == nil ? 1024 : 4096
        guard result.utf16.count <= limit else { return nil }
        return RenderedMessage(text: result, entities: outputEntities, previewURL: preview)
    }
}
