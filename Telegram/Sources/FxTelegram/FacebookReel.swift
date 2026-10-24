import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol FacebookReelProviding {
    func fetch(reelID: String) async throws -> FacebookReel
}

public struct FacebookReel {
    public let author: String
    public let caption: String
    public let video: Data

    public init(author: String, caption: String, video: Data) {
        self.author = author
        self.caption = caption
        self.video = video
    }
}

public enum FacebookReelPreview {
    public static func reelID(in url: String) -> String? {
        guard let parts = strictURL(url),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.percentEncodedHost?.lowercased(),
              ["facebook.com", "www.facebook.com", "m.facebook.com", "facebed.com", "www.facebed.com"].contains(host),
              parts.port == nil || parts.port == (scheme == "https" ? 443 : 80) else { return nil }
        let authority = host + (parts.port.map { ":\($0)" } ?? "")
        guard url.lowercased().hasPrefix("\(scheme)://\(authority)/") else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard (path.count == 3 || (path.count == 4 && path[3].isEmpty)),
              path[0].isEmpty, path[1] == "reel", validID(String(path[2])) else { return nil }
        return String(path[2])
    }

    fileprivate static func validID(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) }
    }
}

public enum FacebookReelError: Error {
    case invalidReelID
    case invalidResponse
    case responseTooLarge
}

public final class FacebookReelFetcher: FacebookReelProviding {
    private let configuration: URLSessionConfiguration

    /// Only protocol classes are inherited, to allow offline URLProtocol fixtures.
    /// Transport privacy settings and timeouts cannot be overridden by the caller.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let safe = URLSessionConfiguration.ephemeral
        safe.protocolClasses = configuration.protocolClasses
        safe.timeoutIntervalForRequest = 6
        safe.timeoutIntervalForResource = 20
        safe.urlCache = nil
        safe.requestCachePolicy = .reloadIgnoringLocalCacheData
        safe.httpShouldSetCookies = false
        safe.httpCookieStorage = nil
        safe.urlCredentialStorage = nil
        self.configuration = safe
    }

    public func fetch(reelID: String) async throws -> FacebookReel {
        guard FacebookReelPreview.validID(reelID) else { throw FacebookReelError.invalidReelID }
        try Task.checkCancellation()
        let page = try await load(URL(string: "https://facebed.com/reel/\(reelID)")!,
                                  mime: "text/html", limit: 512 * 1024)
        guard let html = String(data: page, encoding: .utf8) else { throw FacebookReelError.invalidResponse }
        let metadata = try ReelHTML.metadata(html)
        guard let author = metadata["og:title"], !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let caption = metadata["og:description"], let source = metadata["og:video"],
              let videoURL = Self.videoURL(source) else { throw FacebookReelError.invalidResponse }
        try Task.checkCancellation()
        let video = try await load(videoURL, mime: "video/mp4", limit: 20 * 1024 * 1024)
        // ISO BMFF starts with a box length followed by its four-byte type and brand.
        guard video.count >= 12, Array(video[4..<8]) == Array("ftyp".utf8) else {
            throw FacebookReelError.invalidResponse
        }
        let boxLength = video.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard boxLength >= 12, boxLength <= video.count else { throw FacebookReelError.invalidResponse }
        try Task.checkCancellation()
        return FacebookReel(author: author, caption: caption, video: video)
    }

    private func load(_ url: URL, mime: String, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpShouldHandleCookies = false
        request.setValue("TelegramBot", forHTTPHeaderField: "User-Agent")
        request.setValue(mime, forHTTPHeaderField: "Accept")
        return try await ReelDataLoader(configuration: configuration, request: request, mime: mime, limit: limit).load()
    }

    private static func videoURL(_ value: String) -> URL? {
        guard let parts = strictURL(value), parts.scheme == "https", parts.port == nil,
              parts.fragment == nil, let host = parts.percentEncodedHost,
              host.hasSuffix(".fbcdn.net"), value.hasPrefix("https://\(host)/") else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        let path = parts.percentEncodedPath
        guard path.hasPrefix("/"), path.count > 5, path.hasSuffix(".mp4"),
              !path.contains("%"), !path.contains("\\"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return parts.url
    }
}

