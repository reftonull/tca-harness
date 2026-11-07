#!/usr/bin/env python3
"""Run every testing pattern on Shelf with SHELF_BUGS unset and with SHELF_BUGS=all, then print a
matrix of which pattern caught which planted bug. Use run_ladder.sh, which builds first.

    python3 ladder.py [--skip-ui] [--explore-runs 30] [--settings none,all]

Exits 1 if a clean run found anything, or a bug was not caught by the pattern it was planted for.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
TCA = str(HERE.parent.parent / 'scripts' / 'tca')
SERVER_PORT = 8799

# bug -> (pattern it was planted for, rung, signature in the CLI's output)
BUGS = {
    'stuck-save': ('chaos', 1, r'saving means a save is in flight|addBook/(save|retry) still running|stranded(?!: neither "Refresh")'),
    'double-save': ('explore', 1, r'no duplicate books'),
    'badge-drift': ('invariant', 1, r'unread badge matches the list'),
    'chatty-search': ('network', 1, r'budget: \d+ requests|POST \S*/events \S* (had no fixture|was blocked)'
                                    r'|requests after step \d+ "Search".*unexpected POST /events'),
    'wall-clock': ('determinism', 1, r'addedAt'),
    'view-only-seen': ('diff', 2, r'hasNewBooks'),
    'late-delete': ('issue', 1, r'received a presentation action'),
    'stats-stuck': ('chaos', 1, r'stranded: neither "Refresh"|root/stats/\S+ still running'),
    'goal-drift': ('invariant', 1, r'progress matches the goal'),
    'v2-contract': ('contract', 3, r"unexpected shape|missing key 'author'"),
}

# What finding kind a matching line reports, for the matrix cells.
KINDS = [('requests', r'\brequests (at launch|after step)'), ('budget', r'budget:'), ('invariant', r'invariant'), ('stuck', r'stuck|still running'),
         ('stranded', r'stranded'), ('issue', r'\bissue\b|received a presentation action'),
         ('diff', r'^\s+\S+: .* vs '), ('network', r'had no fixture|was blocked')]


def kind_of(line):
    for kind, pattern in KINDS:
        if re.search(pattern, line):
            return kind
    return 'found'


class Server:
    """server.py on SERVER_PORT, fresh state each start."""

    def __init__(self, v2=False):
        self.process = subprocess.Popen([sys.executable, str(HERE / 'server.py'), '--quiet', '--port', str(SERVER_PORT)]
                                        + (['--v2'] if v2 else []), stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        import socket
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                socket.create_connection(('127.0.0.1', SERVER_PORT), timeout=0.2).close()
                return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError('server.py did not start')

    def stop(self):
        self.process.send_signal(signal.SIGTERM)
        self.process.wait(timeout=5)


def tca(args, bugs, cwd=HERE):
    """Run the CLI with SHELF_BUGS set (or unset); (exit code, output, seconds)."""
    env = dict(os.environ)
    env.pop('SHELF_BUGS', None)
    if bugs:
        env['SHELF_BUGS'] = bugs
    started = time.monotonic()
    done = subprocess.run([TCA, *args], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return done.returncode, done.stdout, time.monotonic() - started


def live_workspace():
    """A scratch copy of journeys and fixtures, so recording never touches the committed cassettes."""
    root = Path(tempfile.mkdtemp(prefix='shelf-live-'))
    shutil.copytree(HERE / 'journeys', root / 'journeys')
    shutil.copytree(HERE / 'fixtures', root / 'fixtures')
    config = (HERE / 'harness.toml').read_text().replace('.build/debug/shelf-headless',
                                                         str(HERE / '.build/debug/shelf-headless'))
    (root / 'harness.toml').write_text(config)
    return root


def run_patterns(bugs, args, findings_dir):
    """{pattern: (exit code, output, seconds)} for one SHELF_BUGS setting."""
    journeys = sorted(str(p.relative_to(HERE)) for p in (HERE / 'journeys').glob('*.toml'))
    out = ['--out', str(findings_dir)]
    results = {}

    def step(name, rung, command):
        print(f'  [{bugs or "none"}] {name} (rung {rung}) ...', end='', flush=True)
        results[name] = command()
        code, _, seconds = results[name]
        print(f' exit {code}, {seconds:.1f}s', flush=True)

    step('journey', 1, lambda: tca(['journey', 'run', *journeys], bugs))
    step('explore', 1, lambda: tca(['explore', '--fixtures', 'fixtures/shelf', '--runs', str(args.explore_runs),
                                    '--steps', '40', *out], bugs))
    def chaos():
        # The TCA editor and the vanilla Reading stats screen (a Hosted @Observable model).
        runs = [tca(['chaos', journey, *out], bugs) for journey in ('journeys/add-book.toml', 'journeys/view-stats.toml')]
        return max(r[0] for r in runs), ''.join(r[1] for r in runs), sum(r[2] for r in runs)

    step('chaos', 1, chaos)
    step('determinism', 1, lambda: tca(['determinism', 'journeys/add-book.toml', *out], bugs))
    if not args.skip_ui:
        step('diff', 2, lambda: tca(['diff', 'journeys/mark-read.toml', '--targets', 'headless,ui', *out], bugs))

    def live():
        root = live_workspace()
        codes, texts, total = [], [], 0.0
        for journey in journeys:
            server = Server()
            try:
                code, text, seconds = tca(['journey', 'run', journey, '--target', 'live', '--network', 'record'], bugs, root)
            finally:
                server.stop()
            codes.append(code)
            texts.append(text)
            total += seconds
        shutil.rmtree(root, ignore_errors=True)
        return max(codes), ''.join(texts), total

    def contract():
        root = live_workspace()
        enabled = bugs == 'all' or 'v2-contract' in bugs.split(',')
        server = Server(v2=enabled)
        try:
            return tca(['journey', 'run', 'journeys/search.toml', '--target', 'live', '--network', 'record'], bugs, root)
        finally:
            server.stop()
            shutil.rmtree(root, ignore_errors=True)

    step('live', 3, live)
    step('contract', 3, contract)
    return results


def attribute(output):
    """{bug: kind} for every bug whose signature appears in a command's output."""
    caught = {}
    for line in output.splitlines():
        for bug, (_, _, signature) in BUGS.items():
            if bug not in caught and re.search(signature, line):
                caught[bug] = kind_of(line)
    return caught


