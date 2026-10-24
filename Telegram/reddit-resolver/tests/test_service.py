"""Generic generated fixtures only. Run with Docker --network none."""
from copy import deepcopy
from email.message import Message
import http.client
import inspect
import io
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, "/service")
import service as s
import upstream_adapter as adapter

POST_ID = "abc123"
ROOT = "https://v.redd.it/fixture123/"
MASTER = ROOT + "master.m3u8"


def post_document():
    return [{"data": {"children": [{"kind": "t3", "data": {
        "id": POST_ID, "title": "Generic fixture", "author": "fixture",
        "subreddit_name_prefixed": "r/fixture", "ups": 0, "selftext": "",
        "subreddit_type": "public", "removed_by_category": None,
        "is_self": False, "is_video": True, "post_hint": "hosted:video",
        "domain": "v.redd.it", "url": ROOT.rstrip("/"),
        "media": {"reddit_video": {
            "hls_url": MASTER, "fallback_url": ROOT + "never-use-this.mp4",
            "has_audio": True, "is_gif": False, "width": 1280, "height": 720,
            "transcoding_status": "completed",
        }},
        "preview": {"images": [{"source": {"url": "https://example.invalid/fixture.png"}}]},
    }}]}}]


def master(audio=True):
    text = '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="fixture",URI="sound.m3u8"\n'
    for name, resolution, bandwidth in (("high", "1280x720", 2000000), ("low", "854x480", 1000000)):
        codecs = "avc1.4d401f,mp4a.40.2" if audio else "avc1.4d401f"
        text += f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={resolution},CODECS="{codecs}"'
        if audio:
            text += ',AUDIO="a"'
        text += f'\n{name}.m3u8\n'
    return text


def media(filename, size):
    # Deliberately different manifest and media filenames: replacing .m3u8 with
    # .mp4 would fetch the wrong resource. The init and every segment must agree.
    return (f'#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:1\n'
            f'#EXT-X-MAP:URI="{filename}",BYTERANGE="32@0"\n'
            f'#EXTINF:1,\n#EXT-X-BYTERANGE:{size-32}@32\n{filename}\n#EXT-X-ENDLIST\n')


class FixtureNet:
    def __init__(self, video, audio, high_size=s.CAP + 1):
        self.metadata_url = f"https://api.reddit.com/comments/{POST_ID}?raw_json=1"
        self.document = post_document()
        self.urls = {
            MASTER: master().encode(),
            ROOT + "high.m3u8": media("actual-large.mp4", len(video)).encode(),
            ROOT + "low.m3u8": media("actual-small.mp4", len(video)).encode(),
            ROOT + "sound.m3u8": media("actual-sound.mp4", len(audio)).encode(),
            ROOT + "actual-small.mp4": video, ROOT + "actual-sound.mp4": audio,
            ROOT + "actual-large.mp4": video,
        }
        self.sizes = {url: len(data) for url, data in self.urls.items()}
        self.sizes[ROOT + "actual-large.mp4"] = high_size
        self.calls = []

    def remaining(self):
        return 30

    def get(self, url, limit, destination=None, expected=None):
        self.calls.append(("GET", url))
        data = json.dumps(self.document).encode() if url == self.metadata_url else self.urls[url]
        if len(data) > limit or (expected is not None and len(data) != expected):
            raise s.Failure()
        if destination is not None:
            return destination.write(data)
        return data

    def head(self, url):
        self.calls.append(("HEAD", url))
        return self.sizes[url]


