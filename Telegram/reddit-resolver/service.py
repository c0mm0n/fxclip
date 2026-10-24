"""Private, stateless native Reddit video resolver. No upstream web routes."""
from contextlib import contextmanager
from dataclasses import dataclass
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import math
import os
from pathlib import Path
import re
import signal
import socket
from socketserver import ThreadingMixIn
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urljoin, urlsplit

import m3u8
from upstream_adapter import embed_info_from_post

MIB = 1024 * 1024
CAP = 20 * MIB
MAX_NETWORK = 64 * MIB
MAX_REQUESTS = 64
SECONDS = 40
WORKER_SECONDS = 43
ID = re.compile(r"[a-z0-9]{1,32}", re.ASCII)
MEDIA_PATH = re.compile(r"/([a-z0-9]{1,64})/([A-Za-z0-9_.-]{1,128})", re.ASCII)
ROUTE = re.compile(r"/video/([a-z0-9]{1,32})\.mp4", re.ASCII)


class Failure(Exception):
    def __init__(self, status=502):
        self.status = status
        super().__init__("Video unavailable.")


def media_url(url, media_id=None, suffix=None):
    """No URL normalisation before validation, credentials, ports or redirects."""
    if not isinstance(url, str) or len(url) > 2048 or not url.isascii():
        raise Failure()
    if any(ord(c) <= 32 or ord(c) == 127 for c in url) or "\\" in url:
        raise Failure()
    parts = urlsplit(url)
    match = MEDIA_PATH.fullmatch(parts.path)
    if (parts.scheme != "https" or parts.netloc != "v.redd.it" or
            parts.fragment or not match or match[2] in (".", "..") or
            (media_id is not None and match[1] != media_id) or
            (suffix and not match[2].endswith(suffix))):
        raise Failure()
    return url, match[1]


def reference(base, uri, media_id, suffix):
    # Validate the reference before urljoin can erase dot segments or whitespace.
    if (not isinstance(uri, str) or not uri or len(uri) > 2048 or
            not uri.isascii() or "\\" in uri or "%" in uri or
            any(ord(c) <= 32 or ord(c) == 127 for c in uri) or
            any(p in (".", "..") for p in urlsplit(uri).path.split("/"))):
        raise Failure()
    return media_url(urljoin(base, uri), media_id, suffix)[0]


class Transport:
    """Explicit stdlib HTTPS; no requests sessions, env, proxies or cookie jar."""
    def __init__(self, post_id):
        if not ID.fullmatch(post_id):
            raise Failure(422)
        self.metadata_url = f"https://api.reddit.com/comments/{post_id}?raw_json=1"
        self.deadline = time.monotonic() + SECONDS
        self.bytes_left = MAX_NETWORK
        self.requests_left = MAX_REQUESTS
        self.context = ssl.create_default_context()

    def remaining(self):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise Failure()
        return left

    @contextmanager
    def response(self, url, method):
        if url != self.metadata_url:
            media_url(url)
        if self.requests_left <= 0:
            raise Failure()
        self.requests_left -= 1
        parts = urlsplit(url)
        conn = http.client.HTTPSConnection(parts.hostname, 443, context=self.context,
                                            timeout=min(6, self.remaining()))
        conn.response_class = BoundedResponse
        try:
            path = parts.path + ("?" + parts.query if parts.query else "")
            conn.request(method, path, headers={
                "User-Agent": "TelegramBot (like TwitterBot)",
                "Accept-Encoding": "identity", "Connection": "close",
            })
            response = conn.getresponse()
            if response.status != 200 or response.getheader("Content-Encoding", "identity") != "identity":
                raise Failure()
            yield response, conn
        except (OSError, ValueError, http.client.HTTPException) as exc:
            raise Failure() from exc
        finally:
            conn.close()

    @staticmethod
    def length(response):
        values = response.headers.get_all("Content-Length", [])
        if (len(values) != 1 or not re.fullmatch(r"[0-9]{1,12}", values[0]) or
                response.getheader("Transfer-Encoding")):
            raise Failure()
        value = int(values[0])
        if value <= 0:
            raise Failure()
        return value

    def head(self, url):
        with self.response(url, "HEAD") as (response, _):
            return self.length(response)

    def get(self, url, limit, destination=None, expected=None):
        with self.response(url, "GET") as (response, conn):
            # Reddit JSON may be chunked. Binary downloads require exact length.
            lengths = response.headers.get_all("Content-Length", [])
            declared = self.length(response) if lengths else None
            if expected is not None and declared != expected:
                raise Failure()
            if declared is not None and declared > limit:
                raise Failure()
            data = bytearray() if destination is None else None
            total = 0
            while True:
                if conn.sock:
                    conn.sock.settimeout(min(6, self.remaining()))
                self.remaining()
                block = response.read1(min(65536, limit - total + 1, self.bytes_left + 1))
                if not block:
                    break
                total += len(block)
                self.bytes_left -= len(block)
                if total > limit or self.bytes_left < 0:
                    raise Failure()
                if destination is None:
                    data.extend(block)
                else:
                    destination.write(block)
            if (declared is not None and total != declared) or (expected is not None and total != expected):
                raise Failure()
            return bytes(data) if data is not None else total