def clean(code, output):
    """Every command exits 1 when it found something (and 2 when it could not run)."""
    return code == 0


def matrix(runs, patterns):
    lines = []
    width = max(len(b) for b in BUGS) + 2
    header = 'bug'.ljust(width) + 'planted for'.ljust(18) + ''.join(p.ljust(13) for p in patterns)
    lines.append(header)
    lines.append('-' * len(header))
    all_run = runs.get('all')
    for bug, (pattern, rung, _) in BUGS.items():
        row = bug.ljust(width) + f'{pattern} (r{rung})'.ljust(18)
        for name in patterns:
            if all_run is None or name not in all_run:
                cell = 'n/a'
            else:
                cell = attribute(all_run[name][1]).get(bug, '.')
            row += cell.ljust(13)
        lines.append(row)
    lines.append('-' * len(header))
    for setting in runs:
        row = f'SHELF_BUGS={setting}'.ljust(width + 18)
        for name in patterns:
            if name not in runs[setting]:
                row += 'n/a'.ljust(13)
                continue
            code, output, _ = runs[setting][name]
            row += ('clean' if clean(code, output) else 'FINDINGS').ljust(13)
        lines.append(row)
    for setting in runs:
        row = f'seconds ({setting})'.ljust(width + 18)
        for name in patterns:
            row += (f'{runs[setting][name][2]:.1f}' if name in runs[setting] else '').ljust(13)
        lines.append(row)
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--skip-ui', action='store_true', help='skip rung 2 (tca diff against the simulator)')
    parser.add_argument('--explore-runs', type=int, default=30)
    parser.add_argument('--settings', default='none,all', help='SHELF_BUGS settings to run (none means unset)')
    args = parser.parse_args()
    findings = HERE / '.tca' / 'ladder'
    shutil.rmtree(findings, ignore_errors=True)
    runs = {}
    for setting in args.settings.split(','):
        bugs = '' if setting == 'none' else setting
        runs[setting] = run_patterns(bugs, args, findings / setting)
    patterns = list(next(iter(runs.values())))
    for setting, results in runs.items():
        log = findings / f'{setting}.log'
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(''.join(f'===== {name} (exit {code}, {seconds:.1f}s)\n{output}\n'
                               for name, (code, output, seconds) in results.items()))
    print()
    print('Cells: the finding kind that exposed each bug with SHELF_BUGS=all ("." = not caught by that pattern).')
    print(matrix(runs, patterns))
    print(f'\nFull output: {findings.relative_to(HERE)}/<setting>.log, findings under {findings.relative_to(HERE)}/<setting>/')

    problems = []
    for setting, results in runs.items():
        if setting == 'none':
            problems += [f'{name} found something with no bugs planted' for name, (code, out, _) in results.items()
                         if not clean(code, out)]
    if 'all' in runs:
        for bug, (pattern, _, _) in BUGS.items():
            home = {'invariant': 'journey', 'network': 'journey', 'issue': 'journey'}.get(pattern, pattern)
            if home in runs['all'] and bug not in attribute(runs['all'][home][1]):
                problems.append(f'{bug} was not caught by {home}')
    print('\n' + ('\n'.join('MISSED: ' + p for p in problems) if problems else 'Every bug was caught where it was planted; clean runs were clean.'))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
