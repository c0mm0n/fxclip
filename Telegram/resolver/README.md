# Private Facebook metadata resolver

This sidecar runs the complete [Facebed source](https://github.com/facebed/facebed/tree/ccc612c6d99bdd126b3a6f5ea3fe9fb88ee04e72), privately. It serves upstream's Bottle application on internal port `9812`; the bot retains responsibility for downloading and sending video. It never calls the public `facebed.com` service. Use only on the bot's private container network, with no published host port.

The source is fetched during image construction, without GitHub credentials:

- Facebed revision: `ccc612c6d99bdd126b3a6f5ea3fe9fb88ee04e72`.
- [Source archive](https://codeload.github.com/facebed/facebed/tar.gz/ccc612c6d99bdd126b3a6f5ea3fe9fb88ee04e72) SHA-256: `c72514385f302a298c6bcc42e487df165e2bb8e45dcb38435e8c5073978e2e86`.
- Base: `python:3.14-slim`, pinned to manifest `sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8`.
- `requirements.txt` must exactly match upstream's seven pinned requirements. `requirements.lock` also freezes their runtime transitive dependencies. The resulting image records `REVISION`, upstream's README, and `dependency-freeze.txt` in `/opt/facebed`. Python package build tooling is not a reproducible wheel lock.

Facebed remains in `/opt/facebed`, separate from the fxclip runtime. Its scraper and parser routing are unchanged. Attribution belongs to the Facebed project and its contributors; the pinned archive contains no standalone LICENSE file.

## Build, run and offline checks

Run from the repository root:

```sh
docker build -f Telegram/resolver/Dockerfile -t fxclip-facebook-resolver:local .
```

Entrypoint: `python /service/service.py`. The image runs as UID/GID `10002:10002`. The root Compose configuration must apply `read_only: true`, an ephemeral `/tmp` tmpfs, `cap_drop: [ALL]`, `no-new-privileges`, `logging: {driver: none}`, memory/PID limits, reduced CPU shares, and no host `ports`, secrets or persistent volumes. CPU shares lower its scheduling priority under contention; they are not a hard CPU quota. These runtime options cannot be enforced by a Dockerfile. The service reads no configuration file or webhook environment variable.

Example isolated local smoke container, with no published port and no external network:

```sh
docker run -d --name fxclip-resolver-smoke --network none \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges --log-driver none \
  fxclip-facebook-resolver:local
docker exec fxclip-resolver-smoke python /service/healthcheck.py
docker rm -f fxclip-resolver-smoke
```

The built-in Docker healthcheck uses `/service/healthcheck.py`, which fetches only loopback `/healthz`. The existing Facebed health route returns status, uptime and request/error counts, without URLs or titles. Health is a process probe; it does not establish that Facebook accepts the NAS IP.

Tests use `unittest` and stdlib mocks, the real pinned Bottle routes and upstream CFFI redirect loop. They do not make Facebook requests. A loopback HTTP server verifies concurrency and malformed-request privacy. Mount only the test directory into the built image:

```sh
docker run --rm --network none --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges \
  --mount "type=bind,src=$PWD/Telegram/resolver/tests,dst=/tests,readonly" \
  --entrypoint python fxclip-facebook-resolver:local \
  -m unittest discover -s /tests -v
```

Read the exact installed dependency freeze without starting the server:

```sh
docker run --rm --network none --read-only --entrypoint cat \
  fxclip-facebook-resolver:local /opt/facebed/dependency-freeze.txt
```

## Audit of the pinned source and wrapper changes

- **Logs:** upstream configures Python logging at import, logs outbound URLs and resolution failures, and its optional `log_to_logger` plugin logs client addresses, URLs and titles. The wrapper disables all Python logging before import and again after `basicConfig`, removes handlers, and keeps a null handler to prevent implicit stderr reconfiguration. It never calls `main()`, `app.run()` or installs that plugin. The process also discards stdout/stderr at the file-descriptor level. The HTTP handler suppresses access/error logging and content-bearing parse errors. Unexpected application errors, Bottle errors and upstream scraper fallbacks yield only `Preview unavailable.` with no URL, exception or response body. Health/exit status provides operational feedback.
- **Discord:** `Utils.warn` creates a thread that can send messages, embeds and body attachments. `_send_dump_report` and `_send_restricted_page_report` assemble those reports. The wrapper forcibly sets `notifier_webhook` to an empty string and replaces all three functions with no-ops; tests verify no webhook construction or thread creation even if that config value is later set. Discord's package remains installed because the unchanged source imports it.
- **Files and retained data:** upstream's only explicit file reads are the static index and optional YAML config; the wrapper does not invoke the config-reading `main()`. No explicit application file writes or disk media cache were found. Upstream's CFFI cache, response records and cookies live only for one request scope and are discarded on exit. The wrapper keeps bounded page bytes in memory and disables Python bytecode writes. Runtime is compatible with a read-only root and ephemeral `/tmp`; no credentials or Facebook login cookies are supplied.
- **Routes:** the WSGI boundary accepts only bodyless GET/HEAD requests. Only literal `/healthz` with no query may access a control route. It rejects `/dump` at any path segment, static/config/admin/login/update control routes, traversal, backslashes, control bytes and encoded path separators. It inspects repeated percent-decoding layers and rejects excessive nesting before Bottle sees the request. The original content path and query are otherwise passed through unchanged.
- **Outbound requests:** upstream `CFFI._request` already follows redirects manually with libcurl auto-follow disabled, but permits arbitrary HTTP(S) redirect hosts. Validating only `_request`'s initial URL would miss those hops. The wrapper subclasses its session transport, checking every request in the unchanged redirect loop. It permits only HTTPS, normal TLS verification, port 443, no userinfo, and `facebook.com`, `fbcdn.net`, `fbsbx.com` or their true subdomains. Ambient proxies are disabled. HTTP downgrade, public Facebed, Discord, IP literals and other destinations are blocked before network I/O. This is a transport allowlist, not a network firewall or independent DNS/IP pinning.
- **Media metadata:** Facebed can emit arbitrary HTTPS media URLs from the parsed page. This service returns those metadata bytes and does not fetch video; the bot must retain its own URL/redirect/size checks for media downloads. The wrapper does not add alternative scraper logic or emulate successful Facebook resolution.
- **Bounds:** two concurrent HTTP workers, four queued sockets, five-second socket I/O timeout, 8 KiB request target, 16 KiB request headers and no request body. Each metadata request has a 25-second outbound budget, at most 12 transport calls, no upstream retry, at most 16 MiB of decoded upstream bodies in aggregate, and a 2 MiB final response. libcurl auto-redirect and streaming/background downloads are disabled. The content callback returns `CURL_WRITEFUNC_ERROR` on overflow; `curl_cffi==0.15.0` ignores ordinary short writes. The outbound budget bounds network I/O, not a hard interruption of Python HTML parsing; container resource limits bound pathological parsing.

No real Facebook request is part of these checks. Public content availability, authentication walls, rate limits and NAS connectivity require the separately authorized integration check before activating the bot option.