def parse_post(document, post_id):
    """Strict native/public gate, then the actual pinned upstream post parser."""
    try:
        children = document[0]["data"]["children"]
        if len(children) != 1 or children[0]["kind"] != "t3":
            raise Failure()
        post = children[0]["data"]
        if post["id"] != post_id:
            raise Failure()
        if (post.get("subreddit_type") != "public" or post.get("removed_by_category") or
                post.get("removed") or post.get("is_self") or post.get("is_video") is not True or
                post.get("post_hint") != "hosted:video" or post.get("domain") != "v.redd.it"):
            raise Failure(422)
        video = post["media"]["reddit_video"]
        if video.get("transcoding_status") != "completed" or not isinstance(video.get("has_audio"), bool):
            raise Failure(422)
        # Do not infer audio absence from a missing group/metadata key.
        info = embed_info_from_post(post)
        if info["post_type"] != "video":
            raise Failure(422)
        master, media_id = media_url(info["video_url"], suffix=".m3u8")
        origin = urlsplit(post["url"])
        if (origin.scheme != "https" or origin.netloc != "v.redd.it" or
                origin.path not in (f"/{media_id}", f"/{media_id}/") or origin.fragment):
            raise Failure()
        return master, media_id, video["has_audio"]
    except Failure:
        raise
    except (KeyError, IndexError, TypeError, AttributeError, ValueError) as exc:
        raise Failure() from exc


def playlist(text):
    if not text.startswith("#EXTM3U") or len(text) > 256 * 1024:
        raise Failure()
    try:
        result = m3u8.loads(text)
        if result.keys and any(k and k.method != "NONE" for k in result.keys):
            raise Failure(422)
        return result
    except (ValueError, TypeError, KeyError, AttributeError) as exc:
        raise Failure() from exc


@dataclass(frozen=True)
class Rendition:
    video: str
    audio: str | None
    quality: tuple


def renditions(text, base, media_id, has_audio):
    master = playlist(text)
    if not master.is_variant or not 1 <= len(master.playlists) <= 16 or len(master.media) > 16:
        raise Failure(422)
    results = []
    for entry in master.playlists:
        info = entry.stream_info
        codecs = (info.codecs or "").split(",")
        if not any(c.startswith(("avc1.", "avc3.")) for c in codecs):
            continue
        if has_audio and not any(c.startswith("mp4a.40.") for c in codecs):
            continue
        video = reference(base, entry.uri, media_id, ".m3u8")
        audio = None
        if has_audio:
            choices = [m for m in master.media if m.type == "AUDIO" and m.group_id == info.audio and m.uri]
            if len(choices) != 1:
                continue
            audio = reference(base, choices[0].uri, media_id, ".m3u8")
        width, height = info.resolution or (0, 0)
        if not 0 < width <= 8192 or not 0 < height <= 8192:
            raise Failure(422)
        results.append(Rendition(video, audio, (height, width, info.bandwidth or 0)))
    if not results:
        raise Failure(422)
    return sorted(set(results), key=lambda r: r.quality, reverse=True)


