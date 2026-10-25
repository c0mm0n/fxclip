import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FxTelegram

final class YouTubePreviewTests: XCTestCase {
    private let videoID = "aB3_dE-fG09"

    override func setUp() {
        super.setUp()
        YouTubeURLProtocol.reset()
    }

    func testRecognizesOnlySupportedYouTubeRoutes() {
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com", "WWW.YouTube.COM"] {
            for scheme in ["http", "https", "HTTPS"] {
                for path in ["/watch?v=\(videoID)", "/shorts/\(videoID)", "/live/\(videoID)"] {
                    let url = "\(scheme)://\(host)\(path)"
                    XCTAssertEqual(YouTubePreview.videoID(in: url), videoID, url)
                }
            }
        }
        for host in ["youtu.be", "www.youtu.be"] {
            XCTAssertEqual(YouTubePreview.videoID(in: "https://\(host)/\(videoID)?si=tracking&t=4#fragment"), videoID)
        }
        for url in [
            "https://youtube.com/watch?feature=share&v=\(videoID)&t=30#chapter",
            "https://youtube.com:443/watch?v=\(videoID)",
            "http://youtu.be:80/\(videoID)",
        ] {
            XCTAssertEqual(YouTubePreview.videoID(in: url), videoID, url)
        }
    }

    func testRejectsMissingAmbiguousAndUnsupportedRoutes() {
        for url in [
            "https://youtube.com", "https://youtube.com/watch", "https://youtube.com/watch?v",
            "https://youtube.com/watch?v=", "https://youtube.com/watch?V=\(videoID)",
            "https://youtube.com/watch?v=\(videoID)&v=\(videoID)",
            "https://youtube.com/watch?v=\(videoID)&%76=\(videoID)",
            "https://youtube.com/watch?v=\(videoID)&v=",
            "https://youtube.com/watch/?v=\(videoID)", "https://youtube.com/\(videoID)",
            "https://youtube.com/embed/\(videoID)", "https://youtube.com/shorts/\(videoID)/",
            "https://youtube.com/live/\(videoID)/extra", "https://youtube.com//shorts/\(videoID)",
            "https://youtu.be/", "https://youtu.be/\(videoID)/", "https://youtu.be/\(videoID)/extra",
            "https://youtu.be/watch?v=\(videoID)", "https://youtu.be/shorts/\(videoID)",
            "https://youtube.com/SHORTS/\(videoID)", "https://youtu.be/%61B3_dE-fG09",
        ] {
            XCTAssertNil(YouTubePreview.videoID(in: url), url)
        }
    }

    func testRejectsLookalikeHostsCredentialsSchemesAndOddPorts() {
        for host in ["music.youtube.com", "youtube.com.evil.example", "notyoutube.com", "youtu.be.evil.example",
                     "youtube.com.", "www2.youtube.com", "%79outube.com", "yоutube.com"] {
            XCTAssertNil(YouTubePreview.videoID(in: "https://\(host)/watch?v=\(videoID)"), host)
        }
        for url in [
            "ftp://youtube.com/watch?v=\(videoID)", "//youtube.com/watch?v=\(videoID)",
            "youtube.com/watch?v=\(videoID)", "https://user@youtube.com/watch?v=\(videoID)",
            "https://user:password@youtube.com/watch?v=\(videoID)", "https://@youtu.be/\(videoID)",
            "https://youtube.com@evil.example/watch?v=\(videoID)",
            "https://youtube.com:80/watch?v=\(videoID)", "http://youtube.com:443/watch?v=\(videoID)",
            "https://youtu.be:8443/\(videoID)", "https://youtu.be:invalid/\(videoID)",
            "https://youtu.be:/\(videoID)",
            "https://youtu.be/\(videoID)\n", " https://youtu.be/\(videoID)",
        ] {
            XCTAssertNil(YouTubePreview.videoID(in: url), url)
        }
    }

    func testVideoIDsMustBeExactlyElevenASCIICharacters() {
        for id in ["", "1234567890", "123456789012", "1234567890é", "1234567890😀", "1234567890.",
                   "1234567890+", "1234567890/", "1234567890 "] {
            XCTAssertNil(YouTubePreview.videoID(in: "https://youtu.be/\(id)"), id)
            XCTAssertNil(YouTubePreview.videoID(in: "https://youtube.com/watch?v=\(id)"), id)
        }
        for id in ["01234567890", "abcdefghijk", "ABCDEFGHIJK", "_-_-_-_-_-_"] {
            XCTAssertEqual(YouTubePreview.videoID(in: "https://youtu.be/\(id)"), id)
        }
    }

    func testFetchUsesOnlyFixedOEmbedEndpointAndCanonicalWatchURL() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        YouTubeURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "www.youtube.com")
            XCTAssertEqual(components.path, "/oembed")
            XCTAssertNil(components.user)
            XCTAssertNil(components.port)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(components.queryItems, [
                URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=aB3_dE-fG09"),
                URLQueryItem(name: "format", value: "json"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.timeoutInterval, 4)
            return try self.response(request, title: "Une vidéo 😀 & <test>", contentType: "application/json; charset=utf-8")
        }
        let provider: YouTubeMetadataProviding = YouTubeMetadataFetcher(session: session, nativePreviews: false)
        let result = try await provider.fetch(videoID: videoID)
        XCTAssertEqual(result.title, "Une vidéo 😀 & <test>")
        XCTAssertEqual(result.thumbnailURL.absoluteString, "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        XCTAssertEqual(YouTubeURLProtocol.requests.count, 1)
    }

    func testFetchAcceptsAllowedThumbnailHostsAndUTF16TitleBoundary() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let fetcher = YouTubeMetadataFetcher(session: session, nativePreviews: false)
        for thumbnail in ["https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
                          "https://img.youtube.com/vi/\(videoID)/0.jpg",
                          "https://i.ytimg.com/vi_webp/\(videoID)/hqdefault.webp"] {
            let title = String(repeating: "😀", count: 256)
            YouTubeURLProtocol.handler = { try self.response($0, title: title, thumbnail: thumbnail) }
            let result = try await fetcher.fetch(videoID: videoID)
            XCTAssertEqual(result.title, title)
            XCTAssertEqual(result.thumbnailURL.absoluteString, thumbnail)
        }
    }

    func testInvalidVideoIDsNeverIssueARequest() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        YouTubeURLProtocol.handler = { _ in
            XCTFail("Invalid input must not reach URLSession")
            throw URLError(.badURL)
        }
        let fetcher = YouTubeMetadataFetcher(session: session, nativePreviews: false)
        for id in ["", "1234567890", "123456789012", "https://evil.example/", "../oembed?v=x", "aB3_dE-fG09&url=x",
                   "1234567890é", "1234567890/", "1234567890\n"] {
            do {
                _ = try await fetcher.fetch(videoID: id)
                XCTFail("Expected invalid ID: \(id)")
            } catch YouTubeMetadataError.invalidVideoID {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(YouTubeURLProtocol.requests.isEmpty)
    }

    func testFetchRejectsHTTPFailuresRedirectsAndNonJSONContent() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for (status, type) in [(201, "application/json"), (302, "application/json"), (404, "application/json"),
                               (500, "application/json"), (200, "text/html"), (200, "text/plain"), (200, "")] {
            YouTubeURLProtocol.handler = { try self.response($0, status: status, contentType: type) }
            await assertInvalidResponse(YouTubeMetadataFetcher(session: session, nativePreviews: false))
        }
        XCTAssertEqual(YouTubeURLProtocol.requests.count, 7)
        XCTAssertTrue(YouTubeURLProtocol.requests.allSatisfy { $0.url?.host == "www.youtube.com" })
    }

    func testFetchRejectsMalformedJSONMissingFieldsAndInvalidTitles() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let thumbnail = "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
        let invalidBodies: [Data] = try [
            ["thumbnail_url": thumbnail], ["title": "Title"], ["title": 42, "thumbnail_url": thumbnail],
            ["title": "Title", "thumbnail_url": NSNull()], ["title": "", "thumbnail_url": thumbnail],
            ["title": " \n\t", "thumbnail_url": thumbnail],
            ["title": String(repeating: "a", count: 513), "thumbnail_url": thumbnail],
            ["title": String(repeating: "😀", count: 257), "thumbnail_url": thumbnail],
        ].map { try JSONSerialization.data(withJSONObject: $0) } + [Data("not JSON".utf8), Data("[]".utf8)]
        for body in invalidBodies {
            YouTubeURLProtocol.handler = { request in
                let (response, _) = try self.response(request)
                return (response, body)
            }
            await assertInvalidResponse(YouTubeMetadataFetcher(session: session, nativePreviews: false))
        }
    }

    func testFetchRejectsUnsafeOrMismatchedThumbnailURLs() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for thumbnail in [
            "http://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
            "https://evil.example/vi/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com.evil.example/vi/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com./vi/\(videoID)/hqdefault.jpg",
            "https://%69.ytimg.com/vi/\(videoID)/hqdefault.jpg",
            "https://user@i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com:443/vi/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com:8443/vi/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com:/vi/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com/vi/DIFFERENT_1/hqdefault.jpg",
            "https://i.ytimg.com/other/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/", "https://i.ytimg.com/vi/\(videoID)/..",
            "https://i.ytimg.com/vi/\(videoID)/%2e%2e",
            "https://i.ytimg.com/vi/\(videoID)/nested/hqdefault.jpg",
            "https://i.ytimg.com/vi/%61B3_dE-fG09/hqdefault.jpg", "not a URL",
        ] {
            YouTubeURLProtocol.handler = { try self.response($0, thumbnail: thumbnail) }
            await assertInvalidResponse(YouTubeMetadataFetcher(session: session, nativePreviews: false), message: thumbnail)
        }
    }

    func testTransportFailureIsThrownWithoutRetry() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        YouTubeURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await YouTubeMetadataFetcher(session: session, nativePreviews: false).fetch(videoID: videoID)
            XCTFail("Expected transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(YouTubeURLProtocol.requests.count, 1)
    }

    func testLetterboxedOEmbedThumbnailPrefersAvailableWideHDImage() async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        YouTubeURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                XCTAssertEqual(request.url?.absoluteString, "https://i.ytimg.com/vi/\(self.videoID)/maxresdefault.jpg")
                XCTAssertEqual(request.timeoutInterval, 2)
                XCTAssertFalse(request.httpShouldHandleCookies)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/jpeg")
                return (try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "image/jpeg", "Content-Length": "12345"])), Data())
            }
            return try self.sizedResponse(request)
        }
        let metadata = try await YouTubeMetadataFetcher(session: session, nativePreviews: false).fetch(videoID: videoID)
        XCTAssertTrue(metadata.thumbnailURL.absoluteString.hasSuffix("/maxresdefault.jpg"))
        XCTAssertTrue(metadata.fallbackThumbnailURL?.absoluteString.hasSuffix("/hqdefault.jpg") == true)
        XCTAssertEqual(YouTubeURLProtocol.requests.map(\.httpMethod), ["GET", "HEAD"])
    }

    func testUnavailableOrInvalidWideThumbnailKeepsVerifiedOEmbedURL() async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        for (status, mime, length) in [(404, "image/jpeg", "100"), (302, "image/jpeg", "100"),
                                       (200, "text/html", "100"), (200, "image/jpeg", "0")] {
            YouTubeURLProtocol.handler = { request in
                if request.httpMethod != "HEAD" { return try self.sizedResponse(request) }
                return (try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": mime, "Content-Length": length,
                        "Location": "https://example.invalid/untrusted"])), Data())
            }
            let metadata = try await YouTubeMetadataFetcher(session: session, nativePreviews: false).fetch(videoID: videoID)
            XCTAssertTrue(metadata.thumbnailURL.absoluteString.hasSuffix("/hqdefault.jpg"))
        }
        XCTAssertTrue(YouTubeURLProtocol.requests.allSatisfy { ["www.youtube.com", "i.ytimg.com"].contains($0.url?.host) })
    }

    func testWideProbeTimeoutFallsBackButCancellationPropagates() async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        for code in [URLError.timedOut, .cancelled] {
            YouTubeURLProtocol.handler = { request in
                if request.httpMethod == "HEAD" { throw URLError(code) }
                return try self.sizedResponse(request)
            }
            do {
                let metadata = try await YouTubeMetadataFetcher(session: session, nativePreviews: false).fetch(videoID: videoID)
                XCTAssertEqual(code, .timedOut)
                XCTAssertTrue(metadata.thumbnailURL.absoluteString.hasSuffix("/hqdefault.jpg"))
            } catch let error as URLError {
                XCTAssertEqual(code, .cancelled)
                XCTAssertEqual(error.code, .cancelled)
            }
        }
    }

    func testExistingWideHDMetadataSkipsAvailabilityProbe() async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        YouTubeURLProtocol.handler = { try self.sizedResponse($0, width: 1280, height: 720, file: "maxresdefault.jpg") }
        let metadata = try await YouTubeMetadataFetcher(session: session, nativePreviews: false).fetch(videoID: videoID)
        XCTAssertTrue(metadata.thumbnailURL.absoluteString.hasSuffix("/maxresdefault.jpg"))
        XCTAssertEqual(YouTubeURLProtocol.requests.count, 1)
    }

    private func sizedResponse(_ request: URLRequest, width: Int = 480, height: Int = 360,
                               file: String = "hqdefault.jpg") throws -> (URLResponse, Data) {
        let body: [String: Any] = ["title": "Example video", "thumbnail_url": "https://i.ytimg.com/vi/\(videoID)/\(file)",
                                   "thumbnail_width": width, "thumbnail_height": height]
        return (try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])), try JSONSerialization.data(withJSONObject: body))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [YouTubeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(_ request: URLRequest, title: String = "Video title", thumbnail: String? = nil,
                          status: Int = 200, contentType: String = "application/json") throws -> (URLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                                                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType]))
        let data = try JSONSerialization.data(withJSONObject: [
            "title": title, "thumbnail_url": thumbnail ?? "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
        ])
        return (response, data)
    }

    private func assertInvalidResponse(_ fetcher: YouTubeMetadataFetcher, message: String = "",
                                       file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await fetcher.fetch(videoID: videoID)
            XCTFail("Expected invalid response: \(message)", file: file, line: line)
        } catch YouTubeMetadataError.invalidResponse {} catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class YouTubeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []
    static var handler: ((URLRequest) throws -> (URLResponse, Data))?
    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests = []
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
