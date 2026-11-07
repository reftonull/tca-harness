"""Fixture coverage, per-step request expectations, launch faults and the recording sweep, end to end
against fake_app.py."""
import json
import os
import subprocess
import sys
import tomllib
import unittest

from support import FAKE, PYTHON, Workspace, journeys
import targets

LAUNCH = '''name = "Launch"
fixtures = "../fixtures/shelf"
network = "replay"
launch_requests = ["GET /books"]

[[steps]]
do = "Add book"
requests = []
'''

CONTRACT = '''name = "Contract"
fixtures = "../fixtures/shelf"
network = "replay"

[[steps]]
do = "Add book"
requests = []

[[steps]]
do = "Set title"
args = { value = "Dune" }

[[steps]]
do = "Save"
requests = ["POST /books"]

[[steps]]
do = "Refresh"
requests = ["GET /books?*"]
'''


def start_fake(test, *flags, **env):
    """fake_app.py on a free port, stopped when the test ends. Returns the port."""
    server = subprocess.Popen([sys.executable, str(FAKE), '--port', '0', *flags], stderr=subprocess.PIPE, text=True,
                              env=dict(os.environ, **env))

    def stop():
        server.kill()
        server.wait()
        server.stderr.close()
    test.addCleanup(stop)
    return int(next(line for line in server.stderr if 'listening' in line).rsplit(':', 1)[1])


def fake_requests(*specs):
    return [{'method': m, 'url': 'http://api.test' + p} for m, p in (s.split(' ', 1) for s in specs)]


class RequestPatternTests(unittest.TestCase):
    def test_patterns_match_method_path_templates_and_query_globs(self):
        get = {'method': 'GET', 'url': 'http://api/books/42?page=2'}
        self.assertTrue(journeys.request_matches('GET /books/{id}', get))      # no `?`: query ignored
        self.assertTrue(journeys.request_matches('GET /books/*', get))
        self.assertTrue(journeys.request_matches('GET /books/42?page=*', get))
        self.assertTrue(journeys.request_matches('* /books/42', get))
        self.assertFalse(journeys.request_matches('GET /books/42?page=3', get))
        self.assertFalse(journeys.request_matches('POST /books/{id}', get))
        self.assertFalse(journeys.request_matches('GET /books', get))
        self.assertFalse(journeys.request_matches('GET /books/{id}', {'method': 'GET', 'url': 'http://api/books/1/notes'}))
        self.assertTrue(journeys.request_matches('GET /books?*', {'method': 'GET', 'url': 'http://api/books'}))

    def test_multiset_matching_is_order_insensitive_and_maximal(self):
        made = fake_requests('POST /events', 'GET /books/1', 'POST /books')
        self.assertEqual(journeys.match_requests(['POST /books', 'GET /books/{id}', 'POST /events'], made), ([], []))
        # A greedy match would give `GET /books/*` the first request and miss `GET /books/1`.
        made = fake_requests('GET /books/1', 'GET /books/2')
        self.assertEqual(journeys.match_requests(['GET /books/*', 'GET /books/2'], made), ([], []))
        missing, unexpected = journeys.match_requests(['POST /events', 'POST /books'], fake_requests('POST /events', 'POST /events'))
        self.assertEqual(missing, ['POST /books'])
        self.assertEqual([r['url'] for r in unexpected], ['http://api.test/events'])

    def test_finding_lists_expected_and_made(self):
        finding = journeys.requests_finding(['GET /books', 'POST /events'], fake_requests('GET /books', 'GET /books'), 2)
        self.assertEqual(finding.kind, 'requests')
        self.assertEqual(finding.message, 'expected [GET /books, POST /events], made [GET /books, GET /books] '
                                          '(missing POST /events; unexpected GET /books)')
        steps = [journeys.Step('Open'), journeys.Step('Save')]
        self.assertTrue(finding.describe(steps).startswith('requests after step 2 "Save": expected'))
        self.assertIsNone(journeys.requests_finding([], [], 1))

    def test_recorded_patterns_use_templates_or_id_heuristics(self):
        self.assertEqual(journeys.request_pattern({'method': 'get', 'url': 'http://a/books/123?x=1'}), 'GET /books/{id}')
        self.assertEqual(journeys.request_pattern({'method': 'PUT', 'url': 'http://a/books/2A3F0C1E-8C55-4E0B-9C5A-0B5D7F3A1101'}),
                         'PUT /books/{id}')
        self.assertEqual(journeys.request_pattern({'method': 'GET', 'url': 'http://a/tags/bikes'}, ['/tags/{tag}']), 'GET /tags/{tag}')
        self.assertEqual(journeys.request_pattern({'method': 'GET', 'url': 'http://a/x/1', 'template': '/x/{n}'}), 'GET /x/{n}')
        self.assertEqual(journeys.request_pattern({'method': 'GET', 'url': 'http://a/v1/books'}), 'GET /v1/books')

    def test_invalid_expectations_and_faults_are_refused(self):
        for text, message in [('[[steps]]\ndo = "x"\nrequests = "GET /a"', 'list of strings'),
                              ('[[steps]]\ndo = "x"\nrequests = ["books"]', 'METHOD /path'),
                              ('launch_requests = ["GET books"]', 'METHOD /path'),
                              ('[[faults]]\nkind = "offline"\nat = "boot"', '`at` must be "launch"'),
                              ('[[faults]]\nkind = "offline"\nlaunch_requests = []', 'unknown keys: launch_requests')]:
            with self.assertRaisesRegex(journeys.JourneyError, message):
                journeys.journey_from(tomllib.loads(text))

    def test_documents_round_trip(self):
        journey = journeys.journey_from(tomllib.loads(LAUNCH + '\n[[faults]]\nat = "launch"\nkind = "offline"\n'))
        self.assertEqual(journey.launch_faults, [{'kind': 'offline'}])
        self.assertEqual(journey.connect_faults, [])
        document = journeys.journey_document(journey)
        self.assertEqual(document['launch_requests'], ['GET /books'])
        self.assertEqual(document['steps'][0]['requests'], [])
        self.assertEqual(document['faults'], [{'at': 'launch', 'kind': 'offline'}])


