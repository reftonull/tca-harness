"""A temporary project with a harness.toml whose targets launch fake_app.py, plus fixtures and journeys."""
import contextlib
import io
import json
from pathlib import Path
import shlex
import sys
import tempfile

CLI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CLI))
import journeys  # noqa: E402
import tca  # noqa: E402

FAKE = Path(__file__).resolve().with_name('fake_app.py')
PYTHON = shlex.quote(sys.executable)

TARGETS = {
    'headless': '',
    'buggy': '--bug --strand-on-error',
    'crashy': '--crashy --stuck',
    'unseeded': '--unseeded-ids',
    'v2': '--v2',
    'late': '--late-issue',
    'launch': '--launch-load',
    'racy': '--race-save',
    'search': '--search',
    'stale': '--stale-search',
    'stale-quiet': '--stale-search --quiet-search',
}

ADD_BOOK = '''name = "Add a book"
goal = "Add a book called Dune and see it on the shelf"
fixtures = "../fixtures/shelf"
network = "replay"

[[steps]]
do = "Add book"

[[steps]]
do = "Set title"
args = { value = "Dune" }

[[steps]]
do = "Save"
expect = "not editor"

[[steps]]
do = "Refresh"

[checks]
"Dune is on the shelf" = "any(b.title == 'Dune' for b in shelf.books)"
"nothing is loading" = "not shelf.isLoading"

[budget]
requests = 3
'''


class Workspace:
    def __init__(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name).resolve()
        lines = []
        for name, flags in TARGETS.items():
            lines += [f'[targets.{name}]', f'launch = "{PYTHON} {FAKE} --port {{port}} {flags}"',
                      'port = "auto"', 'ready = "TCA harness listening"', 'ready_timeout = 10', '']
        # The UI rung: no ready line (port polling) and settings passed through {env}.
        lines += ['[targets.ui]', f'launch = "TCA_HARNESS_PORT={{port}} {{env}} {PYTHON} {FAKE} --ui"', 'ready_timeout = 10', '']
        (self.root / 'harness.toml').write_text('\n'.join(lines))
        fixtures = self.root / 'fixtures' / 'shelf'
        fixtures.mkdir(parents=True)
        for method, path, status in (('POST', 'books', 201), ('GET', 'books', 200)):
            (fixtures / f'{method}_{path}_1.json').write_text(json.dumps({
                'request': {'method': method, 'url': f'http://api.shelf.test/{path}', 'body': None},
                'response': {'status': status, 'headers': {}, 'body': {}}}))
        (self.root / 'journeys').mkdir()
        self.journey('add-book', ADD_BOOK)

    def journey(self, name, text):
        path = self.root / 'journeys' / f'{name}.toml'
        path.write_text(text)
        return path

    def cli(self, *argv):
        """Run `tca ARGV...` in the workspace; returns (code, stdout, stderr)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.chdir(self.root), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = tca.main([str(a) for a in argv])
            except SystemExit as exit:
                code = exit.code
        return code, out.getvalue(), err.getvalue()

    def cleanup(self):
        self.directory.cleanup()
