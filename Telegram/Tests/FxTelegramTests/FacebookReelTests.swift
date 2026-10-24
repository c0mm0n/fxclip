import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FxTelegram

final class FacebookReelTests: XCTestCase {
    private let id = "123456789012345"
    private let videoURL = "https://video.example.fbcdn.net/v/sample.mp4?token=fixture&part=1"
    private let mp4 = Data([0, 0, 0, 16] + Array("ftypisom".utf8) + [0, 0, 0, 0])

    override func setUp() {
        super.setUp()
        ReelURLProtocol.reset()
    }

    func testRecognizesOnlyExactReelRoutes() {
        for host in ["facebook.com", "www.facebook.com", "m.facebook.com", "facebed.com", "www.facebed.com", "WWW.Facebook.COM"] {
            for scheme in ["http", "https", "HTTPS"] {
                for suffix in ["", "/", "?tracking=discarded", "/?tracking=discarded#fragment"] {
                    let url = "\(scheme)://\(host)/reel/\(id)\(suffix)"
                    XCTAssertEqual(FacebookReelPreview.reelID(in: url), id, url)
                }
            }
        }
        XCTAssertEqual(FacebookReelPreview.reelID(in: "https://facebook.com:443/reel/1"), "1")
        XCTAssertEqual(FacebookReelPreview.reelID(in: "http://facebed.com:80/reel/1/"), "1")
        let longest = String(repeating: "0", count: 32)
        XCTAssertEqual(FacebookReelPreview.reelID(in: "https://facebook.com/reel/\(longest)"), longest)
    }

    func testRejectsAmbiguousAuthoritiesAndUnsupportedRoutes() {
        for host in ["facebook.com.evil.example", "notfacebook.com", "facebed.com.evil.example", "facebook.com.",
                     "fb.watch", "web.facebook.com", "m.facebed.com", "%66acebook.com", "fаcebook.com",
                     "facebook.com:8443", "facebook.com:", "facebook.com:0443", "facebook.com:80",
                     "user@facebook.com", "user:pass@facebook.com", "@facebook.com", "facebook.com@evil.example"] {
            XCTAssertNil(FacebookReelPreview.reelID(in: "https://\(host)/reel/\(id)"), host)
        }
        for url in [
            "ftp://facebook.com/reel/\(id)", "//facebook.com/reel/\(id)", "facebook.com/reel/\(id)",
            "https://facebook.com", "https://facebook.com/reel", "https://facebook.com/reels/\(id)",
            "https://facebook.com/REEL/\(id)", "https://facebook.com//reel/\(id)",
            "https://facebook.com/reel/\(id)//", "https://facebook.com/reel/\(id)/extra",
            "https://facebook.com/reel/%31", "https://facebook.com/reel/", "https://facebook.com/reel/١٢٣",
            "https://facebook.com/reel/１２３", "https://facebook.com/reel/1a", "https://facebook.com/reel/+1",
            "https://facebook.com/reel/\(String(repeating: "1", count: 33))",
            "https://facebook.com/reel/\(id)\n", " https://facebook.com/reel/\(id)",
            "https://facebook.com\\@evil.example/reel/\(id)", "http://facebook.com:443/reel/\(id)",
            "https://facebook.com/reel/\(id)?a=\n", "https://facebook.com/reel/1%3F2",
        ] {
            XCTAssertNil(FacebookReelPreview.reelID(in: url), url)
        }
    }

