"""Journeys and the run engine behind `tca journey run`, `tca record`, and the generic oracles.

A run is one fresh app process (a `harness.toml` target) or an attached app (`--port`). Steps are
resolved exactly like `tca do`. After every step the generic oracles look for crashes, reported
issues and invariants, unexpected network requests, stuck receipts, rejected operations and dead
ends. `exploration.py` builds explore, chaos, determinism and diff on the same pieces.
"""
import argparse
import copy
from dataclasses import dataclass, field
from datetime import datetime
import importlib
import itertools
import json
import os
from pathlib import Path
import re
import sys
import time
import tomllib
from urllib.parse import urlsplit


def sibling(name):
    """Import a sibling module from the checkout (cli/) or the installed package, sharing tca.py."""
    if __package__:
        return importlib.import_module(f'{__package__}.{name}')
    if name == 'tca':
        main = sys.modules.get('__main__')
        if main is not None and Path(getattr(main, '__file__', None) or '').name == 'tca.py':
            return main
    if name in sys.modules:
        return sys.modules[name]
    directory = str(Path(__file__).resolve().parent)
    if directory not in sys.path:
        sys.path.insert(0, directory)
    return importlib.import_module(name)


expressions = sibling('expressions')
targets = sibling('targets')
tomlout = sibling('tomlout')

NETWORK_MODES = ('block', 'replay', 'record', 'live')
RECORDING = Path('.tca') / 'recording.json'
FINDINGS = Path('.tca') / 'findings'
DEFAULT_WAIT_MS = 5000
SETTLE_SECONDS = 1.0
ORACLE_KINDS = ('crash', 'issue', 'invariant', 'network', 'stuck', 'rejected', 'dead end')
FAULT_TIMES = ('launch',)  # `at` values for [[faults]]; absent means "when the CLI connects".
FAULT_KEYS = {'match', 'kind', 'status', 'delayMs', 'times', 'skip', 'at'}
TOLERATED_REJECTIONS = ('stale_revision', 'invalid_arguments')
NOTES = {}  # Said once per command, printed under the summary.


def note(text):
    NOTES.setdefault(text, None)


def print_notes(stream=None):
    for text in NOTES:
        print(f'note: {text}', file=stream or sys.stdout)
    NOTES.clear()


class JourneyError(ValueError):
    """A journey file that does not parse or validate."""


# Journey files ----------------------------------------------------------------------------------

@dataclass
class Step:
    do: str
    args: dict = field(default_factory=dict)
    expect: str | None = None
    path: str | None = None
    requests: list | None = None  # Expected requests ("GET /books"); None = not checked, [] = none.
    no_wait: bool = False         # Dispatch without waiting for the previous step to finish (a race).
    after_ms: int | None = None   # Pause before dispatching: from the previous dispatch with no_wait, else after it finished.

    def document(self):
        item = {'do': self.do}
        if self.args:
            item['args'] = json.dumps(self.args, ensure_ascii=False) if tomlout.contains_null(self.args) else self.args
        if self.path:
            item['path'] = self.path
        if self.no_wait:
            item['no_wait'] = True
        if self.after_ms:
            item['after_ms'] = self.after_ms
        if self.expect:
            item['expect'] = self.expect
        if self.requests is not None:
            item['requests'] = list(self.requests)
        return item


@dataclass
class Journey:
    path: Path | None
    name: str
    goal: str = ''
    steps: list = field(default_factory=list)
    checks: dict = field(default_factory=dict)
    budget: dict = field(default_factory=dict)
    fixtures: Path | None = None
    network: str | None = None
    seed: int | None = None
    terminal: bool = False
    faults: list = field(default_factory=list)
    launch_requests: list | None = None  # Expected requests before the first step.
    latency: dict | None = None          # Replay latency (TCA_HARNESS_LATENCY): {ms, jitter_ms, seed, paths}.

    @property
    def label(self):
        return str(self.path) if self.path else self.name

    @property
    def launch_faults(self):
        """Faults with `at = "launch"`, without `at`: passed in TCA_HARNESS_FAULTS so they hit launch requests."""
        return [{k: v for k, v in f.items() if k != 'at'} for f in self.faults if f.get('at') == 'launch']

    @property
    def connect_faults(self):
        """Faults set through `network` once the CLI connects, before the first step."""
        return [f for f in self.faults if f.get('at') != 'launch']

    @property
    def checks_requests(self):
        return self.launch_requests is not None or any(step.requests is not None for step in self.steps)


def parse_arguments(raw, where):
    if raw is None:
        return {}
    if isinstance(raw, str):  # JSON text, used when arguments contain null (TOML has none).
        try:
            raw = json.loads(raw)
        except ValueError:
            raise JourneyError(f'{where}: `args` string must be a JSON object') from None
    if not isinstance(raw, dict):
        raise JourneyError(f'{where}: `args` must be a table or a JSON object string')
    return raw


LATENCY_KEYS = {'ms', 'jitter_ms', 'seed', 'paths'}