def mp4_resource(text, base, media_id):
    """Accept VOD byte-range HLS only, backed by one actual MP4, including init."""
    media = playlist(text)
    if media.is_variant or not media.is_endlist or not 1 <= len(media.segments) <= 2048:
        raise Failure(422)
    resource = None
    end = None
    for segment in media.segments:
        init = segment.init_section
        if not init or not init.uri or not init.byterange or segment.discontinuity or segment.gap_tag:
            raise Failure(422)
        current = reference(base, segment.uri, media_id, ".mp4")
        if reference(base, init.uri, media_id, ".mp4") != current or (resource and resource != current):
            raise Failure()
        resource = current
        if not re.fullmatch(r"[1-9][0-9]{0,10}@0", init.byterange):
            raise Failure()
        if not segment.byterange or not re.fullmatch(r"[1-9][0-9]{0,10}(?:@[0-9]{1,11})?", segment.byterange):
            raise Failure(422)
        values = segment.byterange.split("@")
        offset = int(values[1]) if len(values) == 2 else end
        if offset is None or offset < int(init.byterange.split("@")[0]) or (end is not None and offset < end):
            raise Failure()
        if not math.isfinite(segment.duration) or segment.duration <= 0:
            raise Failure()
        end = offset + int(values[0])
        if end > 512 * MIB:
            raise Failure(422)
    return resource, end


def probe(path, timeout=10):
    command = ["/usr/bin/ffprobe", "-v", "error", "-protocol_whitelist", "file,pipe",
               "-format_whitelist", "mov", "-show_entries",
               "stream=codec_type,codec_name,duration,width,height:format=duration",
               "-of", "json", str(path)]
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=timeout, check=False)
        if result.returncode or len(result.stdout) > 65536:
            raise Failure(422)
        return json.loads(result.stdout)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        raise Failure(422) from exc


def check_tracks(info, has_audio, audio_only=False):
    try:
        streams = info["streams"]
        videos = [s for s in streams if s["codec_type"] == "video"]
        audios = [s for s in streams if s["codec_type"] == "audio"]
        if audio_only:
            valid = len(streams) == 1 and len(audios) == 1 and audios[0]["codec_name"] == "aac"
        else:
            valid = (len(videos) == 1 and videos[0]["codec_name"] == "h264" and
                     videos[0]["width"] > 0 and videos[0]["height"] > 0 and
                     len(audios) == int(has_audio) and len(streams) == 1 + int(has_audio) and
                     (not has_audio or audios[0]["codec_name"] == "aac"))
        duration = float(info["format"]["duration"])
        if not valid or not math.isfinite(duration) or duration <= 0:
            raise Failure(422)
        if has_audio and not audio_only:
            duration = float(audios[0]["duration"])
            if not math.isfinite(duration) or duration <= 0:
                raise Failure(422)
    except (KeyError, TypeError, ValueError, IndexError) as exc:
        raise Failure(422) from exc


def faststart(path):
    size = path.stat().st_size
    offset, moov, mdat = 0, None, None
    with path.open("rb") as stream:
        while offset < size:
            stream.seek(offset)
            header = stream.read(8)
            if len(header) != 8:
                raise Failure(422)
            length, kind = struct.unpack(">I4s", header)
            minimum = 8
            if length == 1:
                value = stream.read(8)
                if len(value) != 8:
                    raise Failure(422)
                length = struct.unpack(">Q", value)[0]
                minimum = 16
            elif length == 0:
                length = size - offset
            if length < minimum or offset + length > size:
                raise Failure(422)
            if kind == b"moov":
                moov = offset
            if kind == b"mdat" and mdat is None:
                mdat = offset
            offset += length
    if moov is None or mdat is None or moov >= mdat:
        raise Failure(422)


