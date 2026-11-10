"""Races: replay latency, `no_wait`/`after_ms` steps, `tca explore --races` and `tca chaos --reorder`,
end to end against fake_app.py."""
import json
import time
import tomllib
import unittest

from support import Workspace, journeys  # noqa: F401
import exploration
import targets

DOUBLE_SAVE = '''name = "Double save"
fixtures = "../fixtures/shelf"
network = "replay"
latency = { ms = 150 }

[[steps]]
do = "Add book"

[[steps]]
do = "Set title"
args = { value = "Dune" }

[[steps]]
do = "Save"

[[steps]]
do = "Save"
no_wait = true
after_ms = 20
'''

EDITOR = '''name = "Editor with a title"
fixtures = "../fixtures/shelf"
network = "replay"

[[steps]]
do = "Add book"

[[steps]]
do = "Set title"
args = { value = "Dune" }
'''

TYPE_FAST = '''name = "Search fast"
fixtures = "../fixtures/shelf"
network = "replay"

[[steps]]
do = "Search"
args = { value = "Du" }

[[steps]]
do = "Search"
args = { value = "Dune" }
no_wait = true
requests = ["GET /search", "GET /search"]

[checks]
"shows Dune" = "shelf.resultsFor == 'Dune'"
'''


def race_workspace():
    """A Workspace with a cassette for the fake app's `GET /search` too."""
    workspace = Workspace()
    (workspace.root / 'fixtures' / 'shelf' / 'GET_search_1.json').write_text(json.dumps({
        'request': {'method': 'GET', 'url': 'http://api.shelf.test/search', 'body': None},
        'response': {'status': 200, 'headers': {}, 'body': []}}))
    return workspace


class JourneyTimingTests(unittest.TestCase):
    def setUp(self):
        self.workspace = race_workspace()
        self.addCleanup(self.workspace.cleanup)

    def test_timing_and_latency_round_trip(self):
        path = self.workspace.journey('double', DOUBLE_SAVE)
        journey = journeys.load_journey(path)
        self.assertEqual([(s.no_wait, s.after_ms) for s in journey.steps], [(False, None)] * 3 + [(True, 20)])
        self.assertEqual(journey.latency, {'ms': 150})
        copy = journeys.write_journey(journey, self.workspace.root / 'journeys' / 'copy.toml')
        data = tomllib.loads(copy.read_text())
        self.assertEqual(data['latency'], {'ms': 150})
        self.assertEqual(data['steps'][3], {'do': 'Save', 'no_wait': True, 'after_ms': 20})
        latency = journeys.journey_from({'name': 'x', 'latency': {'ms': 100, 'jitter_ms': 50, 'seed': 2,
                                                                  'paths': {'/search': {'ms': 400}}}}).latency
        self.assertEqual(latency['paths'], {'/search': {'ms': 400}})
        self.assertEqual(journeys.journey_from({'name': 'x', 'latency': 80}).latency, {'ms': 80})

    def test_invalid_timing_is_explained(self):
        cases = [
            ({'steps': [{'do': 'A', 'no_wait': True}]}, 'first step can\'t be `no_wait`'),
            ({'steps': [{'do': 'A'}, {'do': 'B', 'no_wait': 'yes'}]}, '`no_wait` must be true or false'),
            ({'steps': [{'do': 'A', 'after_ms': -5}]}, '`after_ms` must be a non-negative integer'),
            ({'steps': [{'do': 'A', 'expect': 'x'}, {'do': 'B', 'no_wait': True}]}, 'put them on the last step of the race'),
            ({'latency': {'ms': 'fast'}}, 'latency.ms must be'),
            ({'latency': {'delay': 3}}, '`latency` must be milliseconds or a table'),
            ({'latency': {'paths': {'/a': 5}}}, 'latency.paths maps paths'),
        ]
        for data, message in cases:
            with self.assertRaisesRegex(journeys.JourneyError, message):
                journeys.journey_from(dict(name='x', **data))

    def test_latency_reaches_the_app_through_the_environment_and_the_cli(self):
        self.assertEqual(targets.run_environment(latency={'ms': 200, 'jitter_ms': 50})['TCA_HARNESS_LATENCY'],
                         '{"jitter_ms":50,"ms":200}')
        self.assertNotIn('TCA_HARNESS_LATENCY', targets.run_environment(latency=None))
        report = self.workspace.root / 'run.jsonl'
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/add-book.toml', '--latency', '120', '--jitter', '30',
                                          '--report', report)
        self.assertEqual(code, 0, out)
        events = [json.loads(line) for line in report.read_text().splitlines()]
        network = next(e for e in events if e['event'] == 'network')
        self.assertEqual(network['latency'], {'ms': 120, 'jitter_ms': 30})
        requests = [e['request'] for e in events if e['event'] == 'request']
        self.assertTrue(requests and all(90 <= r['ms'] - 1 <= 150 for r in requests), requests)

    def test_a_no_wait_step_races_the_one_before(self):
        self.workspace.journey('double', DOUBLE_SAVE)
        started = time.monotonic()
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/double.toml', '--target', 'racy')
        self.assertEqual(code, 1, out)
        self.assertIn('invariant after step 4 "Save": no duplicate books', out)
        # The correct app hides Save while saving, so the double tap can't happen.
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/double.toml')
        self.assertEqual(code, 1)
        self.assertIn('step 4 "Save": no offered operation matches', out)
        # Waiting (no `no_wait`), the first save closes the editor before the second tap.
        waited = DOUBLE_SAVE.replace('no_wait = true\nafter_ms = 20\n', '')
        self.workspace.journey('waited', waited)
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/waited.toml', '--target', 'racy')
        self.assertIn('step 4 "Save": no offered operation matches', out)
        self.assertLess(time.monotonic() - started, 30)

    def test_after_ms_is_measured_from_the_previous_dispatch(self):
        slept = []
        runner = journeys.Runner(session=None)
        runner.last_dispatch = time.monotonic()
        runner.pause(journeys.Step('x', no_wait=True, after_ms=200), sleep=slept.append)
        runner.pause(journeys.Step('x', after_ms=50), sleep=slept.append)
        runner.pause(journeys.Step('x'), sleep=slept.append)
        self.assertTrue(0.15 < slept[0] <= 0.2)
        self.assertEqual(slept[1:], [0.05])

    def test_a_race_checks_requests_on_its_last_step(self):
        self.workspace.journey('fast', TYPE_FAST)
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/fast.toml', '--target', 'search', '--latency', '150')
        self.assertEqual(code, 0, out)
        self.assertIn('2 request(s)', out)


