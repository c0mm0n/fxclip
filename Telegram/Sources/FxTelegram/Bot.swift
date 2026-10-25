import Foundation
import CoreFoundation
import FxEngine

public final class Bot {
    private let api: BotAPI
    private let store: StateStore
    private let rewriter: Rewriter
    private let allowedChats: Set<Int64>
    private let allowedOwners: Set<Int64>
    private let botID: Int64
    private let username: String
    private let youTubeMetadata: YouTubeMetadataProviding?
    private let facebookReels: FacebookReelProviding?
    private let redditVideos: RedditVideoProviding?
    private let pendingPreviewDelayNanoseconds: UInt64
    private var cleanupRetryAfter: [String: TimeInterval] = [:]
    public init(api: BotAPI, store: StateStore, engine: Engine,
                allowedChats: Set<Int64>, allowedOwners: Set<Int64> = [], botID: Int64, username: String,
                youTubeMetadata: YouTubeMetadataProviding? = nil,
                facebookReels: FacebookReelProviding? = nil,
                pendingPreviewDelayNanoseconds: UInt64 = 700_000_000,
                redditVideos: RedditVideoProviding? = nil) {
        self.api = api; self.store = store; self.rewriter = Rewriter(engine: engine)
        self.allowedChats = allowedChats; self.botID = botID; self.username = username
        self.allowedOwners = allowedOwners
        self.youTubeMetadata = youTubeMetadata
        self.facebookReels = facebookReels
        self.redditVideos = redditVideos
        self.pendingPreviewDelayNanoseconds = pendingPreviewDelayNanoseconds
    }

