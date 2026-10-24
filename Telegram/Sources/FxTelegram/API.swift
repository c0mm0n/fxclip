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
    public init(token: String, session: URLSession? = nil) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 50
        self.session = session ?? URLSession(configuration: config)
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
        guard JSONSerialization.isValidJSONObject(fields) else { throw BotError.invalidResponse }
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
            let (data, _) = try await session.data(for: request)
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BotError.invalidResponse
            }
            if body["ok"] as? Bool == true { return body["result"] ?? NSNull() }
            let code = body["error_code"] as? Int ?? 0
            if code == 429, attempt == 0,
               let parameters = body["parameters"] as? [String: Any],
               let delay = parameters["retry_after"] as? Int, (1...60).contains(delay) {
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
