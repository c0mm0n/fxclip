import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol YouTubeMetadataProviding {
    func fetch(videoID: String) async throws -> YouTubeMetadata
}

public struct YouTubeMetadata {
    public let title: String
    public let thumbnailURL: URL
    public let fallbackThumbnailURL: URL?

    public init(title: String, thumbnailURL: URL, fallbackThumbnailURL: URL? = nil) {
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.fallbackThumbnailURL = fallbackThumbnailURL
    }
}

public enum YouTubePreview {
    /// Keep the source in the linked heading and Open button, without repeating
    /// a long URL in the caption. An automatic replacement must retain its credit.
    static func caption(title: String, url: String, credit: RenderedMessage?) -> RenderedMessage? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 512 else { return nil }
        var prefix = ""
        var entities: [Entity] = []
        if let credit {
            guard let source = credit.text.range(of: url, options: [.backwards, .literal]),
                  source.upperBound == credit.text.endIndex else { return nil }
            prefix = String(credit.text[..<source.lowerBound])
            entities = credit.entities.filter {
                $0.offset >= 0 && $0.length > 0 && $0.offset <= prefix.utf16.count
                    && $0.length <= prefix.utf16.count - $0.offset
            }
        }
        let heading = "YouTube\n"
        let text = prefix + heading + title
        guard text.utf16.count <= 1024 else { return nil }
        entities += [Entity(type: "text_link", offset: prefix.utf16.count, length: 7, url: url),
                     Entity(type: "bold", offset: prefix.utf16.count + heading.utf16.count, length: title.utf16.count)]
        return RenderedMessage(text: text, entities: entities, previewURL: url)
    }

    public static func videoID(in url: String) -> String? {
        guard !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let components = URLComponents(string: url), components.url != nil,
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == (scheme == "https" ? 443 : 80),
              let host = components.percentEncodedHost?.lowercased() else { return nil }
        let authority = host + (components.port.map { ":\($0)" } ?? "")
        guard url.lowercased().hasPrefix("\(scheme)://\(authority)/") else { return nil }

        let path = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        let id: String?
        switch host {
        case "youtu.be", "www.youtu.be":
            id = path.count == 2 && path[0].isEmpty ? String(path[1]) : nil
        case "youtube.com", "www.youtube.com", "m.youtube.com":
            if components.percentEncodedPath == "/watch" {
                let values = (components.queryItems ?? []).filter { $0.name == "v" }
                id = values.count == 1 ? values[0].value : nil
            } else if path.count == 3, path[0].isEmpty, ["shorts", "live"].contains(path[1]) {
                id = String(path[2])
            } else { id = nil }
        default:
            return nil
        }
        guard let id, validVideoID(id) else { return nil }
        return id
    }

    fileprivate static func validVideoID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }
}

public enum YouTubeMetadataError: Error {
    case invalidVideoID
    case invalidResponse
}

public final class YouTubeMetadataFetcher: YouTubeMetadataProviding {
    private let session: URLSession
    private let redirects = YouTubeRedirectBlocker()

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func fetch(videoID: String) async throws -> YouTubeMetadata {
        guard YouTubePreview.validVideoID(videoID) else { throw YouTubeMetadataError.invalidVideoID }
        var endpoint = URLComponents(string: "https://www.youtube.com/oembed")!
        endpoint.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: endpoint.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: redirects)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType?.lowercased() == "application/json",
              let body = try? JSONDecoder().decode(Response.self, from: data),
              !body.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.title.utf16.count <= 512,
              let thumbnail = URLComponents(string: body.thumbnail_url),
              thumbnail.scheme?.lowercased() == "https",
              thumbnail.user == nil, thumbnail.password == nil, thumbnail.port == nil,
              let host = thumbnail.percentEncodedHost?.lowercased(),
              ["i.ytimg.com", "img.youtube.com"].contains(host),
              body.thumbnail_url.lowercased().hasPrefix("https://\(host)/"),
              let thumbnailURL = thumbnail.url else { throw YouTubeMetadataError.invalidResponse }
        let path = thumbnail.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 4, path[0].isEmpty, ["vi", "vi_webp"].contains(path[1]),
              path[2] == videoID, !path[3].isEmpty, !path[3].contains("%"), path[3] != ".", path[3] != ".." else {
            throw YouTubeMetadataError.invalidResponse
        }
        var preferred = thumbnailURL
        // oEmbed often supplies a letterboxed 480×360 image. Prefer YouTube's
        // wide high-resolution thumbnail when available, retaining oEmbed on failure.
        if let width = body.thumbnail_width, let height = body.thumbnail_height,
           width > 0, height > 0,
           width < 1280 || abs(Double(width) / Double(height) - 16.0 / 9.0) > 0.02 {
            let candidate = URL(string: "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg")!
            var check = URLRequest(url: candidate, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
            check.httpMethod = "HEAD"
            check.httpShouldHandleCookies = false
            check.setValue("image/jpeg", forHTTPHeaderField: "Accept")
            do {
                let (_, response) = try await session.data(for: check, delegate: redirects)
                if let response = response as? HTTPURLResponse, response.statusCode == 200,
                   response.mimeType?.lowercased() == "image/jpeg", response.expectedContentLength != 0 {
                    preferred = candidate
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if let error = error as? URLError, error.code == .cancelled { throw error }
            }
            try Task.checkCancellation()
        }
        return YouTubeMetadata(title: body.title, thumbnailURL: preferred,
                               fallbackThumbnailURL: preferred == thumbnailURL ? nil : thumbnailURL)
    }

    private struct Response: Decodable {
        let title: String
        let thumbnail_url: String
        let thumbnail_width: Int?
        let thumbnail_height: Int?
    }
}

private final class YouTubeRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
