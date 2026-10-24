"""Offline stdlib tests. Run with the pinned upstream/dependencies in the image."""
import contextlib
import gzip
import http.server
import io
import json
import logging
import socket
import sys
import threading
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, '/service')
import service


def invoke(app, path='/reel/123', **extra):
    environ = {
        'PATH_INFO': path, 'QUERY_STRING': '', 'REQUEST_METHOD': 'GET',
        'SERVER_NAME': 'resolver', 'SERVER_PORT': '9812', 'SERVER_PROTOCOL': 'HTTP/1.1',
        'wsgi.version': (1, 0), 'wsgi.url_scheme': 'http', 'wsgi.input': io.BytesIO(),
        'wsgi.errors': io.StringIO(), 'wsgi.multithread': False,
        'wsgi.multiprocess': False, 'wsgi.run_once': False,
        'HTTP_USER_AGENT': 'TelegramBot (like TwitterBot)',
    }
    environ.update(extra)
    captured = {}

    def start(status, headers):
        captured.update(status=status, headers=dict(headers))

    captured['body'] = b''.join(service.PrivacyBoundary(app)(environ, start))
    return captured


class BoundaryTests(unittest.TestCase):
    def test_controls_blocked_before_application_including_recursive_encoding(self):
        app = mock.Mock(side_effect=AssertionError('Application must not run'))
        paths = (
            '/', '/dump', '/reel/123/dump', '/reel/123/DuMp/',
            '/reel/123/%64ump', '/reel/123/%2564ump', '/reel%2f123',
            '/reel%252f123', '/reel/123/%252e%252e', '/a/./b', '/a/../b',
            '/%68ealthz', '/%2568ealthz', '/healthz/', '/assets/index.html',
            '/update', '/control', '/config', '/login.php', '/checkpoint',
            '/recover', '/reel\\dump', '/reel/%255cdump', '//evil.test/reel',
            '/reel/%00', '/reel/%250a', '/reel/%ff', '/%25%36%34ump',
            '/reel/%25252fdump', '/reel/%2523dump', '/reel/%253fdump',
        )
        for path in paths:
            with self.subTest(path=path):
                self.assertEqual(invoke(app, path)['status'], '404 Not Found')
        app.assert_not_called()

    def test_content_paths_and_queries_reach_application_unchanged(self):
        for path in ('/reel/123', '/share/r/token', '/person/posts/pfbid123',
                     '/story.php', '/photo.php', '/groups/1/posts/2'):
            with self.subTest(path=path):
                def app(environ, start):
                    self.assertEqual(environ['PATH_INFO'], path)
                    self.assertEqual(environ['QUERY_STRING'], 'id=1&story_fbid=2')
                    self.assertIsNotNone(service._budget.get())
                    start('200 OK', [('Content-Type', 'text/html')])
                    return [b'<meta property="og:title" content="Example">']
                result = invoke(app, path, QUERY_STRING='id=1&story_fbid=2')
                self.assertEqual(result['status'], '200 OK')
        self.assertIsNone(service._budget.get())

    def test_no_bodies_or_other_methods(self):
        app = mock.Mock()
        for fields in ({'REQUEST_METHOD': 'POST'}, {'CONTENT_LENGTH': '1'},
                       {'HTTP_TRANSFER_ENCODING': 'chunked'}):
            self.assertEqual(invoke(app, **fields)['status'], '405 Method Not Allowed')
        self.assertEqual(invoke(app, '/a' * 5000)['status'], '414 URI Too Long')
        self.assertEqual(invoke(app, '/healthz', QUERY_STRING='url=private')['status'], '404 Not Found')
        app.assert_not_called()

    def test_error_body_headers_status_and_tracebacks_never_escape(self):
        secret = 'private-url-title-page-content'

        def exception(environ, start):
            raise RuntimeError(secret)

        def late_exception(environ, start):
            start('200 OK', [])
            yield secret.encode()
            raise RuntimeError(secret)

        def bottle_error(environ, start):
            environ['wsgi.errors'].write(secret)
            start('500 ' + secret, [('X-Error', secret)])
            return [secret.encode()]

        for app in (exception, late_exception, bottle_error):
            with self.subTest(app=app.__name__):
                output = io.StringIO()
                with contextlib.redirect_stderr(output):
                    result = invoke(app)
                self.assertEqual(result['status'], '502 Bad Gateway')
                self.assertEqual(result['body'], service.ERROR_BODY)
                self.assertNotIn(secret, repr(result))
                self.assertEqual(output.getvalue(), '')
        self.assertIsNone(service._budget.get())

    def test_response_size_is_bounded_and_iterator_closed(self):
        closed = []

        def app(environ, start):
            start('200 OK', [])
            try:
                yield b'x' * (service.MAX_RESPONSE_BYTES + 1)
            finally:
                closed.append(True)

        self.assertEqual(invoke(app)['status'], '502 Bad Gateway')
        self.assertEqual(closed, [True])


