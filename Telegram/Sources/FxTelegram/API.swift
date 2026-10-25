import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol BotAPI {
    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any
}

public enum BotError: Error {
    case telegram(Int)
    case invalidResponse
    case configuration(String)
}

/// An in-memory MP4 uploaded by the bot, rather than fetched again by Telegram.
public struct VideoUpload {
    public let data: Data
    public init(data: Data) { self.data = data }
}

public final class TelegramAPI: BotAPI {
    private let token: String
    private let session: URLSession
    private let diagnostics: Bool
    public init(token: String, session: URLSession? = nil, diagnostics: Bool = false) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 50
        self.session = session ?? URLSession(configuration: config)
        self.diagnostics = diagnostics
    }

    /// Only closed labels may leave the API boundary. Telegram descriptions and
    /// URLSession errors can contain tokens, URLs, names or message contents.
    static func failureSummary(method: String, code: Int, description: String?, retryAfter: Int? = nil) -> String {
        let safeMethod = diagnosticMethod(method)
        let text = description?.lowercased() ?? ""
        let reasons: [(String, String)] = [
            ("can't parse entities", "entities"), ("entity bounds", "entities"),
            ("button_data_invalid", "button_data"), ("button_type_invalid", "button_type"),
            ("inline keyboard", "keyboard"), ("reply markup", "keyboard"),
            ("message to reply not found", "reply_missing"), ("reply message not found", "reply_missing"),
            ("message thread not found", "thread_missing"),
            ("message is not modified", "unchanged"), ("message can't be edited", "edit_forbidden"),
            ("message to edit not found", "edit_missing"),
            ("webpage_curl_failed", "preview_fetch"), ("webpage_media_empty", "preview_media"),
            ("wrong http url", "media_url"), ("failed to get http url", "media_fetch"),
            ("wrong file identifier", "media_identifier"),
            ("bot was blocked", "blocked"), ("chat not found", "chat_missing"),
            ("not enough rights", "permissions"), ("can't initiate conversation", "private_not_started"),
            ("too many requests", "rate_limit"), ("not enough stars", "stars")
        ]
        let reason = reasons.first { text.contains($0.0) }?.1 ?? "other"
        let wait = code == 429 ? retryAfter.flatMap { (1...86_400).contains($0) ? ", retry_seconds=\($0)" : nil } ?? "" : ""
        return "Telegram \(safeMethod) rejected: code=\((100...599).contains(code) ? code : 0), reason=\(reason)\(wait)."
    }

    private static func diagnosticMethod(_ method: String) -> String {
        let known: Set<String> = ["getMe", "getUpdates", "getWebhookInfo", "getChatMember", "getBusinessConnection",
            "sendMessage", "sendPhoto", "sendVideo", "editMessageText", "editMessageCaption", "editMessageMedia",
            "editMessageReplyMarkup", "deleteMessage", "answerCallbackQuery", "setMyCommands", "setMyDescription",
            "setMyName", "setMyShortDescription", "getMyName", "getMyDescription", "getMyShortDescription", "getMyCommands"]
        return known.contains(method) ? method : "other"
    }

    public func call(_ method: String, _ parameters: [String: Any] = [:]) async throws -> Any {
        // Do not print URLSession errors: Telegram puts the credential in the request URL.
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/\(method)")!)
        request.httpMethod = "POST"
        var fields = parameters
        let upload: VideoUpload?
        if let video = parameters["video"] as? VideoUpload {
            guard method == "sendVideo", !video.data.isEmpty, video.data.count <= 20 * 1024 * 1024 else {
                throw BotError.invalidResponse
            }
            upload = video
            fields.removeValue(forKey: "video")
        } else if var media = parameters["media"] as? [String: Any],
                  let video = media["media"] as? VideoUpload {
            guard method == "editMessageMedia", media["type"] as? String == "video",
                  video.data.count >= 12, video.data.count <= 20 * 1024 * 1024,
                  video.data.dropFirst(4).prefix(4) == Data("ftyp".utf8) else {
                throw BotError.invalidResponse
            }
            let boxLength = video.data.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard boxLength >= 12, boxLength <= UInt64(video.data.count) else {
                throw BotError.invalidResponse
            }
            upload = video
            media["media"] = "attach://video"
            fields["media"] = media
        } else {
            upload = nil
        }
        // Reject uploads anywhere except the two supported locations before URLSession sees them.
        guard JSONSerialization.isValidJSONObject(fields) else {
            print("Telegram \(Self.diagnosticMethod(method)) rejected locally: invalid JSON fields.")
            throw BotError.invalidResponse
        }
        if let video = upload {
            let boundary = "fxclip-\(UUID().uuidString)"
            var body = Data()
            for key in fields.keys.sorted() {
                guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else {
                    throw BotError.invalidResponse
                }
                let value = fields[key]!
                let bytes: Data
                if let string = value as? String { bytes = Data(string.utf8) }
                else { bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) }
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
                body.append(bytes)
                body.append(Data("\r\n".utf8))
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"video\"; filename=\"reel.mp4\"\r\nContent-Type: video/mp4\r\n\r\n".utf8))
            body.append(video.data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        }
        for attempt in 0..<2 {
            let data: Data
            do { (data, _) = try await session.data(for: request) }
            catch {
                let category = (error as? URLError).map { "url_\($0.code.rawValue)" } ?? "transport"
                print("Telegram \(Self.diagnosticMethod(method)) failed: \(category).")
                throw error
            }
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BotError.invalidResponse
            }
            if body["ok"] as? Bool == true {
                if diagnostics, ["sendMessage", "sendPhoto", "sendVideo", "editMessageText", "editMessageMedia"].contains(method) {
                    print("Telegram \(Self.diagnosticMethod(method)) accepted.")
                }
                return body["result"] ?? NSNull()
            }
            let code = body["error_code"] as? Int ?? 0
            let retryAfter = (body["parameters"] as? [String: Any])?["retry_after"] as? Int
            print(Self.failureSummary(method: method, code: code, description: body["description"] as? String, retryAfter: retryAfter))
            if code == 429, attempt == 0,
               let delay = retryAfter, (1...60).contains(delay) {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                continue
            }
            throw BotError.telegram(code)
        }
        throw BotError.invalidResponse
    }
}

func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

public func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
}

func confirmedMessageID(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          let id = Int64(number.stringValue), id > 0 else { return nil }
    return id
}
