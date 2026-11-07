"""`tca explore`, `tca chaos`, `tca determinism` and `tca diff`, end to end against fake_app.py."""
import random
import tomllib
import unittest
from unittest.mock import patch

from support import Workspace, journeys
import exploration
from fake_app import validate

TWO_SAVES = '''name = "Two books"
fixtures = "../fixtures/shelf"
network = "replay"

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
'''


class GeneratorTests(unittest.TestCase):
    SCHEMAS = [
        {'type': 'object', 'additionalProperties': False, 'required': ['value'], 'properties': {'value': {'type': 'string'}}},
        {'type': 'object', 'properties': {'value': {'type': 'string', 'minLength': 1, 'maxLength': 3}}},
        {'type': 'object', 'properties': {'value': {'type': 'string', 'enum': ['low', 'normal', 'high']}}},
        {'type': 'object', 'properties': {'value': {'type': 'number', 'minimum': 0, 'maximum': 1}}},
        {'type': 'object', 'properties': {'n': {'type': 'integer'}, 'x': {'type': 'number'}, 'b': {'type': 'boolean'}}},
        {'type': 'object', 'properties': {'note': {'anyOf': [{'type': 'string'}, {'type': 'null'}]},
                                          'items': {'type': 'array', 'items': {'type': 'object', 'properties': {
                                              'id': {'type': 'integer'}, 'tags': {'type': 'array', 'items': {'type': 'string'}}}}}}},
    ]

    def test_generated_arguments_satisfy_their_schema(self):
        rng = random.Random(0)
        for schema in self.SCHEMAS:
            for _ in range(200):
                value = exploration.generate(schema, rng)
                self.assertIsNone(validate(schema, value), (schema, value))

    def test_corpus_covers_edge_values_and_is_seeded(self):
        schema = self.SCHEMAS[0]
        values = {exploration.generate(schema, random.Random(n))['value'] for n in range(400)}
        self.assertIn('', values)
        self.assertTrue(any(len(v) > 1000 for v in values))
        self.assertTrue(any(any(ord(c) > 0xffff for c in v) for v in values))
        nullable = self.SCHEMAS[5]['properties']['note']
        self.assertIn(None, [exploration.generate(nullable, random.Random(n)) for n in range(50)])
        bounded = {exploration.generate(self.SCHEMAS[3], random.Random(n))['value'] for n in range(50)}
        self.assertTrue({0, 1} <= bounded)
        self.assertEqual(exploration.generate(schema, random.Random(5)), exploration.generate(schema, random.Random(5)))


class DeltaDebuggingTests(unittest.TestCase):
    def test_minimizes_to_the_needed_steps(self):
        calls = []

        def test(items):
            calls.append(items)
            return 3 in items and 7 in items
        self.assertEqual(exploration.ddmin(list(range(20)), test, 1000), [3, 7])

    def test_order_dependent_pairs_and_budget(self):
        self.assertEqual(exploration.ddmin(['a', 'x', 'a', 'y'], lambda s: s.count('a') >= 2, 100), ['a', 'a'])
        shrunk = exploration.ddmin(list(range(64)), lambda s: 0 in s and 63 in s, 3)
        self.assertTrue(0 in shrunk and 63 in shrunk)  # Out of budget: still a reproducing list.


