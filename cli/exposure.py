"""`tca exposure`: how much of the app an agent can reach, and which reachable operations no run exercised.

Features come from the descriptor's catalog (`inspect` with `catalog`: every feature it can mount),
from `inspect` of an attached or launched app, from `mounts` and `catalog` events in reports and
journey runs, and from the operations offered in their observations. A feature is *reached* when some
run (or the live app) mounted it. Exercised operations are the `dispatch` events whose operation ran,
matched by route (the candidate ID without `@instance`). Paths are templated with the catalog's
patterns (`root/books/{id}`), else like request paths (numeric, UUID and long hex segments become
`{id}`), so every row of a list counts as one feature.
"""
from collections import Counter
from dataclasses import dataclass, field
import glob
from importlib import import_module
import json
from pathlib import Path
import sys

if __package__:
    journeys = import_module(f'{__package__}.journeys')
else:
    journeys = sys.modules.get('journeys') or import_module('journeys')
sibling = journeys.sibling


@dataclass
class Feature:
    key: str                                        # Templated path, e.g. root/books/{id}
    name: str | None = None
    paths: set = field(default_factory=set)         # Concrete paths seen
    operations: dict = field(default_factory=dict)  # Templated operation name -> label
    unexposed: dict = field(default_factory=dict)   # Action -> reason
    inspected: bool = False                         # Described by the catalog, inspect or mounts (else only offers)
    reports_unexposed: bool = False                 # The app sent `unexposed` (newer harness)
    reached: bool = False                           # Mounted in some run or in the live app


class Exposure:
    def __init__(self):
        self.features = {}
        self.exercised = Counter()   # (feature key, operation) -> dispatches that ran
        self.runs = []               # (label, passed, summary) for journeys run here
        self.reports = 0
        self.live = 0
        self.events = []             # Collected from every source; `finish` reads them, catalogs first
        self.templates = []          # Catalog paths, literal ones first
        self.catalogued = False

    def template(self, path):
        return journeys.templated_path(path, self.templates)

    def feature(self, path, name=None):
        key = self.template(path)
        feature = self.features.setdefault(key, Feature(key))
        feature.paths.add(path)
        if name and not feature.name:
            feature.name = name
        return feature

    def add_inspected(self, info, reached=True):
        """One catalog, `inspect` or `mounts` entry: path, name, declaredOperations, unexposed, operations."""
        if not isinstance(info, dict) or not isinstance(info.get('path'), str):
            return
        feature = self.feature(info['path'], info.get('name'))
        feature.inspected = True
        feature.reached |= reached
        for declared in info.get('declaredOperations') or []:
            if isinstance(declared, dict) and isinstance(declared.get('id'), str):
                feature.operations.setdefault(journeys.templated_path(declared['id']), declared.get('label'))
        if isinstance(info.get('unexposed'), list):
            feature.reports_unexposed = True
            for entry in info['unexposed']:
                if isinstance(entry, dict) and isinstance(entry.get('action'), str):
                    feature.unexposed.setdefault(entry['action'], str(entry.get('reason') or 'unexposed'))
        for candidate in info.get('operations') or []:
            self.add_candidate(candidate)

    def add_candidate(self, candidate):
        if not isinstance(candidate, dict) or not isinstance(candidate.get('feature'), str) or not isinstance(candidate.get('id'), str):
            return
        feature = self.feature(candidate['feature'])
        feature.reached = True
        name = journeys.templated_path(sibling('tca').operation_name(candidate))
        if feature.operations.get(name) is None:
            feature.operations[name] = candidate.get('label')

    def add_observation(self, observation):
        for candidate in (observation or {}).get('candidates') or [] if isinstance(observation, dict) else []:
            self.add_candidate(candidate)

    def feature_of(self, route):
        """The longest known feature path that `route` is an operation of."""
        known = [p for f in self.features.values() for p in f.paths if route.startswith(p + '/')]
        return max(known, key=len) if known else None

    def add_dispatch(self, event):
        """A `dispatch` event whose operation ran (it has a receipt)."""
        candidate = event.get('candidate')
        if not isinstance(candidate, str) or not event.get('receipt'):
            return
        route = sibling('tca').route(candidate)
        path = event.get('feature') if isinstance(event.get('feature'), str) else self.feature_of(route)
        if not path or not route.startswith(path + '/'):
            path = route.rsplit('/', 1)[0] if '/' in route else route
        feature = self.feature(path)
        feature.reached = True
        name = journeys.templated_path(route[len(path) + 1:])
        feature.operations.setdefault(name, None)
        self.exercised[(feature.key, name)] += 1

    def add_events(self, events):
        self.events += events

    def finish(self):
        """Read the collected events: catalogs first, so every path is templated with their patterns."""
        catalogs = [e for e in self.events if e.get('event') == 'catalog']
        paths = {f['path'] for e in catalogs for f in e.get('features') or [] if isinstance(f, dict) and isinstance(f.get('path'), str)}
        # Shape-templated too: a descriptor that mounts rows by index (`rides/0` ... `rides/9`) is one feature.
        self.templates = sorted({journeys.templated_path(p) for p in paths}, key=lambda p: (p.count('{'), p))
        self.catalogued = bool(catalogs)
        for event in catalogs:
            for info in event.get('features') or []:
                self.add_inspected(info, reached=False)
        for event in self.events:
            kind = event.get('event')
            if kind == 'mounts':
                for info in event.get('features') or []:
                    self.add_inspected(info)
            elif kind == 'dispatch':
                self.add_observation(event.get('observation'))
                self.add_dispatch(event)
            elif kind == 'goal_finished':
                self.add_observation(event.get('observation'))
        self.events = []
        return self

    def add_report(self, path):
        try:
            lines = Path(path).read_text().splitlines()
        except OSError as error:
            raise journeys.JourneyError(f'{path}: {error.strerror or error}') from None
        events = []
        for number, line in enumerate(lines, 1):
            if not line.strip():
                continue
            try:
                events.append(json.loads(line))
            except ValueError:
                raise journeys.JourneyError(f'{path}:{number}: not a JSON line') from None
        self.reports += 1
        self.add_events(events)

    def add_host(self, host):
        """The catalog and everything mounted on a connected app right now."""
        response = host.call('inspect', catalog=True)
        if not response.get('ok'):
            raise RuntimeError(f"inspect failed: {response.get('error')}")
        self.live += 1
        if isinstance(response.get('catalog'), list):
            self.events.append({'event': 'catalog', 'features': response['catalog']})
        self.events.append({'event': 'mounts', 'features': response.get('features') or []})
        self.events.append({'event': 'goal_finished', 'observation': host.observation})

    # Summary ------------------------------------------------------------------------------------

    def rows(self):
        return sorted(self.features.values(), key=lambda f: f.key.split('/'))

    def totals(self):
        operations = sum(len(f.operations) for f in self.features.values())
        exercised = sum(1 for f in self.features.values() for name in f.operations if self.exercised[(f.key, name)])
        reasons = Counter(reason for f in self.features.values() for reason in f.unexposed.values())
        reached = sum(1 for f in self.features.values() if f.reached)
        return dict(features=len(self.features), reached=reached, catalogued=self.catalogued, operations=operations, exercised=exercised,
                    exercisedPercent=round(100 * exercised / operations, 1) if operations else None,
                    unexposed=sum(reasons.values()), unexposedByReason=dict(reasons.most_common()),
                    uninspected=sum(1 for f in self.features.values() if not f.inspected))

    def as_json(self):
        return dict(
            features=[dict(path=f.key, paths=sorted(f.paths), name=f.name, inspected=f.inspected, reached=f.reached,
                           operations=[dict(name=name, label=label, exercised=self.exercised[(f.key, name)])
                                       for name, label in f.operations.items()],
                           unexposed=[dict(action=a, reason=r) for a, r in f.unexposed.items()])
                      for f in self.rows()],
            totals=self.totals(),
            runs=[dict(file=label, passed=passed) for label, passed, _ in self.runs])