class ExploreRacesTests(unittest.TestCase):
    def setUp(self):
        self.workspace = race_workspace()
        self.addCleanup(self.workspace.cleanup)
        self.workspace.journey('editor', EDITOR)

    def explore(self, target, *extra):
        return self.workspace.cli('explore', '--target', target, '--runs', '8', '--steps', '5', '--seed', '0',
                                  '--journey', 'journeys/editor.toml', '--latency', '100', *extra)

    def test_races_find_a_double_save_and_the_finding_replays_the_timing(self):
        code, out, err = self.explore('racy', '--races')
        self.assertEqual(code, 1, out + err)
        self.assertIn('races, latency 100 ms +/- 0 ms: 1 finding(s)', out)
        self.assertRegex(out, r'invariant  \d+ -> 2  \.tca/findings/invariant-1\.toml  no duplicate books')
        path = self.workspace.root / '.tca/findings/invariant-1.toml'
        data = tomllib.loads(path.read_text())
        self.assertIn('--races', path.read_text().splitlines()[0])
        self.assertEqual([s['do'] for s in data['steps']], ['Add book', 'Set title', 'Save', 'Save'])
        self.assertTrue(data['steps'][3]['no_wait'])
        self.assertNotIn('no_wait', data['steps'][2])
        self.assertEqual(data['latency'], {'ms': 100})
        code, out, _ = self.workspace.cli('journey', 'run', '.tca/findings/invariant-1.toml', '--target', 'racy')
        self.assertEqual(code, 1)
        self.assertIn('invariant after step 4 "Save": no duplicate books', out)

    def test_waiting_explore_misses_it_and_a_correct_app_is_clean(self):
        code, out, err = self.explore('racy')
        self.assertEqual(code, 0, out + err)
        code, out, err = self.explore('headless', '--races')
        self.assertEqual(code, 0, out + err)
        self.assertIn(': 0 finding(s)', out)

    def test_races_default_to_a_latency(self):
        code, out, _ = self.workspace.cli('explore', '--races', '--runs', '1', '--steps', '3', '--fixtures', 'fixtures/shelf')
        self.assertEqual(code, 0, out)
        self.assertIn('races, latency 200 ms +/- 150 ms', out)
        self.assertIn('note: --races without a replay latency', out)

    def test_shrinking_drops_timing_a_finding_does_not_need(self):
        steps = [journeys.Step('Add'), journeys.Step('Save'), journeys.Step('Save', no_wait=True, after_ms=60),
                 journeys.Step('Close', no_wait=True)]
        needs_double_tap = lambda candidate: candidate[2].no_wait
        calm = exploration.without_races(steps, needs_double_tap)
        self.assertEqual([(s.no_wait, s.after_ms) for s in calm], [(False, None), (False, None), (True, 60), (False, None)])

    def test_race_candidates_prefer_the_same_operation_and_dismissals(self):
        import random
        offered = [{'id': 'root/save@1', 'feature': 'root', 'label': 'Save'},
                   {'id': 'root/close@1', 'feature': 'root', 'label': 'Close'},
                   {'id': 'root/other/x@2', 'feature': 'root/other', 'label': 'Other'}]
        rng = random.Random(1)
        picks = [exploration.race_candidate(offered, offered[0], rng)[0]['label'] for _ in range(400)]
        self.assertGreater(picks.count('Save'), picks.count('Other') * 2)
        self.assertGreater(picks.count('Close'), picks.count('Other'))
        self.assertIn('Other', picks)