def mux(video, audio, output, timeout=20):
    command = ["/usr/bin/ffmpeg", "-nostdin", "-v", "error", "-y",
               "-protocol_whitelist", "file,pipe", "-format_whitelist", "mov", "-i", str(video)]
    if audio:
        command += ["-protocol_whitelist", "file,pipe", "-format_whitelist", "mov", "-i", str(audio)]
    command += ["-map", "0:v:0"]
    if audio:
        command += ["-map", "1:a:0"]
    command += ["-c", "copy", "-map_metadata", "-1", "-map_chapters", "-1",
                "-movflags", "+faststart", str(output)]
    try:
        result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=timeout, check=False)
        if result.returncode:
            raise Failure(422)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Failure(422) from exc


def resolve(post_id, directory, transport=None):
    """Offline-testable entry point. Caller owns/deletes the temporary directory."""
    if not ID.fullmatch(post_id):
        raise Failure(422)
    net = transport or Transport(post_id)
    directory = Path(directory)
    try:
        document = json.loads(net.get(net.metadata_url, 4 * MIB))
        master, media_id, has_audio = parse_post(document, post_id)
        candidates = renditions(net.get(master, 256 * 1024).decode("utf-8"), master, media_id, has_audio)
        # Request-scoped manifest/HEAD memo only; never retained across copies.
        manifests, sizes = {}, {}
        def resource(url):
            if url not in manifests:
                manifests[url] = mp4_resource(net.get(url, 256 * 1024).decode("utf-8"), url, media_id)
            file_url, extent = manifests[url]
            if file_url not in sizes:
                sizes[file_url] = net.head(file_url)
            if sizes[file_url] < extent:
                raise Failure()
            return file_url, sizes[file_url]
        oversized = False
        failed = None
        for candidate in candidates:
            try:
                video_url, video_size = resource(candidate.video)
                audio_url, audio_size = resource(candidate.audio) if has_audio else (None, 0)
                if video_url == audio_url:
                    raise Failure(422)
                if video_size + audio_size > CAP:
                    oversized = True
                    continue
                # Each attempt removes all its input and output bytes before retry.
                with tempfile.TemporaryDirectory(dir=directory) as attempt:
                    attempt = Path(attempt)
                    video, audio, output = attempt / "video.mp4", attempt / "audio.mp4", attempt / "result.mp4"
                    with video.open("wb") as stream:
                        net.get(video_url, CAP, stream, expected=video_size)
                    check_tracks(probe(video, min(10, net.remaining())), False)
                    if has_audio:
                        with audio.open("wb") as stream:
                            net.get(audio_url, CAP, stream, expected=audio_size)
                        check_tracks(probe(audio, min(10, net.remaining())), True, audio_only=True)
                    mux(video, audio if has_audio else None, output, min(20, net.remaining()))
                    check_tracks(probe(output, min(10, net.remaining())), has_audio)
                    faststart(output)
                    if output.stat().st_size > CAP:
                        oversized = True
                        continue
                    net.remaining()
                    final = directory / "result.mp4"
                    output.replace(final)
                    return final
            except Failure as exc:
                failed = exc
        # A failed fetch/codec is never reported as a proven size-only failure.
        if failed:
            raise failed
        raise Failure(413 if oversized else 422)
    except Failure:
        raise
    except (OSError, ValueError, TypeError, KeyError, http.client.HTTPException) as exc:
        raise Failure() from exc