def table(rows, headers, prefix='    '):
    widths = [max(len(str(r[i])) for r in [headers, *rows]) for i in range(len(headers))]
    line = lambda row: prefix + '  '.join(str(v).ljust(w) for v, w in zip(row, widths)).rstrip()
    return [line(headers), *map(line, rows)]


def print_exposure(exposure, stream=None):
    stream = stream or sys.stdout
    sources = []
    if exposure.live:
        sources.append(f'{exposure.live} live inspect')
    if exposure.runs:
        sources.append(f'{len(exposure.runs)} journey run(s)')
    if exposure.reports:
        sources.append(f'{exposure.reports} report(s)')
    print(f"exposure: {len(exposure.features)} feature(s) from {', '.join(sources) or 'nothing'}", file=stream)
    for feature in exposure.rows():
        print(f"\n  {feature.key}  {feature.name or '?'}" + ('' if feature.reached else '  (not reached)'), file=stream)
        if feature.operations:
            rows = [(name, label or '', exposure.exercised[(feature.key, name)] or '.')
                    for name, label in feature.operations.items()]
            print('\n'.join(table(rows, ('OPERATION', 'LABEL', 'EXERCISED'))), file=stream)
        else:
            print('    no operations', file=stream)
        by_reason = {}
        for action, reason in feature.unexposed.items():
            by_reason.setdefault(reason, []).append(action)
        for reason, actions in by_reason.items():
            print(f"    unexposed ({reason}): {', '.join(actions)}", file=stream)
        if not feature.inspected:
            print('    (only seen in offered operations, never inspected: unexposed actions unknown)', file=stream)
        elif not feature.reports_unexposed:
            print('    (the app does not report unexposed actions; update the harness package)', file=stream)
    totals = exposure.totals()
    percent = '-' if totals['exercisedPercent'] is None else f"{totals['exercisedPercent']:g}%"
    reasons = ', '.join(f'{reason} {count}' for reason, count in totals['unexposedByReason'].items())
    features = (f"{totals['reached']} of {totals['features']} feature(s) reached" if totals['catalogued']
                else f"{totals['features']} feature(s)")
    print(f"\ntotals: {features}, {totals['operations']} exposed operation(s), "
          f"{totals['exercised']} exercised ({percent}); {totals['unexposed']} unexposed action(s)"
          + (f': {reasons}' if reasons else ''), file=stream)
    unreached = [f.key for f in exposure.rows() if not f.reached]
    if unreached:
        print(f"not reached ({len(unreached)}): {', '.join(unreached)}", file=stream)
    failed = [summary for _, passed, summary in exposure.runs if not passed]
    if failed:
        print(f'\n{len(failed)} journey(s) failed, so their later steps were not exercised:', file=stream)
        for summary in failed:
            print(journeys.indent(summary, '  '), file=stream)