def milliseconds(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def parse_latency(raw, where):
    """`latency = 200` or `latency = { ms = 200, jitter_ms = 150, paths = { "/search" = { ms = 600 } } }`."""
    if raw is None:
        return None
    if milliseconds(raw):
        return {'ms': raw}
    if not isinstance(raw, dict) or set(raw) - LATENCY_KEYS:
        raise JourneyError(f'{where}: `latency` must be milliseconds or a table with ms, jitter_ms, seed and paths')
    for key in ('ms', 'jitter_ms', 'seed'):
        if key in raw and not milliseconds(raw[key]):
            raise JourneyError(f'{where}: latency.{key} must be a non-negative integer')
    paths = raw.get('paths', {})
    if not isinstance(paths, dict) or not all(
            isinstance(rule, dict) and milliseconds(rule.get('ms')) and set(rule) <= {'ms', 'jitter_ms'}
            and milliseconds(rule.get('jitter_ms', 0)) for rule in paths.values()):
        raise JourneyError(f'{where}: latency.paths maps paths to {{ ms = N, jitter_ms = N }}')
    return copy.deepcopy(raw)


def check_expression(source, where):
    try:
        expressions.compile_expression(source)
    except expressions.ExpressionError as error:
        raise JourneyError(f'{where}: {error}') from None
    return source


REQUEST_PATTERN = re.compile(r'^([A-Za-z]+|\*) (/\S*|\*)$')


def parse_requests(raw, where):
    """A `requests` list: strings like "GET /books", "POST /books/{id}" or "GET /books?*"."""
    if raw is None:
        return None
    if not isinstance(raw, list) or not all(isinstance(item, str) for item in raw):
        raise JourneyError(f'{where}: `requests` must be a list of strings like "GET /books"')
    for item in raw:
        if not REQUEST_PATTERN.match(item.strip()):
            raise JourneyError(f'{where}: request {item!r} must be "METHOD /path" (globs `*`, segments `{{id}}`, '
                               'optional `?query`)')
    return [item.strip() for item in raw]


def pattern_regex(target):
    """`/books/{id}?*` as a regex: `{name}` is one path segment, `*` anything."""
    parts = re.split(r'(\{[^}/]*\}|\*)', target)
    regex = ''.join('[^/?]+' if part.startswith('{') else '.*' if part == '*' else re.escape(part) for part in parts)
    return re.compile(regex + r'\Z')


def request_matches(pattern, request):
    """Whether a logged request fits a pattern. Without `?`, the pattern ignores the query."""
    method, _, target = pattern.partition(' ')
    if method != '*' and method.upper() != str(request.get('method', '')).upper():
        return False
    url = urlsplit(str(request.get('url', '')))
    subject = (url.path or '/') + ('?' + url.query if '?' in target and url.query else '?' if '?' in target else '')
    return bool(pattern_regex(target).match(subject))


def request_label(request, width=80):
    url = urlsplit(str(request.get('url', '')))
    text = f"{request.get('method')} {url.path or '/'}" + (f'?{url.query}' if url.query else '')
    return text if len(text) <= width else text[:width - 3] + '...'


def match_requests(patterns, requests):
    """Order-insensitive multiset match: (missing patterns, unexpected requests), from a maximum matching."""
    owner = {}  # request index -> pattern index

    def assign(index, seen):
        for other, request in enumerate(requests):
            if other in seen or not request_matches(patterns[index], request):
                continue
            seen.add(other)
            if other not in owner or assign(owner[other], seen):
                owner[other] = index
                return True
        return False

    matched = {index for index in range(len(patterns)) if assign(index, set())}
    missing = [patterns[i] for i in range(len(patterns)) if i not in matched]
    unexpected = [requests[i] for i in range(len(requests)) if i not in owner]
    return missing, unexpected


def requests_finding(patterns, requests, number):
    """A `requests` finding when the requests made don't match the expectation, else None."""
    missing, unexpected = match_requests(patterns, requests)
    if not missing and not unexpected:
        return None
    made = ', '.join(request_label(r, 60) for r in requests) or 'none'
    message = f"expected [{', '.join(patterns)}], made [{made}]"
    details = ([f"missing {', '.join(missing)}"] if missing else []) + \
              ([f"unexpected {', '.join(request_label(r, 60) for r in unexpected)}"] if unexpected else [])
    return Finding('requests', message + ' (' + '; '.join(details) + ')', number, None,
                   {'expected': list(patterns), 'made': [request_label(r, 200) for r in requests],
                    'missing': missing, 'unexpected': [request_label(r, 200) for r in unexpected]})


ID_SEGMENT = re.compile(r'^(\d+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{16,})$')


def templated_path(path, templates=()):
    """`/books/123` -> `/books/{id}`: the first matching `match.json` template, else numeric, UUID
    and long hex segments become `{id}`."""
    for template in templates:
        parts, segments = template.split('/'), path.split('/')
        if len(parts) == len(segments) and all(
                p == s or ((p == '*' or (p.startswith('{') and p.endswith('}'))) and s) for p, s in zip(parts, segments)):
            return template
    return '/'.join('{id}' if ID_SEGMENT.match(segment) else segment for segment in path.split('/'))


def request_pattern(request, templates=()):
    """How `tca record` writes a request: METHOD and templated path, no query."""
    path = request.get('template') or templated_path(url_path(request.get('url')), templates)
    return f"{str(request.get('method', 'GET')).upper()} {path}"


def load_journey(path):
    path = Path(path)
    try:
        data = tomllib.loads(path.read_text())
    except OSError as error:
        raise JourneyError(f'{path}: {error.strerror or error}') from None
    except tomllib.TOMLDecodeError as error:
        raise JourneyError(f'{path}: {error}') from None
    return journey_from(data, path)


def journey_from(data, path=None):
    where = str(path) if path else 'journey'
    known = {'name', 'goal', 'fixtures', 'network', 'seed', 'terminal', 'steps', 'checks', 'budget', 'faults',
             'launch_requests', 'latency'}
    unknown = sorted(set(data) - known)
    if unknown:
        raise JourneyError(f'{where}: unknown keys: {", ".join(unknown)}')
    name = data.get('name') or (path.stem.replace('-', ' ').replace('_', ' ') if path else 'journey')
    if not isinstance(name, str) or not isinstance(data.get('goal', ''), str):
        raise JourneyError(f'{where}: `name` and `goal` must be strings')
    network = data.get('network')
    if network is not None and network not in NETWORK_MODES:
        raise JourneyError(f'{where}: `network` must be one of {", ".join(NETWORK_MODES)}')
    fixtures = data.get('fixtures')
    if fixtures is not None and not isinstance(fixtures, str):
        raise JourneyError(f'{where}: `fixtures` must be a directory path')
    base = path.resolve().parent if path else Path.cwd()
    seed = data.get('seed')
    if seed is not None and (not isinstance(seed, int) or isinstance(seed, bool)):
        raise JourneyError(f'{where}: `seed` must be an integer')
    steps = []
    raw_steps = data.get('steps', [])
    if not isinstance(raw_steps, list):
        raise JourneyError(f'{where}: `steps` must be an array of tables ([[steps]])')
    for number, raw in enumerate(raw_steps, 1):
        here = f'{where}: step {number}'
        if not isinstance(raw, dict) or not isinstance(raw.get('do'), str) or not raw['do'].strip():
            raise JourneyError(f'{here}: needs `do = "<label, name or ID>"`')
        extra = sorted(set(raw) - {'do', 'args', 'expect', 'path', 'requests', 'no_wait', 'after_ms'})
        if extra:
            raise JourneyError(f'{here}: unknown keys: {", ".join(extra)}')
        if not isinstance(raw.get('no_wait', False), bool):
            raise JourneyError(f'{here}: `no_wait` must be true or false')
        if raw.get('after_ms') is not None and not milliseconds(raw['after_ms']):
            raise JourneyError(f'{here}: `after_ms` must be a non-negative integer')
        if raw.get('no_wait') and number == 1:
            raise JourneyError(f'{here}: the first step can\'t be `no_wait` (runs wait for launch to go quiet)')
        if raw.get('no_wait') and steps and (steps[-1].expect or steps[-1].requests is not None):
            raise JourneyError(f'{where}: step {number - 1}: a step that the next one races (`no_wait`) can\'t have '
                               '`expect` or `requests`; put them on the last step of the race')
        expect = raw.get('expect')
        if expect is not None:
            check_expression(expect, f'{here} expect')
        if raw.get('path') is not None and not isinstance(raw['path'], str):
            raise JourneyError(f'{here}: `path` must be a feature path')
        steps.append(Step(raw['do'], parse_arguments(raw.get('args'), here), expect, raw.get('path'),
                          parse_requests(raw.get('requests'), here), bool(raw.get('no_wait')), raw.get('after_ms')))
    checks = data.get('checks', {})
    if not isinstance(checks, dict) or not all(isinstance(v, str) for v in checks.values()):
        raise JourneyError(f'{where}: [checks] must map names to expression strings')
    for check, source in checks.items():
        check_expression(source, f'{where}: check {check!r}')
    budget = data.get('budget', {})
    if not isinstance(budget, dict) or set(budget) - {'requests'}:
        raise JourneyError(f'{where}: [budget] supports `requests`')
    if 'requests' in budget and (not isinstance(budget['requests'], int) or budget['requests'] < 0):
        raise JourneyError(f'{where}: budget.requests must be a non-negative integer')
    faults = data.get('faults', [])
    if not isinstance(faults, list) or not all(isinstance(f, dict) and isinstance(f.get('kind'), str) for f in faults):
        raise JourneyError(f'{where}: [[faults]] entries need a `kind`')
    for number, fault in enumerate(faults, 1):
        unknown = sorted(set(fault) - FAULT_KEYS)
        if unknown:
            raise JourneyError(f'{where}: fault {number}: unknown keys: {", ".join(unknown)} (a key after [[faults]] '
                               'belongs to that fault; put top-level keys above the first table)')
    if any('at' in f and f['at'] not in FAULT_TIMES for f in faults):
        raise JourneyError(f'{where}: a fault\'s `at` must be "launch" (or absent: set when the CLI connects)')
    terminal = data.get('terminal', False)
    if not isinstance(terminal, bool):
        raise JourneyError(f'{where}: `terminal` must be true or false')
    return Journey(path=path, name=name, goal=data.get('goal', ''), steps=steps, checks=dict(checks), budget=dict(budget),
                   fixtures=(base / fixtures).resolve() if fixtures else None, network=network, seed=seed,
                   terminal=terminal, faults=[dict(f) for f in faults],
                   launch_requests=parse_requests(data.get('launch_requests'), f'{where}: launch_requests'),
                   latency=parse_latency(data.get('latency'), where))


def journey_document(journey, destination=None):
    """A journey as a TOML-ready dict, with `fixtures` relative to where it will be written."""
    document = {'name': journey.name}
    if journey.goal:
        document['goal'] = journey.goal
    if journey.fixtures:
        base = Path(destination).resolve().parent if destination else Path.cwd()
        fixtures = Path(journey.fixtures).resolve()
        # Relative when the two share a directory below the root; absolute otherwise (e.g. findings in /tmp).
        shared = os.path.commonpath([fixtures, base])
        document['fixtures'] = str(fixtures) if shared == fixtures.anchor else os.path.relpath(fixtures, base)
    if journey.network:
        document['network'] = journey.network
    if journey.seed is not None:
        document['seed'] = journey.seed
    if journey.terminal:
        document['terminal'] = True
    if journey.latency:
        document['latency'] = copy.deepcopy(journey.latency)
    if journey.launch_requests is not None:
        document['launch_requests'] = list(journey.launch_requests)
    if journey.steps:
        document['steps'] = [step.document() for step in journey.steps]
    if journey.checks:
        document['checks'] = dict(journey.checks)
    if journey.budget:
        document['budget'] = dict(journey.budget)
    if journey.faults:
        document['faults'] = [dict(f) for f in journey.faults]
    return document


def write_journey(journey, destination, header=None):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    text = tomlout.dumps(journey_document(journey, destination), header=header)
    journey_from(tomllib.loads(text), destination)  # Never write a file `journey run` can't read.
    destination.write_text(text)
    return destination


# Run settings, sessions and targets ---------------------------------------------------------------

@dataclass
class Settings:
    network: str | None = None
    cassettes: Path | None = None
    seed: int | None = None
    wait_ms: int = DEFAULT_WAIT_MS
    faults: list = field(default_factory=list)  # Launch faults, passed as TCA_HARNESS_FAULTS.
    latency: dict | None = None                 # Replay latency, passed as TCA_HARNESS_LATENCY.

    @classmethod
    def for_journey(cls, journey, network=None, seed=None, wait_ms=DEFAULT_WAIT_MS, fixtures=None, latency=None):
        """`latency` (from --latency/--jitter) overrides the journey's."""
        cassettes = Path(fixtures).resolve() if fixtures else journey.fixtures if journey else None
        mode = network or (journey.network if journey else None) or ('replay' if cassettes else 'block')
        if mode == 'record' and cassettes is None and journey and journey.path:
            cassettes = journey.path.resolve().parent / 'fixtures' / journey.path.stem
        if seed is None:
            seed = journey.seed if journey and journey.seed is not None else 0
        return cls(network=mode, cassettes=cassettes, seed=seed, wait_ms=wait_ms,
                   faults=journey.launch_faults if journey else [],
                   latency=latency if latency is not None else journey.latency if journey else None)


class Session:
    """One app connection for one run, with cursors for the issue and network logs."""

    def __init__(self, host, launched=None, owned=True):
        self.host = host
        self.launched = launched
        self.owned = owned  # Stop the process when the run ends (restart = per-run).
        self.mode = None    # Network mode the run asked for.
        self.supports = {}
        self.issue_seq = 0
        self.issue_count = 0
        self.request_seq = 0
        self.fresh = False       # Launched for this run, so TCA_HARNESS_FAULTS reached it.
        self.network = None      # Latest `network` snapshot without requests: mode, cassettes, faults, liveGuard.

    @property
    def observation(self):
        return self.host.observation

    def alive(self):
        return not (self.launched and self.launched.crashed())

    def crash_message(self, error=None):
        if self.launched and self.launched.crashed():
            return f'the app process exited with code {self.launched.exit_code()}'
        return f'the connection dropped ({error})' if error else 'the connection dropped'

    def output(self, last=None):
        return self.launched.output(last) if self.launched else []

    def _method(self, name, **arguments):
        if self.supports.get(name) is False:
            return None
        response = self.host.call(name, **arguments)
        if not response.get('ok') and response.get('error') in ('unknown_method', 'invalid_json_request'):
            self.supports[name] = False
            note(f'the app has no `{name}` method (protocol v2), so the '
                 + ('issue and invariant oracles were' if name == 'issues' else 'network oracle, request budgets and faults were')
                 + ' skipped')
            return None
        self.supports[name] = bool(response.get('ok'))
        return response if response.get('ok') else None

    def new_issues(self):
        count = self.observation.get('issueCount') if isinstance(self.observation, dict) else None
        if self.supports.get('issues') and isinstance(count, int) and count <= self.issue_count:
            return []
        response = self._method('issues', since=self.issue_seq)
        if response is None:
            return []
        issues = [i for i in response.get('issues') or [] if isinstance(i, dict) and i.get('seq', 0) > self.issue_seq]
        if issues:
            self.issue_seq = max(i.get('seq', 0) for i in issues)
        self.issue_count = max(self.issue_count, count if isinstance(count, int) else 0, self.issue_seq)
        return issues

    def new_requests(self):
        response = self._method('network', since=self.request_seq)
        if response is None:
            return []
        self.network = {k: v for k, v in (response.get('network') or {}).items() if k != 'requests'}
        requests = [r for r in (response.get('network') or {}).get('requests') or []
                    if isinstance(r, dict) and r.get('seq', 0) > self.request_seq]
        if requests:
            self.request_seq = max(r.get('seq', 0) for r in requests)
        return requests

    def configure_network(self, mode=None, faults=None, cassettes=None, latency=None):
        """Change the network mode, cassettes, faults and/or latency through `network`. False if unsupported."""
        settings = {}
        if latency is not None:
            settings['latency'] = latency
        if mode:
            settings['mode'] = mode
        if cassettes:
            # Re-sending the same directory reloads it and restarts ordered recordings (`_1`, `_2`, …),
            # which breaks a run attached to an app partway through a sequence; only send a change.
            current = self._method('network') if self.supports.get('network') is not False else None
            if ((current or {}).get('network') or {}).get('cassettes') != str(Path(cassettes).resolve()):
                settings['cassettes'] = str(cassettes)
        if faults is not None:
            settings['faults'] = faults
        return self._method('network', network=settings) is not None

    def close(self):
        try:
            self.host.close()
        except Exception:
            pass
        if self.launched and self.owned:
            self.launched.stop()


def shared_latency(settings):
    """The latency to set on a reused or attached app (a fresh launch gets TCA_HARNESS_LATENCY)."""
    return settings.latency or None


class Opener:
    """Opens a Session per run: a fresh launch of a harness.toml target, or an app on --port."""

    def __init__(self, target=None, port=None):
        self.target = target
        self.port = port
        self.shared = None
        if port is not None:
            note('runs attach to the app on --port, so they share its state; use a harness.toml target for fresh launches')

    @classmethod
    def from_arguments(cls, target_name=None, port=None, starts=()):
        if port is not None:
            return cls(port=port)
        target, _ = targets.resolve_target(target_name, *starts, Path.cwd())
        return cls(target=target)

    @property
    def name(self):
        return self.target.name if self.target else f'port {self.port}'

    def open(self, settings):
        session = self._open(settings)
        session.mode = settings.network
        return session

    def _launch(self, settings):
        return targets.launch(self.target, settings.network, settings.cassettes, settings.seed, faults=settings.faults,
                              latency=settings.latency)

    def _open(self, settings):
        tca = sibling('tca')
        if self.port is not None:
            session = Session(tca.Host(port=self.port))
            session.configure_network(settings.network, cassettes=settings.cassettes, latency=shared_latency(settings))
            return session
        target = self.target
        if target.restart == 'never':
            if self.shared is None or self.shared.crashed() or self.shared.stopped:
                if target.port != 'auto' and targets.port_open(target.port):
                    session = Session(tca.Host(port=target.port), owned=False)
                    session.configure_network(settings.network, cassettes=settings.cassettes, latency=shared_latency(settings))
                    return session
                self.shared = targets.launch(target, settings.network, settings.cassettes, settings.seed,
                                             latency=settings.latency)
            session = Session(tca.Host(port=self.shared.port), self.shared, owned=False)
            session.configure_network(settings.network, cassettes=settings.cassettes, latency=shared_latency(settings))
            return session
        launched = self._launch(settings)
        try:
            session = Session(tca.Host(port=launched.port), launched)
            session.fresh = True
            return session
        except Exception:
            launched.stop()
            raise

    def close(self):
        if self.shared:
            self.shared.stop()
            self.shared = None


# Reports ----------------------------------------------------------------------------------------

class Reporter:
    """JSON lines in the `tca trace` format (traceVersion 1): goal_started, dispatch, finding, goal_finished."""

    def __init__(self, path=None):
        self.file = None
        if path:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            self.file = open(path, 'w')
        self.started = time.monotonic()
        self.sequence = itertools.count(1)

    def emit(self, event, **data):
        if not self.file:
            return
        record = dict(event=event, traceVersion=1, seq=next(self.sequence),
                      timestamp=datetime.now().astimezone().isoformat(),
                      tMs=round((time.monotonic() - self.started) * 1000, 2), **data)
        self.file.write(json.dumps(record, default=str) + '\n')
        self.file.flush()

    def close(self):
        if self.file:
            self.file.close()
            self.file = None


# Findings and the step runner ---------------------------------------------------------------------

@dataclass
class Finding:
    kind: str
    message: str
    step: int | None = None        # 1-based step it surfaced after; 0 = at launch
    operation: str | None = None
    detail: dict = field(default_factory=dict)

    def key(self):
        """Identity for deduplication and for shrinking: kind plus what it is about."""
        if self.kind in ('rejected', 'stuck'):
            return self.kind, self.operation or self.message
        if self.kind == 'network' and self.detail.get('request'):
            request = self.detail['request']
            return self.kind, f"{request.get('method')} {url_path(request.get('url'))}"
        if self.kind == 'crash':
            return self.kind, 'crash'
        return self.kind, self.message

    def describe(self, steps=None):
        named = f'step {self.step}' + (f' "{steps[self.step - 1].do}"' if self.step and steps and self.step <= len(steps) else '')
        if self.kind in ('step', 'expect'):
            return f'{named}: {self.message}'
        if self.kind == 'requests':
            return f"requests {'at launch' if self.step == 0 else f'after {named}'}: {self.message}"
        if self.kind in ('check', 'budget', 'faults'):
            return f'{self.kind}: {self.message}'
        where = 'at launch' if self.step == 0 else f'after {named}' if self.step else ''
        return f'{self.kind} {where}: {self.message}'.replace(' :', ':')

    def record(self):
        return dict(kind=self.kind, message=self.message, step=self.step, operation=self.operation, detail=self.detail)


def url_path(url):
    if not isinstance(url, str):
        return ''
    return urlsplit(url).path or '/'


@dataclass
class Outcome:
    number: int
    query: str
    result: dict | None = None
    findings: list = field(default_factory=list)
    crashed: bool = False
    error: str | None = None

    @property
    def unresolved(self):
        return bool(self.result) and self.result['candidate'] is None

    @property
    def dispatched(self):
        return bool(self.result) and self.result['dispatched']

    @property
    def rejection(self):
        """A dispatch the app refused (nothing ran), e.g. invalid_arguments."""
        if self.result and self.result['candidate'] is not None and not self.result['dispatched']:
            return self.result.get('error') or 'rejected'
        return None

    @property
    def failed_receipt(self):
        return bool(self.result) and self.result['dispatched'] and not self.result['ok']


def step_query(view, observation, candidate):
    """The most readable name that `tca do` resolves back to this candidate: label, name, route, ID."""
    tca = sibling('tca')
    for query in (candidate.get('label'), tca.operation_name(candidate), tca.route(candidate['id'])):
        if query:
            found, _ = tca.resolve_operation(view, observation, query)
            if found and found['id'] == candidate['id']:
                return query
    return candidate['id']


class Runner:
    """Runs steps on a session and applies the generic oracles after each one."""

    def __init__(self, session, reporter=None, wait_ms=DEFAULT_WAIT_MS):
        self.session = session
        self.reporter = reporter or Reporter()
        self.wait_ms = wait_ms
        self.requests = []      # (step, request) for every request seen
        self.crashed = False
        self.network_reported = False
        self.raced = []         # (step, operation, requestID, dispatched at) of receipts nobody waited for
        self.last_dispatch = None

    def play(self, number, step, raced=False):
        """Run a journey step with its timing. `raced`: the next step is `no_wait`, so this one's receipt
        isn't waited for (it's settled when the race ends, with the stuck budget counted from its dispatch).
        A step that ends a race settles every receipt still running from it."""
        self.pause(step)
        outcome = self.step(number, step.do, step.args, step.path, wait=not raced)
        if not raced and not outcome.crashed and self.raced:
            try:
                outcome.findings += self.settle_raced(number)
            except RuntimeError as error:
                return self._broken(outcome, error)
        return outcome

    def pause(self, step, sleep=time.sleep):
        """Honour `after_ms`: measured from the previous dispatch in a race, else from now."""
        if not step.after_ms:
            return
        if step.no_wait and self.last_dispatch is not None:
            sleep(max(0.0, self.last_dispatch + step.after_ms / 1000 - time.monotonic()))
        else:
            sleep(step.after_ms / 1000)

    def settle_raced(self, number):
        """Wait for the receipts of raced steps; one still running after the stuck budget is **stuck**.
        Failed or cancelled raced receipts are not findings: a raced tap often loses."""
        findings = []
        for raced, operation, request_id, dispatched in self.raced:
            remaining = self.wait_ms - (time.monotonic() - dispatched) * 1000
            waited = self.session.host.call('wait', requestID=request_id, timeoutMs=max(int(remaining), 1))
            if waited.get('error') == 'wait_timeout':
                findings.append(Finding('stuck', f'{operation} still running after {self.wait_ms / 1000:g}s', raced, operation,
                                        {'receipt': waited.get('receipt'), 'raced': True}))
        self.raced = []
        for finding in findings:
            self.reporter.emit('finding', **finding.record())
        return findings + self.collect(number)

    def step(self, number, query, arguments=None, path=None, wait=True):
        tca = sibling('tca')
        outcome = Outcome(number, query)
        started = time.monotonic()
        for _ in range(4):
            try:
                outcome.result = tca.do_operation(self.session.host, query, arguments, path, False, self.wait_ms, wait)
            except RuntimeError as error:
                return self._broken(outcome, error)
            if outcome.result.get('error') != 'stale_revision' or outcome.result['dispatched']:
                break
            time.sleep(0.02)  # State moved between observe and dispatch; resolve again.
        result = outcome.result
        candidate = result['candidate']
        operation = tca.route(candidate['id']) if candidate else None
        receipt = result.get('receipt') or {}
        if result['dispatched']:
            self.last_dispatch = time.monotonic()
            if not wait and receipt.get('status') == 'running':
                self.raced.append((number, operation, receipt.get('requestID'), started))
        self.reporter.emit('dispatch', step=number, query=query, candidate=candidate['id'] if candidate else None,
                           arguments=arguments or {}, ok=result['ok'], error=result.get('error'), waited=wait,
                           detail=result.get('detail'), receipt=result.get('receipt'),
                           latencyMs=round((time.monotonic() - started) * 1000, 2), observation=self.session.observation)
        if candidate is not None and not result['dispatched'] and result.get('error') not in TOLERATED_REJECTIONS:
            outcome.findings.append(Finding('rejected', f'{operation} was offered, then rejected: {result.get("error")}'
                                            + (f' ({result["detail"]})' if result.get('detail') else ''),
                                            number, operation, {'error': result.get('error'), 'detail': result.get('detail')}))
        if result['dispatched'] and result.get('error') == 'wait_timeout':
            outcome.findings.append(Finding('stuck', f'{operation} still running after {self.wait_ms / 1000:g}s',
                                            number, operation, {'receipt': result.get('receipt')}))
        try:
            # Mid-race an empty view is the in-flight request, not a dead end; settling the race checks.
            outcome.findings += self.collect(number, operation, allow_dead_end=not wait or bool(self.raced))
        except RuntimeError as error:
            return self._broken(outcome, error)
        if self.crashed:
            outcome.crashed = True
        return outcome

    def _broken(self, outcome, error):
        """A host call failed: a crash if the process died or the connection dropped."""
        message = str(error)
        if self.session.launched:
            deadline = time.monotonic() + 0.5  # Give a dying process a moment to be reaped.
            while self.session.alive() and time.monotonic() < deadline:
                time.sleep(0.02)
        if not self.session.alive() or any(word in message for word in ('disconnected', 'interrupted', 'timed out')):
            self.crashed = outcome.crashed = True
            tail = self.session.output(15)
            finding = Finding('crash', self.session.crash_message(message if self.session.alive() else None),
                              outcome.number, None, {'output': tail})
            outcome.findings.append(finding)
            self.reporter.emit('finding', **finding.record())
        elif 'No mounted features' in message:
            outcome.findings.append(Finding('dead end', 'no mounted features', outcome.number))
        else:
            outcome.error = message
        return outcome

    def collect(self, number, operation=None, allow_dead_end=False):
        """Generic oracles that read the app: crash, issues/invariants, network log, dead end."""
        findings = []
        if not self.session.alive():
            self.crashed = True
            finding = Finding('crash', self.session.crash_message(), number, operation, {'output': self.session.output(15)})
            self.reporter.emit('finding', **finding.record())
            return [finding]
        network_issue = False
        new_requests = self.session.new_requests()
        if self.session.network is not None and not self.network_reported:
            self.network_reported = True  # Mode and cassette directory, once per run (for `tca fixtures coverage`).
            self.reporter.emit('network', **self.session.network)
        for issue in self.session.new_issues():
            kind = issue.get('kind') if issue.get('kind') in ('issue', 'invariant', 'network') else 'issue'
            network_issue |= kind == 'network'
            findings.append(Finding(kind, str(issue.get('message', '')), number, operation, {'issue': issue}))
        for request in new_requests:
            self.requests.append((number, request))
            self.reporter.emit('request', step=number, request=request)
            if request.get('source') == 'blocked' and not network_issue:
                why = 'had no fixture' if self.session.mode == 'replay' else 'was blocked'
                findings.append(Finding('network', f"{request.get('method')} {request.get('url')} {why}",
                                        number, operation, {'request': request}))
        candidates = (self.session.observation or {}).get('candidates')
        if candidates == [] and not allow_dead_end:
            findings.append(Finding('dead end', 'nothing is offered', number, operation))
        for finding in findings:
            self.reporter.emit('finding', **finding.record())
        return findings

    def quiesce(self, number, quiet=0.3, limit=2.0):
        """Watch until the app goes `quiet` seconds with no state change, request or issue (at most
        `limit`), collecting oracles on the way. Late effects (a response landing after the last step)
        show up here instead of after the process is gone. While the app reports requests in flight
        (`pending`), the watch goes on up to the stuck budget (`wait_ms`), so a slow response lands
        before the next step, as it would while a person waits."""
        findings, started = [], time.monotonic()
        deadline, hard = started + limit, started + max(limit, self.wait_ms / 1000)
        last_change, revision = started, None
        while True:
            seen = len(self.requests)
            found = self.collect(number, allow_dead_end=True)
            current = (self.session.observation or {}).get('revision')
            pending = (self.session.network or {}).get('pending') or 0
            now = time.monotonic()
            if found or len(self.requests) != seen or current != revision or pending:
                findings += found
                revision, last_change = current, now
            elif now - last_change >= quiet:
                break
            if self.crashed or now >= (hard if pending else deadline):
                break
            time.sleep(0.05)
            self.session.host.call('observe')
        return findings

    def settle(self, expression, seconds=SETTLE_SECONDS):
        """Evaluate against fresh observations until true or out of time: (holds, error, value)."""
        deadline = time.monotonic() + seconds
        while True:
            state = self.session.host.call('observe')['observation']['state']
            try:
                if expressions.holds(expression, state):
                    return True, None
                error = None
            except expressions.ExpressionError as problem:
                error = str(problem)
            if time.monotonic() >= deadline:
                return False, error
            time.sleep(0.05)


@dataclass
class RunResult:
    journey: Journey
    problems: list = field(default_factory=list)   # Findings, in the order they happened
    outcomes: list = field(default_factory=list)
    states: list = field(default_factory=list)     # Root state at launch and after each step
    requests: list = field(default_factory=list)
    elapsed: float = 0.0
    view: dict | None = None                       # Focused view when a step stopped resolving
    completed: bool = False
    output: list = field(default_factory=list)
    runner: object = None
    final_state: object = None                     # Root state once the app went quiet after the last step

    @property
    def passed(self):
        return not self.problems

    @property
    def findings(self):
        return [p for p in self.problems if p.kind in ORACLE_KINDS]


def run_journey(session, journey, reporter=None, wait_ms=DEFAULT_WAIT_MS, *, checks=True, tolerate_failed_receipts=False,
                after_step=None, steps=None, stop_on_finding=True, label=None, pace=0, quiet_steps=False):
    """Run a journey's steps (or `steps`) on an open session; never raises for app behaviour.

    `pace` sleeps that many seconds after each step and once before the final checks, so a person (or a
    screen recording) can follow along. `quiet_steps` waits for quiet after every step (and race), as
    journeys that declare `requests` do, so each request is attributed to the step that made it."""
    reporter = reporter or Reporter()
    steps = journey.steps if steps is None else steps
    result = RunResult(journey)
    started = time.monotonic()
    reporter.emit('goal_started', goal=label or journey.name, description=journey.goal or journey.name,
                  file=str(journey.path) if journey.path else None)
    runner = Runner(session, reporter, wait_ms)
    result.runner = runner

    def stop(problem):
        result.problems.append(problem)
        if problem.kind not in ORACLE_KINDS:
            reporter.emit('finding', **problem.record())

    check_requests = checks and journey.checks_requests
    contract = []  # Request mismatches: reported, but the run goes on so later oracles still fire.

    def expectation(patterns, number, first=None):
        """Compare the requests seen from step `first` (default `number`) through `number` with `patterns`."""
        if patterns is None or session.supports.get('network') is False:
            return
        first = number if first is None else first
        problem = requests_finding(patterns, [r for s, r in runner.requests if first <= s <= number], number)
        if problem:
            contract.append(problem)
            reporter.emit('finding', **problem.record())

    try:
        if journey.launch_faults and not session.fresh:
            stop(Finding('faults', 'the journey has `at = "launch"` faults, which need a fresh launch '
                         '(a harness.toml target with restart = "per-run"), not --port or restart = "never"', 0))
        elif journey.connect_faults:
            faults = journey.connect_faults
            if journey.launch_faults:
                # Keep launch faults that haven't fired yet (a launch request may still be in flight).
                current = session._method('network')
                faults = list(((current or {}).get('network') or {}).get('faults') or []) + faults
            if not session.configure_network(faults=faults):
                stop(Finding('faults', 'the journey declares faults but the app has no `network` method (protocol v3)', 0))
        if result.passed:
            # Launch effects (first fetches, permission callbacks) land before the first step, as they
            # would before a person's first tap, so step 1 and the launch state don't race them.
            result.problems += runner.quiesce(0)
            if not runner.crashed:
                result.problems += runner.collect(0, allow_dead_end=not steps and journey.terminal)
            result.states.append(copy.deepcopy(session.observation['state']))
            if result.passed and check_requests:
                expectation(journey.launch_requests, 0)
            if after_step and result.passed and not runner.crashed and after_step(0, None, runner) == 'stop':
                steps = []  # The caller has what it needed from the launch (chaos on a launch request).
        race_start = 1
        for number, step in enumerate(steps, 1):
            if not result.passed and stop_on_finding:
                break
            if not step.no_wait:
                race_start = number
            raced = number < len(steps) and steps[number].no_wait
            outcome = runner.play(number, step, raced)
            result.outcomes.append(outcome)
            last = number == len(steps)
            outcome.findings = [f for f in outcome.findings if not (f.kind == 'dead end' and last and journey.terminal)]
            result.problems += outcome.findings
            if outcome.result is not None and session.observation:
                result.states.append(copy.deepcopy(session.observation['state']))
            if outcome.crashed:
                break
            if outcome.error:
                stop(Finding('step', outcome.error, number))
                break
            if outcome.unresolved:
                problem = outcome.result['error']
                choices = outcome.result['choices']
                message = (f'ambiguous, matches {len(choices)} operations' if problem == 'ambiguous'
                           else 'no offered operation matches')
                result.view = outcome.result['before']
                stop(Finding('step', message, number, None, {'error': problem}))
                break
            if outcome.rejection in TOLERATED_REJECTIONS:
                detail = outcome.result.get('detail')
                stop(Finding('step', f'rejected: {outcome.rejection}' + (f' ({detail})' if detail else ''), number))
                break
            if raced:
                continue  # Its expect, requests and receipt are checked when the race ends.
            if outcome.failed_receipt and not tolerate_failed_receipts and not any(f.kind == 'stuck' for f in outcome.findings):
                status = (outcome.result.get('receipt') or {}).get('status', outcome.result.get('error'))
                stop(Finding('step', f'finished {status}', number))
                break
            if not result.passed and stop_on_finding:
                break
            if step.expect and checks:
                holds, error = runner.settle(step.expect)
                if not holds:
                    stop(Finding('expect', f'expected `{step.expect}`' + (f' ({error})' if error else ' to hold'), number))
                    break
            if check_requests or quiet_steps:
                # This step's requests are the ones logged until the app goes quiet again.
                result.problems += runner.quiesce(number)
                if not result.passed and stop_on_finding:
                    break
                if check_requests:
                    expectation(step.requests, number, race_start)
            if after_step and after_step(number, outcome, runner) == 'stop':
                break
            if pace:
                time.sleep(pace)
        else:
            result.completed = result.passed or not stop_on_finding
        if result.completed:
            result.problems += runner.quiesce(len(steps))
            result.final_state = copy.deepcopy((session.observation or {}).get('state'))
            if pace:
                time.sleep(pace)
        if result.completed and checks:
            for name, expression in journey.checks.items():
                holds, error = runner.settle(expression)
                reporter.emit('check', name=name, expression=expression, passed=holds, error=error)
                if not holds:
                    stop(Finding('check', f'"{name}" failed: `{expression}`' + (f' ({error})' if error else ''), len(steps)))
            if 'requests' in journey.budget:
                if session.supports.get('network'):
                    count = len(runner.requests)
                    if count > journey.budget['requests']:
                        stop(Finding('budget', f'{count} requests, budget {journey.budget["requests"]}', len(steps),
                                     None, {'requests': [r for _, r in runner.requests]}))
    except RuntimeError as error:
        outcome = runner._broken(Outcome(len(result.outcomes) + 1, ''), error)
        result.problems += outcome.findings or [Finding('step', str(error), outcome.number)]
    result.problems += contract
    result.requests = list(runner.requests)
    result.elapsed = time.monotonic() - started
    result.output = session.output()
    if session.launched:
        reporter.emit('target_output', target=session.launched.target.name, lines=result.output[-200:])
    first = result.problems[0] if result.problems else None
    reporter.emit('goal_finished', goal=label or journey.name, status='passed' if result.passed else 'failed',
                  elapsedMs=round(result.elapsed * 1000), reason=first.describe(steps) if first else None,
                  problems=[p.record() for p in result.problems], observation=session.observation)
    return result


# `tca journey run` --------------------------------------------------------------------------------

def indent(text, prefix='    '):
    return '\n'.join(prefix + line if line else line for line in text.splitlines())


def summarize(result, file_label, steps=None):
    journey = result.journey
    steps = journey.steps if steps is None else steps
    if result.passed:
        requests = f', {len(result.requests)} request(s)' if result.requests else ''
        return f'PASS  {journey.name}  ({file_label})  {len(steps)} step(s){requests}, {result.elapsed:.2f}s'
    first = result.problems[0]
    lines = [f'FAIL  {journey.name}  ({file_label})', f'  {first.describe(steps)}']
    if first.kind == 'crash' and first.detail.get('output'):
        lines += ['  last output:', indent('\n'.join(first.detail['output'][-10:]))]
    if result.view is not None:
        tca = sibling('tca')
        lines += ['  current view:', indent(tca.format_view(result.view))]
        remaining = [s.do for s in steps[first.step - 1:]] if first.step else []
        if journey.goal:
            lines.append(f'  goal: {journey.goal}')
        if remaining:
            lines.append('  remaining steps: ' + ', '.join(f'"{s}"' for s in remaining))
        lines.append(f'  hint: re-solve it: `tca record start {file_label}`, reach the goal with `tca ls`/`tca do`, '
                     'then `tca record stop`')
    if len(result.problems) > 1:
        lines.append(f'  (+{len(result.problems) - 1} more: ' + '; '.join(p.describe(steps) for p in result.problems[1:4])
                     + ('; ...' if len(result.problems) > 4 else '') + ')')
    return '\n'.join(lines)


def journey_run(arguments):
    reporter = Reporter(arguments.report)
    try:
        journeys = [load_journey(path) for path in arguments.files]
        opener = Opener.from_arguments(arguments.target, arguments.port, [j.path for j in journeys])
    except (JourneyError, targets.TargetError) as error:
        reporter.close()
        print(f'error: {error}', file=sys.stderr)
        return 2
    failed = 0
    try:
        for journey in journeys:
            label = str(journey.path)
            if not journey.steps:
                failed += 1
                reporter.emit('goal_finished', goal=journey.name, status='failed', reason='unsolved: no steps')
                print(f'FAIL  {journey.name}  ({label})\n  unsolved: the journey has a goal but no steps\n'
                      f'  goal: {journey.goal or "(none)"}\n  hint: solve it: `tca record start {label}`, reach the goal '
                      'with `tca ls`/`tca do`, then `tca record stop`')
                continue
            settings = Settings.for_journey(journey, arguments.network, arguments.seed, arguments.wait_ms,
                                            latency=cli_latency(arguments))
            try:
                session = opener.open(settings)
            except (RuntimeError, targets.TargetError) as error:
                failed += 1
                print(f'FAIL  {journey.name}  ({label})\n  could not start {opener.name}: {error}')
                continue
            keep = arguments.keep and journey is journeys[-1] and session.launched is not None
            if keep:
                session.owned = False  # Leave the app running after the last journey.
            try:
                result = run_journey(session, journey, reporter, arguments.wait_ms, pace=arguments.pace)
            finally:
                session.close()
            if keep:
                launched = session.launched
                stop = launched.target.stop or f'kill -- -{launched.process.pid}'
                print(f'left running: {launched.target.name} on 127.0.0.1:{launched.port}; '
                      f'attach with `tca ls --port {launched.port}`, stop it with `{stop}`')
            failed += not result.passed
            print(summarize(result, label))
    finally:
        opener.close()
        reporter.close()
    if len(journeys) > 1:
        print(f'{len(journeys) - failed} passed, {failed} failed')
    print_notes()
    return 1 if failed else 0


# `tca record` ----------------------------------------------------------------------------------

def recording_file():
    return Path.cwd() / RECORDING


def record_start(arguments):
    path = Path(arguments.file).resolve()
    base = {}
    if path.exists():
        try:
            base = tomllib.loads(path.read_text())
            journey_from(base, path)
        except (tomllib.TOMLDecodeError, JourneyError) as error:
            print(f'error: {path}: {error}', file=sys.stderr)
            return 2
    goal = arguments.goal or base.get('goal')
    if not goal:
        print('error: record start needs --goal TEXT (or an existing journey with a goal)', file=sys.stderr)
        return 2
    state = recording_file()
    if state.exists():
        print(f'note: replacing the unfinished recording of {json.loads(state.read_text()).get("file")}', file=sys.stderr)
    base.pop('steps', None)
    base.pop('launch_requests', None)
    base['goal'] = goal
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({'file': str(path), 'base': base, 'steps': [],
                                 'started': datetime.now().astimezone().isoformat()}, indent=2))
    print(f'recording {path}\n  goal: {goal}\n  each successful `tca do` from {Path.cwd()} adds a step with the requests '
          'it made; finish with `tca record stop [--check NAME=EXPR]`')
    return 0