class PatternTests(unittest.TestCase):
    def setUp(self):
        self.workspace = Workspace()
        self.addCleanup(self.workspace.cleanup)

    def test_explore_finds_the_planted_duplicate_and_shrinks_it_to_two_steps(self):
        code, out, err = self.workspace.cli('explore', '--target', 'buggy', '--runs', '3', '--steps', '25', '--seed', '3',
                                            '--fixtures', 'fixtures/shelf', '--report', 'explore.jsonl')
        self.assertEqual(code, 1, out + err)
        self.assertIn('explore: 3 run(s) of up to 25 step(s) on buggy, seed 3: 1 finding(s)', out)
        self.assertRegex(out, r'invariant  \d+ -> 2  \.tca/findings/invariant-1\.toml  no duplicate books')
        finding = self.workspace.root / '.tca/findings/invariant-1.toml'
        data = tomllib.loads(finding.read_text())
        self.assertEqual(data['steps'], [{'do': 'Add sample book'}, {'do': 'Add sample book'}])
        self.assertEqual((data['seed'], data['network'], data['fixtures']), (3, 'replay', '../../fixtures/shelf'))
        code, out, _ = self.workspace.cli('journey', 'run', '.tca/findings/invariant-1.toml', '--target', 'buggy')
        self.assertEqual(code, 1)
        self.assertIn('invariant after step 2 "Add sample book": no duplicate books', out)
        code, out, _ = self.workspace.cli('journey', 'run', '.tca/findings/invariant-1.toml')
        self.assertEqual(code, 1)  # The fixed app no longer offers a second sample book.
        self.assertIn('step 2 "Add sample book": no offered operation matches', out)

    def test_explore_on_a_correct_app_finds_nothing(self):
        code, out, err = self.workspace.cli('explore', '--runs', '2', '--steps', '15', '--fixtures', 'fixtures/shelf')
        self.assertEqual(code, 0, out + err)
        self.assertIn(': 0 finding(s)', out)

    def test_explore_from_a_journey_end_state(self):
        code, out, err = self.workspace.cli('explore', '--target', 'buggy', '--runs', '1', '--steps', '10', '--seed', '1',
                                            '--journey', 'journeys/add-book.toml')
        self.assertIn('run(s) of up to 10 step(s)', out, err)
        for path in (self.workspace.root / '.tca/findings').glob('*.toml'):
            steps = [s['do'] for s in tomllib.loads(path.read_text())['steps']]
            self.assertEqual(steps[:4], ['Add book', 'Set title', 'Save', 'Refresh'])

    def test_chaos_passes_a_resilient_app_and_targets_the_nth_request(self):
        self.workspace.journey('two', TWO_SAVES)
        code, out, err = self.workspace.cli('chaos', 'journeys/two.toml', '--faults', 'status500,offline')
        self.assertEqual(code, 0, out + err)
        self.assertIn('chaos: Two books: 2 request(s) x 2 fault(s), 0 failure(s)', out)
        self.assertRegex(out, r'3\s+POST /books\s+status500\s+ok')  # Save is offered again: a retry.
        self.assertRegex(out, r'6\s+POST /books #2\s+offline\s+ok')

    def test_chaos_flags_a_stranded_user_and_writes_a_repro(self):
        with patch.object(exploration, 'WAY_FORWARD_SECONDS', 0.5):
            code, out, _ = self.workspace.cli('chaos', 'journeys/add-book.toml', '--target', 'buggy', '--faults', 'status500')
        self.assertEqual(code, 1)
        self.assertRegex(out, r'3\s+POST /books\s+status500\s+FAIL stranded: neither "Refresh" nor a retry of "Save" offered')
        self.assertRegex(out, r'4\s+GET /books\s+status500\s+ok')
        data = tomllib.loads((self.workspace.root / '.tca/findings/stranded-1.toml').read_text())
        self.assertEqual([s['do'] for s in data['steps']], ['Add book', 'Set title', 'Save', 'Refresh'])
        self.assertNotIn('expect', data['steps'][2])
        self.assertEqual(data['faults'], [{'match': {'method': 'POST', 'path': '/books'}, 'kind': 'status', 'status': 500, 'times': 1}])
        code, _, _ = self.workspace.cli('journey', 'run', '.tca/findings/stranded-1.toml', '--target', 'buggy')
        self.assertEqual(code, 1)

    def test_chaos_needs_a_passing_baseline(self):
        text = (self.workspace.root / 'journeys/add-book.toml').read_text().replace('"Refresh"', '"Reload"')
        self.workspace.journey('broken', text)
        code, out, _ = self.workspace.cli('chaos', 'journeys/broken.toml')
        self.assertEqual(code, 1)
        self.assertIn('baseline replay failed', out)

    def test_determinism(self):
        code, out, _ = self.workspace.cli('determinism', 'journeys/add-book.toml', '--runs', '2')
        self.assertEqual(code, 0, out)
        self.assertIn('PASS  determinism: Add a book  2 runs, seed 0', out)
        code, out, _ = self.workspace.cli('determinism', 'journeys/add-book.toml', '--runs', '2', '--target', 'unseeded')
        self.assertEqual(code, 1)
        self.assertIn('differs after step 3 "Save" (run 1 vs run 2):', out)
        self.assertRegex(out, r'shelf\.books\[0\]\.id: "\w+" vs "\w+"')
        data = tomllib.loads((self.workspace.root / '.tca/findings/nondeterminism-1.toml').read_text())
        self.assertEqual(len(data['steps']), 3)

    def test_diff_reports_the_first_differing_path(self):
        code, out, _ = self.workspace.cli('diff', 'journeys/add-book.toml', '--targets', 'headless,ui')
        self.assertEqual(code, 1, out)
        self.assertIn('differs after step 1 "Add book" (headless vs ui):', out)
        self.assertIn('editor.focusedField: <missing> vs "title"', out)
        code, out, _ = self.workspace.cli('diff', 'journeys/add-book.toml', '--targets', 'headless,unseeded')
        self.assertEqual(code, 1)
        self.assertIn('shelf.books[0].id: "book-1" vs', out)

    def test_differences_ignore_bookkeeping_keys(self):
        left = {'a': [1, {'b': 2, 'revision': 1}], 'sessionID': 'x'}
        right = {'a': [1, {'b': 3, 'revision': 2}, 4], 'sessionID': 'y'}
        self.assertEqual(exploration.differences(left, right), [('a[1].b', 2, 3), ('a[2]', '<missing>', 4)])

    def test_usage_errors(self):
        self.assertEqual(self.workspace.cli('chaos', 'journeys/add-book.toml', '--faults', 'meteor')[0], 2)
        self.assertEqual(self.workspace.cli('diff', 'journeys/add-book.toml', '--targets', 'headless')[0], 2)
        self.assertEqual(self.workspace.cli('determinism', 'journeys/add-book.toml', '--runs', '1')[0], 2)


if __name__ == '__main__':
    unittest.main()
