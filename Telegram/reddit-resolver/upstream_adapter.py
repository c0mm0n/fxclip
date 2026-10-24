"""Import the complete pinned upstream, exposing only its post parser."""
import logging
import os
import sys

# No ambient credentials, proxies, config files, HOME or .netrc. In particular,
# config.py must take its non-writing serverless branch before vxreddit imports.
os.environ.clear()
os.environ.update({
    "RUNNING_SERVERLESS": "1", "DOMAINNAME": "reddit-resolver.invalid",
    "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": "/opt/python", "TMPDIR": "/tmp",
})
sys.dont_write_bytecode = True
logging.disable(logging.CRITICAL)
sys.path.insert(0, "/opt/vxreddit")
import vxreddit as upstream  # noqa: E402


def forbidden(*args, **kwargs):
    raise RuntimeError("Disabled upstream transport")


class DisabledTransport:
    def __getattr__(self, name):
        return forbidden


upstream.requests = DisabledTransport()
upstream.praw = DisabledTransport()
upstream.get_embed_info_from_url_praw = lambda *args: None
upstream.get_embed_info_from_url = forbidden
upstream.videoCombiner.combine_videos = forbidden
upstream.videoCombiner.video_from_id = forbidden
upstream.app.wsgi_app = forbidden
for key in ("praw_client_id", "praw_client_secret", "praw_user_agent"):
    upstream.config.currentConfig["MAIN"][key] = ""
upstream.r_headers = {}

# Keep embed_info_from_post unchanged. Its get_video_urls hook now extracts the
# master manifest only. service.py performs bounded, validated HLS selection;
# upstream's m3u8.load / fallback URL and network ffmpeg paths are never used.
upstream.get_video_urls = lambda post: (post["media"]["reddit_video"]["hls_url"], None)
embed_info_from_post = upstream.embed_info_from_post