class ExpectationRunTests(unittest.TestCase):
    def setUp(self):
        self.workspace = Workspace()
        self.addCleanup(self.workspace.cleanup)

    def test_per_step_requests_pass_and_fail_with_both_lists(self):
        self.workspace.journey('contract', CONTRACT)
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/contract.toml')
        self.assertEqual(code, 0, out)
        self.workspace.journey('contract', CONTRACT.replace('requests = ["POST /books"]', 'requests = ["POST /books", "POST /events"]'))
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/contract.toml')
        self.assertEqual(code, 1)
        self.assertIn('requests after step 3 "Save": expected [POST /books, POST /events], made [POST /books] '
                      '(missing POST /events)', out)

    def test_launch_requests_and_launch_faults(self):
        self.add_target('fetch', '--launch-fetch')
        self.workspace.journey('launch', LAUNCH)
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/launch.toml', '--target', 'fetch')
        self.assertEqual(code, 0, out)
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/launch.toml', '--target', 'headless')
        self.assertEqual(code, 1)
        self.assertIn('requests at launch: expected [GET /books], made [none] (missing GET /books)', out)
        # The fault reaches the request made before the CLI connected.
        faulted = LAUNCH + '\n[[faults]]\nat = "launch"\nmatch = { path = "/books" }\nkind = "status"\nstatus = 500\n\n' \
                           '[checks]\n"the error shows" = "shelf.error == \\"Couldn\'t load\\""\n'
        self.workspace.journey('faulted', faulted)
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/faulted.toml', '--target', 'fetch', '--report', 'run.jsonl')
        self.assertEqual(code, 0, out)
        requests = [json.loads(l)['request'] for l in (self.workspace.root / 'run.jsonl').read_text().splitlines()
                    if json.loads(l)['event'] == 'request']
        self.assertEqual([(r['match'], r['status']) for r in requests], [('fault', 500)])

    def test_launch_faults_need_a_fresh_launch(self):
        port = start_fake(self)
        self.workspace.journey('faulted', LAUNCH + '\n[[faults]]\nat = "launch"\nkind = "offline"\n')
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/faulted.toml', '--port', port)
        self.assertEqual(code, 1)
        self.assertIn('need a fresh launch', out)

    def test_environment_carries_launch_faults(self):
        variables = targets.run_environment('replay', faults=[{'kind': 'offline', 'match': {'path': '/books'}}])
        self.assertEqual(variables['TCA_HARNESS_FAULTS'], '[{"kind":"offline","match":{"path":"/books"}}]')
        self.assertNotIn('TCA_HARNESS_FAULTS', targets.run_environment('replay', faults=[]))

    def test_recording_pins_each_steps_requests(self):
        port = str(start_fake(self, '--launch-fetch', TCA_HARNESS_NETWORK='replay',
                              TCA_HARNESS_CASSETTES=str(self.workspace.root / 'fixtures' / 'shelf')))
        path = self.workspace.root / 'journeys' / 'recorded.toml'
        path.write_text('name = "Recorded"\nfixtures = "../fixtures/shelf"\nnetwork = "replay"\n')
        self.assertEqual(self.workspace.cli('record', 'start', path, '--goal', 'Add Dune')[0], 0)
        notes = []
        for argv in (['Add book'], ['Set title', '{"value": "Dune"}'], ['Save'], ['Refresh'], ['Mark Dune read']):
            code, _, err = self.workspace.cli('do', *argv, '--port', port)
            self.assertEqual(code, 0, err)
            notes.append(err)
        self.assertIn('recorded 1 request(s) made before the first step as `launch_requests`', notes[0])
        code, out, err = self.workspace.cli('record', 'stop')
        self.assertEqual(code, 0, err)
        self.assertIn('3 expected request(s)', out)
        written = tomllib.loads(path.read_text())
        self.assertEqual(written['launch_requests'], ['GET /books'])
        self.assertEqual([s.get('requests') for s in written['steps']], [[], [], ['POST /books'], ['GET /books'], []])
        self.add_target('fetch', '--launch-fetch')
        code, out, _ = self.workspace.cli('journey', 'run', path, '--target', 'fetch')
        self.assertEqual(code, 0, out)

    def add_target(self, name, flags):
        config = self.workspace.root / 'harness.toml'
        config.write_text(config.read_text() + f'\n[targets.{name}]\nlaunch = "{PYTHON} {FAKE} --port {{port}} {flags}"\n'
                          'port = "auto"\nready = "TCA harness listening"\nready_timeout = 10\n')