def run_worker(post_id, directory):
    try:
        # A killable process also bounds DNS stalls and media parser CPU time.
        with subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--resolve", post_id, str(directory)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              start_new_session=True) as process:
            try:
                returncode = process.wait(timeout=WORKER_SECONDS)
            except BaseException:
                # No preexec_fn in this threaded server. A separate session lets
                # us kill ffmpeg/ffprobe too, including a stuck child of either.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                raise
    except (OSError, subprocess.SubprocessError) as exc:
        raise Failure() from exc
    if returncode:
        raise Failure({10: 413, 11: 422}.get(returncode, 502))
    output = Path(directory) / "result.mp4"
    if not output.is_file() or not 0 < output.stat().st_size <= CAP:
        raise Failure()
    return output


class HeaderReader:
    def __init__(self, stream):
        self.stream, self.remaining = stream, 16 * 1024

    def readline(self, limit=-1):
        value = self.stream.readline(min(self.remaining + 1, limit if limit >= 0 else self.remaining + 1))
        self.remaining -= len(value)
        if self.remaining < 0:
            raise Failure(400)
        return value

    def close(self):
        self.stream.close()


class BoundedResponse(http.client.HTTPResponse):
    def begin(self):
        original = self.fp
        self.fp = HeaderReader(original)
        try:
            return super().begin()
        finally:
            # HEAD responses may close self.fp while parsing the headers.
            if self.fp is not None:
                self.fp = original


class Handler(BaseHTTPRequestHandler):
    server_version = ""
    sys_version = ""

    def setup(self):
        super().setup()
        self.rfile = HeaderReader(self.rfile)

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except Failure:
            self.send_error(400)
        except (OSError, ValueError):
            pass

    def send_error(self, code, *args, **kwargs):
        self.close_connection = True
        try:
            self.reply(code, b"Video unavailable.\n")
        except (OSError, ValueError):
            pass

    def reply(self, status, body, content_type="text/plain"):
        self.send_response_only(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.close_connection = True
        lengths = self.headers.get_all("Content-Length", [])
        if lengths not in ([], ["0"]) or any(self.headers.get(k) is not None for k in ("Transfer-Encoding", "Expect")):
            self.send_error(400)
            return
        # BaseHTTPRequestHandler collapses leading //; inspect the raw target too.
        raw = self.requestline.split()
        target = raw[1] if len(raw) == 3 else ""
        if target == "/healthz":
            self.reply(200, b"ok\n")
            return
        match = ROUTE.fullmatch(target)
        if not match:
            self.send_error(404)
            return
        if not self.server.video_slot.acquire(blocking=False):
            self.send_error(503)
            return
        started = False
        try:
            with tempfile.TemporaryDirectory(prefix="reddit-") as directory:
                output = self.server.resolve_video(match[1], directory)
                with output.open("rb") as video:
                    started = True
                    self.send_response_only(200)
                    self.send_header("Content-Type", "video/mp4")
                    self.send_header("Content-Length", str(output.stat().st_size))
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    while block := video.read(65536):
                        self.wfile.write(block)
        except Failure as exc:
            if not started:
                self.send_error(exc.status)
        except Exception:
            if not started:
                self.send_error(502)
        finally:
            self.server.video_slot.release()


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    request_queue_size = 2

    def __init__(self, address, resolve_video=run_worker):
        self.handlers = threading.BoundedSemaphore(3)
        self.video_slot = threading.BoundedSemaphore(1)
        self.resolve_video = resolve_video
        super().__init__(address, Handler)

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(5)
        return request, address

    def process_request(self, request, address):
        if not self.handlers.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.handlers.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.handlers.release()

    def handle_error(self, *args):
        pass


def main():
    # Never emit access logs, tracebacks, upstream prints or media diagnostics.
    with open(os.devnull, "w") as null:
        os.dup2(null.fileno(), 1)
        os.dup2(null.fileno(), 2)
    if len(sys.argv) == 4 and sys.argv[1] == "--resolve":
        try:
            resolve(sys.argv[2], Path(sys.argv[3]))
            return 0
        except Failure as exc:
            return {413: 10, 422: 11}.get(exc.status, 12)
        except Exception:
            return 12
    if len(sys.argv) != 1:
        return 12
    Server(("0.0.0.0", 9813)).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
