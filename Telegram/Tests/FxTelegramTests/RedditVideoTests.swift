import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FxTelegram

final class RedditVideoTests: XCTestCase {
    private let id = "fixture123"
    private let mp4 = Data([0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0])

    override func setUp() {
        super.setUp()
        RedditURLProtocol.reset()
    }

    func testRecognizesExactPostRoutesWithoutCleaningTheURL() {
        for host in ["reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com",
                     "vxreddit.com", "www.vxreddit.com", "WWW.REDDIT.COM"] {
            for scheme in ["http", "https", "HTTPS"] {
                for path in ["/r/example/comments/\(id)", "/r/Example_Sub/comments/\(id)/example_slug",
                             "/comments/\(id)"] {
                    for suffix in ["", "/", "?utm_source=fixture&title=some%20text", "/?context=3#fragment"] {
                        let source = "\(scheme)://\(host)\(path)\(suffix)"
                        XCTAssertEqual(RedditVideoPreview.postID(in: source), id, source)
                    }
                }
            }
        }
        for host in ["vxreddit.com", "www.vxreddit.com"] {
            for suffix in ["", "/", "?fixture=1", "/#fragment"] {
                XCTAssertEqual(RedditVideoPreview.postID(in: "https://\(host)/\(id)\(suffix)"), id)
            }
        }
        XCTAssertEqual(RedditVideoPreview.postID(in: "https://reddit.com:443/comments/a"), "a")
        XCTAssertEqual(RedditVideoPreview.postID(in: "http://vxreddit.com:80/0"), "0")
        let longest = String(repeating: "a", count: 32)
        XCTAssertEqual(RedditVideoPreview.postID(in: "https://reddit.com/comments/\(longest)"), longest)
    }

    func testRejectsAmbiguousAndUnsupportedAuthorities() {
        for authority in [
            "redd.it", "v.redd.it", "np.reddit.com", "preview.redd.it", "m.vxreddit.com", "old.vxreddit.com",
            "reddit.com.evil.example", "evilreddit.com", "vxreddit.com.evil.example", "reddit.com.",
            "%72eddit.com", "rеddit.com", "reddit.com:80", "reddit.com:8443", "reddit.com:",
            "reddit.com:0443", "reddit.com:+443", "reddit.com:0", "reddit.com:65536",
            "user@reddit.com", "user:pass@reddit.com", "@reddit.com", "reddit.com@evil.example",
        ] {
            let source = "https://\(authority)/comments/\(id)"
            XCTAssertNil(RedditVideoPreview.postID(in: source), source)
        }
        for source in ["http://reddit.com:443/comments/\(id)", "//reddit.com/comments/\(id)",
                       "reddit.com/comments/\(id)", "ftp://reddit.com/comments/\(id)",
                       "https:////reddit.com/comments/\(id)", "https://reddit.com\\@evil.example/comments/\(id)"] {
            XCTAssertNil(RedditVideoPreview.postID(in: source), source)
        }
    }

    func testRejectsShareTokensCommentRoutesAndEncodedPathTricks() {
        for path in [
            "", "/", "/\(id)", "/comments", "/comments/", "/comments/\(id)/slug",
            "/comments/\(id)/slug/comment1", "/r/example/comments/\(id)/slug/comment1",
            "/r/example/comments/\(id)/slug//", "/r/example/comments/\(id)//",
            "/r//comments/\(id)", "/r/example/COMMENTS/\(id)", "/R/example/comments/\(id)",
            "/r/example/s/fixturetoken", "/s/fixturetoken", "/share/fixturetoken",
            "/r/example/comments/\(id)/slug/extra", "/r/../comments/\(id)/slug",
            "/r/a%2fb/comments/\(id)", "/r/example/comments/%66ixture123/slug",
            "/r/example/comments/\(id)/.", "/r/example/comments/\(id)/..",
            "/r/example/comments/\(id)/%2e", "/r/example/comments/\(id)/%252E%252e",
            "/r/example/comments/\(id)/a%2fb", "/r/example/comments/\(id)/a%252Fb",
            "/comments/\(id).json", "/comments/\(id).mp4", "/comments/\(id)//",
            "//comments/\(id)", "/./comments/\(id)", "/%63omments/\(id)",
        ] {
            let source = "https://reddit.com\(path)"
            XCTAssertNil(RedditVideoPreview.postID(in: source), source)
        }
        for invalid in invalidIDs {
            XCTAssertNil(RedditVideoPreview.postID(in: "https://reddit.com/comments/\(invalid)"), invalid)
            XCTAssertNil(RedditVideoPreview.postID(in: "https://vxreddit.com/\(invalid)"), invalid)
        }
    }