class ChaosAtLaunchTests(unittest.TestCase):
    def setUp(self):
        self.workspace = Workspace()
        self.addCleanup(self.workspace.cleanup)
        ExpectationRunTests.add_target(self, 'fetch', '--launch-fetch')
        ExpectationRunTests.add_target(self, 'fragile', '--fragile-launch')
        self.workspace.journey('launch', LAUNCH.replace('launch_requests = ["GET /books"]\n', ''))

    def test_launch_requests_are_faulted_through_the_environment(self):
        code, out, _ = self.workspace.cli('chaos', 'journeys/launch.toml', '--target', 'fetch', '--faults', 'status500,offline')
        self.assertEqual(code, 0, out)
        self.assertIn('launch  GET /books  status500  ok', out)
        self.assertIn('launch  GET /books  offline    ok', out)
        self.assertNotIn("can't be faulted", out)

    def test_a_launch_failure_that_strands_the_user(self):
        code, out, _ = self.workspace.cli('chaos', 'journeys/launch.toml', '--target', 'fragile', '--faults', 'timeout',
                                          '--out', 'found')
        self.assertEqual(code, 1, out)
        self.assertIn('FAIL stranded: "Add book" not offered within 5s', out)
        repro = self.workspace.root / 'found' / 'stranded-1.toml'
        self.assertEqual(journeys.load_journey(repro).faults, [{'match': {'method': 'GET', 'path': '/books'},
                                                                'kind': 'timeout', 'times': 1, 'at': 'launch'}])
        code, out, _ = self.workspace.cli('journey', 'run', repro, '--target', 'fragile')
        self.assertEqual(code, 1, out)
        self.assertIn('no offered operation matches', out)


