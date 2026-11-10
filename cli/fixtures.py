"""`tca fixtures coverage` and `tca fixtures record`: how well cassettes cover what journeys request.

Every request in a run's log says how it was answered (`match`): `exact`, `ordered` (one of several
equal recordings, by occurrence), `template` (a cassette for the same `match.json` path template),
`path` (fallback: the latest cassette for the method and path), `synthetic` (a `match.json` rule, such
as the terminal page of a paginated endpoint), `fault`, `blocked` or `live`. Coverage groups them by
endpoint (method and templated path), lists cassettes nothing used, and the requests that only matched
by fallback.
"""
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

from importlib import import_module

if __package__:
    journeys = import_module(f'{__package__}.journeys')
else:
    journeys = sys.modules.get('journeys') or import_module('journeys')

KINDS = ('exact', 'ordered', 'template', 'path', 'synthetic', 'fault', 'blocked', 'live')
SMELLS = ('path', 'blocked')  # What `--strict` fails on.
SOURCE_KINDS = {'fault': 'fault', 'blocked': 'blocked', 'live': 'live', 'fixture': 'fixture'}


class Coverage:
    """Requests from one or more runs, with where each came from and which cassette directory served it."""

    def __init__(self):
        self.entries = []        # dict(run, step, request, cassettes)
        self.directories = set()
        self.runs = []           # (label, passed, summary line)
        self.guards = set()
        self.unreported = False  # The app logged requests without `match` (an older harness).

    def add(self, run, step, request, cassettes):
        if cassettes:
            self.directories.add(str(Path(cassettes).resolve()))
        if 'match' not in request:
            self.unreported = True
        self.entries.append(dict(run=run, step=step, request=request,
                                 cassettes=str(Path(cassettes).resolve()) if cassettes else None))

    @staticmethod
    def kind(request):
        return request.get('match') or SOURCE_KINDS.get(request.get('source'), 'fixture')

    def templates(self):
        found = []
        for directory in sorted(self.directories):
            found += [t for t in journeys.cassette_templates(directory) if t not in found]
        return found

    def endpoint(self, request, templates):
        return journeys.request_pattern(request, templates)

    def table(self):
        templates = self.templates()
        rows = defaultdict(Counter)
        for entry in self.entries:
            rows[self.endpoint(entry['request'], templates)][self.kind(entry['request'])] += 1
        return rows

    def unused(self):
        """{directory: [cassette files no request was answered with]}."""
        used = defaultdict(set)
        for entry in self.entries:
            if entry['cassettes'] and entry['request'].get('cassette'):
                used[entry['cassettes']].add(entry['request']['cassette'])
        result = {}
        for directory in sorted(self.directories):
            files = sorted(p.name for p in Path(directory).glob('*.json') if p.name != 'match.json')
            result[directory] = (files, [f for f in files if f not in used[directory]])
        return result

    def listed(self, kinds):
        """Requests of `kinds`, deduplicated: [(kind, label, cassette, count, where)]."""
        groups = {}
        for entry in self.entries:
            kind = self.kind(entry['request'])
            if kind not in kinds:
                continue
            request = entry['request']
            key = (kind, journeys.request_label(request, 100), request.get('cassette'))
            where = f"{entry['run']} " + ('at launch' if entry['step'] == 0 else f"step {entry['step']}")
            group = groups.setdefault(key, [0, []])
            group[0] += 1
            if where not in group[1]:
                group[1].append(where)
        return [(kind, label, cassette, count, where) for (kind, label, cassette), (count, where) in groups.items()]

    def problems(self):
        return [e for e in self.entries if self.kind(e['request']) in SMELLS]


def relative(path):
    try:
        return os.path.relpath(path)
    except ValueError:
        return str(path)


