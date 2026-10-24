import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol RedditVideoProviding {
    func fetch(postID: String) async throws -> Data
}

public enum RedditVideoPreview {
    /// Extracts a route from the engine-cleaned link; never resolves or cleans a URL.
    public static func postID(in source: String) -> String? {
        guard let parts = redditStrictURL(source),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.percentEncodedHost?.lowercased(),
              ["reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com",
               "vxreddit.com", "www.vxreddit.com"].contains(host),
              parts.port == nil || parts.port == (scheme == "https" ? 443 : 80) else { return nil }
        let authority = "\(scheme)://\(host)" + (parts.port.map { ":\($0)" } ?? "")
        guard source.lowercased().hasPrefix(authority + "/") else { return nil }

        var segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first == "" else { return nil }
        segments.removeFirst()
        if segments.last == "" { segments.removeLast() }
        guard !segments.contains(where: { $0.isEmpty }) else { return nil }
        let id: String
        if (segments.count == 4 || segments.count == 5), segments[0] == "r", segments[2] == "comments",
           !segments[1].isEmpty, segments[1].utf8.allSatisfy({
               (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
           }), segments.count == 4 || safeSlug(String(segments[4])) {
            id = String(segments[3])
        } else if segments.count == 2, segments[0] == "comments" {
            id = String(segments[1])
        } else if segments.count == 1, ["vxreddit.com", "www.vxreddit.com"].contains(host) {
            id = String(segments[0])
        } else {
            return nil
        }
        return validID(id) ? id : nil
    }

    fileprivate static func validID(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count) && id.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0)
        }
    }

    private static func safeSlug(_ slug: String) -> Bool {
        var value = slug
        while true {
            guard !value.isEmpty, value != ".", value != "..", !value.contains("/") else { return false }
            guard let decoded = value.removingPercentEncoding else { return false }
            if decoded == value { return true }
            value = decoded
        }
    }
}

public enum RedditVideoError: Error {
    case invalidPostID
    case invalidOrigin
    case invalidResponse
    case videoTooLarge
}

public final class RedditVideoFetcher: RedditVideoProviding {
    private let configuration: URLSessionConfiguration
    private let origin: URLComponents?

    /// The operator controls this fixed origin; a submitted link supplies only an ID.
    /// Only URLProtocol fixtures are inherited from the caller's configuration.
    public init(configuration: URLSessionConfiguration = .ephemeral,
                origin: URL = URL(string: "http://reddit-resolver:9813")!) {
        self.origin = Self.validatedOrigin(origin)
        let safe = URLSessionConfiguration.ephemeral
        safe.protocolClasses = configuration.protocolClasses
        safe.timeoutIntervalForRequest = 50
        safe.timeoutIntervalForResource = 60
        safe.urlCache = nil
        safe.requestCachePolicy = .reloadIgnoringLocalCacheData
        safe.httpShouldSetCookies = false
        safe.httpCookieStorage = nil
        safe.urlCredentialStorage = nil
        safe.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                          "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        self.configuration = safe
    }

    public func fetch(postID: String) async throws -> Data {
        try Task.checkCancellation()
        guard RedditVideoPreview.validID(postID) else { throw RedditVideoError.invalidPostID }
        guard var endpoint = origin else { throw RedditVideoError.invalidOrigin }
        endpoint.path = "/video/\(postID).mp4"
        guard let url = endpoint.url else { throw RedditVideoError.invalidOrigin }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 50)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("video/mp4", forHTTPHeaderField: "Accept")
        request.setValue("TelegramBot", forHTTPHeaderField: "User-Agent")
        let video = try await RedditVideoLoader(configuration: configuration, request: request).load()
        try Task.checkCancellation()
        // An ordinary ISO BMFF ftyp box must fit entirely in the returned body.
        guard video.count >= 12, video[4..<8].elementsEqual("ftyp".utf8) else {
            throw RedditVideoError.invalidResponse
        }
        let length = video.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length >= 12, length <= UInt64(video.count) else { throw RedditVideoError.invalidResponse }
        return video
    }

    private static func validatedOrigin(_ origin: URL) -> URLComponents? {
        guard let parts = redditStrictURL(origin.absoluteString),
              let scheme = parts.scheme, ["http", "https"].contains(scheme),
              let host = parts.percentEncodedHost, !host.isEmpty,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }), !["reddit.com", "vxreddit.com", "redd.it"].contains(where: {
            host == $0 || host.hasSuffix("." + $0)
        }) else { return nil }
        if scheme == "http" {
            guard (host == "reddit-resolver" && parts.port == 9813) ||
                    ["localhost", "127.0.0.1"].contains(host) else { return nil }
        }
        let authority = "\(scheme)://\(host)" + (parts.port.map { ":\($0)" } ?? "")
        guard origin.absoluteString == authority || origin.absoluteString == authority + "/" else { return nil }
        return parts
    }
}

/// Reject parser repairs and hidden controls before extracting any route or origin.
private func redditStrictURL(_ value: String) -> URLComponents? {
    guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
        return nil
    }
    var decoded = value
    while true {
        guard !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        // Decode valid escapes even beside a literal percent, including nested escapes.
        let bytes = Array(decoded.utf8)
        var next: [UInt8] = []
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count,
               let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                next.append(high * 16 + low)
                index += 3
            } else {
                next.append(bytes[index])
                index += 1
            }
        }
        guard let nextValue = String(bytes: next, encoding: .utf8) else { return nil }
        if nextValue == decoded { break }
        decoded = nextValue
    }
    guard let parts = URLComponents(string: value), parts.url != nil,
          parts.user == nil, parts.password == nil else { return nil }
    return parts
}

/// One bounded request, with no redirect, download file, authentication or retry.
private final class RedditVideoLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let request: URLRequest
    private let limit = 20 * 1024 * 1024
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var data = Data()
    private var cancelled = false
    private var finished = false

    init(configuration: URLSessionConfiguration, request: URLRequest) {
        self.configuration = configuration
        self.request = request
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
                session.dataTask(with: request).resume()
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
        data = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let failure: RedditVideoError?
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 413 {
                failure = .videoTooLarge
            } else if http.statusCode != 200 ||
                        http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", omittingEmptySubsequences: false)
                        .first?.trimmingCharacters(in: .whitespaces).lowercased() != "video/mp4" {
                failure = .invalidResponse
            } else if response.expectedContentLength > Int64(limit) {
                failure = .videoTooLarge
            } else {
                failure = nil
            }
        } else {
            failure = .invalidResponse
        }
        if let failure {
            finish(.failure(failure))
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard chunk.count <= limit - data.count else {
            lock.unlock()
            finish(.failure(RedditVideoError.videoTooLarge))
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
        finish(.failure(RedditVideoError.invalidResponse))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust"
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
