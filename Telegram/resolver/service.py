"""Privacy boundary around the pinned Facebed Bottle app; no scraper code here."""
import contextvars
import importlib
import io
import logging
import re
import socketserver
import sys
import threading
import time
import warnings
from dataclasses import dataclass
from urllib.parse import unquote, urlsplit
from wsgiref.simple_server import ServerHandler, WSGIRequestHandler, WSGIServer, make_server

REQUEST_SECONDS = 25
MAX_UPSTREAM_REQUESTS = 12
MAX_UPSTREAM_BYTES = 16 * 1024 * 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_TARGET_BYTES = 8192
MAX_HEADER_BYTES = 16384
ERROR_BODY = b'Preview unavailable.\n'
_budget = contextvars.ContextVar('request_budget', default=None)
_control_routes = {
    'dump', 'control', 'healthz', 'assets', 'favicon.ico', 'banner.png',
    'update', 'admin', 'config', 'metrics', 'login', 'logout', 'checkpoint', 'recover',
}


def disable_logging():
    # Do this before import (upstream calls basicConfig) and again afterwards.
    logging.disable(sys.maxsize)
    logging.lastResort = None
    for logger in [logging.getLogger(), *list(logging.Logger.manager.loggerDict.values())]:
        if isinstance(logger, logging.Logger):
            logger.disabled = True
            for handler in logger.handlers[:]:
                logger.removeHandler(handler)
                handler.close()
    # A handler prevents logging.info()/critical() from implicitly reinstalling
    # basicConfig's stderr handler when upstream emits its next log call.
    logging.getLogger().addHandler(logging.NullHandler())
    warnings.simplefilter('ignore')


disable_logging()


@dataclass
class RequestBudget:
    deadline: float
    calls: int = 0
    received: int = 0


def allowed_upstream_url(url):
    """Validate every transport hop, rather than only the initial CFFI URL."""
    if not isinstance(url, str) or len(url) > MAX_TARGET_BYTES:
        return False
    if any(ord(char) <= 32 or ord(char) >= 127 for char in url) or '\\' in url:
        return False
    try:
        parsed = urlsplit(url)
        host = parsed.hostname or ''
        return (
            parsed.scheme == 'https' and parsed.port in (None, 443)
            and parsed.username is None and parsed.password is None
            and '%' not in parsed.netloc and not host.endswith('.')
            and any(host == domain or host.endswith('.' + domain)
                    for domain in ('facebook.com', 'fbcdn.net', 'fbsbx.com'))
        )
    except ValueError:
        return False


def restricted_session(base):
    class RestrictedSession(base):
        def __init__(self, *args, **kwargs):
            # Ignore ambient proxies and never read .netrc or persist cookies.
            kwargs['trust_env'] = False
            super().__init__(*args, **kwargs)

        def request(self, method, url, **kwargs):
            budget = _budget.get()
            if (method not in ('GET', 'HEAD') or not allowed_upstream_url(url)
                    or budget is None or budget.calls >= MAX_UPSTREAM_REQUESTS):
                raise ValueError('Upstream request refused')
            remaining = budget.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Upstream request timed out')
            budget.calls += 1
            body = io.BytesIO()
            connect_timeout = min(5.0, remaining / 2)

            def receive(chunk):
                if (time.monotonic() >= budget.deadline
                        or budget.received + len(chunk) > MAX_UPSTREAM_BYTES):
                    # curl_cffi 0.15 ignores short writes (including 0); only
                    # libcurl's explicit CURL_WRITEFUNC_ERROR actually aborts.
                    return 0xFFFFFFFF
                budget.received += len(chunk)
                body.write(chunk)
                return len(chunk)

            kwargs.update(
                allow_redirects=False, max_redirects=0,
                # curl_cffi adds connect + read to obtain total timeout.
                timeout=(connect_timeout, min(20.0, remaining - connect_timeout)),
                content_callback=receive, stream=False, verify=True,
                proxy='', proxies={},
            )
            result = super().request(method, url, **kwargs)
            # curl_cffi leaves content empty with a callback. Facebed expects
            # an ordinary in-memory Response; never use a download/media cache.
            result.content = body.getvalue()
            return result

    return RestrictedSession


def _noop(*args, **kwargs):
    return None


def load_facebed():
    disable_logging()
    facebed = importlib.import_module('facebed')
    disable_logging()
    facebed.config = dict(facebed.default_config, notifier_webhook='', timezone=0)
    facebed.Utils.warn = staticmethod(_noop)
    facebed._send_dump_report = _noop
    facebed._send_restricted_page_report = _noop
    facebed.CffiSession = restricted_session(facebed.CffiSession)
    facebed.CFFI.max_attempts = 1
    facebed.app.catchall = False

    def unavailable(_original_url):
        facebed.response.status = 502
        return ERROR_BODY.decode('ascii')

    facebed.format_error_message_embed = unavailable
    # Do not call main(), app.run(), or install the URL/title logging plugin.
    return facebed


