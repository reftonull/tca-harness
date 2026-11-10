import contextlib
import importlib.util
import io
import json
import gzip
import base64
import re
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location('trace_view', ROOT / 'trace_view.py')
viewer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(viewer)
spec = importlib.util.spec_from_file_location('cli_trace_test', ROOT / 'tca.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class TraceTests(unittest.TestCase):
    def test_legacy_timing_is_not_invented_and_summary_is_not_a_state_diff(self):
        data = viewer.normalize([
            {'event': 'goal_started', 'goal': 'game'},
            {'event': 'decision', 'choice': 'root/play@id', 'latencyMs': 180},
            {'event': 'goal_finished', 'goal': 'game', 'status': 'passed', 'elapsedMs': 2000,
             'state': {'score': 12}},
        ])
        self.assertFalse(data['timed'])
        self.assertIsNone(data['goals'][0]['events'][1]['timing'])
        self.assertEqual(data['goals'][0]['events'][-1]['stateEvidence'], 'summary')
        self.assertIsNone(data['goals'][0]['events'][-1]['before'])

    def test_measured_and_configured_spans_have_different_semantics(self):
        data = viewer.normalize([
            {'event': 'decision', 'tMs': 1200, 'latencyMs': 200},
            {'event': 'presentation_settle', 'tMs': 1300, 'seconds': 3},
        ])
        measured, configured = data['goals'][0]['events']
        self.assertEqual(measured['timing'], {'startMs': 1000, 'endMs': 1200})
        self.assertEqual(configured['timing'], {'startMs': 1300, 'endMs': 4300, 'configured': True})

    def test_cancelled_receipt_does_not_override_verified_goal(self):
        data = viewer.normalize([
            {'event': 'goal_started', 'goal': 'navigate'},
            {'event': 'dispatch', 'ok': True, 'receipt': {'status': 'cancelled'}},
            {'event': 'goal_finished', 'status': 'passed'},
        ])
        self.assertEqual(data['goals'][0]['status'], 'passed')
        self.assertEqual(data['goals'][0]['events'][1]['raw']['receipt']['status'], 'cancelled')

    def test_repeated_goal_names_remain_distinct(self):
        data = viewer.normalize([
            {'event': 'goal_started', 'goal': 'run'}, {'event': 'verified'},
            {'event': 'goal_started', 'goal': 'run'}, {'event': 'stopped', 'reason': 'step_limit'},
        ])
        self.assertEqual([g['status'] for g in data['goals']], ['passed', 'failed'])
        self.assertNotEqual(data['goals'][0]['id'], data['goals'][1]['id'])

    def test_decision_evidence_survives_and_lossy_summary_does_not_replace_snapshot(self):
        observation = {'state': {'score': 0, 'faces': [1]}, 'candidates': [{'id': 'root/play'}]}
        data = viewer.normalize([
            {'event': 'decision', 'observation': observation},
            {'event': 'goal_finished', 'state': {'score': 0}},
            {'event': 'decision', 'observation': {'state': {'score': 12, 'faces': [1]}}},
        ])
        events = data['goals'][0]['events']
        self.assertEqual(events[0]['alternatives'], observation['candidates'])
        self.assertEqual(events[-1]['before'], observation['state'])

    def test_partial_trace_warns_and_executable_content_stays_inert(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'run.jsonl'
            source.write_text(json.dumps({'event': 'goal_started', 'description': '</script><script>alert(1)</script>'}) + '\n{"event":')
            target = viewer.render_trace(source)
            data = viewer.load_trace(source)
            self.assertEqual(len(data['warnings']), 1)
            rendered = target.read_text()
            self.assertNotIn('</script><script>alert(1)', rendered)
            encoded = re.search(r'application/gzip\+base64">([^<]+)', rendered).group(1)
            restored = json.loads(gzip.decompress(base64.b64decode(encoded)))
            self.assertEqual(restored['goals'][0]['description'], '</script><script>alert(1)</script>')
            with self.assertRaises(ValueError):
                viewer.render_trace(source, source)

    def test_summary_only_trace_explains_missing_events(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'summary.jsonl'
            source.write_text('{"event":"suite_finished","passed":8}\n')
            with self.assertRaisesRegex(ValueError, 'No inspectable run events'):
                viewer.load_trace(source)

    def test_empty_input_explains_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'empty.jsonl'
            source.write_text('not JSON\n')
            with self.assertRaisesRegex(ValueError, 'No run events'):
                viewer.load_trace(source)

    def test_emit_adds_monotonic_evidence_without_overwriting_goal_duration(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            cli.emit('goal_finished', elapsedMs=42)
            cli.emit('decision')
        first, second = map(json.loads, output.getvalue().splitlines())
        self.assertEqual(first['elapsedMs'], 42)
        self.assertLess(first['seq'], second['seq'])
        self.assertLessEqual(first['tMs'], second['tMs'])
        self.assertIn('timestamp', first)

    def test_model_run_records_inputs_arguments_wait_and_verification(self):
        class FakeHost:
            def __init__(self):
                self.observation = {'state': {'saved': False}, 'revision': 1,
                                    'candidates': [{'id': 'root/save', 'argumentSchema': {'type': 'object'}}]}

            def call(self, method, **kwargs):
                if method == 'verify':
                    return {'ok': True, 'verified': self.observation['state']['saved']}
                if method == 'wait':
                    self.observation = dict(self.observation, state={'saved': True}, revision=2)
                return {'ok': True, 'observation': self.observation}

            def dispatch(self, candidate, **kwargs):
                self.arguments = kwargs['arguments']
                return {'ok': True, 'receipt': {'requestID': 'save-1', 'status': 'running'},
                        'observation': self.observation}

        host = FakeHost()
        output = io.StringIO()
        with patch.object(cli, 'decide', return_value={'choice': 'root/save', 'model': 'classifier', 'latencyMs': 12}), \
             patch.object(cli, 'extract_arguments', return_value={'arguments': {'value': .25}, 'model': 'argument-model'}), \
             patch.object(cli.time, 'sleep'), contextlib.redirect_stdout(output):
            self.assertTrue(cli.run_goal(host, 'Save at quarter volume', 'classifier', 'saved', 2, step_delay=.1))
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([e['event'] for e in events],
                         ['goal_started', 'decision', 'arguments_generated', 'dispatch', 'wait', 'pacing', 'verified'])
        self.assertFalse(events[1]['observation']['state']['saved'])
        self.assertEqual(events[3]['arguments'], {'value': .25})
        self.assertEqual(host.arguments, {'value': .25})
        self.assertTrue(events[4]['observation']['state']['saved'])
        self.assertIn('latencyMs', events[4])
        self.assertEqual(viewer.normalize(events)['goals'][0]['status'], 'passed')

    def test_trace_command_does_not_connect_or_load_model_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'run.jsonl'
            source.write_text('{"event":"goal_started","goal":"offline"}\n')
            import sys
            with patch.dict(sys.modules, {'trace_view': viewer}), patch.object(sys, 'argv', ['tca', 'trace', '--input', str(source)]), \
                 patch.object(cli, 'Host') as host, \
                 patch.object(cli, 'model_config') as router, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cli.main(), 0)
            host.assert_not_called()
            router.assert_not_called()
            self.assertTrue(source.with_suffix('.html').exists())


if __name__ == '__main__':
    unittest.main()
