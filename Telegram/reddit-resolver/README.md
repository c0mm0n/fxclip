# Private Reddit video resolver

Private sidecar for the Telegram bot, internal HTTP port **9813**, UID/GID
**10003:10003**. It returns a completed MP4 containing H.264 video and AAC audio
when the original has audio. No public vxReddit service, upstream Flask routes,
Reddit login, cookies, PRAW calls, persistent state or media cache is used.
Deployment and bot activation belong to the parent integration.

## Exact API

| Request | Response |
| --- | --- |
| `GET /healthz` | `200`, `text/plain`, `ok\n`; local process health only |
| `GET /video/<id>.mp4` | `200`, `video/mp4`, exact `Content-Length`, at most 20 MiB |

`id` is **1–32 ASCII lowercase letters or digits**. The literal request target
must match; queries (even an empty `?`), percent encoding, fragments, extra
slashes, absolute URLs and other routes are rejected. No request body,
`Transfer-Encoding` or `Expect` is accepted. No authentication mechanism is
implemented: keep this on the bot's private network with **no published port**.

Errors contain only `Video unavailable.\n`, with exact length and no URL, post
content, exception, title or identity. Responses use `Cache-Control: no-store`
and close the connection. Statuses:

- `413`: all usable renditions exceed the size preflight or final output cap.
- `422`: unsupported post/manifest/codec, unavailable original audio, or invalid media.
- `502`: upstream/network failure, mismatched post ID, resource validation failure,
  exhausted budget, worker failure or timeout.
- `503`: a video is already being resolved or sent; retry later.
- `404`: target outside the two literal routes; `400`: invalid/body-bearing request;
  unsupported HTTP methods return `501` with the same generic error.

There are no range, proxy, URL-input, public preview or configuration endpoints.

## Pinned upstream and dependencies