class GeneratedMedia(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        directory = Path(cls.directory.name)
        video, audio = directory / "v.mp4", directory / "a.mp4"
        commands = [
            ["-f", "lavfi", "-i", "testsrc2=size=64x48:rate=10:duration=1", "-an", "-c:v", "libx264", "-threads", "1", "-pix_fmt", "yuv420p", str(video)],
            ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1", "-vn", "-c:a", "aac", str(audio)],
        ]
        for args in commands:
            subprocess.run(["/usr/bin/ffmpeg", "-nostdin", "-v", "error", "-y"] + args,
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15)
        cls.video, cls.audio = video.read_bytes(), audio.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def net(self):
        return FixtureNet(self.video, self.audio)

    def test_real_upstream_parser_and_real_mux_select_highest_fitting_with_sound(self):
        net = self.net()
        with tempfile.TemporaryDirectory() as directory, patch("socket.create_connection", side_effect=AssertionError("offline")):
            output = s.resolve(POST_ID, directory, net)
            self.assertLessEqual(output.stat().st_size, s.CAP)
            s.check_tracks(s.probe(output), True)
            s.faststart(output)
            # Decode the complete generic fixture to check actual playable A/V.
            subprocess.run(["/usr/bin/ffmpeg", "-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "file,pipe", "-i", str(output), "-f", "null", "-"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
            self.assertEqual(list(Path(directory).iterdir()), [output])
        self.assertNotIn(("GET", ROOT + "actual-large.mp4"), net.calls)
        self.assertIn(("GET", ROOT + "actual-small.mp4"), net.calls)
        self.assertIn(("GET", ROOT + "actual-sound.mp4"), net.calls)

    def test_highest_is_used_when_it_fits(self):
        net = self.net()
        net.sizes[ROOT + "actual-large.mp4"] = len(self.video)
        with tempfile.TemporaryDirectory() as directory:
            s.resolve(POST_ID, directory, net)
        self.assertIn(("GET", ROOT + "actual-large.mp4"), net.calls)
        self.assertNotIn(("GET", ROOT + "low.m3u8"), net.calls)

    def test_real_http_pipeline_uses_parser_and_local_mux(self):
        net = self.net()
        server = s.Server(("127.0.0.1", 0), lambda post_id, directory: s.resolve(post_id, directory, net))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            connection = http.client.HTTPConnection(*server.server_address, timeout=5)
            connection.request("GET", f"/video/{POST_ID}.mp4")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Content-Type"), "video/mp4")
            body = response.read()
            self.assertEqual(len(body), int(response.getheader("Content-Length")))
            connection.close()
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "received.mp4"
                path.write_bytes(body)
                s.check_tracks(s.probe(path), True)
                s.faststart(path)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(3)

    def test_no_audio_original_stays_video_only(self):
        net = self.net()
        net.document[0]["data"]["children"][0]["data"]["media"]["reddit_video"]["has_audio"] = False
        net.urls[MASTER] = master(False).encode()
        with tempfile.TemporaryDirectory() as directory:
            output = s.resolve(POST_ID, directory, net)
            s.check_tracks(s.probe(output), False)
        self.assertNotIn(("GET", ROOT + "sound.m3u8"), net.calls)

    def test_original_audio_cannot_disappear(self):
        net = self.net()
        net.urls[ROOT + "actual-sound.mp4"] = self.video
        net.urls[ROOT + "sound.m3u8"] = media("actual-sound.mp4", len(self.video)).encode()
        net.sizes[ROOT + "actual-sound.mp4"] = len(self.video)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(s.Failure) as caught:
                s.resolve(POST_ID, directory, net)
            self.assertEqual(caught.exception.status, 422)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_all_oversized_is_413_without_downloading(self):
        net = self.net()
        net.sizes[ROOT + "actual-small.mp4"] = s.CAP + 1
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(s.Failure) as caught:
                s.resolve(POST_ID, directory, net)
            self.assertEqual(caught.exception.status, 413)
            self.assertEqual(list(Path(directory).iterdir()), [])
        self.assertFalse(any(method == "GET" and url.endswith(".mp4") for method, url in net.calls))

    def test_output_oversized_retries_lower_and_cleans_attempt(self):
        net = self.net()
        net.sizes[ROOT + "actual-large.mp4"] = len(self.video)
        real_mux = s.mux
        def first_too_large(video, audio, output, timeout):
            real_mux(video, audio, output, timeout)
            if len([call for call in net.calls if call == ("GET", ROOT + "actual-large.mp4")]) and not any(call == ("GET", ROOT + "actual-small.mp4") for call in net.calls):
                with output.open("ab") as stream:
                    # A valid padding atom keeps atom validation meaningful.
                    size = s.CAP + 1 - output.stat().st_size
                    stream.write(struct.pack(">I4s", size, b"free") + bytes(size - 8))
        with tempfile.TemporaryDirectory() as directory, patch.object(s, "mux", side_effect=first_too_large):
            output = s.resolve(POST_ID, directory, net)
            self.assertLess(output.stat().st_size, s.CAP)
            self.assertEqual(list(Path(directory).iterdir()), [output])
        self.assertIn(("GET", ROOT + "actual-small.mp4"), net.calls)

    def test_network_failure_is_not_reported_as_size_failure(self):
        net = self.net()
        net.sizes[ROOT + "actual-small.mp4"] += 10
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(s.Failure) as caught:
                s.resolve(POST_ID, directory, net)
            self.assertEqual(caught.exception.status, 502)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_bad_codec_is_422(self):
        net = self.net()
        net.urls[MASTER] = master().replace("avc1.4d401f", "hvc1.1.6").encode()
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(s.Failure) as caught:
                s.resolve(POST_ID, directory, net)
            self.assertEqual(caught.exception.status, 422)

    def test_ffmpeg_command_has_only_local_inputs_and_no_truncation(self):
        result = type("Result", (), {"returncode": 0})()
        with patch.object(s.subprocess, "run", return_value=result) as run:
            s.mux(Path("/tmp/video.mp4"), Path("/tmp/audio.mp4"), Path("/tmp/out.mp4"), 2)
        args = run.call_args.args[0]
        self.assertNotIn("-fs", args)
        self.assertNotIn("https", " ".join(args))
        self.assertEqual(args.count("-protocol_whitelist"), 2)
        self.assertEqual(args.count("file,pipe"), 2)
        self.assertIn("+faststart", args)
        self.assertIn("1:a:0", args)
        self.assertEqual(run.call_args.kwargs["timeout"], 2)


class MetadataTests(unittest.TestCase):
    def test_parser_is_the_pinned_real_module(self):
        self.assertIs(adapter.embed_info_from_post, adapter.upstream.embed_info_from_post)
        self.assertEqual(inspect.getfile(adapter.embed_info_from_post), "/opt/vxreddit/vxreddit.py")
        self.assertEqual(Path("/opt/vxreddit/REVISION").read_text().strip(), "990860a01ca865774b0e77b5de9af76b54947900")
        self.assertIn("Version 2, December 2004", Path("/opt/vxreddit/LICENSE.txt").read_text())
        self.assertFalse(Path("/service/vxReddit.conf").exists())
        for call in (adapter.upstream.requests.get, adapter.upstream.praw.Reddit, adapter.upstream.videoCombiner.combine_videos, adapter.upstream.app.wsgi_app):
            with self.assertRaises(RuntimeError):
                call()

    def test_native_post(self):
        self.assertEqual(s.parse_post(post_document(), POST_ID), (MASTER, "fixture123", True))

    def test_mismatched_id(self):
        with self.assertRaises(s.Failure) as caught:
            s.parse_post(post_document(), "different")
        self.assertEqual(caught.exception.status, 502)

    def test_unsupported_posts_are_422(self):
        for updates in ({"subreddit_type": "private"}, {"is_video": False}, {"post_hint": "image"},
                        {"post_hint": "self"}, {"post_hint": "rich:video"}, {"removed_by_category": "deleted"},
                        {"domain": "example.invalid"}, {"is_self": True}):
            document = post_document()
            document[0]["data"]["children"][0]["data"].update(updates)
            with self.subTest(updates=updates), self.assertRaises(s.Failure) as caught:
                s.parse_post(document, POST_ID)
            self.assertEqual(caught.exception.status, 422)

    def test_audio_unknown_is_not_assumed_silent(self):
        document = post_document()
        del document[0]["data"]["children"][0]["data"]["media"]["reddit_video"]["has_audio"]
        with self.assertRaises(s.Failure) as caught:
            s.parse_post(document, POST_ID)
        self.assertEqual(caught.exception.status, 422)

    def test_malformed_metadata_is_generic(self):
        for document in (None, [], {}, [{"data": {"children": []}}]):
            with self.subTest(document=document), self.assertRaises(s.Failure) as caught:
                s.parse_post(document, POST_ID)
            self.assertEqual(str(caught.exception), "Video unavailable.")


class ManifestTests(unittest.TestCase):
    def test_url_allowlist(self):
        for url in ("http://v.redd.it/fixture123/video.mp4", "https://v.redd.it:443/fixture123/video.mp4",
                    "https://v.redd.it.evil.invalid/fixture123/video.mp4", "https://x@v.redd.it/fixture123/video.mp4",
                    "https://127.0.0.1/fixture123/video.mp4", "https://v.redd.it/fixture123/../video.mp4",
                    "https://v.redd.it/fixture123/%2e.mp4", ROOT + "video.mp4#secret", ROOT + "v\\ideo.mp4",
                    ROOT + "video.mp4\n", " https://v.redd.it/fixture123/video.mp4"):
            with self.subTest(url=url), self.assertRaises(s.Failure):
                s.media_url(url)

    def test_actual_resource_from_init_and_segments(self):
        self.assertEqual(s.mp4_resource(media("arbitrary.mp4", 100), ROOT + "other.m3u8", "fixture123"), (ROOT + "arbitrary.mp4", 100))

    def test_reject_changed_media_id_or_host_and_traversal(self):
        for uri in ("https://v.redd.it/other123/v.mp4", "https://example.invalid/fixture123/v.mp4",
                    "//example.invalid/v.mp4", "../v.mp4", "%2e%2e/v.mp4", "v.mp4\n"):
            with self.subTest(uri=uri), self.assertRaises(s.Failure):
                s.reference(MASTER, uri, "fixture123", ".mp4")

    def test_all_segments_and_init_must_match(self):
        text = media("one.mp4", 100)
        cases = [text.replace('URI="one.mp4"', 'URI="two.mp4"'),
                 text.replace("#EXT-X-ENDLIST", "#EXTINF:1,\n#EXT-X-BYTERANGE:32@100\ntwo.mp4\n#EXT-X-ENDLIST"),
                 text.replace("#EXT-X-ENDLIST", ""), text.replace("#EXT-X-MAP:", "#OTHER:"),
                 text.replace("#EXTINF:1,", '#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:1,'),
                 text.replace("#EXTINF:1,", "#EXT-X-DISCONTINUITY\n#EXTINF:1,"),
                 text.replace("68@32", "68@0")]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(s.Failure):
                s.mp4_resource(case, MASTER, "fixture123")

    def test_missing_original_audio_group_rejected(self):
        with self.assertRaises(s.Failure) as caught:
            s.renditions(master().replace('GROUP-ID="a"', 'GROUP-ID="other"'), MASTER, "fixture123", True)
        self.assertEqual(caught.exception.status, 422)


class FakeResponse:
    def __init__(self, body=b"abc", status=200, headers=None):
        self.status = status
        self.headers = Message()
        for name, value in (headers if headers is not None else [("Content-Length", str(len(body)))]):
            self.headers[name] = value
        self.body = io.BytesIO(body)

    def getheader(self, key, default=None):
        return self.headers.get(key, default)

    def read1(self, size):
        return self.body.read1(size)


class FakeConnection:
    def __init__(self, response):
        self.response, self.sock, self.closed, self.requests = response, None, False, []

    def request(self, *args, **kwargs):
        self.requests.append((args, kwargs))

    def getresponse(self):
        return self.response

    def close(self):
        self.closed = True


class TransportTests(unittest.TestCase):
    def perform(self, response, action):
        connection = FakeConnection(response)
        net = s.Transport(POST_ID)
        with patch.object(s.http.client, "HTTPSConnection", return_value=connection) as constructor:
            value = action(net)
        self.assertTrue(connection.closed)
        self.assertEqual(constructor.call_args.args[:2], ("api.reddit.com", 443))
        headers = connection.requests[0][1]["headers"]
        self.assertNotIn("Cookie", headers)
        self.assertNotIn("Authorization", headers)
        self.assertEqual(connection.requests[0][0][1], f"/comments/{POST_ID}?raw_json=1")
        return value

    def test_fixed_comments_transport(self):
        self.assertEqual(self.perform(FakeResponse(), lambda net: net.get(net.metadata_url, 10)), b"abc")

    def test_redirects_and_compression_rejected(self):
        for response in (FakeResponse(status=302), FakeResponse(headers=[("Content-Encoding", "gzip")])):
            with self.assertRaises(s.Failure):
                self.perform(response, lambda net: net.get(net.metadata_url, 10))

    def test_byte_budget_and_declared_lengths(self):
        actions = [lambda net: net.get(net.metadata_url, 2),
                   lambda net: net.get(net.metadata_url, 10, expected=4),
                   lambda net: (setattr(net, "bytes_left", 2), net.get(net.metadata_url, 10))]
        for action in actions:
            with self.subTest(action=action), self.assertRaises(s.Failure):
                self.perform(FakeResponse(), action)
        for headers in ([("Content-Length", "3"), ("Content-Length", "3")],
                        [("Content-Length", "4")], [("Content-Length", "3"), ("Transfer-Encoding", "chunked")]):
            with self.assertRaises(s.Failure):
                self.perform(FakeResponse(headers=headers), lambda net: net.get(net.metadata_url, 10))

    def test_unknown_length_stream_is_bounded(self):
        with self.assertRaises(s.Failure):
            self.perform(FakeResponse(headers=[]), lambda net: net.get(net.metadata_url, 2))

    def test_request_and_time_budget(self):
        for field, value in (("requests_left", 0), ("deadline", 0)):
            net = s.Transport(POST_ID)
            setattr(net, field, value)
            with patch.object(s.http.client, "HTTPSConnection") as connection, self.assertRaises(s.Failure):
                net.get(net.metadata_url, 10)
            connection.assert_not_called()

    def test_only_exact_post_api_transport(self):
        net = s.Transport(POST_ID)
        for url in ("https://api.reddit.com/comments/other?raw_json=1", "https://www.reddit.com/comments/abc123.json", "https://vxreddit.com/abc123"):
            with patch.object(s.http.client, "HTTPSConnection") as connection, self.assertRaises(s.Failure):
                net.get(url, 10)
            connection.assert_not_called()

    def test_bounded_response_headers(self):
        class FakeSocket:
            def makefile(self, *args):
                return io.BytesIO(b"HTTP/1.1 200 OK\r\nX-Test: " + b"x" * 17000 + b"\r\n\r\n")
        response = s.BoundedResponse(FakeSocket())
        with self.assertRaises(s.Failure):
            response.begin()

    def test_head_does_not_leak_response_wrapper(self):
        class FakeSocket:
            def makefile(self, *args):
                return io.BytesIO(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n")
        response = s.BoundedResponse(FakeSocket(), method="HEAD")
        response.begin()
        self.assertEqual(response.status, 200)
        response.close()


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.paths = []
        def resolver(post_id, directory):
            self.paths.append(directory)
            path = Path(directory) / "result.mp4"
            path.write_bytes(b"fixture-mp4")
            return path
        self.server = s.Server(("127.0.0.1", 0), resolver)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.address = self.server.server_address

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(3)

    def get(self, target, method="GET", headers=None):
        connection = http.client.HTTPConnection(*self.address, timeout=3)
        connection.request(method, target, headers=headers or {})
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def test_video_length_type_and_cleanup(self):
        status, headers, body = self.get(f"/video/{POST_ID}.mp4")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "video/mp4")
        self.assertEqual(int(headers["Content-Length"]), len(body))
        for _ in range(100):
            if not Path(self.paths[0]).exists():
                break
            time.sleep(.005)
        self.assertFalse(Path(self.paths[0]).exists())

    def test_only_bodyless_literal_routes(self):
        targets = ["/", "/redditvideo.mp4", "/oembed", "/healthz?", "/healthz/", "//healthz",
                   "/video/A.mp4", "/video/abc%31.mp4", "/video/" + "a" * 33 + ".mp4",
                   "/video/a.mp4?x=1", "/video/a.mp4/", "http://localhost/healthz"]
        for target in targets:
            with self.subTest(target=target):
                status, headers, body = self.get(target)
                self.assertEqual(status, 404)
                self.assertEqual(body, b"Video unavailable.\n")
        for headers in ({"Content-Length": "1"}, {"Transfer-Encoding": "chunked"}, {"Expect": "100-continue"}):
            self.assertEqual(self.get("/healthz", headers=headers)[0], 400)
        for method in ("POST", "HEAD", "PUT", "OPTIONS", "DELETE"):
            self.assertEqual(self.get("/healthz", method=method)[0], 501)
        self.assertEqual(self.paths, [])
        self.assertEqual(self.get("/healthz")[2], b"ok\n")

    def test_non_ascii_id_is_rejected_on_wire(self):
        with socket.create_connection(self.address, timeout=2) as connection:
            connection.sendall(b"GET /video/\xc3\xa9.mp4 HTTP/1.1\r\nHost: private\r\n\r\n")
            response = http.client.HTTPResponse(connection)
            response.begin()
            self.assertEqual(response.status, 404)
            self.assertEqual(response.read(), b"Video unavailable.\n")

    def test_health_is_available_while_single_video_worker_busy(self):
        entered, release = threading.Event(), threading.Event()
        def busy(post_id, directory):
            entered.set()
            release.wait(3)
            raise s.Failure(422)
        self.server.resolve_video = busy
        result = []
        first = threading.Thread(target=lambda: result.append(self.get("/video/a.mp4")))
        first.start()
        try:
            self.assertTrue(entered.wait(2))
            self.assertEqual(self.get("/healthz")[0], 200)
            self.assertEqual(self.get("/video/b.mp4")[0], 503)
            self.assertEqual(self.server.request_queue_size, 2)
        finally:
            release.set()
            first.join(3)
        self.assertEqual(result[0][0], 422)

    def test_failures_are_generic_and_tempfiles_deleted(self):
        for status in (413, 422, 502):
            paths = []
            def fail(post_id, directory):
                paths.append(directory)
                (Path(directory) / "partial.mp4").write_bytes(b"partial")
                raise s.Failure(status)
            self.server.resolve_video = fail
            self.assertEqual(self.get("/video/a.mp4")[::2], (status, b"Video unavailable.\n"))
            self.assertFalse(Path(paths[0]).exists())

    def test_header_limit_does_not_echo_request(self):
        with socket.create_connection(self.address, timeout=2) as connection:
            connection.sendall(b"GET /healthz HTTP/1.1\r\nHost: private\r\nX-Private: " + b"x" * 17000 + b"\r\n\r\n")
            response = http.client.HTTPResponse(connection)
            response.begin()
            self.assertEqual(response.status, 400)
            self.assertEqual(response.read(), b"Video unavailable.\n")

    def test_reduced_real_worker_deadline_releases_slot_and_tempfiles(self):
        # Exercise actual process-group timeout/kill/wait through real HTTP.
        # Only replace the child's work with a generic local fixture; no Reddit.
        real_popen = subprocess.Popen
        directories = []
        with tempfile.TemporaryDirectory() as observer:
            grandchild_file = Path(observer) / "pid"
            def controlled_child(command, **kwargs):
                directory = command[-1]
                directories.append(directory)
                program = ("from pathlib import Path; import sys,time,subprocess; "
                           "p=Path(sys.argv[1]); (p/'partial').write_bytes(b'fixture'); ")
                if len(directories) == 1:
                    program += ("child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(10)']); "
                                f"Path({str(grandchild_file)!r}).write_text(str(child.pid)); time.sleep(10); ")
                else:
                    program += "time.sleep(.03); "
                program += "(p/'result.mp4').write_bytes(b'fixture-mp4')"
                self.assertTrue(kwargs["start_new_session"])
                self.assertNotIn("preexec_fn", kwargs)
                return real_popen([sys.executable, "-c", program, directory], **kwargs)
            self.server.resolve_video = s.run_worker
            with patch.object(s, "WORKER_SECONDS", .3), patch.object(s.subprocess, "Popen", side_effect=controlled_child):
                before = time.monotonic()
                status, _, body = self.get("/video/a.mp4")
                self.assertEqual((status, body), (502, b"Video unavailable.\n"))
                self.assertLess(time.monotonic() - before, 1.5)
                self.assertFalse(Path(directories[0]).exists())
                self.assertTrue(grandchild_file.exists())
                pid = int(grandchild_file.read_text())
                def still_running():
                    try:
                        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
                    except FileNotFoundError:
                        return False
                for _ in range(100):
                    if not still_running():
                        break
                    time.sleep(.005)
                self.assertFalse(still_running(), "grandchild survived process-group kill")
                self.assertEqual(self.get("/healthz")[0], 200)
                before = time.monotonic()
                status, _, body = self.get("/video/b.mp4")
                self.assertEqual((status, body), (200, b"fixture-mp4"))
                self.assertLess(time.monotonic() - before, 1.5)
                for _ in range(100):
                    if not Path(directories[1]).exists():
                        break
                    time.sleep(.005)
                self.assertFalse(Path(directories[1]).exists())
        self.assertLess(s.SECONDS, s.WORKER_SECONDS)
        self.assertLessEqual(s.WORKER_SECONDS, 45)


class ValidationTests(unittest.TestCase):
    def test_audio_and_video_codecs_duration(self):
        valid = {"streams": [{"codec_type": "video", "codec_name": "h264", "width": 64, "height": 48},
                             {"codec_type": "audio", "codec_name": "aac", "duration": "1"}], "format": {"duration": "1"}}
        s.check_tracks(valid, True)
        for kind, codec in ((0, "hevc"), (1, "opus")):
            value = deepcopy(valid)
            value["streams"][kind]["codec_name"] = codec
            with self.assertRaises(s.Failure):
                s.check_tracks(value, True)
        for duration in ("0", "nan", "inf", "-1"):
            value = deepcopy(valid)
            value["format"]["duration"] = duration
            with self.assertRaises(s.Failure):
                s.check_tracks(value, True)
        value = deepcopy(valid)
        value["streams"].pop()
        with self.assertRaises(s.Failure):
            s.check_tracks(value, True)

    def test_atom_order_and_lengths(self):
        def atom(kind):
            return struct.pack(">I4s", 8, kind)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.mp4"
            path.write_bytes(atom(b"ftyp") + atom(b"moov") + atom(b"mdat"))
            s.faststart(path)
            for data in (atom(b"ftyp") + atom(b"mdat") + atom(b"moov"), b"invalid", atom(b"ftyp")):
                path.write_bytes(data)
                with self.assertRaises(s.Failure):
                    s.faststart(path)

    def test_worker_timeout_and_exit_codes(self):
        for returncode, status in ((10, 413), (11, 422), (12, 502), (-9, 502)):
            process = MagicMock()
            process.__enter__.return_value = process
            process.wait.return_value = returncode
            with patch.object(s.subprocess, "Popen", return_value=process) as popen, self.assertRaises(s.Failure) as caught:
                s.run_worker(POST_ID, "/tmp/fixture")
            self.assertEqual(caught.exception.status, status)
            process.wait.assert_called_once_with(timeout=43)
            self.assertTrue(popen.call_args.kwargs["start_new_session"])
            self.assertNotIn("preexec_fn", popen.call_args.kwargs)
        process = MagicMock()
        process.__enter__.return_value = process
        process.pid = 12345
        process.wait.side_effect = [subprocess.TimeoutExpired("worker", 43), -9]
        with patch.object(s.subprocess, "Popen", return_value=process), patch.object(s.os, "killpg") as killpg, self.assertRaises(s.Failure) as caught:
            s.run_worker(POST_ID, "/tmp/fixture")
        self.assertEqual(caught.exception.status, 502)
        killpg.assert_called_once_with(12345, s.signal.SIGKILL)
        self.assertEqual(process.wait.call_count, 2)


if __name__ == "__main__":
    unittest.main()