def allowed_path(path):
    if not isinstance(path, str) or len(path) > MAX_TARGET_BYTES:
        return False
    if path == '/healthz':
        return True
    # Inspect every decoding layer; never rewrite the path passed to Bottle.
    for _ in range(16):
        if (not path.startswith('/') or path == '/' or '//' in path
                or '\\' in path or '?' in path or '#' in path
                or any(ord(char) < 32 or 127 <= ord(char) < 160 for char in path)
                or re.search(r'%(?:2f|5c)', path, re.IGNORECASE)):
            return False
        parts = path.strip('/').casefold().split('/')
        if (any(part in ('.', '..', 'dump') for part in parts)
                or parts[0].removesuffix('.php') in _control_routes):
            return False
        try:
            decoded = unquote(path, errors='strict')
        except UnicodeError:
            return False
        if decoded == path:
            return True
        path = decoded
    return False


def error_response(start_response, status):
    start_response(status, [
        ('Content-Type', 'text/plain; charset=utf-8'),
        ('Content-Length', str(len(ERROR_BODY))), ('Cache-Control', 'no-store'),
    ])
    return [ERROR_BODY]


class PrivacyBoundary:
    def __init__(self, app):
        self.app = app

    def __call__(self, environ, start_response):
        path = environ.get('PATH_INFO', '')
        query = environ.get('QUERY_STRING', '')
        if (environ.get('REQUEST_METHOD') not in ('GET', 'HEAD')
                or environ.get('CONTENT_LENGTH') not in ('', '0', None)
                or environ.get('HTTP_TRANSFER_ENCODING')):
            return error_response(start_response, '405 Method Not Allowed')
        if len(path) + len(query) > MAX_TARGET_BYTES:
            return error_response(start_response, '414 URI Too Long')
        if not allowed_path(path) or (path == '/healthz' and query):
            return error_response(start_response, '404 Not Found')
        captured = {}

        def capture(status, headers, exc_info=None):
            if exc_info:
                raise RuntimeError('Application failed')
            captured.update(status=status, headers=headers)
            # Bottle returns an iterable; a WSGI write() is deliberately refused.
            return lambda _data: (_ for _ in ()).throw(RuntimeError('Unsupported response'))

        token = _budget.set(RequestBudget(time.monotonic() + REQUEST_SECONDS))
        result = None
        try:
            environ['wsgi.errors'] = io.StringIO()  # no request traceback sink
            result = self.app(environ, capture)
            body = bytearray()
            for part in result:
                if len(body) + len(part) > MAX_RESPONSE_BYTES:
                    raise ValueError('Response too large')
                body.extend(part)
            if int(captured['status'].split()[0]) >= 400:
                return error_response(start_response, '502 Bad Gateway')
            start_response(captured['status'], captured['headers'])
            return [bytes(body)]
        except Exception:
            return error_response(start_response, '502 Bad Gateway')
        finally:
            if result is not None and hasattr(result, 'close'):
                # A generator close failure must not become a server traceback.
                try:
                    result.close()
                except Exception:
                    pass
            _budget.reset(token)


class QuietServerHandler(ServerHandler):
    def log_exception(self, exc_info):
        pass

    def error_output(self, environ, start_response):
        return error_response(start_response, '502 Bad Gateway')


class QuietHandler(WSGIRequestHandler):
    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def log_message(self, format, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        # BaseHTTPRequestHandler errors can otherwise include the request line.
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(ERROR_BODY)))
        self.end_headers()
        self.wfile.write(ERROR_BODY)

    def handle(self):
        self.raw_requestline = self.rfile.readline(MAX_TARGET_BYTES + 1)
        if len(self.raw_requestline) > MAX_TARGET_BYTES:
            self.requestline = self.request_version = self.command = ''
            self.send_error(414)
            return
        if not self.parse_request():
            return
        if sum(len(k) + len(v) + 4 for k, v in self.headers.items()) > MAX_HEADER_BYTES:
            self.send_error(431)
            return
        handler = QuietServerHandler(self.rfile, self.wfile, io.StringIO(), self.get_environ(),
                                     multithread=True)
        handler.request_handler = self
        handler.run(self.server.get_app())


class BoundedServer(socketserver.ThreadingMixIn, WSGIServer):
    daemon_threads = True
    request_queue_size = 4

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(2)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(b'HTTP/1.0 503 Service Unavailable\r\nContent-Length: 21\r\n\r\n'
                                + ERROR_BODY)
            except OSError:
                pass
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        pass


def main():
    # Suppress even third-party print(), warnings and native-library stderr.
    # Startup failure is observable through exit status/health, never its content.
    import os
    with open(os.devnull, 'w') as sink:
        os.dup2(sink.fileno(), 1)
        os.dup2(sink.fileno(), 2)
    try:
        application = PrivacyBoundary(load_facebed().app)
        with make_server('0.0.0.0', 9812, application,
                         server_class=BoundedServer, handler_class=QuietHandler) as server:
            server.serve_forever()
    except Exception:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