private func strictURL(_ value: String) -> URLComponents? {
    guard !value.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
    }), !value.contains("\\"), let parts = URLComponents(string: value), parts.url != nil,
          parts.user == nil, parts.password == nil else { return nil }
    return parts
}

/// One bounded request. A delegate counts every delivered chunk, including when
/// Content-Length is missing or understates the body. No download file is created.
private final class ReelDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let request: URLRequest
    private let mime: String
    private let limit: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var cancelled = false
    private var finished = false

    init(configuration: URLSessionConfiguration, request: URLRequest, mime: String, limit: Int) {
        self.configuration = configuration
        self.request = request
        self.mime = mime
        self.limit = limit
    }

    func load() async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                task = session.dataTask(with: request)
                task?.resume()
                lock.unlock()
            }
        }, onCancel: {
            self.lock.lock()
            self.cancelled = true
            self.lock.unlock()
            self.finish(.failure(CancellationError()))
        })
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        data = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", omittingEmptySubsequences: false)
                .first?.trimmingCharacters(in: .whitespaces).lowercased() == mime else {
            completionHandler(.cancel)
            finish(.failure(FacebookReelError.invalidResponse))
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel)
            finish(.failure(FacebookReelError.responseTooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard chunk.count <= limit - data.count else {
            lock.unlock()
            finish(.failure(FacebookReelError.responseTooLarge))
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result: Result<Data, Error> = error.map { .failure($0) } ?? .success(data)
        lock.unlock()
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(FacebookReelError.invalidResponse))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Ordinary TLS trust uses the system verifier; HTTP authentication is never attempted.
        completionHandler(challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust"
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

/// A small, strict tokenizer for quoted/unquoted HTML attributes. It never
/// interprets markup decoded from an attribute, nor metadata inside raw text.
private enum ReelHTML {
    static func metadata(_ html: String) throws -> [String: String] {
        let bytes = Array(html.utf8)
        let lower = bytes.map { asciiLower($0) }
        var index = 0
        var result: [String: String] = [:]
        while index < bytes.count {
            guard bytes[index] == 60 else { index += 1; continue }
            if matches(bytes, index, "<!--") {
                guard let end = find(bytes, from: index + 4, text: "-->") else { throw FacebookReelError.invalidResponse }
                index = end + 3
                continue
            }
            index += 1
            let nameStart = index
            while index < bytes.count, isName(bytes[index]) { index += 1 }
            let tag = String(decoding: lower[nameStart..<index], as: UTF8.self)
            if tag.isEmpty { continue }
            guard index < bytes.count, whitespace(bytes[index]) || bytes[index] == 47 || bytes[index] == 62 else {
                throw FacebookReelError.invalidResponse
            }
            let attributes = try attributes(bytes, index: &index, capture: tag == "meta")
            if tag == "meta" {
                let property = try attributes["property"].map(decode)
                let name = try attributes["name"].map(decode)
                let keys = [property, name].compactMap { $0 }
                let relevant = keys.filter { ["og:title", "og:description", "og:video"].contains($0) }
                if let key = relevant.first {
                    guard keys.allSatisfy({ $0 == key }), result[key] == nil,
                          let raw = attributes["content"] else { throw FacebookReelError.invalidResponse }
                    result[key] = try decode(raw)
                }
            } else if ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"].contains(tag) {
                // Skip until the actual end tag name, not a prefix such as </scripted>.
                var search = index
                var closing: Int?
                while let found = find(lower, from: search, text: "</\(tag)") {
                    let after = found + tag.utf8.count + 2
                    if after < bytes.count, whitespace(bytes[after]) || bytes[after] == 62 || bytes[after] == 47 {
                        closing = after
                        break
                    }
                    search = after
                }
                guard var end = closing else { throw FacebookReelError.invalidResponse }
                _ = try Self.attributes(bytes, index: &end, capture: false)
                index = end
            } else if tag == "plaintext" { break }
        }
        return result
    }

    private static func attributes(_ bytes: [UInt8], index: inout Int, capture: Bool) throws -> [String: String] {
        var result: [String: String] = [:]
        while index < bytes.count {
            while index < bytes.count, whitespace(bytes[index]) { index += 1 }
            guard index < bytes.count else { break }
            if bytes[index] == 62 { index += 1; return result }
            if bytes[index] == 47, index + 1 < bytes.count, bytes[index + 1] == 62 { index += 2; return result }
            let start = index
            while index < bytes.count, !whitespace(bytes[index]), ![47, 62, 61].contains(bytes[index]) {
                guard ![0, 34, 39, 60, 96].contains(bytes[index]) else { throw FacebookReelError.invalidResponse }
                index += 1
            }
            guard index > start else { throw FacebookReelError.invalidResponse }
            let name = String(decoding: bytes[start..<index].map(asciiLower), as: UTF8.self)
            while index < bytes.count, whitespace(bytes[index]) { index += 1 }
            var value = ""
            if index < bytes.count, bytes[index] == 61 {
                index += 1
                while index < bytes.count, whitespace(bytes[index]) { index += 1 }
                guard index < bytes.count else { throw FacebookReelError.invalidResponse }
                let quote = bytes[index]
                if quote == 34 || quote == 39 {
                    index += 1
                    let start = index
                    while index < bytes.count, bytes[index] != quote {
                        guard bytes[index] != 0, bytes[index] != 60 else { throw FacebookReelError.invalidResponse }
                        index += 1
                    }
                    guard index < bytes.count else { throw FacebookReelError.invalidResponse }
                    value = String(decoding: bytes[start..<index], as: UTF8.self)
                    index += 1
                    guard index < bytes.count, whitespace(bytes[index]) || bytes[index] == 47 || bytes[index] == 62 else {
                        throw FacebookReelError.invalidResponse
                    }
                } else {
                    let start = index
                    while index < bytes.count, !whitespace(bytes[index]), bytes[index] != 62 {
                        guard ![0, 34, 39, 60, 61, 96].contains(bytes[index]) else { throw FacebookReelError.invalidResponse }
                        index += 1
                    }
                    guard index > start else { throw FacebookReelError.invalidResponse }
                    value = String(decoding: bytes[start..<index], as: UTF8.self)
                }
            }
            if capture {
                guard result[name] == nil else { throw FacebookReelError.invalidResponse }
                result[name] = value
            }
        }
        throw FacebookReelError.invalidResponse
    }

    private static func decode(_ value: String) throws -> String {
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] != "&" {
                guard !value[index].unicodeScalars.contains(where: { $0.value == 0 }) else { throw FacebookReelError.invalidResponse }
                output.append(value[index])
                index = value.index(after: index)
                continue
            }
            let start = value.index(after: index)
            // Supported references need at most ten characters before the semicolon.
            let bound = value.index(start, offsetBy: 11, limitedBy: value.endIndex) ?? value.endIndex
            guard let end = value[start..<bound].firstIndex(of: ";") else { throw FacebookReelError.invalidResponse }
            let entity = String(value[start..<end])
            if let replacement = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">" ][entity] {
                output += replacement
            } else {
                guard entity.hasPrefix("#") else { throw FacebookReelError.invalidResponse }
                let hex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                let digits = entity.dropFirst(hex ? 2 : 1)
                guard !digits.isEmpty, digits.utf8.allSatisfy({
                    (48...57).contains($0) || (hex && ((65...70).contains($0) || (97...102).contains($0)))
                }), let number = UInt32(digits, radix: hex ? 16 : 10),
                      number >= 32, !(127...159).contains(number),
                      let scalar = UnicodeScalar(number), !(0xFDD0...0xFDEF).contains(number),
                      number & 0xFFFF != 0xFFFE, number & 0xFFFF != 0xFFFF else { throw FacebookReelError.invalidResponse }
                output.unicodeScalars.append(scalar)
            }
            index = value.index(after: end)
        }
        return output
    }

    private static func whitespace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
    private static func asciiLower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }
    private static func isName(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 58
    }
    private static func matches(_ bytes: [UInt8], _ start: Int, _ text: String) -> Bool {
        let target = Array(text.utf8)
        return start + target.count <= bytes.count && bytes[start..<(start + target.count)].elementsEqual(target)
    }
    private static func find(_ bytes: [UInt8], from start: Int, text: String) -> Int? {
        let target = Array(text.utf8)
        guard start <= bytes.count - target.count else { return nil }
        for index in start...(bytes.count - target.count) {
            if bytes[index] == target[0], bytes[index..<(index + target.count)].elementsEqual(target) { return index }
        }
        return nil
    }
}