def cassette_templates(directory):
    """`path_templates` from `match.json` in a cassette directory, if any."""
    try:
        rules = json.loads((Path(directory) / 'match.json').read_text())
    except (OSError, ValueError, TypeError):
        return []
    templates = rules.get('path_templates') if isinstance(rules, dict) else None
    return [t for t in templates if isinstance(t, str)] if isinstance(templates, list) else []


def record_requests(host, port=None):
    """Called by `tca do` before it dispatches while recording: the requests logged since the last
    `do` belong to the previous step (or, before the first step, to launch). Returns how many."""
    state = recording_file()
    data = json.loads(state.read_text())
    since = data.get('requestSeq', 0)
    response = host.call('network', since=since)
    if not response.get('ok'):
        data['network'] = False  # Protocol v2: no request log, so steps get no `requests`.
        state.write_text(json.dumps(data, indent=2))
        return 0
    network = response.get('network') or {}
    requests = [r for r in network.get('requests') or [] if isinstance(r, dict) and r.get('seq', 0) > since]
    templates = cassette_templates(network['cassettes']) if network.get('cassettes') else []
    patterns = [request_pattern(r, templates) for r in requests]
    if data['steps']:
        data['steps'][-1].setdefault('requests', []).extend(patterns)
    elif patterns:
        data.setdefault('launchRequests', []).extend(patterns)
        print(f'recorded {len(patterns)} request(s) made before the first step as `launch_requests` '
              '(the launch requests, when recording started on a fresh launch)', file=sys.stderr)
    if requests:
        data['requestSeq'] = max(r.get('seq', 0) for r in requests)
    data['network'] = True
    if port is not None:
        data['port'] = port
    state.write_text(json.dumps(data, indent=2))
    return len(patterns)


