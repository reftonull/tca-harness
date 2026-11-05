import importlib.util
import json
import shutil
import socket
import subprocess
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location('devtools', ROOT / 'devtools.py')
devtools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(devtools)


class FakeHarness:
    """A JSON-lines listener that answers timeline requests like the embedded server."""

    def __init__(self, reply):
        self.reply = reply
        self.requests = []
        self.listener = socket.create_server(('127.0.0.1', 0))
        self.port = self.listener.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            with connection, connection.makefile('rb') as stream:
                for line in stream:
                    request = json.loads(line)
                    self.requests.append(request)
                    connection.sendall((json.dumps(self.reply(request)) + '\n').encode())

    def close(self):
        self.listener.close()


def page(since):
    entry = {'index': 0, 'sequence': 1, 'action': ['increment'], 'source': 'app', 'state': {'count': 1}}
    return {'ok': True, 'timeline': {'timelineID': 't', 'startedAt': '', 'capacity': 500, 'dropped': 0,
                                      'sequence': 1, 'hasMore': False, 'entries': [entry] if since < 1 else []}}


class DevtoolsTests(unittest.TestCase):
    def start(self, app_port):
        server = devtools.LoopbackServer(('127.0.0.1', 0), devtools.make_handler(devtools.TimelineRelay(app_port)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f'http://127.0.0.1:{server.server_port}'

    def get(self, url):
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def test_relays_timeline_pages_and_serves_panel(self):
        harness = FakeHarness(lambda request: page(request['since']))
        self.addCleanup(harness.close)
        base = self.start(harness.port)
        status, body = self.get(base + '/api/timeline?since=0')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['timeline']['entries'][0]['action'], ['increment'])
        status, body = self.get(base + '/api/timeline?since=1')
        self.assertEqual(json.loads(body)['timeline']['entries'], [])
        self.assertEqual(harness.requests, [{'method': 'timeline', 'since': 0}, {'method': 'timeline', 'since': 1}])
        status, body = self.get(base + '/')
        self.assertEqual(status, 200)
        self.assertIn(b'TCA DevTools', body)

    def test_explains_missing_timeline_and_disconnected_app(self):
        harness = FakeHarness(lambda _: {'ok': False, 'error': 'timeline_unavailable'})
        self.addCleanup(harness.close)
        status, body = self.get(self.start(harness.port) + '/api/timeline?since=0')
        self.assertIn('.harnessTimeline()', json.loads(body)['detail'])

        unused = socket.create_server(('127.0.0.1', 0))
        port = unused.getsockname()[1]
        unused.close()
        status, body = self.get(self.start(port) + '/api/timeline?since=0')
        self.assertEqual(status, 502)
        self.assertIn('TCA_HARNESS_PORT=' + str(port), json.loads(body)['detail'])

    def test_rejects_foreign_host_headers(self):
        harness = FakeHarness(lambda request: page(request['since']))
        self.addCleanup(harness.close)
        base = self.start(harness.port)
        request = urllib.request.Request(base + '/api/timeline?since=0', headers={'Host': 'attacker.example:80'})
        status, _ = self.get(request)
        self.assertEqual(status, 403)
        self.assertEqual(harness.requests, [])
        port = base.rsplit(':', 1)[1]
        status, _ = self.get(urllib.request.Request(base + '/', headers={'Host': 'localhost:' + port}))
        self.assertEqual(status, 200)

    def test_rejects_invalid_cursor(self):
        status, _ = self.get(self.start(1) + '/api/timeline?since=abc')
        self.assertEqual(status, 400)


class PanelTests(unittest.TestCase):
    def test_panel_against_recorded_timeline(self):
        # Needs Node and jsdom (e.g. `npm install jsdom` in any directory, then NODE_PATH=<it>/node_modules).
        node = shutil.which('node')
        if not node or subprocess.run([node, '-e', 'require("jsdom")'], capture_output=True).returncode:
            self.skipTest('node with jsdom on NODE_PATH is unavailable')
        result = subprocess.run([node, str(ROOT / 'tests/devtools_checks.js')], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
