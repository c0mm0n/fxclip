"""Local-only real-download fixtures for the disposable Windows runner."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import sys
import time
from urllib.parse import urlsplit
root, log, port_file = map(Path, sys.argv[1:])
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with log.open('a') as stream:
            stream.write(self.path + '\n')
        mode, name = urlsplit(self.path).path.strip('/').split('/', 1)
        if Path(name).name != name or not (root / name).is_file():
            self.send_error(404); return
        data = (root / name).read_bytes()
        if mode == 'older' and name.endswith('.json'):
            feed = json.loads(data)
            for asset in feed['Assets']: asset['Version'] = '0.9.0'
            data = json.dumps(feed).encode()
        if mode == 'corrupt' and name.endswith('.nupkg'):
            data = bytes([data[0] ^ 1]) + data[1:]
        self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers()
        try:
            for offset in range(0, len(data), 65536):
                self.wfile.write(data[offset:offset+65536])
                if mode == 'slow' and name.endswith('.nupkg'): time.sleep(.02)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError): pass
    def log_message(self, *_): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
port_file.write_text(str(server.server_port))
server.serve_forever()