def record_step(result, arguments, path=None):
    """Called by `tca do` while recording: append the step by its label. Returns (number, query)."""
    state = recording_file()
    data = json.loads(state.read_text())
    query = step_query(result['before'], result['observation'], result['candidate'])
    step = {'do': query}
    if arguments:
        step['args'] = arguments
    if path:
        step['path'] = path
    if data.get('network'):
        step['requests'] = []  # Filled in by the next `do`, or by `record stop`.
    data['steps'].append(step)
    state.write_text(json.dumps(data, indent=2))
    return len(data['steps']), query


def record_last_requests(data, quiet=0.5, limit=3.0):
    """At `record stop`: wait until the app has made no request for `quiet` seconds, then give the
    last step its requests. Without a reachable app the last step is left unchecked."""
    if not data.get('network') or not data.get('steps') or data.get('port') is None:
        return data
    tca = sibling('tca')
    try:
        host = tca.Host(port=data['port'])
    except RuntimeError:
        data['steps'][-1].pop('requests', None)
        note(f"the app on port {data['port']} is gone, so the last step has no `requests`")
        return data
    try:
        seen, last_change, deadline = None, time.monotonic(), time.monotonic() + limit
        while time.monotonic() < deadline:
            response = host.call('network', since=data.get('requestSeq', 0))
            count = len((response.get('network') or {}).get('requests') or [])
            if count != seen:
                seen, last_change = count, time.monotonic()
            elif time.monotonic() - last_change >= quiet:
                break
            time.sleep(0.05)
        record_requests(host)
    finally:
        host.close()
    return json.loads(recording_file().read_text())