# Sources ------------------------------------------------------------------------------------------

def expand(patterns):
    files = []
    for pattern in patterns:
        matches = sorted(glob.glob(str(pattern))) if glob.has_magic(str(pattern)) else [str(pattern)]
        if not matches:
            raise journeys.JourneyError(f'{pattern}: no journey files match')
        files += [Path(m) for m in matches]
    return files


def run_journeys(exposure, loaded, opener, arguments):
    for journey in loaded:
        label = str(journey.path)
        settings = journeys.Settings.for_journey(journey, None, arguments.seed, arguments.wait_ms)
        try:
            session = opener.open(settings)
        except (RuntimeError, journeys.targets.TargetError) as error:
            exposure.runs.append((label, False, f'FAIL  {journey.name}  ({label})\n  could not start {opener.name}: {error}'))
            continue
        reporter = journeys.MemoryReporter()
        try:
            result = journeys.run_journey(session, journey, reporter, arguments.wait_ms)
        finally:
            session.close()
        exposure.add_events(reporter.events)
        exposure.runs.append((label, result.passed, journeys.summarize(result, label)))


def launch_and_inspect(exposure, opener, arguments):
    """A fresh launch (network blocked unless the target says otherwise), inspected once it is quiet."""
    session = opener.open(journeys.Settings(network='block', seed=arguments.seed or 0, wait_ms=arguments.wait_ms))
    try:
        journeys.Runner(session, wait_ms=arguments.wait_ms).quiesce(0)
        exposure.add_host(session.host)
    finally:
        session.close()


def exposure_command(arguments):
    exposure = Exposure()
    try:
        for report in arguments.reports or []:
            exposure.add_report(report)
        loaded = [journeys.load_journey(path) for path in expand(arguments.journeys or [])]
        live = arguments.port is not None or not (loaded or arguments.reports)
        if live or loaded:
            opener = journeys.Opener.from_arguments(arguments.target, arguments.port, [j.path for j in loaded])
            try:
                if live:
                    if arguments.port is not None:
                        host = sibling('tca').Host(port=arguments.port)
                        try:
                            exposure.add_host(host)
                        finally:
                            host.close()
                    elif not loaded:
                        launch_and_inspect(exposure, opener, arguments)
                if loaded:
                    run_journeys(exposure, loaded, opener, arguments)
            finally:
                opener.close()
    except (journeys.JourneyError, journeys.targets.TargetError, RuntimeError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    exposure.finish()
    if arguments.json:
        print(json.dumps(exposure.as_json(), indent=2))
    else:
        print_exposure(exposure)
        journeys.print_notes()
    totals = exposure.totals()
    failed = any(not passed for _, passed, _ in exposure.runs)
    below = arguments.min_exercised is not None and (totals['exercisedPercent'] or 0) < arguments.min_exercised
    if below:
        percent = totals['exercisedPercent'] or 0
        print(f'min-exercised: {percent:g}% of exposed operations exercised, below {arguments.min_exercised:g}%',
              file=sys.stderr if arguments.json else sys.stdout)
    return 1 if failed or below else 0


def add_parser(commands):
    parser = commands.add_parser('exposure', help='Which features and operations an agent can reach, and which runs exercised them')
    parser.add_argument('--port', type=int, help='Inspect the app running on this port (journeys attach to it too)')
    parser.add_argument('--target', help='harness.toml target to launch (default: headless, or the only one)')
    parser.add_argument('--reports', nargs='+', type=Path, metavar='FILE',
                        help='JSON-lines reports of earlier runs (journey run, explore, chaos, ... --report)')
    parser.add_argument('--journeys', nargs='+', metavar='GLOB',
                        help="Run these journeys (quote globs, e.g. 'journeys/*.toml') and count what they reach")
    parser.add_argument('--json', action='store_true', help='Machine-readable output')
    parser.add_argument('--min-exercised', type=float, metavar='PCT',
                        help='Exit 1 if fewer than PCT percent of exposed operations were exercised')
    parser.add_argument('--seed', type=int)
    parser.add_argument('--wait-ms', type=int, default=journeys.DEFAULT_WAIT_MS)
    return parser