class ReorderTests(unittest.TestCase):
    def setUp(self):
        self.workspace = race_workspace()
        self.addCleanup(self.workspace.cleanup)
        self.workspace.journey('fast', TYPE_FAST.replace('requests = ["GET /search", "GET /search"]\n', ''))

    def test_groups_and_targets(self):
        steps = [journeys.Step('a'), journeys.Step('b', no_wait=True), journeys.Step('c'), journeys.Step('d', no_wait=True)]
        self.assertEqual(exploration.race_groups(steps), [(1, 2), (3, 4)])
        journey = journeys.Journey(path=None, name='x', steps=steps)
        get = lambda path: {'method': 'GET', 'url': f'http://api{path}'}
        requests = [(0, get('/s')), (1, get('/s')), (2, get('/s')), (3, get('/t')), (4, get('/s'))]
        self.assertEqual(exploration.reorder_targets(journey, requests), [(1, 2, {'method': 'GET', 'path': '/s'}, 0)])

    def test_a_stale_response_is_caught_and_a_cancelling_app_passes(self):
        code, out, _ = self.workspace.cli('chaos', 'journeys/fast.toml', '--target', 'search', '--reorder')
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r'1-2\s+GET /search\s+held 1000 ms\s+ok')
        code, out, _ = self.workspace.cli('chaos', 'journeys/fast.toml', '--target', 'stale', '--reorder', '--reorder-ms', '600')
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r'1-2\s+GET /search\s+held 600 ms\s+FAIL invariant after step 2 "Search": results are for the search field')
        data = tomllib.loads((self.workspace.root / '.tca/findings/invariant-1.toml').read_text())
        self.assertEqual(data['faults'], [{'match': {'method': 'GET', 'path': '/search'}, 'kind': 'delay', 'delayMs': 600,
                                           'times': 1}])
        self.assertTrue(data['steps'][1]['no_wait'])
        code, out, _ = self.workspace.cli('journey', 'run', '.tca/findings/invariant-1.toml', '--target', 'stale')
        self.assertEqual(code, 1, out)

    def test_without_an_invariant_the_final_state_shows_the_stale_response(self):
        code, out, _ = self.workspace.cli('chaos', 'journeys/fast.toml', '--target', 'stale-quiet', '--reorder',
                                          '--reorder-ms', '600')
        self.assertEqual(code, 1, out)
        # The journey's own check fails first; without it, the state comparison does.
        self.assertIn('check: "shows Dune" failed', out)
        self.workspace.journey('unchecked', TYPE_FAST.replace('requests = ["GET /search", "GET /search"]\n', '')
                               .split('[checks]')[0])
        code, out, _ = self.workspace.cli('chaos', 'journeys/unchecked.toml', '--target', 'stale-quiet', '--reorder',
                                          '--reorder-ms', '600')
        self.assertEqual(code, 1, out)
        self.assertIn('FAIL stale response: final state differs from the in-order run at shelf.resultsFor: "Du" instead of "Dune"',
                      out)
        self.assertTrue((self.workspace.root / '.tca/findings/stale-1.toml').exists())

    def test_nothing_to_reorder(self):
        code, out, _ = self.workspace.cli('chaos', 'journeys/add-book.toml', '--reorder')
        self.assertEqual(code, 0, out)
        self.assertIn('no step or race makes two requests to the same endpoint', out)


if __name__ == '__main__':
    unittest.main()