def record_stop(arguments):
    state = recording_file()
    if not state.exists():
        print(f'error: no recording in progress ({state} not found); start one with `tca record start FILE --goal TEXT`',
              file=sys.stderr)
        return 2
    data = record_last_requests(json.loads(state.read_text()))
    path = Path(data['file'])
    document = dict(data['base'])
    if data.get('launchRequests') is not None and data.get('steps'):
        document['launch_requests'] = data['launchRequests']
    elif data.get('network') and data.get('steps'):
        document['launch_requests'] = []
    document.setdefault('name', path.stem.replace('-', ' ').replace('_', ' ').capitalize())
    checks = dict(document.get('checks') or {})
    for item in arguments.check or []:
        name, separator, expression = item.partition('=')
        if not separator or not name.strip() or not expression.strip():
            print(f'error: --check takes NAME=EXPRESSION, got {item!r}', file=sys.stderr)
            return 2
        try:
            expressions.compile_expression(expression.strip())
        except expressions.ExpressionError as error:
            print(f'error: check {name.strip()!r}: {error}', file=sys.stderr)
            return 2
        checks[name.strip()] = expression.strip()
    document['steps'] = data['steps']
    if checks:
        document['checks'] = checks
    try:
        journey = journey_from(document, path)
    except JourneyError as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    if not journey.steps:
        note('no steps were recorded; run `tca do` from this directory while recording')
    if not journey.network and not journey.fixtures:
        note('the journey sets no `network`/`fixtures`, so replays block the network; add `network = "live"`, '
             'or record cassettes with `tca journey run FILE --network record` and set `fixtures`')
    write_journey(journey, path)
    state.unlink()
    pinned = sum(len(step.requests or []) for step in journey.steps) + len(journey.launch_requests or [])
    print(f'wrote {path}: {len(journey.steps)} step(s), {len(journey.checks)} check(s)'
          + (f', {pinned} expected request(s)' if journey.checks_requests else ''))
    print(f'  replay it with `tca journey run {os.path.relpath(path)}`')
    print_notes()
    return 0