    private var forwardedRoutes: [String] {
        [
            "/creator/posts/example-post?story_fbid=123&id=456&comment_id=789",
            "/groups/example-group/posts/123/?comment_id=456",
            "/groups/example-group/permalink/123/?comment_id=456&reply_comment_id=789",
            "/permalink.php?story_fbid=123&id=456&comment_id=789",
            "/story.php?story_fbid=123&id=456",
            "/share/r/ExampleReelToken/", "/share/v/ExampleVideoToken/?mibextid=fixture",
            "/share/p/ExamplePostToken/", "/share/ExampleShareToken/",
            "/reel/123/", "/watch/?v=123&list=example%2Clist",
            "/photo.php?fbid=123&id=456&set=example&list=example%3Alist",
            "/photo/?fbid=123&list=example+list",
            "/creator/posts/example%20post?story_fbid=123&id=456&comment_id=789&list=a%2fb%2Fc&x=1&x=2",
            "/future-content-format/example?key=value",
        ]
    }

    func testFacebedHostReplacementPreservesContentPathAndQuery() {
        for host in ["facebook.com", "www.facebook.com", "m.facebook.com", "facebed.com", "www.facebed.com", "WWW.Facebook.COM"] {
            for scheme in ["http", "https", "HTTPS"] {
                for route in forwardedRoutes {
                    let source = "\(scheme)://\(host)\(route)#private-fragment"
                    XCTAssertEqual(FacebookReelPreview.facebedURL(in: source)?.absoluteString,
                                   "https://facebed.com\(route)", source)
                }
            }
        }
        XCTAssertEqual(FacebookReelPreview.facebedURL(in: "https://facebook.com:443/share/r/ExampleToken")?.absoluteString,
                       "https://facebed.com/share/r/ExampleToken")
        XCTAssertEqual(FacebookReelPreview.facebedURL(in: "http://facebed.com:80/share/v/ExampleToken")?.absoluteString,
                       "https://facebed.com/share/v/ExampleToken")
    }

    private var unsafeSourceURLs: [String] {
        let authorities = [
            "facebook.com.evil.example", "notfacebook.com", "facebed.com.evil.example", "facebook.com.",
            "fb.watch", "web.facebook.com", "m.facebed.com", "%66acebook.com", "fаcebook.com",
            "facebook.com:8443", "facebook.com:", "facebook.com:0443", "facebook.com:+443", "facebook.com:80",
            "user@facebook.com", "user:pass@facebook.com", "@facebook.com", "facebook.com@evil.example",
        ].map { "https://\($0)/share/r/ExampleToken" }
        let paths = [
            "", "/", "/?story_fbid=123&id=456", "//evil.example/share/r/ExampleToken",
            "/share//r/ExampleToken", "/./share/r/ExampleToken", "/share/../ExampleToken",
            "/%2e/share/r/ExampleToken", "/share/%252E%252e/ExampleToken",
            "/share/r/a%2fb", "/share/r/a%5Cb", "/share/r/a%252Fb", "/share/r/a%255cb",
            "/share/r/a%00", "/share/r/a%0d%0a", "/share/r/a%250A", "/share/r/a%252500",
            "/share/r/a%C2%85", "/share/r/a%25literal%250a",
            "/dump", "/dump/", "/DUMP?url=example", "/share/r/dump", "/share/dump/ExampleToken",
            "/%64ump", "/share/%2564%2575%256d%2570/ExampleToken",
            "/healthz", "/healthz/", "/%68ealthz", "/assets/image.png", "/%2561ssets/image.png",
            "/favicon.ico", "/%66avicon.ico", "/banner.png", "/%2562anner.png", "/update", "/UPDATE/now",
        ].map { "https://facebook.com\($0)" }
        return authorities + paths + [
            "ftp://facebook.com/share/r/ExampleToken", "//facebook.com/share/r/ExampleToken",
            "facebook.com/share/r/ExampleToken", "http://facebook.com:443/share/r/ExampleToken",
            " https://facebook.com/share/r/ExampleToken", "https://facebook.com/share/r/ExampleToken\n",
            "https://facebook.com\\@evil.example/share/r/ExampleToken", "https://facebook.com/share/r/ExampleToken?x=\n",
            "https://facebook.com/share/r/ExampleToken#\u{0000}",
        ]
    }

