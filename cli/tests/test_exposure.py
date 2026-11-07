"""`tca exposure` end to end against fake_app.py: live inspect, journey runs and reports."""
import json
import unittest

from support import Workspace
from test_fixtures import start_fake


class ExposureTests(unittest.TestCase):
    def setUp(self):
        self.workspace = Workspace()
        self.addCleanup(self.workspace.cleanup)

    def exposure(self, *argv):
        code, out, err = self.workspace.cli('exposure', *argv)
        return code, out, err

    def feature(self, report, path):
        return next(f for f in report['features'] if f['path'] == path)

    def test_live_app_lists_the_catalog_unexposed_actions_and_what_is_not_reached(self):
        port = start_fake(self)
        code, out, err = self.exposure('--port', port)
        self.assertEqual(code, 0, out + err)
        self.assertIn('exposure: 3 feature(s) from 1 live inspect', out)
        self.assertIn('unexposed (ignored): booksResponse', out)
        self.assertIn('unexposed (unannotated): swipeToDelete', out)
        self.assertIn('root/shelf/editor  Editor  (not reached)', out)
        self.assertIn('2 of 3 feature(s) reached', out)
        self.assertIn('0 exercised (0%)', out)
        self.assertIn('not reached (1): root/shelf/editor', out)

    def test_journeys_count_exercised_operations_by_route(self):
        code, out, err = self.exposure('--journeys', 'journeys/*.toml', '--json')
        self.assertEqual(code, 0, out + err)
        report = json.loads(out)
        shelf = {o['name']: o['exercised'] for o in self.feature(report, 'root/shelf')['operations']}
        self.assertEqual(shelf['addBook'], 1)
        self.assertEqual(shelf['refresh'], 1)
        self.assertEqual(shelf['dismissError'], 0)  # Declared, never offered: still counted as exposed
        editor = self.feature(report, 'root/shelf/editor')
        self.assertTrue(editor['reached'])
        self.assertEqual({o['name']: o['exercised'] for o in editor['operations']},
                         {'setTitle': 1, 'setRating': 0, 'setDetails': 0, 'save': 1})
        self.assertEqual(editor['unexposed'], [{'action': 'binding', 'reason': 'binding'}])
        totals = report['totals']
        self.assertEqual((totals['features'], totals['reached'], totals['operations'], totals['exercised']), (3, 3, 10, 4))  # toggleRead/{id} for the book it added
        self.assertEqual(totals['unexposedByReason'], {'lifecycle': 1, 'ignored': 1, 'unannotated': 1, 'binding': 1})
        self.assertEqual(report['runs'], [{'file': 'journeys/add-book.toml', 'passed': True}])

    def test_reports_carry_mounts_and_the_catalog(self):
        code, out, err = self.workspace.cli('journey', 'run', 'journeys/add-book.toml', '--report', 'run.jsonl')
        self.assertEqual(code, 0, out + err)
        events = [json.loads(line) for line in (self.workspace.root / 'run.jsonl').read_text().splitlines()]
        kinds = [e['event'] for e in events]
        self.assertEqual(kinds.count('catalog'), 1)
        self.assertIn('mounts', kinds)
        dispatch = next(e for e in events if e['event'] == 'dispatch')
        self.assertEqual(dispatch['feature'], 'root/shelf')
        code, out, err = self.exposure('--reports', 'run.jsonl', '--json')
        self.assertEqual(code, 0, out + err)
        self.assertEqual(json.loads(out)['totals']['exercised'], 4)

    def test_older_reports_match_dispatches_by_route_without_inspect_data(self):
        events = [
            {'event': 'goal_started', 'goal': 'old'},
            {'event': 'dispatch', 'candidate': 'root/shelf/addBook@I-SHELF', 'receipt': {'status': 'succeeded'},
             'observation': {'candidates': [
                 {'id': 'root/shelf/closeEditor@I-SHELF', 'feature': 'root/shelf', 'label': 'Close editor'},
                 {'id': 'root/shelf/editor/save@I-E', 'feature': 'root/shelf/editor', 'label': 'Save'}]}},
            {'event': 'dispatch', 'candidate': 'root/shelf/editor/save@I-E', 'receipt': None, 'error': 'stale_revision'},
            {'event': 'dispatch', 'candidate': 'root/shelf/toggleRead/4f1c2d3e-0000-4000-8000-000000000001@I-SHELF',
             'receipt': {'status': 'succeeded'}},
        ]
        (self.workspace.root / 'old.jsonl').write_text('\n'.join(map(json.dumps, events)))
        code, out, err = self.exposure('--reports', 'old.jsonl')
        self.assertEqual(code, 0, out + err)
        self.assertIn('toggleRead/{id}', out)
        self.assertIn('never inspected: unexposed actions unknown', out)
        self.assertIn('4 exposed operation(s), 2 exercised (50%)', out)  # The rejected save didn't run

    def test_min_exercised_fails_below_the_threshold(self):
        port = start_fake(self)
        code, out, _ = self.exposure('--port', port, '--min-exercised', '10')
        self.assertEqual(code, 1)
        self.assertIn('min-exercised: 0% of exposed operations exercised, below 10%', out)
        code, _, err = self.exposure('--port', port, '--min-exercised', '120')
        self.assertEqual(code, 2)
        self.assertIn('percentage', err)

    def test_a_v2_app_without_unexposed_metadata_says_so(self):
        port = start_fake(self, '--v2')
        code, out, err = self.exposure('--port', port)
        self.assertEqual(code, 0, out + err)
        self.assertIn('the app does not report unexposed actions', out)


if __name__ == '__main__':
    unittest.main()