# Findings on disk ---------------------------------------------------------------------------------

def finding_path(kind, directory=None):
    directory = Path(directory) if directory else Path.cwd() / FINDINGS
    slug = kind.replace(' ', '-')
    for number in itertools.count(1):
        path = directory / f'{slug}-{number}.toml'
        if not path.exists():
            return path


# Command line --------------------------------------------------------------------------------------

def add_run_options(parser, target=True, network=True):
    if target:
        parser.add_argument('--target', help='harness.toml target to launch (default: headless, or the only one)')
    if network:
        parser.add_argument('--network', choices=NETWORK_MODES, help="Override the journey's network mode")
    parser.add_argument('--seed', type=int, help='TCA_HARNESS_SEED for the app (default: the journey seed, else 0)')
    parser.add_argument('--report', type=Path, help='Write JSON lines (viewable with `tca trace`)')
    parser.add_argument('--wait-ms', type=int, default=DEFAULT_WAIT_MS,
                        help='How long a receipt may stay running before it is stuck (default 5000)')
    parser.add_argument('--latency', type=int, metavar='MS',
                        help="Replay latency: hold each replayed response this long (overrides the journey's and match.json's)")
    parser.add_argument('--jitter', type=int, metavar='MS',
                        help='Replay latency jitter: +/- this much per request, drawn from the seed (default 0)')