    func testFacebedRejectsUnsafeAuthoritiesPathsAndDiagnostics() {
        for source in unsafeSourceURLs {
            XCTAssertNil(FacebookReelPreview.facebedURL(in: source), source)
        }
    }

    func testSourceURLFetchForwardsRoutesThroughTheSameLoader() async throws {
        let provider: FacebookReelProviding = makeFetcher()
        for route in forwardedRoutes {
            ReelURLProtocol.reset()
            stub(page: page())
            let result = try await provider.fetch(sourceURL: "http://www.facebook.com\(route)#private-fragment")
            XCTAssertEqual(result.author, "Example Creator")
            XCTAssertEqual(result.caption, "Example caption")
            XCTAssertEqual(result.video, mp4)
            XCTAssertEqual(ReelURLProtocol.requests.map { $0.url?.absoluteString },
                           ["http://facebook-resolver:9812\(route)", videoURL])
            XCTAssertEqual(ReelURLProtocol.requests.first?.value(forHTTPHeaderField: "Accept"), "text/html")
            XCTAssertEqual(ReelURLProtocol.requests.last?.value(forHTTPHeaderField: "Accept"), "video/mp4")
        }
    }

    func testDefaultMetadataOriginIsPrivateForBothFetchMethods() async throws {
        let provider = makeFetcher()
        stub(page: page())
        _ = try await provider.fetch(reelID: id)
        _ = try await provider.fetch(sourceURL: "https://facebook.com/reel/\(id)")
        XCTAssertEqual(ReelURLProtocol.requests.map { $0.url?.absoluteString }, [
            "http://facebook-resolver:9812/reel/\(id)", videoURL,
            "http://facebook-resolver:9812/reel/\(id)", videoURL,
        ])
    }

    func testConfiguredOriginsPreserveRoutesWithoutChangingMediaOrigin() async throws {
        for origin in ["http://localhost:9812", "http://127.0.0.1:19812/", "https://resolver.example:8443/"] {
            let provider = makeFetcher(metadataOrigin: URL(string: origin)!)
            let expectedOrigin = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
            for route in forwardedRoutes + ["/reel/123?", "/share/r/Token?x=%252f&x=a+b&x=%2F"] {
                ReelURLProtocol.reset()
                stub(page: page())
                _ = try await provider.fetch(sourceURL: "https://www.facebed.com\(route)#private-fragment")
                XCTAssertEqual(ReelURLProtocol.requests.map { $0.url?.absoluteString },
                               ["\(expectedOrigin)\(route)", videoURL])
            }
            ReelURLProtocol.reset()
            stub(page: page())
            _ = try await provider.fetch(reelID: id)
            XCTAssertEqual(ReelURLProtocol.requests.first?.url?.absoluteString, "\(expectedOrigin)/reel/\(id)")
        }
    }

    func testPublicFacebedSourcesNeverRequestThePublicService() async throws {
        for host in ["facebed.com", "www.facebed.com"] {
            ReelURLProtocol.reset()
            stub(page: page())
            _ = try await makeFetcher().fetch(sourceURL: "https://\(host)/share/r/Token?x=%2f&x=2")
            XCTAssertEqual(ReelURLProtocol.requests.map { $0.url?.absoluteString },
                           ["http://facebook-resolver:9812/share/r/Token?x=%2f&x=2", videoURL])
        }
    }