def print_coverage(coverage, stream=None):
    out = stream or sys.stdout
    rows = coverage.table()
    passed = sum(1 for _, ok, _ in coverage.runs if ok)
    runs = f'{len(coverage.runs)} run(s), {len(coverage.runs) - passed} failed; ' if coverage.runs else ''
    print(f'fixtures coverage: {runs}{len(coverage.entries)} request(s) to {len(rows)} endpoint(s)', file=out)
    for label, ok, summary in coverage.runs:
        if not ok:
            print(journeys.indent(summary, '  '), file=out)
    if rows:
        seen = [k for k in (*KINDS, 'fixture') if any(k in counts for counts in rows.values())]
        table = [[endpoint, sum(counts.values()), *[counts.get(k) or '.' for k in seen]] for endpoint, counts in sorted(rows.items())]
        print(sibling_table(table, ['ENDPOINT', 'REQUESTS', *[k.upper() for k in seen]]), file=out)
    for directory, (files, unused) in coverage.unused().items():
        print(f'cassettes in {relative(directory)}: {len(files) - len(unused)} of {len(files)} used', file=out)
        for name in unused:
            print(f'  unused: {name}', file=out)
    fallbacks = coverage.listed(('path',))
    if fallbacks:
        print(f'fallback matches ({sum(f[3] for f in fallbacks)}): no cassette for the exact request, so the latest one for '
              'its path answered. Record one, or add a `match.json` rule (ignore_query, ignore_body, path_templates, '
              'pagination):', file=out)
        for _, label, cassette, count, where in fallbacks:
            print(f'  {label}  -> {cassette}' + (f'  x{count}' if count > 1 else '') + f'  ({", ".join(where[:3])}'
                  + (', ...' if len(where) > 3 else '') + ')', file=out)
    blocked = coverage.listed(('blocked',))
    if blocked:
        print(f'blocked ({sum(b[3] for b in blocked)}): no fixture, network mode block, or refused by the live guard:', file=out)
        for _, label, _, count, where in blocked:
            print(f'  {label}' + (f'  x{count}' if count > 1 else '') + f'  ({", ".join(where[:3])}'
                  + (', ...' if len(where) > 3 else '') + ')', file=out)
    if coverage.unreported:
        journeys.note('the app logs requests without `match` (an older TCAHarness), so fixture matches show as FIXTURE')


def sibling_table(rows, headers):
    widths = [max(len(str(r[i])) for r in [headers, *rows]) for i in range(len(headers))]
    line = lambda row: '  ' + '  '.join(str(v).ljust(w) for v, w in zip(row, widths)).rstrip()
    return '\n'.join([line(headers), *map(line, rows)])


# Sources: journey runs or --report files --------------------------------------------------------------

def from_reports(paths, coverage):
    for path in paths:
        run, cassettes = str(path), None
        try:
            lines = Path(path).read_text().splitlines()
        except OSError as error:
            raise journeys.JourneyError(f'{path}: {error.strerror or error}') from None
        for number, line in enumerate(lines, 1):
            try:
                event = json.loads(line)
            except ValueError:
                raise journeys.JourneyError(f'{path}:{number}: not a JSON line') from None
            kind = event.get('event')
            if kind == 'goal_started':
                run, cassettes = event.get('file') or event.get('goal') or str(path), None
                run = relative(run) if event.get('file') else run
            elif kind == 'network':
                cassettes = event.get('cassettes') or cassettes
                if event.get('liveGuard'):
                    coverage.guards.add(event['liveGuard'])
            elif kind == 'request' and isinstance(event.get('request'), dict):
                coverage.add(run, event.get('step'), event['request'], cassettes)
            elif kind == 'goal_finished':
                ok = event.get('status') == 'passed'
                coverage.runs.append((run, ok, f"FAIL  {event.get('goal')}  ({run})\n  {event.get('reason')}" if not ok else ''))