def cli_latency(arguments):
    """`--latency`/`--jitter` as a TCA_HARNESS_LATENCY dict, or None when neither is given."""
    ms, jitter = getattr(arguments, 'latency', None), getattr(arguments, 'jitter', None)
    if ms is None and jitter is None:
        return None
    latency = {'ms': ms or 0}
    if jitter:
        latency['jitter_ms'] = jitter
    return latency


def build_parser():
    parser = argparse.ArgumentParser(prog='tca', description='Behaviour tests over the harness. See docs/testing.md.')
    commands = parser.add_subparsers(dest='command', required=True, metavar='command')

    journey = commands.add_parser('journey', help='Run journey files')
    journey_commands = journey.add_subparsers(dest='action', required=True, metavar='run')
    run = journey_commands.add_parser('run', help='Run journeys on fresh launches and apply the generic oracles')
    run.add_argument('files', nargs='+', type=Path, metavar='FILE')
    add_run_options(run)
    run.add_argument('--port', type=int, help='Attach to an app already running on this port instead of launching')
    run.add_argument('--keep', action='store_true',
                     help='Leave the app launched for the last journey running, e.g. to inspect or record it')
    run.add_argument('--pace', type=float, default=0, metavar='SECONDS',
                     help='Pause after each step and before the final checks, e.g. for a screen recording (default 0)')

    record = commands.add_parser('record', help='Record `tca do` steps into a journey')
    record_commands = record.add_subparsers(dest='action', required=True, metavar='start|stop')
    start = record_commands.add_parser('start', help='Start recording; each successful `tca do` appends a step')
    start.add_argument('file', type=Path, metavar='FILE')
    start.add_argument('--goal', help='What the journey achieves (kept from FILE if it exists)')
    stop = record_commands.add_parser('stop', help='Write the recorded steps to the journey file')
    stop.add_argument('--check', action='append', metavar='NAME=EXPR', help='Add a final check (repeatable)')

    explore = commands.add_parser('explore', help='Random walks over offered operations; shrinks findings')
    add_run_options(explore)
    explore.add_argument('--runs', type=int, default=50)
    explore.add_argument('--steps', type=int, default=40)
    explore.add_argument('--journey', type=Path, help='Start every walk from the end of this journey')
    explore.add_argument('--fixtures', type=Path, help='Cassette directory for replay (default: the journey fixtures)')
    explore.add_argument('--shrink-trials', type=int, default=100, help='Relaunches allowed per finding (default 100)')
    explore.add_argument('--out', type=Path, help='Where to write findings (default .tca/findings)')
    explore.add_argument('--races', action='store_true',
                         help="Don't wait for steps that leave something in flight: double taps, dismissing "
                              'mid-request, out-of-order responses. Uses a replay latency (default 200 +/- 150 ms)')

    chaos = commands.add_parser('chaos', help='Fail each request of a journey in turn')
    chaos.add_argument('file', type=Path, metavar='FILE')
    add_run_options(chaos, network=False)
    chaos.add_argument('--faults', default='status500,timeout,offline,malformed,slow',
                       help='Comma-separated: status500, timeout, offline, malformed, slow')
    chaos.add_argument('--out', type=Path, help='Where to write findings (default .tca/findings)')
    chaos.add_argument('--reorder', action='store_true',
                       help='Instead of failing requests: where a step (or a race of no_wait steps) makes two or more '
                            'requests to one endpoint, hold the first back so the responses arrive out of order')
    chaos.add_argument('--reorder-ms', type=int, default=1000, metavar='MS',
                       help='How long --reorder holds the first response back (default 1000)')

    determinism = commands.add_parser('determinism', help='Replay a journey several times and compare state')
    determinism.add_argument('file', type=Path, metavar='FILE')
    add_run_options(determinism)
    determinism.add_argument('--runs', type=int, default=3)
    determinism.add_argument('--out', type=Path, help='Where to write findings (default .tca/findings)')

    diff = commands.add_parser('diff', help='Run a journey on two targets and compare state')
    diff.add_argument('file', type=Path, metavar='FILE')
    diff.add_argument('--targets', required=True, help='Two harness.toml targets, e.g. headless,ui')
    add_run_options(diff, target=False)
    diff.add_argument('--out', type=Path, help='Where to write findings (default .tca/findings)')

    sibling('fixtures').add_parsers(commands)
    return parser