class ChaosKeepsJourneyFaultsTests(unittest.TestCase):
    def test_the_journeys_own_faults_stay(self):
        workspace = Workspace()
        self.addCleanup(workspace.cleanup)
        workspace.journey('retry', '''name = "Two saves, the first one slow"
fixtures = "../fixtures/shelf"
network = "replay"

[[faults]]
match = { method = "POST", path = "/books" }
kind = "delay"
delayMs = 50

[[steps]]
do = "Add book"

[[steps]]
do = "Set title"
args = { value = "Dune" }

[[steps]]
do = "Save"

[[steps]]
do = "Add book"

[[steps]]
do = "Set title"
args = { value = "Emma" }

[[steps]]
do = "Save"
''')
        code, out, _ = workspace.cli('chaos', 'journeys/retry.toml', '--faults', 'status500')
        self.assertEqual(code, 0, out)
        self.assertIn('6     POST /books #2  status500  ok', out)
        self.assertIn("POST /books #1 is already failed by the journey's [[faults]]", out)


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.workspace = Workspace()
        self.addCleanup(self.workspace.cleanup)

    def test_coverage_by_endpoint_unused_cassettes_and_strict(self):
        fixtures = self.workspace.root / 'fixtures' / 'shelf'
        (fixtures / 'DELETE_books_1.json').write_text((fixtures / 'GET_books_1.json').read_text())
        code, out, _ = self.workspace.cli('fixtures', 'coverage', 'journeys/add-book.toml', '--strict')
        self.assertEqual(code, 0, out)
        self.assertIn('fixtures coverage: 1 run(s), 0 failed; 2 request(s) to 2 endpoint(s)', out)
        self.assertRegex(out, r'GET /books\s+1\s+1')
        self.assertRegex(out, r'POST /books\s+1\s+1')
        self.assertIn('cassettes in fixtures/shelf: 2 of 3 used\n  unused: DELETE_books_1.json', out)
        (fixtures / 'GET_books_1.json').unlink()
        code, out, _ = self.workspace.cli('fixtures', 'coverage', 'journeys/add-book.toml', '--strict')
        self.assertEqual(code, 1)
        self.assertIn('blocked (1)', out)
        self.assertIn('GET /books  (journeys/add-book.toml step 4)', out)
        self.assertIn('strict: 1 request(s) fell back or were blocked', out)

    def test_coverage_from_reports_of_earlier_runs(self):
        self.assertEqual(self.workspace.cli('journey', 'run', 'journeys/add-book.toml', '--report', 'a.jsonl')[0], 0)
        self.assertEqual(self.workspace.cli('explore', '--fixtures', 'fixtures/shelf', '--network', 'replay', '--runs', '2',
                                            '--steps', '5', '--report', 'b.jsonl')[0], 0)
        code, out, _ = self.workspace.cli('fixtures', 'coverage', '--report', 'a.jsonl', '--report', 'b.jsonl')
        self.assertEqual(code, 0, out)
        self.assertIn('3 run(s), 0 failed', out)
        self.assertIn('cassettes in fixtures/shelf: 2 of 2 used', out)
        self.assertEqual(self.workspace.cli('fixtures', 'coverage')[0], 2)

    def test_record_sweep_sanitizes_then_reports_coverage(self):
        sanitizer = self.workspace.root / 'sanitize.py'
        sanitizer.write_text('import sys, pathlib\nfor d in sys.argv[1:]:\n'
                             '    (pathlib.Path(d) / "sanitized.txt").write_text("ok")\n')
        recorded = self.workspace.root / 'recorded'
        code, out, _ = self.workspace.cli('fixtures', 'record', 'journeys/add-book.toml', '--into', recorded,
                                          '--sanitize', 'sanitize.py')
        self.assertEqual(code, 0, out)
        self.assertIn('2 cassette(s) written to recorded', out)
        self.assertEqual(sorted(p.name for p in recorded.iterdir()), ['GET_books_1.json', 'POST_books_1.json', 'sanitized.txt'])
        self.assertIn('note: the app sets no live guard', out)
        self.assertIn('fixtures coverage: 1 run(s), 0 failed', out)  # Replayed with the journey's own fixtures.
        code, _, err = self.workspace.cli('fixtures', 'record', 'journeys/add-book.toml', '--into', recorded,
                                          '--sanitize', f'{PYTHON} -c "raise SystemExit(3)"', '--no-coverage')
        self.assertEqual(code, 1)
        self.assertIn('the sanitizer exited with 3', err)


if __name__ == '__main__':
    unittest.main()
