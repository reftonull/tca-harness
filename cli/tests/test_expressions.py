"""Check expressions: the allowed subset, None-propagation, and inputs that must be refused."""
from pathlib import Path
import sys
import tomllib
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import expressions  # noqa: E402
from expressions import ExpressionError, evaluate, holds  # noqa: E402
import tomlout  # noqa: E402

STATE = {
    'shelf': {'books': [{'id': 'a', 'title': 'Dune', 'isRead': False, 'pages': 412},
                        {'id': 'b', 'title': 'Emma', 'isRead': True, 'pages': 300}],
              'isLoading': False, 'unreadCount': 1, 'tags': {'sf': 2}},
    'editor': None,
    'destination': {'case': 'edit', 'value': {'draft': 'x'}},
    'count': 3,
    'name': 'Ünïcödé',
}


class AllowedTests(unittest.TestCase):
    def test_spec_examples(self):
        self.assertTrue(holds("any(b.title == 'Dune' for b in shelf.books)", STATE))
        self.assertTrue(holds('not shelf.isLoading', STATE))
        self.assertTrue(holds('not editor', STATE))

    def test_missing_keys_and_reads_from_none_are_none(self):
        self.assertIsNone(evaluate('nothing', STATE))
        self.assertIsNone(evaluate('editor.title', STATE))
        self.assertIsNone(evaluate('editor.title.length', STATE))
        self.assertIsNone(evaluate("editor['title']", STATE))
        self.assertTrue(holds('not editor.title', STATE))
        self.assertIsNone(evaluate('shelf.books[5]', STATE))
        self.assertTrue(holds('editor is None and nothing is None', STATE))
        self.assertFalse(holds('shelf.missing > 0', STATE))  # Ordering with a missing value is false.
        self.assertFalse(holds("'x' in editor", STATE))

    def test_indexing_slices_and_enums(self):
        self.assertEqual(evaluate('shelf.books[0].title', STATE), 'Dune')
        self.assertEqual(evaluate('shelf.books[-1].id', STATE), 'b')
        self.assertEqual(evaluate("shelf['tags']['sf']", STATE), 2)
        self.assertEqual(evaluate('shelf.books[0:1][0].id', STATE), 'a')
        self.assertEqual(evaluate('name[0]', STATE), 'Ü')
        self.assertTrue(holds("destination.case == 'edit' and destination.value.draft == 'x'", STATE))

    def test_comparisons_boolean_logic_and_arithmetic(self):
        self.assertTrue(holds('1 < count <= 3', STATE))
        self.assertTrue(holds("count != 4 and (count * 2 - 1) / 5 == 1", STATE))
        self.assertEqual(evaluate('count // 2 + count % 2', STATE), 2)
        self.assertEqual(evaluate('-count', STATE), -3)
        self.assertEqual(evaluate("editor or 'none'", STATE), 'none')
        self.assertTrue(holds("'sf' in shelf.tags and 'Du' in shelf.books[0].title", STATE))
        self.assertTrue(holds("'zz' not in shelf.tags", STATE))
        self.assertEqual(evaluate("'ab' + 'cd'", STATE), 'abcd')
        self.assertEqual(evaluate("'-' * 3", STATE), '---')

    def test_functions_and_generators(self):
        self.assertEqual(evaluate('len(shelf.books)', STATE), 2)
        self.assertEqual(evaluate('sum(b.pages for b in shelf.books)', STATE), 712)
        self.assertEqual(evaluate('max(b.pages for b in shelf.books)', STATE), 412)
        self.assertEqual(evaluate('min(b.pages for b in shelf.books)', STATE), 300)
        self.assertEqual(evaluate('sorted(b.title for b in shelf.books)', STATE), ['Dune', 'Emma'])
        self.assertTrue(holds('len(set(b.id for b in shelf.books)) == len(shelf.books)', STATE))
        self.assertTrue(holds('all(b.pages > 100 for b in shelf.books)', STATE))
        self.assertTrue(holds('shelf.unreadCount == sum(1 for b in shelf.books if not b.isRead)', STATE))
        self.assertTrue(holds('any(a.id != b.id for a in shelf.books for b in shelf.books)', STATE))
        self.assertTrue(holds('not any(b for b in editor)', STATE))  # Iterating a missing value: nothing.
        self.assertEqual(evaluate('sorted(k for k in shelf.tags)', STATE), ['sf'])

    def test_compile_once_evaluate_many(self):
        tree = expressions.compile_expression('count > 2')
        self.assertTrue(holds(tree, STATE))
        self.assertFalse(holds(tree, {'count': 1}))