    func testUnreachableResolverDoesNotFallBackForEitherFetchMethod() async {
        for useSourceURL in [false, true] {
            ReelURLProtocol.reset()
            ReelURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
            do {
                let provider = makeFetcher()
                if useSourceURL {
                    _ = try await provider.fetch(sourceURL: "https://facebed.com/reel/\(id)")
                } else {
                    _ = try await provider.fetch(reelID: id)
                }
                XCTFail("Expected unavailable resolver")
            } catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }
            catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(ReelURLProtocol.requests.map { $0.url?.absoluteString },
                           ["http://facebook-resolver:9812/reel/\(id)"])
        }
    }

    func testInvalidMetadataOriginsNeverReachTheNetwork() async {
        for origin in [
            "http://resolver.example:9812", "http://192.168.1.2:9812", "http://facebook-resolver",
            "http://facebook-resolver:80", "http://facebook-resolver:09812", "http://localhost:",
            "http://localhost:0", "http://localhost:65536", "http://127.0.0.2:9812",
            "https://user:password@resolver.example", "https://@resolver.example", "https://resolver.example?",
            "https://resolver.example?x=1", "https://resolver.example#", "https://resolver.example#fragment",
            "https://resolver.example/base", "https://resolver.example//", "https://resolver.example/%2f",
            "ftp://resolver.example", "//resolver.example", "/relative", "https://resolver.example.",
            "https://%72esolver.example", "https://-resolver.example", "https://resolver..example",
            "https://facebed.com", "https://www.facebed.com", "https://other.facebed.com",
            "https://facebook.com", "https://www.facebook.com", "http://facebed.com",
        ] {
            let provider = makeFetcher(metadataOrigin: URL(string: origin)!)
            for useSourceURL in [false, true] {
                do {
                    if useSourceURL {
                        _ = try await provider.fetch(sourceURL: "https://facebook.com/reel/\(id)")
                    } else {
                        _ = try await provider.fetch(reelID: id)
                    }
                    XCTFail("Expected invalid metadata origin: \(origin)")
                } catch FacebookReelError.invalidMetadataOrigin {}
                catch { XCTFail("Unexpected error for \(origin): \(error)") }
            }
            XCTAssertTrue(ReelURLProtocol.requests.isEmpty, origin)
        }
    }

    func testUnsafeSourceURLsNeverReachTheNetwork() async {
        let provider: FacebookReelProviding = makeFetcher()
        for source in unsafeSourceURLs {
            do {
                _ = try await provider.fetch(sourceURL: source)
                XCTFail("Expected invalid source: \(source)")
            } catch FacebookReelError.invalidReelID {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(ReelURLProtocol.requests.isEmpty)
    }

    func testLegacyProvidersDefaultToExactNumericReelID() async throws {
        let legacy = LegacyReelProvider()
        let provider: FacebookReelProviding = legacy
        let result = try await provider.fetch(sourceURL: "https://facebook.com/reel/\(id)/?x=1#fragment")
        XCTAssertEqual(legacy.ids, [id])
        XCTAssertEqual(result.author, "Example Creator")
        for source in ["https://facebook.com/share/r/ExampleToken", "https://facebook.com/reel/not-numeric",
                       "https://evil.example/reel/123", "https://facebook.com/reel/%31"] {
            do {
                _ = try await provider.fetch(sourceURL: source)
                XCTFail("Expected invalid source: \(source)")
            } catch FacebookReelError.invalidReelID {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(legacy.ids, [id])
    }

    func testInvalidIDsNeverReachTheNetwork() async {
        let fetcher = makeFetcher()
        for value in ["", "-1", "1/", "１", "١", "1\n", "1?tracking=x", "../123", "https://example.com/1",
                      String(repeating: "1", count: 33)] {
            do {
                _ = try await fetcher.fetch(reelID: value)
                XCTFail("Expected invalid ID: \(value)")
            } catch FacebookReelError.invalidReelID {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(ReelURLProtocol.requests.isEmpty)
    }

    func testValidWireFixtureAndPrivacySettings() async throws {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [ReelURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Cookie": "unwanted=1", "Authorization": "unwanted"]
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 100
        ReelURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "TelegramBot")
            XCTAssertEqual(request.timeoutInterval, 6)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url?.host == "facebook-resolver" {
                XCTAssertEqual(request.url?.absoluteString, "http://facebook-resolver:9812/reel/\(self.id)")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
                var fixture = self.page(author: "Example Creator", caption: "Une légende 😀 &amp; une suite")
                fixture.headers["Set-Cookie"] = "session=unwanted; Domain=.fbcdn.net; Secure"
                return fixture
            }
            XCTAssertEqual(request.url?.absoluteString, self.videoURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "video/mp4")
            return self.video()
        }
        let provider: FacebookReelProviding = FacebookReelFetcher(configuration: configuration)
        let result = try await provider.fetch(reelID: id)
        XCTAssertEqual(result.author, "Example Creator")
        XCTAssertEqual(result.caption, "Une légende 😀 & une suite")
        XCTAssertEqual(result.video, mp4)
        XCTAssertEqual(ReelURLProtocol.requests.count, 2)
    }

    func testEntitiesDecodeExactlyOnceAndAttributeOrderIsFlexible() async throws {
        let html = """
        <!doctype html><html><head>
        <!-- <meta property="og:video" content="https://evil.example/a.mp4"> -->
        <script>const x = '<meta property="og:video" content="https://evil.example/a.mp4">';</script>
        <style>/* <meta property="og:title" content="ignored"> */</style>
        <title>&lt;meta&gt;</title>
        <META CONTENT='A &amp;amp; B &quot;quote&quot; &apos;x&apos; &lt;tag&gt; &#65;&#x1F600;&#X42;' PROPERTY='og:title'/>
        <meta content="&amp;quot; &amp;#65;" name="og:description">
        <meta property=og:video content="https://video.example.fbcdn.net/v/sample.mp4?token=fixture&amp;part=1">
        </head><body>Done</body></html>
        """
        stub(page: .html(html))
        let result = try await makeFetcher().fetch(reelID: id)
        XCTAssertEqual(result.author, "A &amp; B \"quote\" 'x' <tag> A😀B")
        XCTAssertEqual(result.caption, "&quot; &#65;")
        XCTAssertEqual(ReelURLProtocol.requests.last?.url?.absoluteString, videoURL)
    }

    func testRejectsMalformedOrAmbiguousEntitiesBeforeDownloading() async {
        for entity in ["&", "&amp", "&unknown;", "&#;", "&#x;", "&#-1;", "&#x+41;", "&#0;", "&#9;",
                       "&#xD800;", "&#1114112;", "&#xFFFF;", "&#128;", "&#99999999999999999999;", "&amp&#65;"] {
            ReelURLProtocol.reset()
            stub(page: page(author: entity))
            await assertFailure(.invalidResponse)
            XCTAssertEqual(ReelURLProtocol.requests.count, 1, entity)
        }
    }

    func testRejectsMissingDuplicateMalformedAndHiddenMetadata() async {
        let videoTag = "<meta property='og:video' content='https://video.example.fbcdn.net/a.mp4'>"
        let title = "<meta property='og:title' content='Example Creator'>"
        let caption = "<meta property='og:description' content='Caption'>"
        for html in [
            "<html><title>Log in to Facebook</title></html>", "", title + caption, title + videoTag, caption + videoTag,
            title + caption + videoTag + videoTag,
            title + title + caption + videoTag,
            "<meta property='og:title' PROPERTY='og:title' content='A'>" + caption + videoTag,
            title + caption + "<meta property='og:video' content='https://video.example.fbcdn.net/a.mp4' content='b'>",
            title + caption + "<meta property='og:video' name='other' content='https://video.example.fbcdn.net/a.mp4'>",
            "<meta property='og:title' content=''>" + caption + videoTag,
            "<meta property='og:title' content='  '>" + caption + videoTag,
            title + caption + "<meta property='og:video' content='https://video.example.fbcdn.net/a.mp4>",
            title + caption + "<meta property='og:video'content='https://video.example.fbcdn.net/a.mp4'>",
            title + caption + "<!-- " + videoTag + " -->",
            title + caption + "<script>" + videoTag + "</script>",
            title + caption + "<textarea>" + videoTag + "</textarea>",
            title + caption + "<script>ignore</scripted>" + videoTag + "</script>",
            title + caption + "<plaintext>" + videoTag,
            title + caption + "<meta property='og:video' content='&#x3C;script&#x3E;'>",
            title + caption + "<meta property='og:video' content='https://video.example.fbcdn.net/a.mp4?x=1&y=2'>",
        ] {
            ReelURLProtocol.reset()
            stub(page: .html(html))
            await assertFailure(.invalidResponse)
            XCTAssertEqual(ReelURLProtocol.requests.count, 1, html)
        }
    }

    func testRejectsUnsafeVideoURLsBeforeDownloading() async {
        for url in [
            "http://video.example.fbcdn.net/a.mp4", "HTTPS://video.example.fbcdn.net/a.mp4",
            "https://fbcdn.net/a.mp4", "https://evil.example/a.mp4", "https://video.fbcdn.net.evil.example/a.mp4",
            "https://evilfbcdn.net/a.mp4", "https://video.fbcdn.net./a.mp4", "https://VIDEO.fbcdn.net/a.mp4",
            "https://%76ideo.fbcdn.net/a.mp4", "https://vidéo.fbcdn.net/a.mp4", "https://xn--vido-dpa.fbcdn.net./a.mp4",
            "https://video..fbcdn.net/a.mp4", "https://-video.fbcdn.net/a.mp4", "https://video_.fbcdn.net/a.mp4",
            "https://video.fbcdn.net:443/a.mp4", "https://video.fbcdn.net:8443/a.mp4", "https://video.fbcdn.net:/a.mp4",
            "https://user@video.fbcdn.net/a.mp4", "https://user:pass@video.fbcdn.net/a.mp4", "https://@video.fbcdn.net/a.mp4",
            "https://video.fbcdn.net@evil.example/a.mp4", "https://video.fbcdn.net\\@evil.example/a.mp4",
            "https://video.fbcdn.net/", "https://video.fbcdn.net/a", "https://video.fbcdn.net/a.MP4",
            "https://video.fbcdn.net/a.mp4/extra", "https://video.fbcdn.net/a%2Emp4", "https://video.fbcdn.net/a%2Fb.mp4",
            "https://video.fbcdn.net/../a.mp4", "https://video.fbcdn.net/a.mp4#fragment", "https://video.fbcdn.net/.mp4",
            "https://video.fbcdn.net/a.mp4\n", "//video.fbcdn.net/a.mp4",
        ] {
            ReelURLProtocol.reset()
            stub(page: page(source: url))
            await assertFailure(.invalidResponse)
            XCTAssertEqual(ReelURLProtocol.requests.count, 1, url)
        }
    }

    func testRejectsStatusesMIMETypesAndRedirectResponsesAtBothStages() async {
        for stage in ["page", "video"] {
            for status in [201, 204, 301, 302, 303, 307, 308, 401, 403, 404, 500] {
                var failure = stage == "page" ? page() : video()
                failure.status = status
                failure.headers["Location"] = "https://evil.example/redirect"
                ReelURLProtocol.reset()
                stub(page: stage == "page" ? failure : page(), video: stage == "video" ? failure : video())
                await assertFailure(.invalidResponse)
                XCTAssertEqual(ReelURLProtocol.requests.count, stage == "page" ? 1 : 2)
                XCTAssertFalse(ReelURLProtocol.requests.contains { $0.url?.host == "evil.example" })
            }
            for type in ["", "text/plain", "application/json", "application/octet-stream", stage == "page" ? "video/mp4" : "text/html"] {
                var failure = stage == "page" ? page() : video()
                failure.headers["Content-Type"] = type
                stub(page: stage == "page" ? failure : page(), video: stage == "video" ? failure : video())
                await assertFailure(.invalidResponse)
            }
        }
    }

    #if !canImport(FoundationNetworking)
    func testActualRedirectCallbacksAreRefusedAtBothStages() async {
        // corelibs Foundation does not implement URLProtocol's redirect callback.
        for stage in ["page", "video"] {
            var redirect = stage == "page" ? page() : video()
            redirect.redirect = URL(string: "https://evil.example/redirect")!
            ReelURLProtocol.reset()
            stub(page: stage == "page" ? redirect : page(), video: stage == "video" ? redirect : video())
            await assertFailure(.invalidResponse)
            XCTAssertEqual(ReelURLProtocol.requests.count, stage == "page" ? 1 : 2)
        }
    }
    #endif

    func testKnownAndStreamedSizeLimitsAtBothStages() async {
        for stage in ["page", "video"] {
            let limit = stage == "page" ? 512 * 1024 : 20 * 1024 * 1024
            for length in [String(limit + 1), "1", nil] {
                var oversized = stage == "page" ? page() : video()
                oversized.headers["Content-Length"] = length
                let chunk = Data(repeating: 32, count: 64 * 1024)
                oversized.chunks = Array(repeating: chunk, count: limit / chunk.count) + [Data([32])]
                ReelURLProtocol.reset()
                stub(page: stage == "page" ? oversized : page(), video: stage == "video" ? oversized : video())
                let expected: FacebookReelError = stage == "page" ? .responseTooLarge :
                    .videoTooLarge(author: "Example Creator", caption: "Example caption")
                await assertFailure(expected)
                XCTAssertEqual(ReelURLProtocol.requests.count, stage == "page" ? 1 : 2)
            }
        }
    }

    func testExactSizeBoundariesAndChunkedMP4AreAccepted() async throws {
        var html = page()
        let original = html.chunks[0]
        html.chunks = [original + Data(repeating: 32, count: 512 * 1024 - original.count)]
        html.headers["Content-Length"] = String(512 * 1024)
        var movie = video()
        movie.chunks = [mp4.prefix(3), mp4.dropFirst(3), Data(repeating: 0, count: 20 * 1024 * 1024 - mp4.count)]
        movie.headers["Content-Length"] = String(20 * 1024 * 1024)
        stub(page: html, video: movie)
        let result = try await makeFetcher().fetch(reelID: id)
        XCTAssertEqual(result.video.count, 20 * 1024 * 1024)
        XCTAssertEqual(result.video.prefix(mp4.count), mp4)
    }

    func testSourceURLVideoLimitCarriesOnlyDecodedAuthorAndCaption() async {
        var movie = video()
        movie.headers["Content-Length"] = String(55_500_000)
        stub(page: page(author: "Example &amp; Creator", caption: "A &quot;caption&quot;"), video: movie)
        do {
            _ = try await makeFetcher().fetch(sourceURL: "https://facebook.com/share/r/ExampleToken#private-fragment")
            XCTFail("Expected video size limit")
        } catch FacebookReelError.videoTooLarge(let author, let caption) {
            XCTAssertEqual(author, "Example & Creator")
            XCTAssertEqual(caption, "A \"caption\"")
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(ReelURLProtocol.requests.count, 2)
    }

    func testRejectsEmptyTruncatedNonMP4AndInvalidUTF8() async {
        for body in [Data(), Data("ftyp".utf8), Data("not a video at all".utf8),
                     Data([0, 0, 0, 99] + Array("ftypisom".utf8)),
                     Data([0, 0, 0, 4] + Array("ftypisom".utf8))] {
            var movie = video()
            movie.chunks = [body]
            stub(page: page(), video: movie)
            await assertFailure(.invalidResponse)
        }
        var html = page()
        html.chunks = [Data([0xff, 0xfe, 0xff])]
        stub(page: html)
        await assertFailure(.invalidResponse)
    }

    func testTransportErrorsArePropagatedWithoutRetry() async {
        for stage in ["page", "video"] {
            ReelURLProtocol.reset()
            ReelURLProtocol.handler = { request in
                if stage == "page" || request.url?.host != "facebook-resolver" { throw URLError(.timedOut) }
                return self.page()
            }
            do {
                _ = try await makeFetcher().fetch(reelID: id)
                XCTFail("Expected timeout")
            } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
            catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(ReelURLProtocol.requests.count, stage == "page" ? 1 : 2)
        }
    }

    func testCancellationBeforeFetchDoesNotStartNetwork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await makeFetcher().fetch(reelID: id)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(ReelURLProtocol.requests.isEmpty)
    }

    func testCancellationStopsAnInFlightRequestAtBothStages() async {
        for stage in ["page", "video"] {
            ReelURLProtocol.reset()
            let started = expectation(description: "\(stage) started")
            let stopped = expectation(description: "\(stage) stopped")
            ReelURLProtocol.handler = { request in
                if stage == "video" && request.url?.host == "facebook-resolver" { return self.page() }
                return ReelFixture(headers: [:], chunks: [], onStart: { started.fulfill() }, onStop: { stopped.fulfill() })
            }
            let task = Task { try await makeFetcher().fetch(reelID: id) }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            await fulfillment(of: [stopped], timeout: 2)
        }
    }

    private func makeFetcher(metadataOrigin: URL? = nil) -> FacebookReelFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReelURLProtocol.self]
        if let metadataOrigin {
            return FacebookReelFetcher(configuration: configuration, metadataOrigin: metadataOrigin)
        }
        return FacebookReelFetcher(configuration: configuration)
    }

    private func page(author: String = "Example Creator", caption: String = "Example caption", source: String? = nil) -> ReelFixture {
        // Escape only the URL: author/caption arguments can deliberately contain encoded or malformed entities.
        let source = (source ?? videoURL).replacingOccurrences(of: "&", with: "&amp;")
        return .html("""
        <html><head><meta property="og:title" content="\(author)">
        <meta property="og:description" content="\(caption)">
        <meta property="og:video" content="\(source)"></head></html>
        """)
    }

    private func video() -> ReelFixture {
        ReelFixture(headers: ["Content-Type": "video/mp4; charset=binary"], chunks: [mp4])
    }

    private func stub(page: ReelFixture, video: ReelFixture? = nil) {
        ReelURLProtocol.handler = { request in
            request.value(forHTTPHeaderField: "Accept") == "text/html" ? page : (video ?? self.video())
        }
    }

    private func assertFailure(_ expected: FacebookReelError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await makeFetcher().fetch(reelID: id)
            XCTFail("Expected failure", file: file, line: line)
        } catch let error as FacebookReelError {
            switch (expected, error) {
            case (.invalidReelID, .invalidReelID), (.invalidResponse, .invalidResponse), (.responseTooLarge, .responseTooLarge): break
            case let (.videoTooLarge(expectedAuthor, expectedCaption), .videoTooLarge(author, caption)):
                XCTAssertEqual(author, expectedAuthor, file: file, line: line)
                XCTAssertEqual(caption, expectedCaption, file: file, line: line)
            default: XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
}

private final class LegacyReelProvider: FacebookReelProviding {
    var ids: [String] = []

    func fetch(reelID: String) async throws -> FacebookReel {
        ids.append(reelID)
        return FacebookReel(author: "Example Creator", caption: "Example caption", video: Data())
    }
}

private struct ReelFixture {
    var status = 200
    var headers: [String: String]
    var chunks: [Data]
    var redirect: URL?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    static func html(_ value: String) -> ReelFixture {
        ReelFixture(headers: ["Content-Type": "text/html; charset=utf-8"], chunks: [Data(value.utf8)])
    }
}

private final class ReelURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []
    private static var callback: ((URLRequest) throws -> ReelFixture)?
    private let stopLock = NSLock()
    private var onStop: (() -> Void)?

    static var handler: ((URLRequest) throws -> ReelFixture)? {
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
