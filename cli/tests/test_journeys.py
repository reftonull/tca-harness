"""`tca journey run`, `tca record`, targets and the generic oracles, end to end against fake_app.py."""
import json
import os
from pathlib import Path
import time
import tomllib
import unittest

from support import CLI, FAKE, PYTHON, Workspace, journeys, tca
import targets
import trace_view


class TargetTests(unittest.TestCase):
    def setUp(self):
        self.workspace = Workspace()
        self.addCleanup(self.workspace.cleanup)

    def test_config_is_found_upward_and_defaults_to_headless(self):
        nested = self.workspace.root / 'journeys' / 'deep'
        nested.mkdir()
        target, path = targets.resolve_target(None, nested / 'x.toml')
        self.assertEqual((target.name, path), ('headless', self.workspace.root / 'harness.toml'))
        with self.assertRaisesRegex(targets.TargetError, "no target 'nope'"):
            targets.resolve_target('nope', nested)
        with self.assertRaisesRegex(targets.TargetError, 'No harness.toml'):
            targets.resolve_target(None, Path('/'))

    def test_invalid_configs_are_explained(self):
        bad = self.workspace.root / 'bad.toml'
        for text, message in [('[targets.a]\nport = 1', '`launch`'), ('[targets.a]\nlaunch = "x"\nport = "any"', '`port`'),
                              ('[targets.a]\nlaunch = "x"\nrestart = "always"', '`restart`'), ('x = 1', 'no \\[targets')]:
            bad.write_text(text)
            with self.assertRaisesRegex(targets.TargetError, message):
                targets.load_targets(bad)

    def test_env_expansion(self):
        variables = targets.run_environment('replay', self.workspace.root, 7, 9000)
        self.assertEqual(targets.expand("run --port {port} --env '{env}'", 9000, variables),
                         f"run --port 9000 --env 'TCA_HARNESS_NETWORK=replay TCA_HARNESS_CASSETTES={self.workspace.root} "
                         "TCA_HARNESS_SEED=7 TCA_HARNESS_PORT=9000'")

    def test_launch_passes_settings_and_kills_the_process_group(self):
        script = self.workspace.root / 'env.py'
        script.write_text('import os, sys, socket, time, subprocess\n'
                          'child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])\n'
                          'open("child.pid", "w").write(str(child.pid))\n'
                          's = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen()\n'
                          'print({k: v for k, v in os.environ.items() if k.startswith("TCA_HARNESS")}, sys.argv[2], file=sys.stderr, flush=True)\n'
                          'print("ready now", file=sys.stderr, flush=True)\ntime.sleep(60)\n')
        target = targets.Target('t', f'{PYTHON} env.py {{port}} "{{env}}"', self.workspace.root, ready='ready now',
                                env={'EXTRA': 'yes'})
        launched = targets.launch(target, 'replay', self.workspace.root / 'fixtures', 4)
        try:
            output = '\n'.join(launched.output())
            for expected in ("'TCA_HARNESS': '1'", "'TCA_HARNESS_NETWORK': 'replay'", "'TCA_HARNESS_SEED': '4'",
                             f"'TCA_HARNESS_PORT': '{launched.port}'", 'EXTRA=yes TCA_HARNESS_NETWORK=replay'):
                self.assertIn(expected, output)
            child = int((self.workspace.root / 'child.pid').read_text())
        finally:
            launched.stop()
        self.assertIsNotNone(launched.process.poll())
        self.assertFalse(launched.crashed())
        time.sleep(0.1)
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)

    def test_launch_failures_include_output(self):
        early = targets.Target('t', 'echo boom >&2; exit 4', self.workspace.root, ready='never')
        with self.assertRaisesRegex(targets.TargetError, r'exited with code 4[\s\S]*boom'):
            targets.launch(early)
        slow = targets.Target('t', 'sleep 30', self.workspace.root, ready='never', ready_timeout=0.3)
        started = time.monotonic()
        with self.assertRaisesRegex(targets.TargetError, 'not ready after 0.3s'):
            targets.launch(slow)
        self.assertLess(time.monotonic() - started, 5)