    func testRejectsLiteralAndEncodedControlsAndBackslashesEverywhere() {
        for forbidden in ["\n", "\r", "\t", "\u{0000}", "\u{007f}", "\\", "%00", "%0A", "%0d%0a",
                          "%5c", "%255C", "%250a", "%C2%85", "%25literal%250a"] {
            for source in ["https://reddit.com/comments/\(id)?value=\(forbidden)",
                           "https://reddit.com/comments/\(id)#\(forbidden)",
                           "https://reddit.com/r/example/comments/\(id)/slug\(forbidden)"] {
                XCTAssertNil(RedditVideoPreview.postID(in: source), source)
            }
        }
        for source in [" https://reddit.com/comments/\(id)", "https://reddit.com/comments/\(id) ",
                       "https://reddit.com/comments/\(id)?value=two words"] {
            XCTAssertNil(RedditVideoPreview.postID(in: source), source)
        }
    }

    func testProtocolFetchesOnlyPrivateGETEndpointAndDropsAmbientConfiguration() async throws {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [RedditURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer fixture", "Cookie": "fixture=1"]
        configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "proxy.example", "HTTPPort": 8080]
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        RedditURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://reddit-resolver:9813/video/\(self.id).mp4")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "video/mp4")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "TelegramBot")
            XCTAssertEqual(request.timeoutInterval, 50)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return RedditFixture(headers: ["Content-Type": "Video/MP4; charset=binary", "Set-Cookie": "fixture=1"],
                                 chunks: [self.mp4.prefix(3), self.mp4.dropFirst(3)])
        }
        let provider: RedditVideoProviding = RedditVideoFetcher(configuration: configuration)
        let first = try await provider.fetch(postID: id)
        let second = try await provider.fetch(postID: id)
        XCTAssertEqual(first, mp4)
        XCTAssertEqual(second, mp4)
        XCTAssertEqual(RedditURLProtocol.requests.count, 2)
    }

    func testOperatorOriginsUseOnlyTheFixedVideoRoute() async throws {
        for origin in ["http://reddit-resolver:9813/", "http://localhost", "http://localhost:19813/",
                       "http://127.0.0.1:9813", "https://resolver.example", "https://resolver.example:8443/"] {
            RedditURLProtocol.reset()
            stub(video())
            let result = try await makeFetcher(origin: URL(string: origin)!).fetch(postID: id)
            XCTAssertEqual(result, mp4)
            let expected = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
            XCTAssertEqual(RedditURLProtocol.requests.map { $0.url?.absoluteString }, ["\(expected)/video/\(id).mp4"])
        }
    }

    func testInvalidOriginsFailClosedWithoutARequest() async {
        for origin in [
            "http://reddit-resolver", "http://reddit-resolver:9812", "http://reddit-resolver.evil.example:9813",
            "http://resolver.example:9813", "http://192.168.1.2:9813", "http://127.0.0.2:9813",
            "https://reddit.com", "https://www.reddit.com", "https://old.reddit.com", "https://vxreddit.com",
            "https://www.vxreddit.com", "https://v.redd.it", "https://redd.it",
            "https://resolver.example/path", "https://resolver.example/?query=1", "https://resolver.example/#fragment",
            "https://resolver.example?", "https://resolver.example#", "https://user:pass@resolver.example",
            "https://@resolver.example", "https://resolver.example.", "https://%72esolver.example",
            "https://resolver..example", "https://-resolver.example", "https://resolver_.example",
            "https://RESOLVER.example", "HTTPS://resolver.example", "https://resolver.example:0443",
            "https://resolver.example:", "https://resolver.example:0", "https://resolver.example:65536",
            "file:///video", "ftp://resolver.example", "https://resolver.example/%2e%2e",
        ] {
            await assertFailure(.invalidOrigin, fetcher: makeFetcher(origin: URL(string: origin)!))
            XCTAssertTrue(RedditURLProtocol.requests.isEmpty, origin)
        }
    }

    func testInvalidIDsFailBeforeAnyNetworkRequest() async {
        for invalid in invalidIDs + ["http://evil.example", "fixture123?origin=evil", "fixture123#fragment"] {
            await assertFailure(.invalidPostID, postID: invalid)
        }
        XCTAssertTrue(RedditURLProtocol.requests.isEmpty)
    }

    func testRejectsAllNon200StatusesAndMaps413BeforeMIMEValidation() async {
        for status in [201, 204, 206, 301, 302, 303, 307, 308, 400, 401, 403, 404, 429, 500, 502] {
            RedditURLProtocol.reset()
            var fixture = video()
            fixture.status = status
            fixture.headers["Location"] = "https://evil.example/redirect"
            stub(fixture)
            await assertFailure(.invalidResponse)
            XCTAssertEqual(RedditURLProtocol.requests.count, 1)
        }
        stub(RedditFixture(status: 413, headers: ["Content-Type": "application/json"], chunks: []))
        await assertFailure(.videoTooLarge)
    }

    func testRejectsMissingAndIncorrectMIMETypes() async {
        for mime in [nil, "", "text/html", "application/json", "application/octet-stream", "video/webm", "video/mp4evil"] {
            var fixture = video()
            fixture.headers["Content-Type"] = mime
            stub(fixture)
            await assertFailure(.invalidResponse)
        }
    }

    #if !canImport(FoundationNetworking)
    func testActualRedirectCallbackIsRefusedWithoutFollowingAnyDestination() async {
        for destination in ["https://evil.example/movie.mp4", "http://reddit-resolver:9813/video/anotherfixture.mp4"] {
            RedditURLProtocol.reset()
            var fixture = video()
            fixture.redirect = URL(string: destination)!
            stub(fixture)
            await assertFailure(.invalidResponse)
            XCTAssertEqual(RedditURLProtocol.requests.count, 1)
        }
    }
    #endif

    func testHeaderAndStreamedCapsIncludeMissingAndUnderstatedLengths() async {
        let limit = 20 * 1024 * 1024
        for length in [String(limit + 1), String(Int64.max), "1", nil] {
            var fixture = video()
            fixture.headers["Content-Length"] = length
            let chunk = Data(repeating: 0, count: 64 * 1024)
            fixture.chunks = [mp4] + Array(repeating: chunk, count: limit / chunk.count)
            stub(fixture)
            await assertFailure(.videoTooLarge)
        }
        // A large declared body is refused even if no bytes follow the header.
        stub(RedditFixture(headers: ["Content-Type": "video/mp4", "Content-Length": String(limit + 1)], chunks: []))
        await assertFailure(.videoTooLarge)
    }

    func testExactly20MiBAndChunkedHeadersAreAccepted() async throws {
        let limit = 20 * 1024 * 1024
        for length in [String(limit), nil] {
            var fixture = video()
            fixture.headers["Content-Length"] = length
            fixture.chunks = [mp4.prefix(2), mp4[2..<7], mp4.dropFirst(7), Data(repeating: 0, count: limit - mp4.count)]
            stub(fixture)
            let result = try await makeFetcher().fetch(postID: id)
            XCTAssertEqual(result.count, limit)
            XCTAssertEqual(result.prefix(mp4.count), mp4)
        }
    }

    func testRejectsEmptyTruncatedNonMP4AndInvalidBoxLengths() async {
        for body in [Data(), Data("ftyp".utf8), Data("not a video at all".utf8),
                     Data([0, 0, 0, 16] + Array("freeisom".utf8) + [0, 0, 0, 0]),
                     Data([0, 0, 0, 99] + Array("ftypisom".utf8)),
                     Data([0, 0, 0, 4] + Array("ftypisom".utf8)),
                     Data([0, 0, 0, 0] + Array("ftypisom".utf8)),
                     Data([0, 0, 0, 1] + Array("ftypisom".utf8)),
                     Data([255, 255, 255, 255] + Array("ftypisom".utf8))] {
            var fixture = video()
            fixture.chunks = [body]
            stub(fixture)
            await assertFailure(.invalidResponse)
        }
    }

    func testTransportFailurePropagatesWithoutRetry() async {
        RedditURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await makeFetcher().fetch(postID: id)
            XCTFail("Expected transport failure")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(RedditURLProtocol.requests.count, 1)
    }

    func testCancellationBeforeFetchStartsNoRequest() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await makeFetcher().fetch(postID: id)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(RedditURLProtocol.requests.isEmpty)
    }

    func testCancellationStopsAnInFlightRequestAndCompletesOnce() async {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request stopped once")
        stopped.assertForOverFulfill = true
        RedditURLProtocol.handler = { _ in
            RedditFixture(headers: [:], chunks: [], onStart: { started.fulfill() }, onStop: { stopped.fulfill() })
        }
        let task = Task { try await makeFetcher().fetch(postID: id) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(RedditURLProtocol.requests.count, 1)
    }

    private var invalidIDs: [String] {
        ["", "Fixture123", "FIXTURE", "fixture_1", "fixture-1", "a.b", "a/b", "a\\b", "%61", "a%00",
         "a\n", " a", "a ", "é", "١٢٣", "１２３", String(repeating: "a", count: 33)]
    }

    private func makeFetcher(origin: URL? = nil) -> RedditVideoFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedditURLProtocol.self]
        if let origin { return RedditVideoFetcher(configuration: configuration, origin: origin) }
        return RedditVideoFetcher(configuration: configuration)
    }

    private func video() -> RedditFixture {
        RedditFixture(headers: ["Content-Type": "video/mp4"], chunks: [mp4])
    }

    private func stub(_ fixture: RedditFixture) {
        RedditURLProtocol.handler = { _ in fixture }
    }

    private func assertFailure(_ expected: RedditVideoError, fetcher: RedditVideoFetcher? = nil, postID: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await (fetcher ?? makeFetcher()).fetch(postID: postID ?? id)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as RedditVideoError {
            switch (expected, error) {
            case (.invalidPostID, .invalidPostID), (.invalidOrigin, .invalidOrigin),
                 (.invalidResponse, .invalidResponse), (.videoTooLarge, .videoTooLarge): break
            default: XCTFail("Expected \(expected), got \(error)", file: file, line: line)
            }
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
}

private struct RedditFixture {
    var status = 200
    var headers: [String: String]
    var chunks: [Data]
    var redirect: URL?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
}

private final class RedditURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []
    private static var callback: ((URLRequest) throws -> RedditFixture)?
    private let stopLock = NSLock()
    private var onStop: (() -> Void)?

    static var handler: ((URLRequest) throws -> RedditFixture)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); defer { lock.unlock() }; callback = newValue }
    }
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recordedRequests = []
        callback = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let handler = Self.callback
        Self.lock.unlock()
        do {
            guard let handler, let url = request.url else { throw URLError(.unsupportedURL) }
            let fixture = try handler(request)
            if let started = fixture.onStart {
                stopLock.lock()
                onStop = fixture.onStop
                stopLock.unlock()
                started()
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: fixture.redirect == nil ? fixture.status : 302,
                                           httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
            if let redirect = fixture.redirect {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in fixture.chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        stopLock.lock()
        let callback = onStop
        onStop = nil
        stopLock.unlock()
        callback?()
    }
}