def from_runs(loaded, opener, arguments, coverage, network=None, fixtures=None, reporter=None):
    """Run each journey on a fresh launch and add its requests."""
    reporter = reporter or journeys.Reporter()
    for journey in loaded:
        label = relative(journey.path)
        settings = journeys.Settings.for_journey(journey, network or arguments.network, arguments.seed, arguments.wait_ms,
                                                 fixtures, journeys.cli_latency(arguments))
        try:
            session = opener.open(settings)
        except (RuntimeError, journeys.targets.TargetError) as error:
            coverage.runs.append((label, False, f'FAIL  {journey.name}  ({label})\n  could not start {opener.name}: {error}'))
            continue
        try:
            result = journeys.run_journey(session, journey, reporter, arguments.wait_ms)
        finally:
            session.close()
        network_state = session.network or {}
        if network_state.get('liveGuard'):
            coverage.guards.add(network_state['liveGuard'])
        cassettes = network_state.get('cassettes') or (str(settings.cassettes) if settings.cassettes else None)
        if cassettes:
            coverage.directories.add(str(Path(cassettes).resolve()))
        for step, request in result.requests:
            coverage.add(label, step, request, cassettes)
        coverage.runs.append((label, result.passed, journeys.summarize(result, label)))
    return coverage


def load_all(paths):
    return [journeys.load_journey(path) for path in paths]


