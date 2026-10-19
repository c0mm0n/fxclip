"""Local HTTP release fixtures for real Qt updates on the disposable Linux runner."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import hashlib
import json
import sys
import time
archive, log, port = map(Path, sys.argv[1:])
data = archive.read_bytes()
digest = 'sha256:' + hashlib.sha256(data).hexdigest()
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with log.open('a') as stream: stream.write(self.path + '\n')
        mode, name = urlsplit(self.path).path.strip('/').split('/', 1)
        if mode == 'network': self.send_error(503); return
        if name == 'latest':
            version = {'older': '0.9.0', 'equal': '1.0.0'}.get(mode, '1.0.1')
            body = json.dumps({'tag_name': 'v' + version, 'draft': mode == 'draft', 'prerelease': mode == 'prerelease', 'body': 'A real Qt and service update, downloaded only after confirmation.', 'assets': [{'name': 'fxclip-linux-x86_64.tar.gz', 'browser_download_url': f'http://127.0.0.1:{self.server.server_port}/{mode}/fxclip-linux-x86_64.tar.gz', 'size': len(data), 'digest': digest}]}).encode()
        elif name == 'fxclip-linux-x86_64.tar.gz': body = bytes([data[0] ^ 1]) + data[1:] if mode == 'corrupt' else data
        else: self.send_error(404); return
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
        try:
            for offset in range(0, len(body), 65536):
                self.wfile.write(body[offset:offset+65536])
                if mode == 'slow' and name.endswith('.tar.gz'): time.sleep(.02)
        except (BrokenPipeError, ConnectionResetError): pass
    def log_message(self, *_): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
port.write_text(str(server.server_port))
server.serve_forever()