class RefusedTests(unittest.TestCase):
    MALICIOUS = [
        "__import__('os').system('true')",
        'open("/etc/passwd")',
        'eval("1")',
        'exec("x=1")',
        'getattr(shelf, "books")',
        'shelf.__class__',
        "().__class__.__bases__[0].__subclasses__()",
        "(lambda: 1)()",
        "[x for x in shelf.books]",
        "{x for x in shelf.books}",
        "{'a': 1}",
        "[1, 2]",
        "(1, 2)",
        "f'{count}'",
        "count if count else 0",
        "x := 1",
        "2 ** 10",
        "count << 2",
        "count & 1",
        "~count",
        "len(*shelf.books)",
        "sorted(shelf.books, key=len)",
        "shelf.books.__len__()",
        "shelf.books.count('a')",
        "print(1)",
        "type(count)",
        "__builtins__",
        "[b async for b in shelf.books]",
        "await count",
        "count; count",
        "import os",
        "b'bytes'",
        "...",
        "1j",
    ]

    def test_refused_at_compile_time(self):
        for source in self.MALICIOUS:
            with self.subTest(source=source):
                with self.assertRaises(ExpressionError):
                    expressions.compile_expression(source)

    def test_runtime_errors_are_expression_errors(self):
        for source in ['len(editor)', 'count / 0', "count + 'a'", "shelf.books.x", "count[0]",
                       "shelf.books['x']", "set(shelf.books)", "min(b for b in editor)", "'a' < 1", "-name",
                       "1 in name"]:
            with self.subTest(source=source):
                with self.assertRaises(ExpressionError):
                    evaluate(source, STATE)

    def test_resource_limits(self):
        with self.assertRaises(ExpressionError):
            evaluate("'x' * 1000000000", STATE)
        with self.assertRaises(ExpressionError):
            compile_expression_of_length(expressions.MAX_LENGTH + 1)
        with self.assertRaises(ExpressionError):
            expressions.compile_expression('-' * 100 + '1')
        with self.assertRaises(ExpressionError):
            expressions.compile_expression('not ' * 100 + 'count')
        big = {'xs': list(range(2000))}
        with self.assertRaises(ExpressionError):
            evaluate('sum(1 for a in xs for b in xs)', big)

    def test_empty_and_unparseable(self):
        for source in ['', '   ', 'count >', 'count ==== 1', None]:
            with self.subTest(source=source):
                with self.assertRaises(ExpressionError):
                    expressions.compile_expression(source)


def compile_expression_of_length(length):
    return expressions.compile_expression('1' + ' ' * (length - 1))


class TomlWriterTests(unittest.TestCase):
    def test_round_trips_journey_shaped_documents(self):
        document = {
            'name': 'Add "a" book', 'goal': 'line\nbreak\ttab \\ backslash \u0007 bell', 'seed': 3, 'terminal': True,
            'ratio': 0.5, 'big': 1e20, 'list': [1, 'two', [3.0]],
            'steps': [{'do': 'Add book'}, {'do': 'Set title', 'args': {'value': 'Dune', 'nested': {'a': [1, {'b': False}]}}},
                      {'do': 'root/shelf/save', 'expect': "not editor and 'x' != \"y\""}],
            'checks': {'Dune is on the shelf': "any(b.title == 'Dune' for b in shelf.books)", 'plain_key': 'True'},
            'budget': {'requests': 3},
            'faults': [{'match': {'method': 'POST', 'path': '/books'}, 'kind': 'status', 'status': 500, 'times': 1}],
            'unicode key ü': '日本語 👩‍👩‍👧',
        }
        text = tomlout.dumps(document, header='Found by a test.\nSecond line.')
        self.assertTrue(text.startswith('# Found by a test.\n# Second line.\n'))
        self.assertEqual(tomllib.loads(text), document)
        self.assertLess(text.index('[[steps]]'), text.index('[checks]'))

    def test_special_floats_and_null(self):
        self.assertEqual(tomllib.loads(tomlout.dumps({'a': float('inf'), 'b': -float('inf')})), {'a': float('inf'), 'b': -float('inf')})
        with self.assertRaises(ValueError):
            tomlout.dumps({'a': None})
        self.assertTrue(tomlout.contains_null({'a': [1, {'b': None}]}))


if __name__ == '__main__':
    unittest.main()