def coverage_command(arguments):
    coverage = Coverage()
    try:
        if arguments.report:
            from_reports(arguments.report, coverage)
        if arguments.files:
            loaded = load_all(arguments.files)
            opener = journeys.Opener.from_arguments(arguments.target, None, [j.path for j in loaded])
            reporter = journeys.Reporter(arguments.save_report)
            try:
                from_runs(loaded, opener, arguments, coverage, fixtures=arguments.fixtures, reporter=reporter)
            finally:
                opener.close()
                reporter.close()
        elif arguments.fixtures:
            coverage.directories.add(str(Path(arguments.fixtures).resolve()))
    except (journeys.JourneyError, journeys.targets.TargetError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    print_coverage(coverage)
    journeys.print_notes()
    failed = any(not ok for _, ok, _ in coverage.runs)
    smelly = bool(coverage.problems())
    if arguments.strict and smelly:
        print(f'strict: {len(coverage.problems())} request(s) fell back or were blocked')
    return 1 if failed or (arguments.strict and smelly) else 0


# `tca fixtures record` ----------------------------------------------------------------------------------

def run_sanitizer(command, directories):
    """Run the sanitizer once, from the current directory, with the recorded directories as arguments
    and in TCA_HARNESS_CASSETTES (the first). A `.py` file runs with this Python."""
    parts = shlex.split(command)
    if len(parts) == 1 and parts[0].endswith('.py'):
        parts = [sys.executable, parts[0]]
    env = dict(os.environ, TCA_HARNESS_CASSETTES=str(directories[0]) if directories else '')
    print(f'sanitize: {" ".join(shlex.quote(p) for p in parts)}', flush=True)
    done = subprocess.run(parts + [str(d) for d in directories], env=env, check=False)
    return done.returncode


def record_command(arguments):
    try:
        loaded = load_all(arguments.files)
        opener = journeys.Opener.from_arguments(arguments.target, None, [j.path for j in loaded])
    except (journeys.JourneyError, journeys.targets.TargetError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    if opener.target and opener.target.restart == 'never':
        journeys.note(f'target {opener.target.name} has restart = "never", so every journey records in one process')
    reporter = journeys.Reporter(arguments.save_report)
    recorded = Coverage()
    try:
        arguments.network = 'record'
        from_runs(loaded, opener, arguments, recorded, network='record', fixtures=arguments.into, reporter=reporter)
    finally:
        opener.close()
        reporter.close()
    directories = sorted(recorded.directories)
    written = defaultdict(set)
    for entry in recorded.entries:
        if entry['request'].get('cassette'):
            written[entry['cassettes']].add(entry['request']['cassette'])
    refused = recorded.listed(('blocked',))
    where = ', '.join(f'{len(written[d])} cassette(s) written to {relative(d)}' for d in directories) or 'no cassette directory'
    print(f'record: {len(loaded)} journey(s) on {opener.name}; {where}')
    for label, ok, summary in recorded.runs:
        print(('  ' + summary.replace('\n', '\n  ')) if not ok else f'  recorded {label}')
    if recorded.guards:
        print('  live guard: ' + ', '.join(sorted(recorded.guards)))
    elif recorded.entries:
        journeys.note('the app sets no live guard (HarnessNetwork.shared.liveGuard), so every request it made reached '
                      'the network; set `.readOnly(hosts:)` before recording from a production service')
    if refused:
        print(f'  refused or blocked ({sum(r[3] for r in refused)}), not recorded:')
        for _, label, _, count, _ in refused:
            print(f'    {label}' + (f'  x{count}' if count > 1 else ''))
    if arguments.sanitize:
        code = run_sanitizer(arguments.sanitize, directories)
        if code:
            print(f'error: the sanitizer exited with {code}', file=sys.stderr)
            journeys.print_notes()
            return 1
    status = 0
    if not arguments.no_coverage:
        print()
        coverage = Coverage()
        replay = journeys.Opener.from_arguments(arguments.replay_target, None, [j.path for j in loaded])
        arguments.network = None
        try:
            from_runs(loaded, replay, arguments, coverage)
        finally:
            replay.close()
        print_coverage(coverage)
        status = 1 if any(not ok for _, ok, _ in coverage.runs) or (arguments.strict and coverage.problems()) else 0
    journeys.print_notes()
    return status


def add_parsers(commands):
    fixtures = commands.add_parser('fixtures', help='Fixture coverage, and recording sweeps')
    actions = fixtures.add_subparsers(dest='action', required=True, metavar='coverage|record')

    coverage = actions.add_parser('coverage', help='Run journeys (or read reports) and show how each request was answered')
    coverage.add_argument('files', nargs='*', type=Path, metavar='FILE')
    coverage.add_argument('--target', help='harness.toml target to launch (default: headless, or the only one)')
    coverage.add_argument('--network', choices=journeys.NETWORK_MODES, help="Override the journeys' network mode")
    coverage.add_argument('--fixtures', type=Path, help="Cassette directory (default: each journey's fixtures)")
    coverage.add_argument('--report', type=Path, action='append', metavar='JSONL',
                          help='Read requests from a --report file of an earlier run instead (repeatable)')
    coverage.add_argument('--save-report', type=Path, metavar='JSONL', help='Write the runs as JSON lines')
    coverage.add_argument('--strict', action='store_true', help='Exit 1 if any request fell back (path) or was blocked')
    coverage.add_argument('--seed', type=int)
    coverage.add_argument('--wait-ms', type=int, default=journeys.DEFAULT_WAIT_MS)

    record = actions.add_parser('record', help='Record cassettes for journeys, sanitize them, then show coverage')
    record.add_argument('files', nargs='+', type=Path, metavar='FILE')
    record.add_argument('--target', help='harness.toml target that reaches the real backend (e.g. live)')
    record.add_argument('--into', type=Path, metavar='DIR', help="Where to write cassettes (default: each journey's fixtures)")
    record.add_argument('--sanitize', metavar='COMMAND',
                        help='Run after recording with the cassette directories as arguments (a .py file runs with Python)')
    record.add_argument('--replay-target', help='Target for the coverage replay (default: headless, or the only one)')
    record.add_argument('--no-coverage', action='store_true', help='Skip the coverage replay')
    record.add_argument('--strict', action='store_true', help='Exit 1 if the coverage replay falls back or blocks')
    record.add_argument('--save-report', type=Path, metavar='JSONL', help='Write the recording runs as JSON lines')
    record.add_argument('--seed', type=int)
    record.add_argument('--wait-ms', type=int, default=journeys.DEFAULT_WAIT_MS)


def main(arguments):
    if arguments.action == 'coverage':
        if not arguments.files and not arguments.report:
            print('error: give journey files to run, or --report JSONL', file=sys.stderr)
            return 2
        return coverage_command(arguments)
    return record_command(arguments)
