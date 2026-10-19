"""Loopback-only release fixtures; never used by the public Android APK."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import hashlib
import json
import os
import sys
import time

root, proof = map(Path, sys.argv[1:])
proof.mkdir(parents=True, exist_ok=True)
log = proof / 'requests.jsonl'
log.touch()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        mode = (proof / 'mode').read_text().strip()
        with log.open('a') as stream:
            stream.write(json.dumps({'path': self.path, 'mode': mode, 'user_agent': self.headers.get('User-Agent')}) + '\n')
        if mode == 'network':
            self.send_error(503); return
        filename = {'old-code': 'old-code.apk', 'certificate': 'other-certificate.apk', 'package': 'wrong-package.apk'}.get(mode, '1.0.1.apk')
        data = (root / filename).read_bytes()
        if self.path == '/latest':
            version = {'older': '0.9.0', 'equal': '1.0.0'}.get(mode, '1.0.1')
            body = json.dumps({'tag_name': 'v' + version, 'draft': mode == 'draft', 'prerelease': mode == 'prerelease',
                'body': 'Verified Android update. Settings, counter and history are kept.',
                'assets': [{'name': 'fxclip-android.apk', 'browser_download_url': 'http://127.0.0.1:48637/fxclip-android.apk',
                    'size': len(data) + (1 if mode == 'size' else 0),
                    'digest': 'sha256:' + ('0' * 64 if mode == 'digest' else hashlib.sha256(data).hexdigest())}]}).encode()
        elif self.path == '/fxclip-android.apk':
            body = bytes([data[0] ^ 1]) + data[1:] if mode == 'corrupt' else data
        else:
            self.send_error(404); return
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
        if mode == 'interrupted' and self.path.endswith('.apk'):
            self.wfile.write(body[:len(body)//3]); self.close_connection = True; return
        try:
            for offset in range(0, len(body), 65536):
                self.wfile.write(body[offset:offset+65536]); self.wfile.flush()
                if mode == 'slow' and self.path.endswith('.apk'): time.sleep(.2)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass

server = ThreadingHTTPServer(('127.0.0.1', 48637), Handler)
(proof / 'server-ready').write_text(str(os.getpid()))
server.serve_forever()