class JourneyRunTests(unittest.TestCase):
    def setUp(self):
        self.workspace = Workspace()
        self.addCleanup(self.workspace.cleanup)

    def test_passing_journey_with_expect_checks_budget_and_report(self):
        code, out, err = self.workspace.cli('journey', 'run', 'journeys/add-book.toml', '--report', 'run.jsonl')
        self.assertEqual(code, 0, out + err)
        self.assertRegex(out, r'^PASS  Add a book  \(journeys/add-book.toml\)  4 step\(s\), 2 request\(s\)')
        events = [json.loads(line) for line in (self.workspace.root / 'run.jsonl').read_text().splitlines()]
        self.assertEqual([e['event'] for e in events if e['event'] in ('goal_started', 'goal_finished')],
                         ['goal_started', 'goal_finished'])
        self.assertTrue(all(e['traceVersion'] == 1 for e in events))
        self.assertEqual(sum(e['event'] == 'dispatch' for e in events), 4)
        self.assertTrue(any(e['event'] == 'target_output' and any('listening' in l for l in e['lines']) for e in events))
        trace = trace_view.load_trace(self.workspace.root / 'run.jsonl')
        self.assertEqual(trace['goals'][0]['status'], 'passed')
        self.assertEqual(trace['goals'][0]['name'], 'Add a book')

    def test_pace_waits_after_each_step_and_before_the_checks(self):
        started = time.monotonic()
        code, out, err = self.workspace.cli('journey', 'run', 'journeys/add-book.toml', '--pace', '0.25')
        elapsed = time.monotonic() - started
        self.assertEqual(code, 0, out + err)
        self.assertGreaterEqual(elapsed, 5 * 0.25)  # 4 steps + once before the checks
        self.assertEqual(journeys.build_parser().parse_args(['journey', 'run', 'x.toml']).pace, 0)

    def test_each_run_is_a_fresh_process(self):
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/add-book.toml', 'journeys/add-book.toml')
        self.assertEqual(code, 0, out)
        self.assertIn('2 passed, 0 failed', out)

    def test_unresolved_step_shows_the_view_goal_and_hint(self):
        text = (self.workspace.root / 'journeys/add-book.toml').read_text().replace('"Set title"', '"Set titel"')
        self.workspace.journey('moved', text)
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/moved.toml')
        self.assertEqual(code, 1)
        self.assertIn('FAIL  Add a book  (journeys/moved.toml)\n  step 2 "Set titel": no offered operation matches', out)
        self.assertIn('  current view:\n    Editor (root/shelf/editor)', out)
        self.assertIn('setTitle  - Set title', out)
        self.assertIn('goal: Add a book called Dune', out)
        self.assertIn('remaining steps: "Set titel", "Save", "Refresh"', out)
        self.assertIn('hint: re-solve it: `tca record start journeys/moved.toml`', out)

    def test_failed_expect_check_and_budget(self):
        text = (self.workspace.root / 'journeys/add-book.toml').read_text()
        self.workspace.journey('expect', text.replace('expect = "not editor"', 'expect = "editor.title == \'Emma\'"'))
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/expect.toml')
        self.assertEqual(code, 1)
        self.assertIn('step 3 "Save": expected `editor.title == \'Emma\'` to hold', out)
        self.workspace.journey('check', text.replace("b.title == 'Dune'", "b.title == 'Emma'"))
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/check.toml')
        self.assertIn('check: "Dune is on the shelf" failed', out)
        self.workspace.journey('budget', text.replace('requests = 3', 'requests = 1'))
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/budget.toml')
        self.assertEqual(code, 1)
        self.assertIn('budget: 2 requests, budget 1', out)

    def test_network_oracle_in_block_mode(self):
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/add-book.toml', '--network', 'block')
        self.assertEqual(code, 1)
        self.assertIn('network after step 3 "Save": POST http://api.shelf.test/books attempted with the network blocked', out)

    def test_unmatched_request_in_replay_is_a_network_finding(self):
        (self.workspace.root / 'fixtures/shelf/GET_books_1.json').unlink()
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/add-book.toml')
        self.assertEqual(code, 1)
        self.assertIn('network after step 4 "Refresh": GET http://api.shelf.test/books has no fixture', out)

    def test_crash_stuck_and_dead_end(self):
        self.workspace.journey('crash', 'name = "crash"\n[[steps]]\ndo = "Add book"\n[[steps]]\ndo = "Crash"\n')
        self.workspace.journey('stuck', 'name = "stuck"\n[[steps]]\ndo = "Sync forever"\n')
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/crash.toml', 'journeys/stuck.toml',
                                          '--target', 'crashy', '--wait-ms', '200')
        self.assertEqual(code, 1)
        self.assertIn('crash after step 2 "Crash": the app process exited with code 3', out)
        self.assertIn('last output:', out)
        self.assertIn('stuck after step 1 "Sync forever": root/shelf/syncForever still running after 0.2s', out)
        self.assertIn('0 passed, 2 failed', out)

    def test_effects_that_land_after_the_last_step_are_still_caught(self):
        self.workspace.journey('late', 'name = "late"\n[[steps]]\ndo = "Add book"\n[[steps]]\ndo = "Close editor"\n')
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/late.toml', '--target', 'late')
        self.assertEqual(code, 1, out)
        self.assertIn('late response sent to the closed editor', out)
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/late.toml', '--target', 'headless')
        self.assertEqual(code, 0, out)

    def test_launch_effects_land_before_the_first_step(self):
        # The first fetch answers after the listener is up; step 1 depends on it, as a person's first tap would.
        self.workspace.journey('launch', 'name = "launch"\n[[steps]]\ndo = "Mark Launch read"\n')
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/launch.toml', '--target', 'launch')
        self.assertEqual(code, 0, out)

    def test_fixtures_path_is_absolute_when_nothing_but_the_root_is_shared(self):
        journey = journeys.Journey(path=None, name='x', fixtures=str(self.workspace.root / 'fixtures' / 'shelf'))
        near = journeys.journey_document(journey, self.workspace.root / 'journeys' / 'x.toml')
        self.assertEqual(near['fixtures'], '../fixtures/shelf')
        far = journeys.journey_document(journey, Path('/') / 'x.toml')
        self.assertEqual(far['fixtures'], str(self.workspace.root / 'fixtures' / 'shelf'))

    def test_rejected_operations(self):
        self.workspace.journey('invalid', 'name = "invalid"\n[[steps]]\ndo = "Add book"\n'
                                          '[[steps]]\ndo = "Set title"\nargs = { value = 3 }\n')
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/invalid.toml')
        self.assertEqual(code, 1)
        self.assertIn('step 2 "Set title": rejected: invalid_arguments (arguments.value: wrong JSON type)', out)

    def test_protocol_v2_skips_oracles_and_says_so_once(self):
        self.workspace.journey('live', 'name = "live"\nnetwork = "live"\n[[steps]]\ndo = "Add book"\n[[steps]]\n'
                                       'do = "Set title"\nargs = { value = "x" }\n[[steps]]\ndo = "Save"\n[budget]\nrequests = 0\n')
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/live.toml', 'journeys/live.toml', '--target', 'v2')
        self.assertEqual(code, 0, out)
        self.assertEqual(out.count('no `issues` method (protocol v2)'), 1)
        self.assertEqual(out.count('no `network` method (protocol v2)'), 1)

    def test_unsolved_and_invalid_journeys(self):
        self.workspace.journey('goal', 'name = "Only a goal"\ngoal = "Rate Dune five stars"\n')
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/goal.toml')
        self.assertEqual(code, 1)
        self.assertIn('unsolved: the journey has a goal but no steps', out)
        self.assertIn('hint: solve it: `tca record start journeys/goal.toml`', out)
        self.workspace.journey('bad', 'name = "bad"\n[checks]\nx = "__import__(\'os\')"\n')
        code, _, err = self.workspace.cli('journey', 'run', 'journeys/bad.toml')
        self.assertEqual(code, 2)
        self.assertIn("check 'x': only len, any, all", err)
        self.workspace.journey('typo', 'name = "typo"\n[[stepz]]\ndo = "x"\n')
        code, _, err = self.workspace.cli('journey', 'run', 'journeys/typo.toml')
        self.assertEqual((code, 'unknown keys: stepz' in err), (2, True))

    def test_missing_harness_toml_suggests_port(self):
        (self.workspace.root / 'harness.toml').unlink()
        code, _, err = self.workspace.cli('journey', 'run', 'journeys/add-book.toml')
        self.assertEqual(code, 2)
        self.assertIn('pass --port', err)

    def test_null_arguments_round_trip_through_json_strings(self):
        journey = journeys.Journey(path=None, name='n', steps=[journeys.Step('Set details', {'note': None, 'tags': []})])
        path = journeys.write_journey(journey, self.workspace.root / 'journeys' / 'null.toml')
        self.assertIn('args = "{\\"note\\": null, \\"tags\\": []}"', path.read_text())
        self.assertEqual(journeys.load_journey(path).steps[0].args, {'note': None, 'tags': []})


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.workspace = Workspace()
        self.addCleanup(self.workspace.cleanup)
        target, _ = targets.resolve_target('headless', self.workspace.root)
        self.app = targets.launch(target, 'replay', self.workspace.root / 'fixtures/shelf', 0)
        self.addCleanup(self.app.stop)

    def test_recording_a_session_writes_a_replayable_journey(self):
        port = str(self.app.port)
        code, out, _ = self.workspace.cli('record', 'start', 'journeys/rec.toml', '--goal', 'Add a book called Dune')
        self.assertEqual(code, 0, out)
        self.assertTrue((self.workspace.root / '.tca/recording.json').exists())
        self.assertEqual(self.workspace.cli('do', 'add book', '--port', port)[0], 0)
        code, _, err = self.workspace.cli('do', 'setTitle', '{"value": "Dune"}', '--port', port)
        self.assertEqual(code, 0)
        self.assertIn('recorded step 2: Set title', err)
        self.assertEqual(self.workspace.cli('do', 'Nope', '--port', port)[0], 2)  # Failures are not recorded.
        self.assertEqual(self.workspace.cli('do', 'root/shelf/editor/save', '--port', port, '--json')[0], 0)
        code, out, err = self.workspace.cli('record', 'stop', '--check', "Dune is on the shelf=any(b.title == 'Dune' for b in shelf.books)")
        self.assertEqual(code, 0, err)
        self.assertFalse((self.workspace.root / '.tca/recording.json').exists())
        self.assertIn('replays block the network', out)
        data = tomllib.loads((self.workspace.root / 'journeys/rec.toml').read_text())
        self.assertEqual(data['goal'], 'Add a book called Dune')
        # Each step pins the requests it made (none before Save); launch made none.
        self.assertEqual(data['steps'], [{'do': 'Add book', 'requests': []},
                                         {'do': 'Set title', 'args': {'value': 'Dune'}, 'requests': []},
                                         {'do': 'Save', 'requests': ['POST /books']}])
        self.assertEqual(data['launch_requests'], [])
        self.assertEqual(data['checks'], {'Dune is on the shelf': "any(b.title == 'Dune' for b in shelf.books)"})
        # Add the network settings and replay it on a fresh launch.
        path = self.workspace.root / 'journeys/rec.toml'
        path.write_text('fixtures = "../fixtures/shelf"\nnetwork = "replay"\n' + path.read_text())
        code, out, _ = self.workspace.cli('journey', 'run', 'journeys/rec.toml')
        self.assertEqual(code, 0, out)

    def test_re_solving_keeps_the_rest_of_the_journey(self):
        path = self.workspace.root / 'journeys/add-book.toml'
        self.assertEqual(self.workspace.cli('record', 'start', 'journeys/add-book.toml')[0], 0)
        self.workspace.cli('do', 'Add book', '--port', str(self.app.port))
        code, _, err = self.workspace.cli('record', 'stop', '--check', 'oops=len(')
        self.assertEqual(code, 2)
        self.assertIn("check 'oops': syntax error", err)
        self.assertEqual(self.workspace.cli('record', 'stop')[0], 0)
        journey = journeys.load_journey(path)
        self.assertEqual([s.do for s in journey.steps], ['Add book'])
        self.assertEqual(journey.goal, 'Add a book called Dune and see it on the shelf')
        self.assertEqual(journey.budget, {'requests': 3})
        self.assertEqual(len(journey.checks), 2)
        self.assertEqual(journey.fixtures, self.workspace.root / 'fixtures/shelf')

    def test_record_needs_a_goal_and_stop_needs_a_recording(self):
        code, _, err = self.workspace.cli('record', 'start', 'journeys/new.toml')
        self.assertEqual(code, 2)
        self.assertIn('--goal', err)
        code, _, err = self.workspace.cli('record', 'stop')
        self.assertEqual(code, 2)
        self.assertIn('no recording in progress', err)

    def test_steps_by_label_fall_back_when_labels_repeat(self):
        observation = {'revision': 1, 'sessionID': 's', 'state': {}, 'candidates': [
            {'id': 'root/rows/a/delete@1', 'feature': 'root/rows/a', 'label': 'Delete'},
            {'id': 'root/rows/b/delete@2', 'feature': 'root/rows/b', 'label': 'Delete'}]}
        features = [('root', 'Root'), ('root/rows/a', 'a'), ('root/rows/b', 'b')]
        view = tca.focus_view(observation, features)
        self.assertEqual(journeys.step_query(view, observation, observation['candidates'][1]), 'root/rows/b/delete')


class AttachTests(unittest.TestCase):
    def test_port_attaches_without_harness_toml(self):
        workspace = Workspace()
        self.addCleanup(workspace.cleanup)
        target, _ = targets.resolve_target('headless', workspace.root)
        app = targets.launch(target, 'replay', workspace.root / 'fixtures/shelf', 0)
        self.addCleanup(app.stop)
        (workspace.root / 'harness.toml').unlink()
        code, out, _ = workspace.cli('journey', 'run', 'journeys/add-book.toml', '--port', app.port)
        self.assertEqual(code, 0, out)
        self.assertIn('share its state', out)


if __name__ == '__main__':
    unittest.main()