def main(argv):
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if getattr(arguments, 'wait_ms', 1) <= 0:
        parser.error('--wait-ms must be positive')
    if any((getattr(arguments, name, None) or 0) < 0 for name in ('latency', 'jitter', 'reorder_ms')):
        parser.error('--latency, --jitter and --reorder-ms must not be negative')
    NOTES.clear()
    if arguments.command == 'journey':
        return journey_run(arguments)
    if arguments.command == 'record':
        return record_start(arguments) if arguments.action == 'start' else record_stop(arguments)
    if arguments.command == 'fixtures':
        return sibling('fixtures').main(arguments)
    exploration = sibling('exploration')
    if arguments.command == 'explore':
        if arguments.runs < 1 or arguments.steps < 1 or arguments.shrink_trials < 0:
            parser.error('--runs and --steps must be at least 1')
        return exploration.explore_command(arguments)
    if arguments.command == 'chaos':
        unknown = set(arguments.faults.split(',')) - set(exploration.FAULTS)
        if unknown:
            parser.error('unknown fault(s): ' + ', '.join(sorted(unknown)) + '; use ' + ', '.join(exploration.FAULTS))
        return exploration.chaos_command(arguments)
    if arguments.command == 'determinism':
        if arguments.runs < 2:
            parser.error('--runs must be at least 2')
        return exploration.determinism_command(arguments)
    names = [n.strip() for n in arguments.targets.split(',') if n.strip()]
    if len(names) != 2:
        parser.error('--targets takes two names, e.g. headless,ui')
    arguments.targets = names
    return exploration.diff_command(arguments)