    public func handle(_ update: Update, now fixedNow: Int? = nil) async throws {
        let now = fixedNow ?? Int(Date().timeIntervalSince1970)
        try store.observeLanguage(update.callback_query?.from ?? update.message?.from ?? update.edited_message?.from
                                  ?? update.business_message?.from ?? update.edited_business_message?.from)
        if let edited = update.edited_message {
            try store.invalidatePublicationOriginal(chatID: edited.chat.id, originalMessageID: edited.message_id)
        }
        if let membership = update.my_chat_member {
            try store.discover(membership.chat, member: membership.new_chat_member)
            // Only an explicit arrival is a greeting: missing old membership is ambiguous.
            // The runtime reserves each update before this send, including disabled groups.
            if membership.chat.isGroup, membership.old_chat_member?.isAbsent == true,
               ["member", "administrator", "creator"].contains(membership.new_chat_member.status)
                || (membership.new_chat_member.status == "restricted" && membership.new_chat_member.is_member == true) {
                try await sendPanel(SettingsUI.welcome(chatID: membership.chat.id, username: username,
                                                      language: store.groupLanguage(membership.chat.id),
                                                      enabled: isEnabled(chatID: membership.chat.id),
                                                      groupTitle: membership.chat.title),
                                    to: membership.chat.id)
            }
        }
        // Discovery precedes eligibility, age and content checks, and never rewrites edits.
        for message in [update.message, update.edited_message].compactMap({ $0 }) {
            try store.discover(message.chat)
        }
        if let callback = update.callback_query {
            try await settingsCallback(callback, now: fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970)
            return
        }
        if let message = update.business_message ?? update.edited_business_message {
            try await secretary(message, now: now)
            return
        }
        guard let message = update.message, now - message.date <= 300,
              message.from?.is_bot != true || message.sender_chat != nil,
              message.is_automatic_forward != true,
              message.has_protected_content != true, message.is_paid_post != true else { return }
        let words = (message.text ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let target = (words.first ?? "").split(separator: "@", maxSplits: 1).map(String.init)
        if (words.first ?? "").hasPrefix("/"), target.count == 2,
           target[1].lowercased() != username.lowercased() { return }
        let command = target.first ?? ""
        let language = interfaceLanguage(message)
        if ["/supprimer", "/delete"].contains(command) {
            await deletePublicationCommand(message, now: TimeInterval(now), language: language)
            return
        }
        if command == "/publications" || (command == "/start" && words.dropFirst().first == "publications") {
            if message.chat.type == "private", message.chat.id == message.from?.id, message.from?.is_bot == false {
                try await sendPanel(publicationsPanel(userID: message.chat.id, page: 0, now: TimeInterval(now)), to: message.chat.id)
            } else {
                try await reply(language.text("Find your recent publications in private.", "Retrouvez vos publications récentes en privé."),
                    to: message, markup: ["inline_keyboard": [[["text": language.text("🗂 My publications", "🗂 Mes publications"),
                        "url": "https://t.me/\(username)?start=publications"]]]])
            }
            return
        }
        if try await rulesCommand(message, command: command, words: words, language: language) { return }
        if command == "/chatid" {
            try await reply(language.text("Chat ID: \(message.chat.id)", "Identifiant de cette conversation : \(message.chat.id)"), to: message)
            return
        }
        if message.chat.type == "private", let user = message.from, message.chat.id == user.id,
           ["/start", "/help", "/settings", "/mode", "/secretary", "/default", "/groups", "/language"].contains(command) {
            if ["/start", "/help", "/settings"].contains(command) {
                await refreshPrivateCommands(user.id)
            }
            if command == "/language" {
                if words.count == 2 {
                    if words[1] == "auto" {
                        try store.setUserLanguage(nil, userID: user.id)
                    } else if let chosen = BotLanguage(rawValue: words[1]) {
                        try store.setUserLanguage(chosen, userID: user.id)
                    }
                }
                try await sendPanel(languagePanel(user.id), to: message.chat.id)
                await refreshPrivateCommands(user.id)
                return
            }
            if command == "/groups" {
                guard allowedOwners.contains(user.id) else {
                    try await reply(language.text("Only the bot owner can manage connected groups.", "La gestion des groupes est réservée au propriétaire du bot."), to: message)
                    return
                }
                try await sendPanel(groupsPanel(language: language), to: message.chat.id)
                return
            }
            if command == "/default" {
                guard allowedOwners.contains(user.id) else {
                    try await reply(language.text("Only the bot owner can change the global default. Open /settings to choose your personal mode.", "Seul le propriétaire du bot peut changer le réglage général. Ouvrez /settings pour choisir votre mode personnel."), to: message)
                    return
                }
                if words.count == 2, let mode = Mode(rawValue: words[1]) { try store.setDefault(mode) }
                try await sendPanel(SettingsUI.defaults(mode: store.state.defaultMode, language: language), to: message.chat.id)
                return
            }
            if command == "/mode", words.count == 2 {
                if words[1] == "default" { try store.setMode(nil, userID: user.id) }
                else if let mode = Mode(rawValue: words[1]) { try store.setMode(mode, userID: user.id) }
            }
            if command == "/secretary", words.count == 2, ["on", "off"].contains(words[1]) {
                try store.setSecretary(words[1] == "on", userID: user.id)
            }
            try await sendPanel(personalPanel(userID: user.id), to: message.chat.id)
            return
        }
        if command == "/start" || command == "/help" {
            try await reply(language.text(
                "fxclip cleans links and improves previews.\n\nOpen my private settings to choose what happens to your messages.\n\nAdmins: /setup configures this group. Commands: /fxclip reply, /fxclip replace, /fxclip off or /fxclip previews on|off.\n\nThe bot reads messages in this group. Cleaned links are sent to Telegram and, for some previews, to mirror sites.",
                "fxclip nettoie les liens et améliore leurs aperçus.\n\nOuvrez mes réglages en privé pour choisir le comportement de vos messages.\n\nAdmins : /setup permet de régler ce groupe. Commandes : /fxclip reply, /fxclip replace, /fxclip off ou /fxclip previews on|off.\n\nLe bot lit les messages de ce groupe. Les liens nettoyés passent par Telegram et, pour certains aperçus, par un site miroir."),
                to: message, markup: privateSettingsLink(language: language))
            return
        }
        if message.chat.isGroup, command == "/setup" || (command == "/fxclip" && words.count == 1) {
            try await sendPanel(chatPanel(message.chat), to: message.chat.id, removingCommand: message)
            return
        }
        var settings = chatSettings(message.chat.id)
        if command == "/fxclip" {
            guard message.chat.isGroup else { return }
            if words.count > 1 {
                // Anonymous admin identities cannot be authenticated as a particular member.
                guard message.sender_chat == nil, let user = message.from,
                      try await isAdmin(chatID: message.chat.id, userID: user.id) else {
                    try await reply(language.text("Only an identified group admin can change this setting. If you post anonymously, use your personal profile.", "Seul un administrateur identifié du groupe peut changer ce réglage. Si vous publiez anonymement, utilisez votre profil personnel."), to: message)
                    return
                }
                if words.count == 2, let mode = Mode(rawValue: words[1]), mode != .secretary {
                    if mode == .replace, !(try await canDelete(in: message.chat)) {
                        try await reply(language.text("To enable replacement, first grant fxclip Delete messages permission in the group's admin settings.", "Pour activer le remplacement, donnez d’abord à fxclip le droit de supprimer les messages dans les réglages administrateurs du groupe."), to: message)
                        return
                    }
                    settings.mode = mode
                    settings.modeInherited = false
                } else if words.count == 3, words[1] == "previews", ["on", "off"].contains(words[2]) {
                    settings.previews = words[2] == "on"
                } else {
                    try await reply(language.text(
                        "Use /fxclip reply to reply, /fxclip replace to replace, or /fxclip off to do nothing.\n\nImproved previews: /fxclip previews on or /fxclip previews off.\n\nChoose Secretary Mode in private with /settings; it only works in connected private chats.",
                        "Choisissez /fxclip reply pour répondre, /fxclip replace pour remplacer ou /fxclip off pour désactiver.\n\nAperçus améliorés : /fxclip previews on ou /fxclip previews off.\n\nLe mode Secrétaire se choisit en privé avec /settings et agit uniquement dans les conversations privées connectées."), to: message)
                    return
                }
                try store.set(settings, chatID: message.chat.id)
            }
            let source = store.state.chats[String(message.chat.id)] == nil
                ? language.text("Global default applied", "Réglage général appliqué")
                : language.text("Group setting", "Réglage du groupe")
            let previews = settings.previews ? language.text("on", "activés") : language.text("off", "désactivés")
            let summary = "\(source): \(SettingsUI.title(settings.mode, language: language)).\n\n\(SettingsUI.outcome(settings.mode, language: language))\n\n"
            try await reply(summary + language.text(
                "Improved previews: \(previews).\nWhen on, plain YouTube links use the chosen style: public Koutube (public processed-link cache, photo fallback) or our YouTube photo card, even if already clean. Separately enabled Facebook videos use Facebed metadata and download public Facebook video to the bot server for upload to Telegram (20 MiB maximum). A duplicate is possible when Telegram's own preview works.\nA personal choice overrides this mode, including /fxclip off, while cleaning is enabled for this group. Choose yours in private.\n\nAdmins: /fxclip reply · /fxclip replace · /fxclip off\n/fxclip previews on|off",
                "Aperçus améliorés : \(previews).\nLorsqu’ils sont activés, les liens YouTube seuls suivent le style choisi : Koutube public (cache public des liens traités, photo en secours) ou notre carte photo YouTube, même s’ils sont déjà propres. Les vidéos Facebook activées séparément passent par Facebed pour les métadonnées ; le bot télécharge la vidéo publique sur son serveur puis en envoie une copie à Telegram (20 Mio maximum). Un doublon est possible si l’aperçu Telegram fonctionne.\nUn choix personnel passe avant ce mode, y compris /fxclip off, tant que le nettoyage est activé pour ce groupe. Choisissez le vôtre en privé.\n\nAdmins : /fxclip reply · /fxclip replace · /fxclip off\n/fxclip previews on|off"),
                to: message, markup: privateSettingsLink(language: language))
            return
        }
        // Sending a link to the bot is an explicit request, independent of group
        // activation, group modes and connected Business/Secretary conversations.
        let directMessage = message.chat.type == "private"
            && message.sender_chat == nil && message.from?.is_bot == false
            && message.chat.id > 0 && message.chat.id == message.from?.id
            && message.business_connection_id == nil && message.sender_business_bot == nil
        if message.chat.type == "private" {
            guard directMessage else { return }
            // Unknown commands and media captions are not direct link requests.
            guard !command.hasPrefix("/"), message.text != nil else { return }
            settings = ChatSettings()
            settings.mode = .reply
        } else {
            guard message.chat.isGroup, isEnabled(chatID: message.chat.id) else { return }
        }
        if !directMessage, message.sender_chat == nil, let user = message.from,
           let personal = store.state.users[String(user.id)], personal != .secretary { settings.mode = personal }
        guard ["group", "supergroup", "private"].contains(message.chat.type),
              settings.mode != .off, settings.mode != .secretary else { return }
        let senderID = message.sender_chat == nil ? message.from?.id : nil
        let settingsChatID = directMessage ? nil : message.chat.id
        let youTubeStyle = youTubeStyle(chatID: settingsChatID, userID: senderID)
        let configured = configuredRewriter(chatID: settingsChatID, userID: senderID)
        let replyContent = configured.rewrite(message, previews: settings.previews, attribution: false,
                                              includeUnchangedLinks: directMessage)
        // This is presentation, not another cleaning engine. Only plain, single-link
        // messages qualify; formatting, hidden links and media keep their existing path.
        let videoID: String?
        if settings.previews, cardsEnabled(chatID: settingsChatID, userID: senderID),
           message.link_preview_options?.is_disabled != true,
           youTubeMetadata != nil, let text = message.text,
           (message.entities ?? []).allSatisfy({ $0.type == "url" }), isBareURL(text) {
            videoID = YouTubePreview.videoID(in: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else { videoID = nil }
        let facebookSource: String?
        if settings.previews, facebookEnabled(chatID: settingsChatID, userID: senderID),
           message.link_preview_options?.is_disabled != true, facebookReels != nil,
           message.forward_origin == nil, message.sender_chat == nil,
           let text = message.text, (message.entities ?? []).allSatisfy({ $0.type == "url" }), isBareURL(text) {
            let source = configured.engine.clean(text).text.trimmingCharacters(in: .whitespacesAndNewlines)
            facebookSource = FacebookReelPreview.facebedURL(in: source) == nil ? nil : source
        } else { facebookSource = nil }
        let redditSource: (id: String, url: String)?
        if (message.chat.isGroup || directMessage), settings.previews,
           redditEnabled(chatID: settingsChatID, userID: senderID), redditVideos != nil,
           message.link_preview_options?.is_disabled != true, message.forward_origin == nil, message.sender_chat == nil,
           let text = message.text, (message.entities ?? []).allSatisfy({ $0.type == "url" }), isBareURL(text) {
            let source = configured.engine.clean(text).text.trimmingCharacters(in: .whitespacesAndNewlines)
            redditSource = RedditVideoPreview.postID(in: source).map { ($0, source) }
        } else { redditSource = nil }
        guard replyContent != nil || videoID != nil || facebookSource != nil || redditSource != nil else { return }
        let cleanRedditOriginal = redditSource.map {
            $0.url == (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? false
        // Media, forwards and anonymous/channel-authored posts retain their originals.
        var replace = false
        let ownershipNow = fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970
        let publicationPoster = message.chat.isGroup && message.sender_chat == nil && message.from?.is_bot == false
            && (message.from?.id ?? 0) > 0 && store.canRecordPublication(now: ownershipNow) ? message.from?.id : nil
        if replyContent != nil && settings.mode == .replace && message.text != nil && publicationPoster != nil && message.forward_origin == nil && !cleanRedditOriginal {
            replace = try await canDelete(in: message.chat)
        }
        let rendered: RenderedMessage?
        if replace {
            guard let credited = configured.rewrite(message, previews: settings.previews, language: language) else { return }
            rendered = credited
        } else {
            // Telegram's reply header already identifies the original sender.
            rendered = replyContent
        }
        let removalPoster = message.sender_chat == nil && message.from?.is_bot == false
            && store.state.replyControls.count < 4096 ? message.from?.id : nil
        var pendingID: Int64?
        var pending = base(message)
        pending["text"] = language.text("Preparing preview…", "Préparation de l’aperçu…")
        pending["disable_notification"] = true
        pending["link_preview_options"] = ["is_disabled": true]
        if replace {
            if let parent = message.reply_to_message {
                pending["reply_parameters"] = ["message_id": parent.message_id, "allow_sending_without_reply": true]
            }
        } else {
            pending["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true]
        }
        let nativeVideo: Data?
        if let source = redditSource, let redditVideos {
            let fetched: (Result<Data, Error>, Int64?)
            if replace {
                do { fetched = (.success(try await redditVideos.fetch(postID: source.id)), nil) }
                catch { fetched = (.failure(error), nil) }
            } else {
                fetched = try await fetchWithPendingPreview(api: api, parameters: pending,
                    originalMessageID: message.message_id, delayNanoseconds: pendingPreviewDelayNanoseconds) {
                    try await redditVideos.fetch(postID: source.id)
                }
            }
            pendingID = fetched.1
            do { nativeVideo = try fetched.0.get() }
            catch RedditVideoError.videoTooLarge {
                try await sendVideoSizeNotice(to: message, author: "", caption: "", cleanURL: source.url,
                    language: language, now: fixedNow, pendingID: pendingID, service: "Reddit")
                return
            } catch is CancellationError {
                await discardPendingPreview(pendingID, chatID: message.chat.id, language: language)
                throw CancellationError()
            } catch { nativeVideo = nil }
        } else if let facebookSource, let facebookReels {
            let fetched: (Result<FacebookReel, Error>, Int64?)
            if replace {
                // An oversized video keeps the original and must reply to it.
                // Telegram cannot retarget a placeholder after it has been sent.
                do { fetched = (.success(try await facebookReels.fetch(sourceURL: facebookSource)), nil) }
                catch { fetched = (.failure(error), nil) }
            } else {
                fetched = try await fetchWithPendingPreview(api: api, parameters: pending,
                    originalMessageID: message.message_id, delayNanoseconds: pendingPreviewDelayNanoseconds) {
                    try await facebookReels.fetch(sourceURL: facebookSource)
                }
            }
            pendingID = fetched.1
            do { nativeVideo = try fetched.0.get().video }
            catch FacebookReelError.videoTooLarge(let author, let caption) {
                try await sendVideoSizeNotice(to: message, author: author, caption: caption,
                    cleanURL: facebookSource, language: language, now: fixedNow, pendingID: pendingID)
                return
            } catch is CancellationError {
                await discardPendingPreview(pendingID, chatID: message.chat.id, language: language)
                throw CancellationError()
            } catch { nativeVideo = nil }
        } else { nativeVideo = nil }
        if let data = nativeVideo {
            let creditLabel = language.text("Posted by ", "Publié par ")
            let credit = replace ? creditLabel + (message.from?.name ?? language.text("Unknown sender", "Auteur inconnu")) : ""
            if !data.isEmpty, data.count <= 20 * 1024 * 1024, credit.utf16.count <= 1024 {
                var video = base(message)
                video["video"] = VideoUpload(data: data)
                video["supports_streaming"] = true
                if let geometry = MP4VideoGeometry.read(data) {
                    video["width"] = geometry.width
                    video["height"] = geometry.height
                }
                video["disable_notification"] = true
                // A reply already identifies the poster. Only actual replacement
                // needs credit because the original is removed after confirmation.
                if replace {
                    video["caption"] = credit
                    if let user = message.from {
                        video["caption_entities"] = try jsonObject([
                            Entity(type: "text_mention", offset: creditLabel.utf16.count, length: user.name.utf16.count, user: user)
                        ])
                    }
                }
                let original = manualReplacementOriginal(message, replacement: replace, now: ownershipNow,
                    content: video["caption"] as? String ?? "", limit: 1024)
                if removalPoster != nil { addRemovalButton(to: &video, language: language, replacement: replace, canReplace: original != nil) }
                if replace {
                    if let parent = message.reply_to_message {
                        video["reply_parameters"] = ["message_id": parent.message_id, "allow_sending_without_reply": true]
                    }
                } else { video["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true] }
                do {
                    let sentID = try await deliverPreview("sendVideo", parameters: video, pendingID: pendingID)
                    if let publicationPoster {
                        try store.recordPublication(chatID: message.chat.id, messageID: sentID, posterID: publicationPoster,
                                                    now: fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970, original: original)
                    }
                    if let removalPoster {
                        try store.recordReplyControl(chatID: message.chat.id, messageID: sentID, posterID: removalPoster,
                                                     now: fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970)
                    }
                    if replace { await deleteReplacedOriginal(message) }
                    return
                } catch BotError.telegram(let code) where code == 400 || code == 403 {
                    // Only an explicit rejection permits a cleaned-text fallback.
                }
            }
        }
        if let videoID, let youTubeMetadata {
            // Fetching metadata is safe to fall back from; a timed-out send is not.
            let fetched = try await fetchWithPendingPreview(api: api, parameters: pending,
                originalMessageID: message.message_id, delayNanoseconds: pendingPreviewDelayNanoseconds) {
                try await youTubeMetadata.fetch(videoID: videoID, nativePreview: youTubeStyle == .koutube)
            }
            pendingID = fetched.1
            if case .failure(let error) = fetched.0, error is CancellationError {
                await discardPendingPreview(pendingID, chatID: message.chat.id, language: language)
                throw error
            }
            let metadata = try? fetched.0.get()
            if let metadata {
                let cleanURL = configured.engine.clean(message.text ?? "").text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if youTubeStyle == .koutube, metadata.nativePreviewAvailable, let mirror = YouTubePreview.koutubeURL(for: cleanURL) {
                    let content = rendered ?? RenderedMessage(text: cleanURL,
                        entities: [Entity(type: "url", offset: 0, length: cleanURL.utf16.count)], previewURL: cleanURL)
                    var card = base(message)
                    card["text"] = content.text
                    card["entities"] = try jsonObject(content.entities)
                    card["link_preview_options"] = ["is_disabled": false, "url": mirror, "prefer_large_media": true]
                    card["disable_notification"] = true
                    card["reply_markup"] = ["inline_keyboard": [[[
                        "text": language.text("▶ Open YouTube", "▶ Ouvrir YouTube"), "url": cleanURL, "style": "danger",
                    ]]]]
                    let original = manualReplacementOriginal(message, replacement: replace, now: ownershipNow,
                                                             content: content.text, limit: 4096)
                    if removalPoster != nil { addRemovalButton(to: &card, language: language, replacement: replace, canReplace: original != nil) }
                    if replace {
                        if let parent = message.reply_to_message {
                            card["reply_parameters"] = ["message_id": parent.message_id, "allow_sending_without_reply": true]
                        }
                    } else { card["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true] }
                    do {
                        let sentID = try await deliverPreview("sendMessage", parameters: card, pendingID: pendingID)
                        if let publicationPoster {
                            try store.recordPublication(chatID: message.chat.id, messageID: sentID, posterID: publicationPoster,
                                now: fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970, original: original)
                        }
                        if let removalPoster {
                            try store.recordReplyControl(chatID: message.chat.id, messageID: sentID, posterID: removalPoster,
                                now: fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970, openButton: openingButton(in: card))
                        }
                        if replace { await deleteReplacedOriginal(message) }
                        return
                    } catch BotError.telegram(let code) where code == 400 || code == 403 {
                        // Only a definite Telegram rejection permits the photo
                        // fallback. A missing rendered web preview is not reported.
                    }
                }
                if let caption = YouTubePreview.caption(title: metadata.title, url: cleanURL, credit: replace ? rendered : nil) {
                    var photo = base(message)
                    photo["photo"] = metadata.thumbnailURL.absoluteString
                    photo["caption"] = caption.text
                    photo["show_caption_above_media"] = true
                    photo["disable_notification"] = true
                    photo["caption_entities"] = try jsonObject(caption.entities)
                    photo["reply_markup"] = ["inline_keyboard": [[[
                        "text": language.text("▶ Open YouTube", "▶ Ouvrir YouTube"), "url": cleanURL, "style": "danger",
                    ]]]]
                    let original = manualReplacementOriginal(message, replacement: replace, now: ownershipNow,
                                                             content: caption.text, limit: 1024)
                    if removalPoster != nil { addRemovalButton(to: &photo, language: language, replacement: replace, canReplace: original != nil) }
                    if replace {
                        if let parent = message.reply_to_message {
                            photo["reply_parameters"] = ["message_id": parent.message_id, "allow_sending_without_reply": true]
                        }
                    } else {
                        photo["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true]
                    }
                    do {
                        let sentID: Int64
                        do {
                            sentID = try await deliverPreview("sendPhoto", parameters: photo, pendingID: pendingID)
                        } catch BotError.telegram(400) where metadata.fallbackThumbnailURL != nil {
                            // A definite HD-image rejection permits one attempt with
                            // the verified oEmbed image, including on the same placeholder.
                            photo["photo"] = metadata.fallbackThumbnailURL!.absoluteString
                            sentID = try await deliverPreview("sendPhoto", parameters: photo, pendingID: pendingID)
                        }
                        if let publicationPoster {
                            try store.recordPublication(chatID: message.chat.id, messageID: sentID, posterID: publicationPoster,
                                                        now: fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970, original: original)
                        }
                        if let removalPoster {
                            try store.recordReplyControl(chatID: message.chat.id, messageID: sentID, posterID: removalPoster,
                                                         now: fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970,
                                                         openButton: openingButton(in: photo))
                        }
                        if replace { await deleteReplacedOriginal(message) }
                        return
                    } catch BotError.telegram(let code) where code == 400 || code == 403 {
                        // Explicit rejection means no photo was sent. Preserve the normal
                        // cleaned-text path; never retry an ambiguous transport failure.
                    }
                }
            }
        }
        guard let rendered else {
            await discardPendingPreview(pendingID, chatID: message.chat.id, language: language)
            return
        }
        var parameters = base(message)
        parameters["text"] = rendered.text
        parameters["entities"] = try jsonObject(rendered.entities)
        parameters["link_preview_options"] = ["is_disabled": false, "url": rendered.previewURL]
        parameters["disable_notification"] = true
        let original = manualReplacementOriginal(message, replacement: replace, now: ownershipNow,
                                                 content: rendered.text, limit: 4096)
        if removalPoster != nil { addRemovalButton(to: &parameters, language: language, replacement: replace, canReplace: original != nil) }
        if replace {
            if let parent = message.reply_to_message {
                parameters["reply_parameters"] = ["message_id": parent.message_id, "allow_sending_without_reply": true]
            }
        } else {
            parameters["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true]
        }
        // No delete until Telegram confirms an actual new message ID. Never retry an ambiguous send.
        let sentID: Int64
        do { sentID = try await deliverPreview("sendMessage", parameters: parameters, pendingID: pendingID) }
        catch BotError.telegram(let code) where code == 400 || code == 403 {
            await discardPendingPreview(pendingID, chatID: message.chat.id, language: language)
            throw BotError.telegram(code)
        }
        if let publicationPoster {
            try store.recordPublication(chatID: message.chat.id, messageID: sentID, posterID: publicationPoster,
                                        now: fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970, original: original)
        }
        if let removalPoster {
            try store.recordReplyControl(chatID: message.chat.id, messageID: sentID, posterID: removalPoster,
                                         now: fixedNow.map(TimeInterval.init) ?? Date().timeIntervalSince1970)
        }
        if replace { await deleteReplacedOriginal(message) }
    }

    /// A confirmed placeholder is edited in place. An ambiguous edit must never
    /// trigger another send or permit deletion of the original.
    private func deliverPreview(_ method: String, parameters: [String: Any], pendingID: Int64?) async throws -> Int64 {
        let result: Any
        if let pendingID {
            var edit: [String: Any] = ["chat_id": parameters["chat_id"]!, "message_id": pendingID,
                                      "reply_markup": parameters["reply_markup"] ?? ["inline_keyboard": []]]
            if method == "sendMessage" {
                for key in ["text", "entities", "link_preview_options"] { edit[key] = parameters[key] }
                result = try await api.call("editMessageText", edit)
            } else {
                var media: [String: Any] = ["type": method == "sendVideo" ? "video" : "photo",
                                           "media": parameters[method == "sendVideo" ? "video" : "photo"]!]
                for key in ["caption", "caption_entities", "show_caption_above_media", "supports_streaming", "width", "height"] { media[key] = parameters[key] }
                edit["media"] = media
                result = try await api.call("editMessageMedia", edit)
            }
        } else {
            result = try await api.call(method, parameters)
        }
        guard let object = result as? [String: Any], let id = confirmedMessageID(object["message_id"]),
              pendingID == nil || id == pendingID else { throw BotError.invalidResponse }
        return id
    }

    private func discardPendingPreview(_ pendingID: Int64?, chatID: Int64, language: BotLanguage) async {
        guard let pendingID else { return }
        do {
            let result = try await api.call("deleteMessage", ["chat_id": chatID, "message_id": pendingID])
            guard result as? Bool == true else { throw BotError.invalidResponse }
        } catch {
            // Never leave a known failed fetch labelled as still preparing.
            _ = try? await api.call("editMessageText", ["chat_id": chatID, "message_id": pendingID,
                "text": language.text("Preview unavailable.", "Aperçu indisponible."),
                "link_preview_options": ["is_disabled": true], "reply_markup": ["inline_keyboard": []]])
        }
    }

    private func manualReplacementOriginal(_ message: Message, replacement: Bool, now: TimeInterval,
                                           content: String, limit: Int) -> OriginalPublication? {
        guard !replacement, message.chat.isGroup, message.message_id > 0, message.date > 0,
              TimeInterval(message.date) <= now, now - TimeInterval(message.date) < PublicationReceipt.retention,
              message.text != nil, message.edit_date == nil, message.sender_chat == nil,
              let poster = message.from, poster.is_bot == false, poster.id > 0,
              store.state.replyControls.count < 4096, store.canRecordPublication(now: now),
              let prefix = PreviewAttribution.prefix(poster: poster, origin: message.forward_origin,
                                                     language: store.groupLanguage(message.chat.id)),
              prefix.text.utf16.count + content.utf16.count <= limit else { return nil }
        return OriginalPublication(messageID: message.message_id, date: message.date)
    }

    private func addRemovalButton(to parameters: inout [String: Any], language: BotLanguage, replacement: Bool = false,
                                  canReplace: Bool = false) {
        var markup = parameters["reply_markup"] as? [String: Any] ?? [:]
        var rows = markup["inline_keyboard"] as? [[[String: String]]] ?? []
        if canReplace {
            rows.append([["text": language.text("🗑 Remove", "🗑 Retirer"), "callback_data": "fxclip:preview:delete"],
                         ["text": language.text("🔁 Replace", "🔁 Remplacer"), "callback_data": "fxclip:preview:replace"]])
        } else {
            rows.append([["text": replacement ? language.text("🗑 Delete my message", "🗑 Supprimer mon message")
                      : language.text("🗑 Remove preview", "🗑 Retirer l’aperçu"),
                      "callback_data": "fxclip:preview:delete"]])
        }
        markup["inline_keyboard"] = rows
        parameters["reply_markup"] = markup
    }

    private func openingButton(in parameters: [String: Any]) -> InlineKeyboardButton? {
        guard let raw = parameters["reply_markup"],
              let markup = try? decode(InlineKeyboardMarkup.self, from: raw) else { return nil }
        return markup.inline_keyboard.joined().first { $0.url != nil && $0.callback_data == nil }
    }

    private func sendVideoSizeNotice(to message: Message, author: String, caption: String,
                                        cleanURL: String, language: BotLanguage, now: Int?, pendingID: Int64? = nil,
                                        service: String = "Facebook") async throws {
        let heading = service + "\n"
        let creator = facebookCaptionText(author, limit: 160)
        let description = facebookCaptionText(caption.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), limit: 400)
        let notice = language.text("This video exceeds the bot’s 20 MiB limit. Open it on \(service).",
                                   "Cette vidéo dépasse la limite de 20 Mio du bot. Ouvrez-la sur \(service).")
        let prefix = heading + creator + "\n" + description + "\n\n" + notice + "\n\n"
        let includeURL = (prefix + cleanURL).utf16.count <= 4096
        var parameters = base(message)
        parameters["text"] = prefix + (includeURL ? cleanURL : "")
        var entities = [Entity(type: "text_link", offset: 0, length: service.utf16.count, url: cleanURL)]
        if !creator.isEmpty { entities.append(Entity(type: "bold", offset: heading.utf16.count, length: creator.utf16.count)) }
        if includeURL { entities.append(Entity(type: "url", offset: prefix.utf16.count, length: cleanURL.utf16.count)) }
        parameters["entities"] = try jsonObject(entities)
        parameters["disable_notification"] = true
        parameters["link_preview_options"] = ["is_disabled": true]
        parameters["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true]
        parameters["reply_markup"] = ["inline_keyboard": [[[
            "text": language.text("▶ Open \(service)", "▶ Ouvrir \(service)"), "url": cleanURL,
        ]]]]
        let author = message.sender_chat == nil && message.from?.is_bot == false && (message.from?.id ?? 0) > 0
            ? message.from?.id : nil
        let poster = store.state.replyControls.count < 4096 ? author : nil
        if poster != nil { addRemovalButton(to: &parameters, language: language) }
        let sentID: Int64
        do { sentID = try await deliverPreview("sendMessage", parameters: parameters, pendingID: pendingID) }
        catch BotError.telegram(let code) where code == 400 || code == 403 {
            await discardPendingPreview(pendingID, chatID: message.chat.id, language: language)
            throw BotError.telegram(code)
        }
        if let author, message.chat.isGroup, store.canRecordPublication(now: now.map(TimeInterval.init) ?? Date().timeIntervalSince1970) {
            try store.recordPublication(chatID: message.chat.id, messageID: sentID, posterID: author,
                                        now: now.map(TimeInterval.init) ?? Date().timeIntervalSince1970)
        }
        if let poster {
            try store.recordReplyControl(chatID: message.chat.id, messageID: sentID, posterID: poster,
                                         now: now.map(TimeInterval.init) ?? Date().timeIntervalSince1970,
                                         openButton: openingButton(in: parameters))
        }
    }

    private func facebookCaptionText(_ text: String, limit: Int) -> String {
        var result = ""
        var length = 0
        for character in text {
            let count = String(character).utf16.count
            guard length + count <= limit else { break }
            result.append(character)
            length += count
        }
        return result
    }

    /// Runs in the polling loop, not an unsynchronized background task. Only the
    /// keyboard changes; original messages, media and captions are never touched.
    public func expireReplyControls(now fixedNow: TimeInterval? = nil) async throws {
        let now = fixedNow ?? Date().timeIntervalSince1970
        try store.prunePublications(now: now)
        try store.pruneReplyControls(now: now)
        cleanupRetryAfter = cleanupRetryAfter.filter { store.state.replyControls[$0.key] != nil }
        let pending = store.state.replyControls.filter {
            now >= $0.value.createdAt + ReplyControl.lifetime && now >= (cleanupRetryAfter[$0.key] ?? 0)
        }.sorted { $0.value.createdAt == $1.value.createdAt ? $0.key < $1.key : $0.value.createdAt < $1.value.createdAt }
        for (key, control) in pending.prefix(20) {
            let ids = key.split(separator: ":", omittingEmptySubsequences: false)
            guard ids.count == 2, let chatID = Int64(ids[0]), chatID != 0,
                  let messageID = Int64(ids[1]), messageID > 0, key == "\(chatID):\(messageID)" else {
                try store.removeReplyControl(key: key)
                continue
            }
            var rows: [[[String: String]]] = []
            if let button = control.openButton, let url = button.url,
               let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
               ["http", "https"].contains(scheme), parts.host != nil, parts.user == nil, parts.password == nil {
                var opening = ["text": button.text, "url": url]
                if let style = button.style, ["danger", "primary", "success"].contains(style) { opening["style"] = style }
                rows = [[opening]]
            }
            let completed: Bool
            do {
                let result = try await api.call("editMessageReplyMarkup", ["chat_id": chatID, "message_id": messageID,
                    "reply_markup": ["inline_keyboard": rows]])
                let confirmed = (result as? [String: Any]).flatMap { confirmedMessageID($0["message_id"]) } == messageID
                let boolean = (result as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
                guard confirmed || boolean else { throw BotError.invalidResponse }
                completed = true
            } catch BotError.telegram(let code) where code == 400 || code == 403 {
                // Already edited, deleted or no longer accessible: no destructive fallback.
                completed = true
            } catch {
                cleanupRetryAfter[key] = (fixedNow ?? Date().timeIntervalSince1970) + 30
                break // A network outage must not stall every queued message in turn.
            }
            if completed {
                try store.removeReplyControl(chatID: chatID, messageID: messageID)
                cleanupRetryAfter.removeValue(forKey: key)
            }
        }
    }

    private func removePreview(_ callback: CallbackQuery, now: TimeInterval) async {
        let language = store.userLanguage(callback.from.id)
        guard callback.data == "fxclip:preview:delete", callback.from.is_bot != true,
              let message = callback.message, message.from?.id == botID,
              let control = store.state.replyControls["\(message.chat.id):\(message.message_id)"],
              now >= control.createdAt, now - control.createdAt < ReplyControl.lifetime else {
            await answer(callback, language.text("This preview can no longer be removed with this button.", "Cet aperçu ne peut plus être retiré avec ce bouton."), alert: true)
            return
        }
        guard callback.from.id == control.posterID else {
            await answer(callback, language.text("Only the person who posted the original link can remove this preview.", "Seule la personne qui a publié le lien d’origine peut retirer cet aperçu."), alert: true)
            return
        }
        do {
            let deleted = try await api.call("deleteMessage", ["chat_id": message.chat.id, "message_id": message.message_id])
            guard deleted as? Bool == true else { throw BotError.invalidResponse }
            do { try store.removePublication(chatID: message.chat.id, messageID: message.message_id) }
            catch { print("Preview removed; control cleanup will finish later.") }
            await answer(callback, nil)
        } catch {
            await answer(callback, language.text("Could not remove the preview. Please try again.", "Impossible de retirer l’aperçu. Réessayez."), alert: true)
        }
    }

    private func manualPreviewMarkup(_ control: ReplyControl, language: BotLanguage,
                                     confirmation: Bool = false, canReplace: Bool = false) -> [String: Any] {
        var parameters: [String: Any] = [:]
        if let open = control.openButton, let url = open.url {
            var opening = ["text": open.text, "url": url]
            if let style = open.style, ["danger", "primary", "success"].contains(style) { opening["style"] = style }
            parameters["reply_markup"] = ["inline_keyboard": [[opening]]]
        }
        if confirmation {
            var rows = (parameters["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: String]]] ?? []
            rows.append([["text": language.text("✓ Confirm", "✓ Confirmer"), "callback_data": "fxclip:preview:replace:confirm"],
                         ["text": language.text("← Cancel", "← Annuler"), "callback_data": "fxclip:preview:replace:cancel"]])
            return ["inline_keyboard": rows]
        }
        addRemovalButton(to: &parameters, language: language, replacement: !canReplace, canReplace: canReplace)
        return parameters["reply_markup"] as! [String: Any]
    }

    private func replacePreview(_ callback: CallbackQuery, parts: [String], now: TimeInterval) async {
        let language = callback.message.map(interfaceLanguage) ?? store.userLanguage(callback.from.id)
        guard parts == ["fxclip", "preview", "replace"] || parts == ["fxclip", "preview", "replace", "confirm"]
                || parts == ["fxclip", "preview", "replace", "cancel"],
              let message = callback.message, message.chat.isGroup, message.from?.id == botID, message.from?.is_bot == true,
              callback.from.is_bot == false,
              let control = store.state.replyControls["\(message.chat.id):\(message.message_id)"],
              control.posterID == callback.from.id, now >= control.createdAt,
              now - control.createdAt < ReplyControl.lifetime,
              ownsPublication(chatID: message.chat.id, messageID: message.message_id, userID: callback.from.id, now: now) else {
            await answer(callback, language.text("Only the original poster can choose, for 5 minutes.",
                                                 "Seule la personne qui a partagé le message peut choisir, pendant 5 minutes."), alert: true)
            return
        }
        let receipt = store.state.publications["\(message.chat.id):\(message.message_id)"]!
        if parts.last == "cancel" {
            do {
                _ = try await api.call("editMessageReplyMarkup", ["chat_id": message.chat.id, "message_id": message.message_id,
                    "reply_markup": manualPreviewMarkup(control, language: language, canReplace: receipt.original != nil)])
                await answer(callback, nil)
            } catch {
                await answer(callback, language.text("Could not restore the buttons. Nothing was deleted.",
                                                     "Impossible de rétablir les boutons. Aucun message supprimé."), alert: true)
            }
            return
        }
        guard let original = receipt.original,
              let source = message.reply_to_message, source.message_id == original.messageID,
              source.message_id != message.message_id, source.date == original.date,
              TimeInterval(original.date) <= now, now - TimeInterval(original.date) < PublicationReceipt.retention,
              source.sender_chat == nil, source.from?.id == callback.from.id, source.from?.is_bot == false,
              source.text != nil, source.edit_date == nil, source.has_protected_content != true,
              source.is_paid_post != true, source.is_automatic_forward != true,
              let prefix = PreviewAttribution.prefix(poster: callback.from, origin: source.forward_origin, language: language) else {
            await answer(callback, language.text("The original is unavailable, changed or no longer replaceable. Both messages are kept.",
                                                 "L’original est indisponible, modifié ou ne peut plus être remplacé. Les deux messages sont conservés."), alert: true)
            return
        }
        do {
            guard try await canDelete(in: message.chat) else {
                await answer(callback, language.text("fxclip needs Delete messages permission. Both messages are kept.",
                                                     "fxclip a besoin du droit de supprimer les messages. Les deux messages sont conservés."), alert: true)
                return
            }
            if parts.count == 3 {
                let response = try await api.call("editMessageReplyMarkup", ["chat_id": message.chat.id, "message_id": message.message_id,
                    "reply_markup": manualPreviewMarkup(control, language: language, confirmation: true)])
                let confirmed = (response as? [String: Any]).flatMap { confirmedMessageID($0["message_id"]) } == message.message_id
                let boolean = (response as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
                guard confirmed || boolean else { throw BotError.invalidResponse }
                await answer(callback, language.text(
                    "Your original will be deleted. The fxclip version will keep your name and its source. Use Confirm to continue.",
                    "Votre original sera supprimé. La version fxclip gardera votre nom et sa source. Utilisez Confirmer pour continuer."), alert: true)
                return
            }
            let isText = message.text != nil
            let content = isText ? message.text! : (message.caption ?? "")
            let credited = prefix.text + content
            guard credited.utf16.count <= (isText ? 4096 : 1024) else {
                await answer(callback, language.text("Not enough room for attribution. Both messages are kept.",
                                                     "Pas assez de place pour l’attribution. Les deux messages sont conservés."), alert: true)
                return
            }
            var originalEntities = (isText ? message.entities : message.caption_entities) ?? []
            for index in originalEntities.indices { originalEntities[index].offset += prefix.text.utf16.count }
            var edit: [String: Any] = ["chat_id": message.chat.id, "message_id": message.message_id,
                                      "reply_markup": manualPreviewMarkup(control, language: language)]
            edit[isText ? "text" : "caption"] = credited
            edit[isText ? "entities" : "caption_entities"] = try jsonObject(prefix.entities + originalEntities)
            if !isText, let above = message.show_caption_above_media { edit["show_caption_above_media"] = above }
            if isText, let options = message.link_preview_options { edit["link_preview_options"] = try jsonObject(options) }
            // One durable attempt: an ambiguous edit or a repeated/stale callback
            // cannot add another credit or later authorize original deletion.
            guard try store.consumePublicationOriginal(chatID: message.chat.id, messageID: message.message_id,
                posterID: callback.from.id, now: now) == original else {
                throw BotError.invalidResponse
            }
            let response = try await api.call(isText ? "editMessageText" : "editMessageCaption", edit)
            guard let response = response as? [String: Any], confirmedMessageID(response["message_id"]) == message.message_id else {
                throw BotError.invalidResponse
            }
            let deleted = try await api.call("deleteMessage", ["chat_id": message.chat.id, "message_id": original.messageID])
            guard let boolean = deleted as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID(), boolean.boolValue else {
                throw BotError.invalidResponse
            }
            await answer(callback, language.text("Original replaced ✓", "Original remplacé ✓"))
        } catch {
            await answer(callback, language.text("Replacement could not be confirmed. The original was not confirmed deleted; check the chat.",
                                                 "Le remplacement n’a pas pu être confirmé. La suppression de l’original n’est pas confirmée ; vérifiez la conversation."), alert: true)
        }
    }

    private func deleteReplacedOriginal(_ message: Message) async {
        do {
            _ = try await api.call("deleteMessage", ["chat_id": message.chat.id, "message_id": message.message_id])
        } catch {
            print("Replacement posted; original retained because deletion failed.")
        }
    }

    private func ownsPublication(chatID: Int64, messageID: Int64, userID: Int64, now: TimeInterval) -> Bool {
        guard userID > 0, let receipt = store.state.publications["\(chatID):\(messageID)"] else { return false }
        return receipt.posterID == userID && now >= receipt.createdAt
            && now - receipt.createdAt < PublicationReceipt.retention
    }

    private func deletePublication(chatID: Int64, messageID: Int64) async throws {
        let result = try await api.call("deleteMessage", ["chat_id": chatID, "message_id": messageID])
        guard let boolean = result as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID(), boolean.boolValue else {
            throw BotError.invalidResponse
        }
        do { try store.removePublication(chatID: chatID, messageID: messageID) }
        catch { print("Publication removed; ownership cleanup will finish later.") }
    }

    private func deletePublicationCommand(_ message: Message, now: TimeInterval, language: BotLanguage) async {
        guard message.chat.isGroup, message.sender_chat == nil, let user = message.from, user.is_bot == false,
              let target = message.reply_to_message,
              ownsPublication(chatID: message.chat.id, messageID: target.message_id, userID: user.id, now: now) else {
            try? await reply(language.text(
                "Reply to a fxclip publication of your own with /delete or /supprimer. Removal is available for less than 48 hours; older or untracked messages cannot be removed this way.",
                "Répondez à une publication fxclip issue de votre message avec /supprimer ou /delete. Le retrait est possible pendant moins de 48 heures ; les messages plus anciens ou non suivis ne peuvent pas être retirés ainsi."), to: message)
            return
        }
        do {
            try await deletePublication(chatID: message.chat.id, messageID: target.message_id)
            try? await reply(language.text("Deleted ✓", "Supprimé ✓"), to: message)
        } catch {
            try? await reply(language.text("Could not delete the publication. Please try again.",
                                           "Impossible de supprimer la publication. Réessayez."), to: message)
        }
    }

    private func publicationsPanel(userID: Int64, page: Int, now: TimeInterval) -> SettingsUI {
        let entries = store.state.publications.compactMap { key, receipt -> PublicationEntry? in
            let ids = key.split(separator: ":", omittingEmptySubsequences: false)
            guard receipt.posterID == userID, now >= receipt.createdAt, now - receipt.createdAt < PublicationReceipt.retention,
                  ids.count == 2, let chatID = Int64(ids[0]), chatID < 0, let messageID = Int64(ids[1]), messageID > 0,
                  key == "\(chatID):\(messageID)" else { return nil }
            return PublicationEntry(chatID: chatID, messageID: messageID, createdAt: receipt.createdAt,
                                    title: store.state.knownGroups[String(chatID)]?.chat.title)
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            if $0.chatID != $1.chatID { return $0.chatID < $1.chatID }
            return $0.messageID > $1.messageID
        }
        return SettingsUI.publications(entries, page: page, language: store.userLanguage(userID))
    }

    private func publicationsCallback(_ callback: CallbackQuery, parts: [String], now: TimeInterval) async throws {
        let language = store.userLanguage(callback.from.id)
        guard let message = callback.message, message.chat.type == "private", message.chat.id == callback.from.id,
              callback.from.is_bot == false else {
            await answer(callback, language.text("Open /publications in your private chat with the bot.",
                                                 "Ouvrez /publications dans votre conversation privée avec le bot."), alert: true)
            return
        }
        let panel: SettingsUI
        if parts.count == 4, parts[2] == "show", let page = Int(parts[3]), (0...4000).contains(page) {
            panel = publicationsPanel(userID: callback.from.id, page: page, now: now)
            await answer(callback, nil)
        } else if parts.count == 6, ["ask", "del"].contains(parts[2]),
                  let chatID = Int64(parts[3]), chatID < 0, let messageID = Int64(parts[4]), messageID > 0,
                  let page = Int(parts[5]), (0...4000).contains(page),
                  ownsPublication(chatID: chatID, messageID: messageID, userID: callback.from.id, now: now) {
            if parts[2] == "ask" {
                panel = SettingsUI.publicationConfirmation(PublicationEntry(chatID: chatID, messageID: messageID,
                    createdAt: store.state.publications["\(chatID):\(messageID)"]!.createdAt,
                    title: store.state.knownGroups[String(chatID)]?.chat.title), page: page, language: language)
                await answer(callback, nil)
            } else {
                do { try await deletePublication(chatID: chatID, messageID: messageID) }
                catch {
                    await answer(callback, language.text("Could not delete the publication. Please try again.",
                                                        "Impossible de supprimer la publication. Réessayez."), alert: true)
                    return
                }
                panel = publicationsPanel(userID: callback.from.id, page: page, now: now)
                await answer(callback, language.text("Deleted ✓", "Supprimé ✓"))
            }
        } else {
            await answer(callback, language.text("This publication is unavailable or no longer removable.",
                                                 "Cette publication est indisponible ou ne peut plus être retirée."), alert: true)
            return
        }
        try await sendPanel(panel, to: message.chat.id, messageID: message.message_id,
                            previousText: message.text, previousMarkup: message.reply_markup)
    }

    private func secretary(_ message: Message, now: Int) async throws {
        guard message.chat.type == "private", now - message.date <= 300,
              let sender = message.from,
              store.secretaryEnabled(userID: sender.id),
              message.sender_business_bot == nil, message.has_protected_content != true,
              message.is_paid_post != true, let connectionID = message.business_connection_id else { return }
        // Fetch current rights, including after a restart or permission revocation.
        let connection = try decode(BusinessConnection.self, from: await api.call("getBusinessConnection", ["business_connection_id": connectionID]))
        guard connection.id == connectionID, connection.is_enabled,
              connection.user.id == sender.id, connection.rights?.can_reply == true else { return }
        guard let rendered = configuredRewriter(chatID: nil, userID: sender.id)
            .rewrite(message, previews: true, attribution: false) else { return }
        var parameters: [String: Any] = ["business_connection_id": connectionID,
            "chat_id": message.chat.id, "message_id": message.message_id,
            "\(message.text == nil ? "caption_entities" : "entities")": try jsonObject(rendered.entities)]
        if message.text != nil {
            parameters["text"] = rendered.text
            parameters["link_preview_options"] = ["is_disabled": false, "url": rendered.previewURL]
            _ = try await api.call("editMessageText", parameters)
        } else {
            parameters["caption"] = rendered.text
            _ = try await api.call("editMessageCaption", parameters)
        }
    }

    private func base(_ message: Message) -> [String: Any] {
        var parameters: [String: Any] = ["chat_id": message.chat.id]
        // Protection must be set on the initial send: a later Replace action can
        // add account attribution, but Telegram's edit methods cannot add this flag.
        if message.chat.isGroup { parameters["protect_content"] = true }
        if let thread = message.message_thread_id { parameters["message_thread_id"] = thread }
        return parameters
    }
    private func privateSettingsLink(language: BotLanguage) -> [String: Any] {
        ["inline_keyboard": [[["text": language.text("⚙️ My private settings", "⚙️ Mes réglages en privé"), "url": "https://t.me/\(username)?start=settings"]]]]
    }

    private func interfaceLanguage(_ message: Message) -> BotLanguage {
        message.chat.isGroup ? store.groupLanguage(message.chat.id) : store.userLanguage(message.from?.id ?? message.chat.id)
    }

    private func languagePanel(_ userID: Int64) -> SettingsUI {
        SettingsUI.languages(selected: store.state.userLanguages[String(userID)],
                             detected: store.state.detectedLanguages[String(userID)] ?? .en)
    }

    private func refreshPrivateCommands(_ userID: Int64) async {
        do {
            try await BotProfile.configureUser(api: api, userID: userID,
                language: store.state.userLanguages[String(userID)], owner: allowedOwners.contains(userID))
        } catch {
            // Preference persistence and the in-chat menu must survive a metadata failure.
            print("Private command menu refresh failed; the saved language still applies.")
        }
    }

    private func personalPanel(userID: Int64, section: String = "show") -> SettingsUI {
        SettingsUI.personal(mode: store.state.users[String(userID)], defaultMode: store.state.defaultMode,
                            owner: allowedOwners.contains(userID), preference: store.state.userLanguages[String(userID)],
                            language: store.userLanguage(userID), section: section,
                            secretaryEnabled: store.secretaryEnabled(userID: userID))
    }

    private func configuredRewriter(chatID: Int64?, userID: Int64?) -> Rewriter {
        let personal = userID.flatMap { store.state.personalLinkSettings[String($0)] }
        let group = chatID.flatMap { store.state.chats[String($0)]?.engineSettings }
        return Rewriter(engine: Engine(rules: rewriter.engine.rules.applying(personal ?? group ?? store.state.defaultLinkSettings)))
    }

    private func cardsEnabled(chatID: Int64?, userID: Int64?) -> Bool {
        let personal = userID.flatMap { store.state.personalYouTubeCards[String($0)] }
        let group = chatID.flatMap { store.state.chats[String($0)]?.youTubeCards }
        return personal ?? group ?? store.state.defaultYouTubeCards
    }

    private func youTubeStyle(chatID: Int64?, userID: Int64?) -> YouTubePreviewStyle {
        let personal = userID.flatMap { store.state.personalYouTubeStyle[String($0)] }
        let group = chatID.flatMap { store.state.chats[String($0)]?.youTubeStyle }
        return personal ?? group ?? store.state.defaultYouTubeStyle
    }

    private func facebookEnabled(chatID: Int64?, userID: Int64?) -> Bool {
        let personal = userID.flatMap { store.state.personalFacebookReels[String($0)] }
        let group = chatID.flatMap { store.state.chats[String($0)]?.facebookReels }
        return personal ?? group ?? store.state.defaultFacebookReels
    }

    private func redditEnabled(chatID: Int64?, userID: Int64?) -> Bool {
        let personal = userID.flatMap { store.state.personalRedditVideos[String($0)] }
        let group = chatID.flatMap { store.state.chats[String($0)]?.redditVideos }
        return personal ?? group ?? store.state.defaultRedditVideos
    }

    private func chatSettings(_ chatID: Int64) -> ChatSettings {
        if var settings = store.state.chats[String(chatID)] {
            if settings.modeInherited { settings.mode = store.state.defaultMode }
            return settings
        }
        var settings = ChatSettings()
        settings.mode = store.state.defaultMode
        settings.modeInherited = true
        return settings
    }

    private func chatPanel(_ chat: Chat, section: String = "show") -> SettingsUI {
        let context = Chat(id: chat.id, type: chat.type,
                           title: chat.title ?? store.state.knownGroups[String(chat.id)]?.chat.title)
        return SettingsUI.chat(context, settings: chatSettings(chat.id), enabled: isEnabled(chatID: chat.id),
                        inherited: chatSettings(chat.id).modeInherited, username: username,
                        language: store.groupLanguage(chat.id), section: section)
    }

    private func isEnabled(chatID: Int64) -> Bool {
        store.state.groupEnabled[String(chatID)] ?? allowedChats.contains(chatID)
    }

    private func groupsPanel(language: BotLanguage) -> SettingsUI {
        SettingsUI.groups(store.state.knownGroups.values.sorted {
            if $0.chat.title == $1.chat.title { return $0.chat.id < $1.chat.id }
            return ($0.chat.title ?? "") < ($1.chat.title ?? "")
        }, enabled: isEnabled, username: username, language: language)
    }

    private func sendPanel(_ panel: SettingsUI, to chatID: Int64, messageID: Int64? = nil,
                           previousText: String? = nil, previousMarkup: InlineKeyboardMarkup? = nil,
                           removingCommand command: Message? = nil) async throws {
        if messageID != nil, previousText == panel.plainText, let previousMarkup,
           previousMarkup == (try? decode(InlineKeyboardMarkup.self, from: panel.markup)) { return }
        var parameters: [String: Any] = ["chat_id": chatID, "text": panel.text,
            "parse_mode": "HTML", "reply_markup": panel.markup,
            "link_preview_options": ["is_disabled": true]]
        if let messageID {
            parameters["message_id"] = messageID
            do {
                _ = try await api.call("editMessageText", parameters)
                return
            } catch {
                // Preferences are already saved. A deleted/stale panel must never undo them.
                parameters.removeValue(forKey: "message_id")
            }
        }
        // Group settings/welcome messages use this separate send path. Do not pass
        // protect_content to editMessageText, which cannot change that property.
        if chatID < 0 { parameters["protect_content"] = true }
        let sent = try await api.call("sendMessage", parameters)
        // Remove only this handled group command, after a confirmed panel send.
        // Permission lookup and cleanup are best effort: the panel remains usable.
        if let command, command.chat.isGroup, command.chat.id == chatID,
           let sent = sent as? [String: Any],
           let sentID = confirmedMessageID(sent["message_id"]), sentID != command.message_id {
            do {
                guard try await canDelete(in: command.chat) else { return }
                _ = try await api.call("deleteMessage", ["chat_id": chatID, "message_id": command.message_id])
            } catch { /* Missing rights or failed cleanup must not resend the panel. */ }
        }
    }

    private func settingsCallback(_ callback: CallbackQuery, now: TimeInterval) async throws {
        let language = store.userLanguage(callback.from.id)
        // Callback data is client-controlled. Bind every action to a button that
        // Telegram confirms is attached to this exact bot message, before routing.
        guard let message = callback.message, message.from?.id == botID, message.from?.is_bot == true,
              let data = callback.data,
              message.reply_markup?.inline_keyboard.joined().contains(where: { $0.callback_data == data }) == true else {
            await answer(callback, language.text("This button is no longer available. Open settings again.", "Ce bouton n’est plus disponible. Ouvrez de nouveau les réglages."), alert: true)
            return
        }
        let parts = (callback.data ?? "").split(separator: ":").map(String.init)
        if parts.prefix(2) == ["fxclip", "preview"] {
            if parts.prefix(3) == ["fxclip", "preview", "replace"] {
                await replacePreview(callback, parts: parts, now: now)
            } else { await removePreview(callback, now: now) }
            return
        }
        if parts.prefix(2) == ["fxclip", "posts"] {
            try await publicationsCallback(callback, parts: parts, now: now)
            return
        }
        if parts.count >= 2, parts[0] == "fxclip", parts[1] == "rules" {
            try await rulesCallback(callback, parts: parts)
            return
        }
        if parts.count >= 2, parts[0] == "fxclip", parts[1] == "chat" {
            try await chatCallback(callback, parts: parts)
            return
        }
        guard let message = callback.message, message.chat.type == "private",
              message.chat.id == callback.from.id, callback.from.is_bot != true else {
            await answer(callback, language.text("Open /settings in your private chat with the bot.", "Ouvrez /settings dans votre conversation privée avec le bot."), alert: true)
            return
        }
        if parts == ["fxclip", "panel", "close"] {
            await dismissPanel(callback, message: message, language: language)
            return
        }
        if parts.count == 3, parts[0] == "fxclip", parts[1] == "language" {
            let action = parts[2]
            if action == "auto" { try store.setUserLanguage(nil, userID: callback.from.id) }
            else if let chosen = BotLanguage(rawValue: action) { try store.setUserLanguage(chosen, userID: callback.from.id) }
            else if action != "show" {
                await answer(callback, language.text("This button is no longer available. Open /settings.", "Ce bouton n’est plus disponible. Ouvrez /settings."))
                return
            }
            let updated = store.userLanguage(callback.from.id)
            await answer(callback, action == "show" ? nil : updated.text("Language saved ✓", "Langue enregistrée ✓"))
            try await sendPanel(languagePanel(callback.from.id), to: message.chat.id, messageID: message.message_id,
                                previousText: message.text, previousMarkup: message.reply_markup)
            await refreshPrivateCommands(callback.from.id)
            return
        }
        if parts.first == "fxclip", parts.count >= 2, ["groups", "group"].contains(parts[1]) {
            // Every navigation, refresh and activation is owner-only, including old panels.
            guard allowedOwners.contains(callback.from.id) else {
                await answer(callback, language.text("Only the bot owner can manage connected groups.", "La gestion des groupes est réservée au propriétaire du bot."), alert: true)
                return
            }
            try await groupCallback(callback, message: message, parts: parts)
            return
        }
        guard parts.count == 3, parts[0] == "fxclip", ["personal", "default"].contains(parts[1]) else {
            await answer(callback, language.text("This button is no longer available. Open /settings.", "Ce bouton n’est plus disponible. Ouvrez /settings."))
            return
        }
        let ownerPanel = parts[1] == "default"
        // Authenticate on every click, including callbacks from previously issued owner panels.
        guard !ownerPanel || allowedOwners.contains(callback.from.id) else {
            await answer(callback, language.text("Only the bot owner can change this setting.", "Ce réglage est réservé au propriétaire du bot."), alert: true)
            return
        }
        let action = parts[2]
        if !ownerPanel && action == "publications" {
            await answer(callback, nil)
            try await sendPanel(publicationsPanel(userID: callback.from.id, page: 0, now: now),
                to: message.chat.id, messageID: message.message_id, previousText: message.text, previousMarkup: message.reply_markup)
            return
        }
        do {
            if ["show", "mode", "about"].contains(action) || (!ownerPanel && action == "secretary_setup") {
                // Navigation never changes preferences.
            } else if !ownerPanel && action == "default" {
                try store.setMode(nil, userID: callback.from.id)
            } else if !ownerPanel && action == "secretary_off" {
                try store.setSecretary(false, userID: callback.from.id)
            } else if let mode = Mode(rawValue: action) {
                if ownerPanel { try store.setDefault(mode) }
                else { try store.setMode(mode, userID: callback.from.id) }
            } else {
                await answer(callback, language.text("This button is no longer available. Open /settings.", "Ce bouton n’est plus disponible. Ouvrez /settings."))
                return
            }
        } catch {
            await answer(callback, language.text("Could not save the setting. Please try again.", "Le réglage n’a pas pu être enregistré. Réessayez."), alert: true)
            throw error
        }
        let navigation = ["show", "mode", "about", "secretary_setup"].contains(action)
        let saved = ownerPanel ? language.text("Bot defaults saved ✓", "Réglages par défaut du bot enregistrés ✓")
            : language.text("Saved for your messages ✓", "Enregistré pour vos messages ✓")
        await answer(callback, navigation ? nil : saved)
        let section = navigation ? action : !ownerPanel && ["secretary", "secretary_off"].contains(action) ? "secretary_setup" : "mode"
        let panel = ownerPanel
            ? SettingsUI.defaults(mode: store.state.defaultMode, language: language, section: section)
            : personalPanel(userID: callback.from.id, section: section)
        // Clicking the already selected choice should not create a duplicate panel after
        // Telegram rejects an unchanged edit as "message is not modified".
        try await sendPanel(panel, to: message.chat.id, messageID: message.message_id,
                            previousText: message.text, previousMarkup: message.reply_markup)
        if !ownerPanel && action == "show" { await refreshPrivateCommands(callback.from.id) }
    }

    private func chatCallback(_ callback: CallbackQuery, parts: [String]) async throws {
        let language = store.userLanguage(callback.from.id)
        guard parts.count == 4, let chatID = Int64(parts[2]),
              let message = callback.message, message.chat.isGroup, message.chat.id == chatID,
              callback.from.is_bot != true,
              ["show", "activation", "mode", "language", "about", "enable", "disable", "reply", "replace", "off", "mode_default", "previews_on", "previews_off", "lang_en", "lang_fr", "close"].contains(parts[3]) else {
            await answer(callback, language.text("This button does not belong to this group. Open /setup.", "Ce bouton ne correspond pas à ce groupe. Ouvrez /setup."), alert: true)
            return
        }
        // Owners keep their existing authority if Telegram's member lookup is unavailable.
        // Everyone else must prove current group admin rights on every click, even old panels.
        if !allowedOwners.contains(callback.from.id) {
            let admin: Bool
            do { admin = try await isAdmin(chatID: chatID, userID: callback.from.id) }
            catch {
                await answer(callback, language.text("Could not verify your permissions. Please try again.", "Impossible de vérifier vos droits. Réessayez."), alert: true)
                return
            }
            guard admin else {
                await answer(callback, language.text("Only group admins can change this. Use “My settings” for your personal choice.", "Réservé aux administrateurs du groupe. Utilisez « Mes réglages » pour votre choix personnel."), alert: true)
                return
            }
        }
        let action = parts[3]
        if action == "close" {
            await dismissPanel(callback, message: message, language: store.groupLanguage(chatID))
            return
        }
        var settings = chatSettings(chatID)
        if action == "replace" || (action == "enable" && settings.mode == .replace)
            || (action == "mode_default" && store.state.defaultMode == .replace) {
            let mayDelete = (try? await canDelete(in: message.chat)) == true
            guard mayDelete else {
                await answer(callback, language.text("Grant fxclip Delete messages permission before enabling replacement. Setting unchanged.", "Accordez à fxclip le droit de supprimer les messages avant d’activer le remplacement. Réglage inchangé."), alert: true)
                return
            }
        }
        if action == "lang_en" || action == "lang_fr" {
            try store.setGroupLanguage(action == "lang_fr" ? .fr : .en, chatID: chatID)
        } else if action == "enable" || action == "disable" {
            try store.setGroupEnabled(action == "enable", chatID: chatID)
        } else if action == "mode_default" {
            settings.mode = store.state.defaultMode
            settings.modeInherited = true
            try store.set(settings, chatID: chatID)
        } else if let mode = Mode(rawValue: action) {
            settings.mode = mode
            settings.modeInherited = false
            try store.set(settings, chatID: chatID)
        } else if action == "previews_on" || action == "previews_off" {
            settings.previews = action == "previews_on"
            try store.set(settings, chatID: chatID)
        }
        let navigation = ["show", "activation", "mode", "language", "about"].contains(action)
        let panelLanguage = store.groupLanguage(chatID)
        await answer(callback, navigation ? nil : panelLanguage.text("Saved for this group ✓", "Enregistré pour ce groupe ✓"))
        let section = navigation ? action : ["reply", "replace", "off", "mode_default"].contains(action) ? "mode"
            : ["lang_en", "lang_fr"].contains(action) ? "language" : "show"
        let panel = ["previews_on", "previews_off"].contains(action)
            ? rulesPanel(.chat(chatID), section: "previews", language: panelLanguage)
            : chatPanel(message.chat, section: section)
        try await sendPanel(panel, to: chatID, messageID: message.message_id,
                            previousText: message.text, previousMarkup: message.reply_markup)
    }

    private func dismissPanel(_ callback: CallbackQuery, message: Message, language: BotLanguage) async {
        guard message.from?.id == botID else {
            await answer(callback, language.text("This panel cannot be closed.", "Ce panneau ne peut pas être fermé."), alert: true)
            return
        }
        let target: [String: Any] = ["chat_id": message.chat.id, "message_id": message.message_id]
        do {
            _ = try await api.call("deleteMessage", target)
        } catch {
            // Old messages may no longer be deletable. Collapse the panel in place.
            var parameters = target
            parameters["text"] = message.chat.isGroup
                ? language.text("Settings closed. Use /setup to reopen.", "Réglages fermés. /setup pour les rouvrir.")
                : language.text("Settings closed. Use /settings to reopen.", "Réglages fermés. /settings pour les rouvrir.")
            parameters["reply_markup"] = ["inline_keyboard": []] as [String: Any]
            do { _ = try await api.call("editMessageText", parameters) }
            catch {
                await answer(callback, language.text("Could not close this panel. Please try again.", "Impossible de fermer ce panneau. Réessayez."), alert: true)
                return
            }
        }
        await answer(callback, nil)
    }

    private func groupCallback(_ callback: CallbackQuery, message: Message, parts: [String]) async throws {
        let language = store.userLanguage(callback.from.id)
        if parts == ["fxclip", "groups", "show"] {
            await answer(callback, nil)
            try await sendPanel(groupsPanel(language: language), to: message.chat.id, messageID: message.message_id,
                                previousText: message.text, previousMarkup: message.reply_markup)
            return
        }
        guard parts.count == 4, parts[1] == "group", let chatID = Int64(parts[2]),
              ["show", "refresh", "on", "off"].contains(parts[3]),
              let group = store.state.knownGroups[String(chatID)] else {
            await answer(callback, language.text("Group unavailable. Open /groups.", "Groupe indisponible. Ouvrez /groups."), alert: true)
            return
        }
        let action = parts[3]
        // Disabling must remain possible even when Telegram cannot report current rights.
        if action == "off" { try store.setGroupEnabled(false, chatID: chatID) }
        let current: ChatMember
        do {
            current = try await member(chatID: chatID, userID: botID)
        } catch {
            await answer(callback, language.text("Could not verify the bot’s permissions. Please try again.", "Impossible de vérifier les droits du bot. Réessayez."), alert: true)
            try await sendPanel(SettingsUI.group(group, enabled: isEnabled(chatID: chatID), rights: nil, language: language),
                                to: message.chat.id, messageID: message.message_id,
                                previousText: message.text, previousMarkup: message.reply_markup)
            return
        }
        try store.discover(group.chat, member: current)
        if current.isAbsent {
            await answer(callback, language.text("The bot is no longer in this group. Cleaning is disabled.", "Le bot ne fait plus partie de ce groupe. Nettoyage désactivé."), alert: true)
            try await sendPanel(groupsPanel(language: language), to: message.chat.id, messageID: message.message_id,
                                previousText: message.text, previousMarkup: message.reply_markup)
            return
        }
        if action == "on" { try store.setGroupEnabled(true, chatID: chatID) }
        await answer(callback, ["on", "off"].contains(action) ? language.text("Setting saved ✓", "Réglage enregistré ✓") : nil)
        try await sendPanel(SettingsUI.group(group, enabled: isEnabled(chatID: chatID), rights: current, language: language),
                            to: message.chat.id, messageID: message.message_id,
                            previousText: message.text, previousMarkup: message.reply_markup)
    }

    private enum RuleScope {
        case personal(Int64), chat(Int64), defaults
        var key: String {
            switch self {
            case .personal: return "p"
            case .chat(let id): return "c:\(id)"
            case .defaults: return "d"
            }
        }
    }

    private func ruleOverride(_ scope: RuleScope) -> UserSettings? {
        switch scope {
        case .personal(let id): return store.state.personalLinkSettings[String(id)]
        case .chat(let id): return store.state.chats[String(id)]?.engineSettings
        case .defaults: return store.state.defaultLinkSettings
        }
    }

    private func ruleCardsOverride(_ scope: RuleScope) -> Bool? {
        switch scope {
        case .personal(let id): return store.state.personalYouTubeCards[String(id)]
        case .chat(let id): return store.state.chats[String(id)]?.youTubeCards
        case .defaults: return store.state.defaultYouTubeCards
        }
    }

    private func ruleYouTubeStyleOverride(_ scope: RuleScope) -> YouTubePreviewStyle? {
        switch scope {
        case .personal(let id): return store.state.personalYouTubeStyle[String(id)]
        case .chat(let id): return store.state.chats[String(id)]?.youTubeStyle
        case .defaults: return store.state.defaultYouTubeStyle
        }
    }

    private func saveYouTubeStyle(_ scope: RuleScope, style: YouTubePreviewStyle?) throws {
        switch scope {
        case .personal(let id): try store.setPersonalYouTubeStyle(style, userID: id)
        case .chat(let id):
            if store.state.chats[String(id)] == nil, style == nil { return }
            var settings = chatSettings(id)
            settings.youTubeStyle = style
            try store.set(settings, chatID: id)
        case .defaults: try store.setDefaultYouTubeStyle(style ?? .koutube)
        }
    }

    private func ruleFacebookOverride(_ scope: RuleScope) -> Bool? {
        switch scope {
        case .personal(let id): return store.state.personalFacebookReels[String(id)]
        case .chat(let id): return store.state.chats[String(id)]?.facebookReels
        case .defaults: return store.state.defaultFacebookReels
        }
    }

    private func ruleRedditOverride(_ scope: RuleScope) -> Bool? {
        switch scope {
        case .personal(let id): return store.state.personalRedditVideos[String(id)]
        case .chat(let id): return store.state.chats[String(id)]?.redditVideos
        case .defaults: return store.state.defaultRedditVideos
        }
    }

    private func saveReddit(_ scope: RuleScope, enabled: Bool?) throws {
        switch scope {
        case .personal(let id): try store.setPersonalRedditVideos(enabled, userID: id)
        case .chat(let id):
            if store.state.chats[String(id)] == nil, enabled == nil { return }
            var settings = chatSettings(id)
            settings.redditVideos = enabled
            try store.set(settings, chatID: id)
        case .defaults: try store.setDefaultRedditVideos(enabled ?? false)
        }
    }

    private func saveRules(_ scope: RuleScope, settings: UserSettings?, cards: Bool?, facebook: Bool?) throws {
        switch scope {
        case .personal(let id):
            try store.setPersonalLinks(settings, youTubeCards: cards, userID: id)
            if ruleFacebookOverride(scope) != facebook { try store.setPersonalFacebookReels(facebook, userID: id) }
        case .chat(let id):
            if store.state.chats[String(id)] == nil, settings == nil, cards == nil, facebook == nil { return }
            var chat = chatSettings(id)
            chat.engineSettings = settings
            chat.youTubeCards = cards
            chat.facebookReels = facebook
            try store.set(chat, chatID: id)
        case .defaults:
            try store.setDefaultLinks(settings ?? UserSettings(), youTubeCards: cards ?? true)
            if store.state.defaultFacebookReels != (facebook ?? false) { try store.setDefaultFacebookReels(facebook ?? false) }
        }
    }

    private func rulesPanel(_ scope: RuleScope, section: String = "show", language: BotLanguage) -> SettingsUI {
        let settings = ruleOverride(scope)
        let previews: Bool
        if case .chat(let id) = scope { previews = chatSettings(id).previews }
        else { previews = true }
        return SettingsUI.rules(settings ?? store.state.defaultLinkSettings, builtins: rewriter.engine.rules,
                                scope: scope.key, section: section, inherited: settings == nil,
                                previewsEnabled: previews,
                                youTubeCards: ruleCardsOverride(scope) ?? store.state.defaultYouTubeCards,
                                facebookReels: ruleFacebookOverride(scope) ?? store.state.defaultFacebookReels,
                                language: language,
                                groupTitle: {
                                    if case .chat(let id) = scope { return store.state.knownGroups[String(id)]?.chat.title }
                                    return nil
                                }(),
                                youTubeInherited: ruleCardsOverride(scope) == nil,
                                facebookInherited: ruleFacebookOverride(scope) == nil,
                                cleaningEnabled: {
                                    if case .chat(let id) = scope { return isEnabled(chatID: id) }
                                    return true
                                }(),
                                redditVideos: ruleRedditOverride(scope) ?? store.state.defaultRedditVideos,
                                redditInherited: ruleRedditOverride(scope) == nil,
                                youTubeStyle: ruleYouTubeStyleOverride(scope) ?? store.state.defaultYouTubeStyle,
                                youTubeStyleInherited: ruleYouTubeStyleOverride(scope) == nil)
    }

    private func rulesCallback(_ callback: CallbackQuery, parts: [String]) async throws {
        let language = store.userLanguage(callback.from.id)
        guard parts.count >= 4, let message = callback.message, message.from?.id == botID,
              callback.from.is_bot != true else {
            await answer(callback, language.text("Open settings again.", "Ouvrez de nouveau les réglages."), alert: true)
            return
        }
        let scope: RuleScope
        let actions: [String]
        switch parts[2] {
        case "p", "d":
            guard message.chat.type == "private", message.chat.id == callback.from.id,
                  parts[2] != "d" || allowedOwners.contains(callback.from.id) else {
                await answer(callback, language.text("This setting is not available here.", "Ce réglage n’est pas accessible ici."), alert: true)
                return
            }
            scope = parts[2] == "d" ? .defaults : .personal(callback.from.id)
            actions = Array(parts.dropFirst(3))
        case "c":
            guard parts.count >= 5, let id = Int64(parts[3]), message.chat.isGroup, message.chat.id == id else {
                await answer(callback, language.text("This button belongs to another group.", "Ce bouton appartient à un autre groupe."), alert: true)
                return
            }
            if !allowedOwners.contains(callback.from.id) {
                guard (try? await isAdmin(chatID: id, userID: callback.from.id)) == true else {
                    await answer(callback, language.text("Only current group admins can change this.", "Ce réglage est réservé aux administrateurs actuels du groupe."), alert: true)
                    return
                }
            }
            scope = .chat(id)
            actions = Array(parts.dropFirst(4))
        default:
            await answer(callback, language.text("Open settings again.", "Ouvrez de nouveau les réglages."))
            return
        }
        let panelLanguage: BotLanguage
        if case .chat(let id) = scope { panelLanguage = store.groupLanguage(id) }
        else { panelLanguage = language }
        let engineEdit = ["trackers", "site", "providerreset"].contains(actions.first ?? "")
            || (actions.count == 3 && actions[0] == "preview" && ["on", "off"].contains(actions[2]))
        if scope.key != "d", engineEdit, ruleOverride(scope) == nil {
            await answer(callback, panelLanguage.text("Create link preferences first.", "Créez d’abord des préférences de liens."))
            try await sendPanel(rulesPanel(scope, section: "customize", language: panelLanguage),
                to: message.chat.id, messageID: message.message_id,
                previousText: message.text, previousMarkup: message.reply_markup)
            return
        }
        var section = actions.first ?? "show"
        var settings = ruleOverride(scope) ?? store.state.defaultLinkSettings
        var storedSettings = ruleOverride(scope)
        var cards = ruleCardsOverride(scope)
        var facebook = ruleFacebookOverride(scope)
        var reddit = ruleRedditOverride(scope)
        var youTubeStyle = ruleYouTubeStyleOverride(scope)
        var changed = false
        let builtins = rewriter.engine.rules
        switch actions {
        case ["show"], ["clean"], ["previews"], ["excluded"], ["info"], ["customize"]: break
        case ["reset", "show"]: section = "reset"
        case ["youtube", "show"]: section = "youtube"
        case ["youtube", "style", "koutube"]:
            youTubeStyle = .koutube; changed = true; section = "youtube"
        case ["youtube", "style", "photo"]:
            youTubeStyle = .photo; changed = true; section = "youtube"
        case ["youtube", "style", "default"] where scope.key != "d":
            youTubeStyle = nil; changed = true; section = "youtube"
        case ["facebook", "show"]: section = "facebook"
        case ["reddit", "show"]: section = "reddit"
        case ["customize", "confirm"]:
            guard scope.key != "d" else {
                await answer(callback, panelLanguage.text("Bot defaults are already editable.", "Les réglages par défaut du bot sont déjà modifiables."))
                return
            }
            // A stale confirmation must not reset customization created elsewhere.
            if ruleOverride(scope) == nil {
                storedSettings = store.state.defaultLinkSettings
                changed = true
            }
            section = "show"
        case ["reset"]:
            storedSettings = nil; cards = nil; facebook = nil; reddit = nil; youTubeStyle = nil; changed = true; section = "show"
        default:
            if actions.count == 3, actions[0] == "preview", actions[2] == "show",
               builtins.previews.contains(where: { $0.id == actions[1] }) {
                section = "preview:\(actions[1])"
            } else if actions.count == 2, actions[0] == "provider", builtins.previews.contains(where: { $0.id == actions[1] }) {
                section = "provider:\(actions[1])"
            } else if actions.count == 2, actions[0] == "providerreset",
                      let rule = builtins.previews.first(where: { $0.id == actions[1] }) {
                var value = settings.previews[rule.id] ?? .init(enabled: settings.previewDefaultsEnabled, apps: rule.apps)
                value.targetHost = nil
                settings.previews[rule.id] = value
                storedSettings = settings; changed = true; section = "provider:\(rule.id)"
            } else if actions.count == 2, ["youtube", "facebook", "reddit"].contains(actions[0]), actions[1] == "default", scope.key != "d" {
                if actions[0] == "youtube" { cards = nil; section = "youtube" }
                else if actions[0] == "reddit" { reddit = nil; section = "reddit" }
                else { facebook = nil; section = "facebook" }
                changed = true
            } else if actions.count == 2, ["trackers", "youtube", "facebook", "reddit"].contains(actions[0]), ["on", "off"].contains(actions[1]) {
                if actions[0] == "trackers" {
                    settings.trackersEverywhere = actions[1] == "on"; storedSettings = settings
                    section = "clean"
                } else if actions[0] == "youtube" {
                    cards = actions[1] == "on"; section = "youtube"
                } else if actions[0] == "reddit" {
                    reddit = actions[1] == "on"; section = "reddit"
                } else {
                    facebook = actions[1] == "on"; section = "facebook"
                }
                changed = true
            } else if actions.count == 3, ["on", "off"].contains(actions[2]),
                      actions[0] == "site", builtins.trackers.sites.contains(where: { $0.id == actions[1] }) {
                if actions[2] == "off" { settings.disabledSites.insert(actions[1]) }
                else { settings.disabledSites.remove(actions[1]) }
                storedSettings = settings; changed = true; section = "clean"
            } else if actions.count == 3, ["on", "off"].contains(actions[2]), actions[0] == "preview",
                      let rule = builtins.previews.first(where: { $0.id == actions[1] }) {
                var value = settings.previews[rule.id] ?? .init(enabled: settings.previewDefaultsEnabled, apps: rule.apps)
                value.enabled = actions[2] == "on"
                if value.enabled, !value.apps.contains("telegram") { value.apps.append("telegram") }
                settings.previews[rule.id] = value
                storedSettings = settings; changed = true; section = "preview:\(rule.id)"
            } else {
                await answer(callback, language.text("This button is no longer available.", "Ce bouton n’est plus disponible."))
                return
            }
        }
        if changed {
            try saveRules(scope, settings: storedSettings, cards: cards, facebook: facebook)
            if reddit != ruleRedditOverride(scope) { try saveReddit(scope, enabled: reddit) }
            if youTubeStyle != ruleYouTubeStyleOverride(scope) { try saveYouTubeStyle(scope, style: youTubeStyle) }
        }
        let saved: String
        switch scope {
        case .personal: saved = panelLanguage.text("Saved for your messages ✓", "Enregistré pour vos messages ✓")
        case .chat: saved = panelLanguage.text("Saved for this group ✓", "Enregistré pour ce groupe ✓")
        case .defaults: saved = panelLanguage.text("Bot defaults saved ✓", "Réglages par défaut du bot enregistrés ✓")
        }
        await answer(callback, changed ? saved : nil)
        try await sendPanel(rulesPanel(scope, section: section, language: panelLanguage), to: message.chat.id,
                            messageID: message.message_id, previousText: message.text, previousMarkup: message.reply_markup)
    }

    private func rulesCommand(_ message: Message, command: String, words: [String], language: BotLanguage) async throws -> Bool {
        let scope: RuleScope
        let arguments: [String]
        if ["/rules", "/provider", "/exclude"].contains(command),
           message.chat.type == "private", let user = message.from, user.id == message.chat.id {
            scope = .personal(user.id)
            arguments = [String(command.dropFirst())] + words.dropFirst()
        } else if command == "/default", words.count >= 2, ["settings", "provider", "exclude"].contains(words[1]),
                  message.chat.type == "private", let user = message.from, user.id == message.chat.id {
            guard allowedOwners.contains(user.id) else {
                try await reply(language.text("Only the bot owner can change the global defaults.", "Seul le propriétaire du bot peut modifier les réglages généraux."), to: message)
                return true
            }
            scope = .defaults; arguments = Array(words.dropFirst())
        } else if command == "/fxclip", words.count >= 2, ["settings", "provider", "exclude"].contains(words[1]), message.chat.isGroup {
            guard message.sender_chat == nil, let user = message.from else {
                try await reply(language.text("Use your personal admin profile.", "Utilisez votre profil personnel d’administrateur."), to: message)
                return true
            }
            var permitted = allowedOwners.contains(user.id)
            if !permitted { permitted = (try? await isAdmin(chatID: message.chat.id, userID: user.id)) == true }
            guard permitted else {
                try await reply(language.text("Only current group admins can change this.", "Ce réglage est réservé aux administrateurs actuels du groupe."), to: message)
                return true
            }
            scope = .chat(message.chat.id); arguments = Array(words.dropFirst())
        } else { return false }
        if scope.key != "d", ["provider", "exclude"].contains(arguments.first ?? ""), ruleOverride(scope) == nil {
            try await sendPanel(rulesPanel(scope, section: "customize", language: language), to: message.chat.id)
            return true
        }
        var settings = ruleOverride(scope) ?? store.state.defaultLinkSettings
        var section = "show"
        if arguments.first == "provider" {
            guard arguments.count == 3,
                  let rule = rewriter.engine.rules.previews.first(where: { $0.id == arguments[1] }),
                  arguments[2] == "default" || Rules.canonicalPreviewHost(arguments[2]) != nil else {
                try await reply(language.text("Use a known preview ID and a domain only, for example: /provider reddit mirror.example. Use default to restore its provider.", "Utilisez un aperçu connu et un domaine seul, par exemple : /provider reddit mirror.example. Utilisez default pour rétablir le fournisseur."), to: message)
                return true
            }
            var value = settings.previews[rule.id] ?? .init(enabled: settings.previewDefaultsEnabled, apps: rule.apps)
            value.targetHost = arguments[2] == "default" ? nil : Rules.canonicalPreviewHost(arguments[2])
            settings.previews[rule.id] = value
            try saveRules(scope, settings: settings, cards: ruleCardsOverride(scope), facebook: ruleFacebookOverride(scope))
            section = "provider:\(rule.id)"
        } else if arguments.first == "exclude" {
            guard (arguments.count == 3 || arguments.count == 4), ["add", "remove"].contains(arguments[1]),
                  arguments.count == 3 || (arguments[1] == "add" && arguments[3] == "exact"),
                  let host = Rules.canonicalPreviewHost(arguments[2]) else {
                try await reply(language.text("Use /exclude add example.com or /exclude remove example.com. Add exact to exclude only that host. Preview choices remain separate.", "Utilisez /exclude add example.com ou /exclude remove example.com. Ajoutez exact pour exclure uniquement cet hôte. Les aperçus se règlent séparément."), to: message)
                return true
            }
            settings.neverClean.removeAll { $0.host == host }
            if arguments[1] == "add" { settings.neverClean.append(SkipHost(host: host, subdomains: arguments.count == 3)) }
            try saveRules(scope, settings: settings, cards: ruleCardsOverride(scope), facebook: ruleFacebookOverride(scope))
            section = "excluded"
        }
        try await sendPanel(rulesPanel(scope, section: section, language: language), to: message.chat.id)
        return true
    }

    private func answer(_ callback: CallbackQuery, _ text: String?, alert: Bool = false) async {
        var parameters: [String: Any] = ["callback_query_id": callback.id]
        if let text { parameters["text"] = text }
        if alert { parameters["show_alert"] = true }
        // An expired callback acknowledgement must not prevent saving or refreshing the panel.
        _ = try? await api.call("answerCallbackQuery", parameters)
    }

    private func reply(_ text: String, to message: Message, markup: [String: Any]? = nil) async throws {
        var parameters = base(message)
        parameters["text"] = text
        parameters["reply_parameters"] = ["message_id": message.message_id, "allow_sending_without_reply": true]
        if let markup { parameters["reply_markup"] = markup }
        _ = try await api.call("sendMessage", parameters)
    }
    private func member(chatID: Int64, userID: Int64) async throws -> ChatMember {
        try decode(ChatMember.self, from: await api.call("getChatMember", ["chat_id": chatID, "user_id": userID]))
    }
    private func isAdmin(chatID: Int64, userID: Int64) async throws -> Bool {
        try await member(chatID: chatID, userID: userID).isAdmin
    }
    private func canDelete(in chat: Chat) async throws -> Bool {
        if chat.type == "private" { return true }
        return try await member(chatID: chat.id, userID: botID).canDelete(in: chat)
    }
}