class TransportTests(unittest.TestCase):
    def test_only_https_facebook_and_cdn_hosts(self):
        for url in ('https://facebook.com/reel/1', 'https://www.facebook.com/a',
                    'https://m.facebook.com:443/a', 'https://video.xx.fbcdn.net/a',
                    'https://lookaside.fbsbx.com/a'):
            self.assertTrue(service.allowed_upstream_url(url), url)
        for url in ('http://www.facebook.com/a', 'file:///tmp/a',
                    'https://facebook.com.evil.test/a', 'https://evilfacebook.com/a',
                    'https://discord.com/api/webhooks/a', 'https://facebed.com/a',
                    'https://127.0.0.1/a', 'https://[::1]/a',
                    'https://www.facebook.com:9812/a', 'https://facebook.com./a',
                    'https://user:pass@facebook.com/a', 'https://facebook.com%00.evil/a',
                    'https://facebook.com\\@evil.test/a', 'https://facebook.com/\na',
                    'https://facebook.com:bad/a', 'https://facebook.com/é'):
            self.assertFalse(service.allowed_upstream_url(url), url)

    def test_budget_timeout_size_and_ambient_proxy_controls(self):
        calls = []

        class Base:
            def __init__(self, **kwargs):
                self.kwargs = kwargs

            def request(self, method, url, **kwargs):
                calls.append(kwargs)
                self.last_write = kwargs['content_callback'](b'body')
                return types.SimpleNamespace(content=b'')

        session = service.restricted_session(Base)()
        self.assertFalse(session.kwargs['trust_env'])
        token = service._budget.set(service.RequestBudget(time.monotonic() + 2))
        try:
            result = session.request('GET', 'https://facebook.com/a', timeout=999,
                                     allow_redirects=True, proxy='http://private:8080')
            self.assertEqual(result.content, b'body')
            self.assertFalse(calls[0]['allow_redirects'])
            self.assertEqual(calls[0]['max_redirects'], 0)
            self.assertLessEqual(calls[0]['timeout'][1], 2)
            self.assertLessEqual(sum(calls[0]['timeout']), 2)
            self.assertEqual(calls[0]['proxy'], '')
            self.assertEqual(calls[0]['proxies'], {})
            self.assertTrue(calls[0]['verify'])
            budget = service._budget.get()
            budget.received = service.MAX_UPSTREAM_BYTES
            session.request('GET', 'https://facebook.com/a')
            self.assertEqual(session.last_write, 0xFFFFFFFF)
            budget.calls = service.MAX_UPSTREAM_REQUESTS
            with self.assertRaises(ValueError):
                session.request('GET', 'https://facebook.com/a')
            budget.calls = 0
            budget.deadline = time.monotonic() - 1
            with self.assertRaises(TimeoutError):
                session.request('GET', 'https://facebook.com/a')
        finally:
            service._budget.reset(token)
        with self.assertRaises(ValueError):
            session.request('GET', 'https://facebook.com/a')


class UpstreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.facebed = service.load_facebed()

    def test_real_import_and_runtime_logs_are_silent(self):
        output = io.StringIO()
        handler = logging.StreamHandler(output)
        logger = logging.getLogger('privacy-test')
        logger.addHandler(handler)
        try:
            logging.critical('private URL')
            logger.critical('private title')
            self.assertEqual(output.getvalue(), '')
            self.assertGreaterEqual(logging.root.manager.disable, sys.maxsize)
            self.assertTrue(all(isinstance(h, logging.NullHandler)
                                for h in logging.getLogger().handlers))
            self.assertFalse(any(getattr(plugin, '__name__', '') == 'log_to_logger'
                                 for plugin in self.facebed.app.plugins))
        finally:
            logger.removeHandler(handler)

    def test_import_logging_disabled_before_basicconfig_and_after(self):
        output = io.StringIO()
        fake = types.SimpleNamespace(
            default_config={}, Utils=types.SimpleNamespace(),
            CffiSession=type('Session', (), {}), CFFI=types.SimpleNamespace(),
            app=types.SimpleNamespace(),
        )

        def importing(name):
            logging.basicConfig(handlers=[logging.StreamHandler(output)], force=True)
            logging.critical('import-private-url')
            return fake

        with mock.patch.object(service.importlib, 'import_module', side_effect=importing):
            service.load_facebed()
        self.assertEqual(output.getvalue(), '')
        self.assertTrue(all(isinstance(h, logging.NullHandler)
                            for h in logging.getLogger().handlers))

    def test_diagnostics_stay_disabled_even_if_webhook_is_set(self):
        facebed = self.facebed
        self.assertEqual(facebed.config['notifier_webhook'], '')
        with mock.patch.dict(facebed.config, notifier_webhook='https://discord.com/api/webhooks/unused'):
            with mock.patch.object(facebed, 'DiscordWebhook') as webhook:
                with mock.patch.object(facebed.threading, 'Thread') as thread:
                    facebed.Utils.warn('private title', file_content=b'private page')
                    facebed._send_dump_report('private-url', object())
                    facebed._send_restricted_page_report('private-url', Exception('private'), object())
                webhook.assert_not_called()
                thread.assert_not_called()

    def test_real_health_route_has_only_counts(self):
        result = invoke(self.facebed.app, '/healthz')
        self.assertEqual(result['status'], '200 OK')
        payload = json.loads(result['body'])
        self.assertEqual(set(payload), {'status', 'requests', 'errors', 'uptime_secs'})
        self.assertEqual(payload['status'], 'ok')

    def test_real_route_metadata_and_error_privacy_without_facebook(self):
        with mock.patch.object(self.facebed, '_run_tracked_request',
                               return_value=('<meta property="og:video" content="https://video.xx.fbcdn.net/video">', None, True)):
            result = invoke(self.facebed.app)
            self.assertEqual(result['status'], '200 OK')
            self.assertIn(b'og:video', result['body'])
        with mock.patch.object(self.facebed, '_run_tracked_request',
                               side_effect=ValueError('private page body')):
            result = invoke(self.facebed.app, '/reel/private-url')
            self.assertEqual(result['status'], '502 Bad Gateway')
            self.assertEqual(result['body'], service.ERROR_BODY)
            self.assertNotIn(b'private', result['body'])

    def test_real_cffi_redirect_is_guarded_at_every_hop(self):
        # Exercise the actual upstream redirect loop, mocking only network I/O.
        for location in ('https://outside.invalid/private', 'http://facebook.com/private',
                         'https://127.0.0.1/private', 'https://discord.com/api/webhooks/unused'):
            calls = []

            def transport(_session, method, url, **kwargs):
                calls.append(url)
                kwargs['content_callback'](b'first response')
                return types.SimpleNamespace(status_code=302, url=url, content=b'',
                                             headers={'Location': location}, cookies=mock.Mock())

            token = service._budget.set(service.RequestBudget(time.monotonic() + 5))
            try:
                with mock.patch('curl_cffi.requests.Session.request', transport):
                    with self.assertRaises(ValueError):
                        self.facebed.cffi.get('https://www.facebook.com/reel/1')
                self.assertEqual(calls, ['https://www.facebook.com/reel/1'])
            finally:
                service._budget.reset(token)

    def test_real_cffi_same_host_redirect_and_body_still_work(self):
        calls = []

        def transport(_session, method, url, **kwargs):
            calls.append(url)
            kwargs['content_callback'](b'page body')
            return types.SimpleNamespace(status_code=302 if len(calls) == 1 else 200,
                                         url=url, content=b'',
                                         headers={'Location': '/reel/2'} if len(calls) == 1 else {},
                                         cookies=mock.Mock())

        token = service._budget.set(service.RequestBudget(time.monotonic() + 5))
        try:
            with mock.patch('curl_cffi.requests.Session.request', transport):
                result = self.facebed.cffi.get('https://www.facebook.com/share/r/test')
            self.assertEqual(calls, ['https://www.facebook.com/share/r/test', 'https://www.facebook.com/reel/2'])
            self.assertEqual(result.content, b'page body')
            self.assertEqual(result.redirect_count, 1)
            self.assertIsNone(self.facebed.cffi._get_session())
        finally:
            service._budget.reset(token)

    def test_real_libcurl_aborts_oversized_decoded_body_on_loopback(self):
        # Only loopback traffic: prove curl_cffi honors the explicit abort value
        # even when a tiny compressed transfer expands past the body limit.
        payload = gzip.compress(b'x' * 4096)

        class LocalPage(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Encoding', 'gzip')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(('127.0.0.1', 0), LocalPage)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        from curl_cffi.requests import RequestsError
        token = service._budget.set(service.RequestBudget(time.monotonic() + 3))
        try:
            with mock.patch.object(service, 'MAX_UPSTREAM_BYTES', 128):
                with mock.patch.object(service, 'allowed_upstream_url', return_value=True):
                    with self.facebed.CffiSession() as session:
                        with self.assertRaises(RequestsError):
                            session.request('GET', f'http://127.0.0.1:{server.server_port}/')
            self.assertEqual(service._budget.get().received, 0)
        finally:
            service._budget.reset(token)
            server.shutdown()
            server.server_close()
            worker.join(3)


class HTTPTests(unittest.TestCase):
    def test_quiet_http_errors_and_bounded_concurrency(self):
        entered = threading.Event()
        release = threading.Event()

        def app(environ, start):
            entered.set()
            release.wait(3)
            raise RuntimeError('private-title-traceback')

        server = service.make_server('127.0.0.1', 0, service.PrivacyBoundary(app),
                                     server_class=service.BoundedServer, handler_class=service.QuietHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        output = io.StringIO()
        connections = []
        try:
            with contextlib.redirect_stderr(output):
                worker.start()
                for _ in range(2):
                    client = socket.create_connection(server.server_address, timeout=3)
                    connections.append(client)
                    client.sendall(b'GET /reel/private-url HTTP/1.0\r\n\r\n')
                    # Wait until this request has consumed a worker slot.
                    entered.wait(1)
                    entered.clear()
                with socket.create_connection(server.server_address, timeout=3) as third:
                    third.sendall(b'GET /healthz HTTP/1.0\r\n\r\n')
                    self.assertIn(b'503 Service Unavailable', third.recv(4096))
                release.set()
                for client in connections:
                    response = client.makefile('rb').read()
                    self.assertIn(b'502 Bad Gateway', response)
                    self.assertNotIn(b'private', response)
                with socket.create_connection(server.server_address, timeout=3) as invalid:
                    invalid.sendall(b'PRIVATE-CONTENT\r\n\r\n')
                    response = invalid.makefile('rb').read()
                    self.assertNotIn(b'PRIVATE-CONTENT', response)
            self.assertEqual(output.getvalue(), '')
        finally:
            release.set()
            for client in connections:
                client.close()
            server.shutdown()
            server.server_close()
            worker.join(3)


if __name__ == '__main__':
    unittest.main()
