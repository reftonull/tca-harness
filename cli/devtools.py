"""Serve the live devtools panel and relay timeline pages from the app's loopback harness."""
import json
import socket
import socketserver
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PAGE = Path(__file__).with_name('devtools.html')


class TimelineRelay:
    """One persistent JSON-lines connection, reopened after the app restarts."""

    def __init__(self, port):
        self.port = port
        self.lock = threading.Lock()
        self.connection = None
        self.stream = None

    def page(self, since):
        with self.lock:
            for attempt in range(2):
                try:
                    if self.connection is None:
                        self.connection = socket.create_connection(('127.0.0.1', self.port), timeout=5)
                        self.stream = self.connection.makefile('rb')
                    self.connection.sendall((json.dumps({'method': 'timeline', 'since': since}) + '\n').encode())
                    line = self.stream.readline()
                    if not line:
                        raise OSError('closed')
                    return json.loads(line)
                except (OSError, ValueError):
                    self.close()
                    if attempt:
                        raise ConnectionError(
                            f'No harness on 127.0.0.1:{self.port}; launch the app with TCA_HARNESS=1 '
                            f'and TCA_HARNESS_PORT={self.port}') from None

    def close(self):
        if self.connection:
            self.stream.close()
            self.connection.close()
        self.connection = self.stream = None


def make_handler(relay):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            # Browsers send the name they resolved; refusing others blocks DNS-rebinding pages
            # from reading app state through this loopback server.
            port = self.server.server_port
            if self.headers.get('Host') not in (f'127.0.0.1:{port}', f'localhost:{port}'):
                return self.send(403, b'Forbidden host', 'text/plain')
            url = urlparse(self.path)
            if url.path == '/':
                return self.send(200, PAGE.read_bytes(), 'text/html; charset=utf-8')
            if url.path == '/api/timeline':
                try:
                    since = int(parse_qs(url.query).get('since', ['0'])[0])
                except ValueError:
                    return self.json(400, {'ok': False, 'error': 'since must be an integer'})
                try:
                    response = relay.page(max(since, 0))
                except ConnectionError as error:
                    return self.json(502, {'ok': False, 'error': 'disconnected', 'detail': str(error)})
                if response.get('error') == 'timeline_unavailable':
                    response['detail'] = ('Connected, but no timeline is recording. Apply .harnessTimeline() to the root '
                                          'reducer; store.harness(...) must use the same timeline (both default to .shared).')
                return self.json(200, response)
            self.send(404, b'Not found', 'text/plain')

        def json(self, status, value):
            self.send(status, json.dumps(value).encode(), 'application/json')

        def send(self, status, body, content_type):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    return Handler


class LoopbackServer(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer.server_bind does a reverse-DNS lookup that can stall; loopback needs none.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def serve(app_port, http_port):
    relay = TimelineRelay(app_port)
    server = LoopbackServer(('127.0.0.1', http_port), make_handler(relay))
    print(f'Devtools on http://127.0.0.1:{server.server_port} (app harness 127.0.0.1:{app_port}); Ctrl-C stops',
          flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        relay.close()