The image fetches and checksum-verifies the **complete**
[vxReddit archive](https://codeload.github.com/dylanpdx/vxReddit/tar.gz/990860a01ca865774b0e77b5de9af76b54947900)
at build time, including its `LICENSE.txt`, templates and original source.

- Revision: `990860a01ca865774b0e77b5de9af76b54947900`.
- Archive SHA-256: `946fadb5a0c68e7b0ce6064e66563cfa6f25580b9cbd84f02ead7f1c41caf443`.
- License: WTFPL version 2, December 2004. The original license and source are
  retained in `/opt/vxreddit` with `REVISION` and `ARCHIVE_SHA256` records.
- Base: `python:3.14-slim@sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8`,
  the same pinned base as the Facebook sidecar; verified on Linux amd64.
- `requirements.txt` lists the import dependencies. `requirements.lock` pins all
  20 runtime packages and their wheel SHA-256 hashes for CPython 3.14 / Linux
  amd64. Installation requires hashes and binary wheels. Flask/Werkzeug and
  other import dependencies use compatible current versions; this does not
  claim byte-for-byte equivalence to upstream's old requirements file.
- Debian ffmpeg/ffprobe are installed without recommends. Their exact versions
  and all installed Debian packages are recorded in `/opt/versions/ffmpeg.txt`,
  `ffprobe.txt` and `debian-packages.lock`. The apt repository is mutable; its
  packages are version-recorded rather than snapshot-pinned.
- Installed Python versions: `/opt/vxreddit/dependency-freeze.txt`; the wheel
  lock is also retained in `/opt/versions/requirements.lock`.

`upstream_adapter.py` imports the real `vxreddit.py` and uses its unchanged
`embed_info_from_post` function, not a rewritten parser. Fixed
`RUNNING_SERVERLESS=1` and `DOMAINNAME=reddit-resolver.invalid` avoid upstream's
config-file write. Ambient environment is cleared; PRAW configuration is blank,
PRAW and upstream requests are disabled, and upstream's WSGI application and
video-combiner entry points cannot run. Its `get_video_urls` hook extracts the
HLS master URL; only the local validated resolver selects and retrieves media.

## Resolution and bounds

Metadata is fetched only from
`https://api.reddit.com/comments/<id>?raw_json=1`, using the proven
`TelegramBot (like TwitterBot)` User-Agent. The returned post ID must match.
Only completed native hosted videos in a public subreddit are supported;
text, images, galleries, external video, private or removed posts return a
generic error. There is no adult-content policy filter.

The pinned `m3u8` parser reads master and VOD media playlists. Renditions are
ordered by resolution, then bandwidth; the corresponding audio group is
required if metadata says the original has audio. Every segment and init map
must reference the same actual `.mp4` resource under the same media ID.
Encrypted/live/multiple-resource media playlists are unsupported. Resource
names come from the parsed manifest; the service never substitutes `.mp4` for
an untrusted `.m3u8` URL or fetches a fallback URL.

Only HTTPS with exact host `v.redd.it`, no userinfo, explicit port, fragment,
encoded path or traversal is allowed for media. Every reference is validated
before and after resolution. Redirects are never followed. Stdlib HTTPS uses
normal TLS verification and no proxy discovery, requests session, `.netrc`,
cookie jar or authorization headers.

HEAD supplies exact resource sizes. Preflight conservatively requires the sum
of complete video and required audio resources to fit **20 MiB**. Downloads
must match those lengths. This conservative input bound can skip a rendition
just above 20 MiB even when stripping MP4 container overhead might make it fit;
no truncation or transcoding is attempted. The final remux is independently
checked against the 20 MiB output cap and an oversized result tries the next
lower rendition.

All ffmpeg/ffprobe inputs are **local MP4 files**, with `file,pipe` protocol and
`mov` format whitelists. Muxing explicitly maps video and required audio with
`-c copy`, strips source metadata/chapters and uses `+faststart`. ffprobe checks
H.264/AAC, positive finite duration and required tracks. Top-level MP4 atoms
must put `moov` before `mdat`. Missing original audio is never silently dropped.

Per video:

- **40 s** budget from transport creation through selection, downloads, probes,
  mux and output preparation; **43 s** hard timeout for the entire child worker,
  including imports. This stays below the bot's 50 s request / 60 s resource
  budgets. The HTTP transfer follows output preparation.
- Timeout starts a `SIGKILL` of the worker's **entire process group**, then waits
  for the worker. `Popen(start_new_session=True)` avoids threaded `preexec_fn`.
- At most **64** outbound requests and **64 MiB** of response bodies in total.
  Individual metadata is limited to **4 MiB** and manifests to **256 KiB**.
  Each TLS/socket wait is at most **6 s**, also subject to the worker timeout.
- At most 16 master variants, 16 media entries and 2,048 VOD segments per media
  playlist; response/request headers are limited to 16 KiB.
- One video worker, held until its response completes. Up to three bounded
  HTTP handler threads keep health responsive; the listen backlog is two.
  Busy video requests return `503`, with no application work queue or retry.
  Client socket waits are at most five seconds.
- Attempt files and the request directory are deleted on success, errors,
  timeout and disconnected clients. Parsed-manifest/HEAD reuse exists only
  within the current request; nothing is retained between requests.

## Build and offline checks

From the repository root:

```sh
docker build --platform linux/amd64 -f Telegram/reddit-resolver/Dockerfile \
  -t fxclip-reddit-resolver:nas .

docker run --rm --init --platform linux/amd64 --network none --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=128m --cap-drop ALL \
  --security-opt no-new-privileges --log-driver none \
  --memory 512m --pids-limit 64 --cpu-shares 256 \
  --mount "type=bind,src=$PWD/Telegram/reddit-resolver/tests,dst=/tests,readonly" \
  --entrypoint python fxclip-reddit-resolver:nas \
  -m unittest discover -s /tests -v
```

Module functions `parse_post`, `renditions`, `mp4_resource`, `resolve`, `probe`,
`check_tracks`, `faststart`, `mux` and `run_worker` are accessible to offline
tests. Tests generate generic H.264/AAC fixtures locally. They exercise the real
upstream parser, full local remux/decode, HTTP delivery, quality selection,
audio retention, URL/manifest rejection, byte/request/time bounds, size and
codec errors, temp cleanup, concurrent health, and real process-group timeout
with a grandchild. No real post, private media, credentials or live Reddit
requests are included in fixtures.

Read-only health smoke test, with no external network or published port:

```sh
docker run -d --name fxclip-reddit-resolver-smoke --init --network none \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=128m \
  --cap-drop ALL --security-opt no-new-privileges --log-driver none \
  --memory 512m --pids-limit 64 --cpu-shares 256 fxclip-reddit-resolver:nas
docker exec fxclip-reddit-resolver-smoke python /service/healthcheck.py
docker rm -f fxclip-reddit-resolver-smoke
```

Production Compose must apply those restrictions: `init: true`, read-only root,
128 MiB ephemeral `/tmp`, 512 MiB memory, bounded PIDs, CPU shares 256, all
capabilities dropped, no-new-privileges, logging driver `none`, no volumes,
credentials, environment configuration or host ports. CPU shares lower
scheduling priority under contention; they are not a hard CPU quota. Allow
outbound HTTPS to Reddit on the private network for actual resolution.

## Frozen validation record

Verified locally on 2026-10-25:

- Image: `fxclip-reddit-resolver:nas`, Linux amd64.
- Image ID: `sha256:94ed4ec18d92caaf7eecff1d34e35f99d60c5a333a7d05ebb947de0a47186fd1`.
- ffmpeg/ffprobe: `7.1.5-0+deb13u1`.
- **39 offline tests passed**, including the actual HTTP subprocess-group timeout
  and complete generated H.264/AAC decode, under the resource limits above.
- Read-only/no-network healthcheck passed as UID 10003; `/tmp` remained empty;
  logging `none`, no host port, capabilities dropped and resource limits inspected.

This does not establish live Reddit or NAS availability. The parent integration
performs the separately authorized exact-case NAS validation after this freeze.
No deployment, bot activation, Telegram call, clipboard access or Git operation
was performed by this subtree's implementation.
