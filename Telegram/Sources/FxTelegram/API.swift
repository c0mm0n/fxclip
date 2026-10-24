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

public final class TelegramAPI: BotAPI {
    private let token: String
    private let session: URLSession
    public init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 50
        session = URLSession(configuration: config)
    }

    public func call(_ method: String, _ parameters: [String: Any] = [:]) async throws -> Any {
        // Do not print URLSession errors: Telegram puts the credential in the request URL.
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
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
