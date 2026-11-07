"""`tca explore`, `tca chaos`, `tca determinism` and `tca diff`, built on the journey run engine."""
import copy
from dataclasses import replace
import itertools
import json
import math
from pathlib import Path
import random
import sys
import time

from importlib import import_module

if __package__:
    journeys = import_module(f'{__package__}.journeys')
else:
    journeys = sys.modules.get('journeys') or import_module('journeys')

Journey, Step, Finding = journeys.Journey, journeys.Step, journeys.Finding

# Argument generation -------------------------------------------------------------------------------

STRINGS = [
    '', 'a', 'Dune', ' ', '  padded  ', '0', '-1', 'null', 'true', 'O\'Brien "quoted"', 'line\nbreak',
    'tab\tseparated', '<b>markup</b>', '../../etc', 'Ünïcödé', '日本語のタイトル', 'עברית', '👩‍👩‍👧 family', 'é',
    'x' * 256, 'long ' * 400,
]
INTEGERS = [0, 1, -1, 2, 7, 100, 2**31 - 1, -2**31, 2**53]
NUMBERS = [0, 1, -1, 0.5, -0.5, 3.14159, 1e6, -1e6, 1e15, 1e-9]


def generate(schema, rng, depth=0):
    """A JSON value for a harness argument schema (HarnessJSONSchema's wire form)."""
    if not isinstance(schema, dict):
        return None
    if isinstance(schema.get('anyOf'), list):
        variants = [v for v in schema['anyOf'] if isinstance(v, dict)]
        concrete = [v for v in variants if v.get('type') != 'null']
        if not concrete or (len(concrete) < len(variants) and rng.random() < 0.25):
            return None
        return generate(rng.choice(concrete), rng, depth + 1)
    kind = schema.get('type')
    if isinstance(kind, list):
        kind = rng.choice([k for k in kind if k != 'null'] or ['null'])
    if kind == 'string':
        if isinstance(schema.get('enum'), list) and schema['enum']:
            return rng.choice(schema['enum'])
        low, high = schema.get('minLength', 0) or 0, schema.get('maxLength')
        corpus = [s for s in STRINGS if low <= len(s) and (high is None or len(s) <= high)]
        if not corpus:
            corpus = ['a' * low]
        return rng.choice(corpus)
    if kind == 'integer':
        low, high = schema.get('minimum'), schema.get('maximum')
        if low is not None or high is not None:
            low = int(math.ceil(low)) if low is not None else -2**31
            high = int(math.floor(high)) if high is not None else 2**31 - 1
            return rng.choice([low, high, (low + high) // 2, rng.randint(low, high)]) if low <= high else low
        return rng.choice(INTEGERS)
    if kind == 'number':
        low, high = schema.get('minimum'), schema.get('maximum')
        if low is not None and high is not None and low <= high:
            return rng.choice([low, high, (low + high) / 2, rng.uniform(low, high)])
        values = [n for n in NUMBERS if (low is None or n >= low) and (high is None or n <= high)]
        return rng.choice(values or [low if low is not None else high])
    if kind == 'boolean':
        return rng.random() < 0.5
    if kind == 'array':
        if depth > 6:
            return []
        count = rng.choice([0, 1, 2, 3, 10])
        return [generate(schema.get('items'), rng, depth + 1) for _ in range(count)]
    if kind == 'object':
        properties = schema.get('properties') or {}
        if depth > 6:
            return {}
        return {name: generate(field, rng, depth + 1) for name, field in properties.items()}
    if kind == 'null':
        return None
    return None


# Shared helpers -------------------------------------------------------------------------------------

def opener_for(arguments, starts=()):
    return journeys.Opener.from_arguments(getattr(arguments, 'target', None), getattr(arguments, 'port', None), starts)


def run_once(opener, journey, settings, reporter, **options):
    """Fresh session, run, close. Returns a RunResult (a failed launch becomes a crash finding)."""
    try:
        session = opener.open(settings)
    except (RuntimeError, journeys.targets.TargetError) as error:
        result = journeys.RunResult(journey)
        result.problems.append(Finding('crash', f'could not start {opener.name}: {error}', 0))
        return result
    try:
        return journeys.run_journey(session, journey, reporter, settings.wait_ms, **options)
    finally:
        session.close()


def table(rows, headers):
    widths = [max(len(str(r[i])) for r in [headers, *rows]) for i in range(len(headers))]
    line = lambda row: '  ' + '  '.join(str(v).ljust(w) for v, w in zip(row, widths)).rstrip()
    return '\n'.join([line(headers), *map(line, rows)])


def relative(path):
    try:
        return str(Path(path).resolve().relative_to(Path.cwd()))
    except ValueError:
        return str(path)


def load(arguments, attribute='file'):
    try:
        return journeys.load_journey(getattr(arguments, attribute))
    except journeys.JourneyError as error:
        print(f'error: {error}', file=sys.stderr)
        return None


def finding_journey(base, name, goal, steps, settings, faults=None):
    steps = [replace(step, expect=None, requests=None) for step in steps]  # A finding needs only its steps to reproduce.
    return Journey(path=None, name=name, goal=goal, steps=steps, fixtures=settings.cassettes,
                   network=settings.network, seed=settings.seed, terminal=False,
                   faults=list(faults or (base.faults if base else [])))


# explore ----------------------------------------------------------------------------------------------

def walk(opener, settings, rng, prefix, max_steps, reporter, label):
    """One random walk on a fresh launch. Returns (steps taken, first finding or None, error)."""
    tca = journeys.sibling('tca')
    try:
        session = opener.open(settings)
    except (RuntimeError, journeys.targets.TargetError) as error:
        return [], None, f'could not start {opener.name}: {error}'
    taken = list(prefix)
    found = []
    try:
        reporter.emit('goal_started', goal=label, description=f'Random walk, up to {max_steps} steps')
        runner = journeys.Runner(session, reporter, settings.wait_ms)
        launch_findings = runner.collect(0, allow_dead_end=True)
        if launch_findings:
            return taken, launch_findings[0], None
        for number, step in enumerate(prefix, 1):
            outcome = runner.step(number, step.do, step.args, step.path)
            if outcome.findings:
                return taken[:number], outcome.findings[0], None
            if outcome.unresolved or outcome.rejection or outcome.error:
                return taken, None, f'the --journey prefix stopped at step {number} "{step.do}"'
        for _ in range(max_steps):
            observation = session.host.call('observe')['observation']
            candidates = observation['candidates']
            if not candidates:
                return taken, Finding('dead end', 'nothing is offered', len(taken)), None
            view = tca.focus_view(observation, tca.mounted_features(session.host))
            candidate = rng.choice(candidates)
            arguments = generate(candidate['argumentSchema'], rng) if candidate.get('argumentSchema') else {}
            query = journeys.step_query(view, observation, candidate)
            taken.append(Step(query, arguments if isinstance(arguments, dict) else {}))
            outcome = runner.step(len(taken), query, taken[-1].args)
            if outcome.findings:
                found.append(outcome.findings[0])
                return taken, outcome.findings[0], None
            if outcome.error:
                return taken, None, outcome.error
        return taken, None, None
    finally:
        reporter.emit('goal_finished', goal=label, status='failed' if found else 'passed',
                      reason=found[0].describe(taken) if found else None, steps=len(taken))
        session.close()


def reproduces(opener, settings, steps, key, quiet):
    """Relaunch and replay `steps` leniently (steps that no longer resolve are skipped)."""
    try:
        session = opener.open(settings)
    except (RuntimeError, journeys.targets.TargetError):
        return False
    try:
        runner = journeys.Runner(session, quiet, settings.wait_ms)
        if any(f.key() == key for f in runner.collect(0, allow_dead_end=True)):
            return True
        for number, step in enumerate(steps, 1):
            outcome = runner.step(number, step.do, step.args, step.path)
            if any(f.key() == key for f in outcome.findings):
                return True
            if outcome.crashed:
                return False
        return False
    finally:
        session.close()


def ddmin(items, test, budget):
    """Delta debugging: a 1-minimal sublist for which `test` holds, within `budget` tests."""
    trials = itertools.count(1)

    def check(candidate):
        return next(trials) <= budget and test(candidate)

    n = 2
    while len(items) >= 2:
        size = math.ceil(len(items) / n)
        chunks = [items[i:i + size] for i in range(0, len(items), size)]
        for chunk in chunks:
            if check(chunk):
                items, n = chunk, 2
                break
        else:
            for index in range(len(chunks)):
                complement = [x for i, c in enumerate(chunks) if i != index for x in c]
                if check(complement):
                    items, n = complement, max(n - 1, 2)
                    break
            else:
                if n >= len(items):
                    break
                n = min(len(items), n * 2)
    return items


def explore_command(arguments):
    prefix_journey = load(arguments, 'journey') if arguments.journey else None
    if arguments.journey and prefix_journey is None:
        return 2
    starts = [prefix_journey.path] if prefix_journey else []
    try:
        opener = opener_for(arguments, starts)
    except journeys.targets.TargetError as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    seed = arguments.seed if arguments.seed is not None else 0
    settings = journeys.Settings.for_journey(prefix_journey, arguments.network, seed, arguments.wait_ms, arguments.fixtures)
    prefix = prefix_journey.steps if prefix_journey else []
    reporter = journeys.Reporter(arguments.report)
    quiet = journeys.Reporter()
    seen = {}
    rows = []
    walked = 0
    try:
        for run in range(arguments.runs):
            rng = random.Random(f'{seed}:{run}')
            taken, finding, error = walk(opener, settings, rng, prefix, arguments.steps, reporter, f'explore run {run + 1}')
            walked += 1
            if error:
                print(f'error: run {run + 1}: {error}', file=sys.stderr)
                return 2
            if finding is None:
                continue
            key = finding.key()
            if key in seen:
                seen[key]['count'] += 1
                continue
            walk_steps = taken[len(prefix):]
            test = lambda subset: reproduces(opener, settings, prefix + subset, key, quiet)
            if not test(walk_steps):
                shrunk = walk_steps  # Didn't reproduce on a fresh launch: keep the walk as is.
                flaky = True
            else:
                shrunk = ddmin(walk_steps, test, arguments.shrink_trials)
                flaky = False
            out = journeys.finding_path(finding.kind, arguments.out)
            repro = finding_journey(prefix_journey, f'{finding.kind}: {finding.message}'[:120],
                                    f'Reproduce the {finding.kind} found by `tca explore`: {finding.message}',
                                    prefix + shrunk, settings)
            header = (f'Found by `tca explore --seed {seed}` in run {run + 1} after {len(walk_steps)} step(s); '
                      f'shrunk to {len(shrunk)}.' + (' Did not reproduce on relaunch (flaky).' if flaky else ''))
            journeys.write_journey(repro, out, header)
            seen[key] = {'count': 1}
            rows.append([finding.kind, f'{len(walk_steps)} -> {len(shrunk)}' + (' (flaky)' if flaky else ''),
                         relative(out), finding.message[:80]])
            reporter.emit('finding', file=str(out), shrunkSteps=len(shrunk), **finding.record())
    finally:
        opener.close()
        reporter.close()
    print(f'explore: {walked} run(s) of up to {arguments.steps} step(s) on {opener.name}, seed {seed}: '
          f'{len(rows)} finding(s)')
    if rows:
        for row, key in zip(rows, seen):
            if seen[key]['count'] > 1:
                row[3] += f' (x{seen[key]["count"]})'
        print(table(rows, ['KIND', 'STEPS', 'JOURNEY', 'MESSAGE']))
        print('  reproduce one with `tca journey run <JOURNEY>`')
    journeys.print_notes()
    return 1 if rows else 0


# chaos ------------------------------------------------------------------------------------------------

FAULTS = {
    'status500': {'kind': 'status', 'status': 500},
    'timeout': {'kind': 'timeout'},
    'offline': {'kind': 'offline'},
    'malformed': {'kind': 'malformed'},
    'slow': {'kind': 'delay', 'delayMs': 2000},
}
WAY_FORWARD_SECONDS = 5.0


def fault_fired(request):
    return bool(request.get('fault')) or request.get('source') == 'fault'


def way_forward(runner, journey, number):
    """Within 5 s: the next step resolves, the faulted step resolves again (a retry), or, when the
    journey is finished, anything is offered. After a launch fault (`number` 0) the next step is the
    first one."""
    tca = journeys.sibling('tca')
    host = runner.session.host
    following = journey.steps[number] if number < len(journey.steps) else None
    options = ([following] + ([journey.steps[number - 1]] if number else [])) if following else []
    deadline = time.monotonic() + WAY_FORWARD_SECONDS
    while True:
        observation = host.call('observe')['observation']
        if following is None and observation['candidates']:
            return True
        for step in options:
            try:
                view = tca.focus_view(observation, tca.mounted_features(host), step.path)
                if tca.resolve_operation(view, observation, step.do)[0] is not None:
                    return True
            except RuntimeError:
                pass
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)


def chaos_command(arguments):
    journey = load(arguments)
    if journey is None:
        return 2
    try:
        opener = opener_for(arguments, [journey.path])
    except journeys.targets.TargetError as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    settings = journeys.Settings.for_journey(journey, 'replay', arguments.seed, arguments.wait_ms)
    reporter = journeys.Reporter(arguments.report)
    kinds = [k.strip() for k in arguments.faults.split(',') if k.strip()]
    rows, failures = [], 0
    try:
        baseline = run_once(opener, journey, settings, reporter, label=f'{journey.name} (baseline)')
        if not baseline.passed:
            print('chaos: the baseline replay failed, so faults would prove nothing')
            print(journeys.summarize(baseline, str(journey.path)))
            journeys.print_notes()
            return 1
        if baseline.runner.session.supports.get('network') is False:
            print('error: chaos needs the `network` method (protocol v3) to see and fail requests', file=sys.stderr)
            return 2
        # Launch requests are faulted through TCA_HARNESS_FAULTS (counted from process start), later
        # ones through `network` (counted from when the CLI connects), so each has its own occurrences.
        seen = {}
        targets_ = []
        fresh = baseline.runner.session.fresh
        for step, request in baseline.requests:
            match = {'method': request.get('method'), 'path': journeys.url_path(request.get('url'))}
            key = (step == 0, match['method'], match['path'])
            occurrence = seen.get(key, 0)
            seen[key] = occurrence + 1
            if fault_fired(request):
                journeys.note(f"{match['method']} {match['path']} #{occurrence + 1} is already failed by the journey's "
                              '[[faults]]; chaos leaves it as is')
                continue
            if step == 0 and not fresh:
                journeys.note(f"{match['method']} {match['path']} happens before the first step; faulting it needs a fresh "
                              'launch per run (a harness.toml target with restart = "per-run")')
                continue
            targets_.append((step, match, occurrence))
        if not targets_:
            print(f'chaos: {journey.name} makes no requests it can fault')
            journeys.print_notes()
            return 0
        for step, match, occurrence in targets_:
            for kind in kinds:
                fault = dict(match=match, **FAULTS[kind], times=1)
                if occurrence:
                    fault['skip'] = occurrence
                if step == 0:
                    fault['at'] = 'launch'
                verdict = {}

                def after_step(number, outcome, runner, verdict=verdict):
                    fired = lambda: any(fault_fired(r) for s, r in runner.requests if s == number)
                    if not fired() and number == len(journey.steps):
                        # A delayed request is logged when it completes, possibly after the last step.
                        deadline = time.monotonic() + WAY_FORWARD_SECONDS
                        while not fired() and time.monotonic() < deadline:
                            time.sleep(0.1)
                            verdict.setdefault('findings', []).extend(runner.collect(number))
                    if fired():
                        verdict['step'] = number
                        verdict['forward'] = way_forward(runner, journey, number)
                        return 'stop'
                    return None

                # The journey's own faults stay (a retry journey needs its first failure); each `skip`
                # counts requests from the same start, so the extra fault still hits its occurrence.
                faulted = replace(journey, faults=list(journey.faults) + [fault])
                when = ' at launch' if step == 0 else ''
                label = (f"{journey.name}: {kind} on {match['method']} {match['path']}" + (f' #{occurrence + 1}' if occurrence else '')
                         + when)
                launch_settings = replace(settings, faults=faulted.launch_faults)
                result = run_once(opener, faulted, launch_settings, reporter, checks=False, tolerate_failed_receipts=True,
                                  after_step=after_step, label=label)
                request_label = f"{match['method']} {match['path']}" + (f' #{occurrence + 1}' if occurrence else '')
                problems = result.problems + verdict.get('findings', [])
                if problems:
                    problem = problems[0]
                    status = f'FAIL {problem.describe(journey.steps)}'
                    kind_name, upto = problem.kind, max(problem.step or step, 1)
                elif 'step' not in verdict:
                    status = 'not reached (the request did not happen on this run)'
                    kind_name = None
                elif not verdict['forward']:
                    following = journey.steps[verdict['step']].do if verdict['step'] < len(journey.steps) else None
                    retry = journey.steps[verdict['step'] - 1].do if verdict['step'] else None
                    status = ('FAIL stranded: ' + (f'neither "{following}" nor a retry of "{retry}" offered' if following and retry
                                                   else f'"{following}" not offered' if following else 'nothing offered')
                              + f' within {WAY_FORWARD_SECONDS:g}s')
                    kind_name, upto = 'stranded', verdict['step'] + 1
                else:
                    status = 'ok'
                    kind_name = None
                if kind_name:
                    failures += 1
                    out = journeys.finding_path(kind_name, arguments.out)
                    repro = finding_journey(journey, f'{kind_name} after {kind} on {request_label}'[:120],
                                            f'{status[5:]} (from `tca chaos {journey.path}`)',
                                            journey.steps[:upto], settings, faulted.faults)
                    journeys.write_journey(repro, out, f'Found by `tca chaos` with --faults {kind}.')
                    status += f'  -> {relative(out)}'
                rows.append(['launch' if step == 0 else f'{step}', request_label, kind, status])
    finally:
        opener.close()
        reporter.close()
    print(f'chaos: {journey.name}: {len(targets_)} request(s) x {len(kinds)} fault(s), {failures} failure(s)')
    print(table(rows, ['STEP', 'REQUEST', 'FAULT', 'RESULT']))
    journeys.print_notes()
    return 1 if failures else 0


# determinism and diff ------------------------------------------------------------------------------------

IGNORED_KEYS = {'sessionID', 'revision'}


def differences(left, right, path='', limit=20, found=None):
    """JSON paths where two states differ, e.g. `shelf.books[0].id`."""
    found = [] if found is None else found
    if len(found) >= limit:
        return found
    if isinstance(left, dict) and isinstance(right, dict):
        for key in sorted(set(left) | set(right), key=str):
            if key in IGNORED_KEYS:
                continue
            child = f'{path}.{key}' if path else str(key)
            if key not in left or key not in right:
                found.append((child, left.get(key, '<missing>'), right.get(key, '<missing>')))
            else:
                differences(left[key], right[key], child, limit, found)
            if len(found) >= limit:
                break
    elif isinstance(left, list) and isinstance(right, list):
        for index in range(max(len(left), len(right))):
            child = f'{path}[{index}]'
            if index >= len(left) or index >= len(right):
                found.append((child, left[index] if index < len(left) else '<missing>',
                              right[index] if index < len(right) else '<missing>'))
            else:
                differences(left[index], right[index], child, limit, found)
            if len(found) >= limit:
                break
    elif left != right or type(left) is not type(right) and not (isinstance(left, (int, float)) and isinstance(right, (int, float))):
        found.append((path or '(root)', left, right))
    return found


def short(value, width=60):
    text = json.dumps(value, ensure_ascii=False) if not isinstance(value, str) or value != '<missing>' else value
    return text if len(text) <= width else text[:width - 3] + '...'


def first_difference(runs):
    """(step index, run index, paths) of the first state that differs from run 0, else None."""
    reference = runs[0].states
    for index in range(max(len(r.states) for r in runs)):
        for number, run in enumerate(runs[1:], 1):
            if index >= len(run.states) or index >= len(reference):
                return index, number, [('(run length)', len(reference), len(run.states))]
            paths = differences(reference[index], run.states[index])
            if paths:
                return index, number, paths
    return None


def step_name(journey, index):
    return 'at launch' if index == 0 else f'after step {index} "{journey.steps[index - 1].do}"'


def report_difference(journey, settings, difference, names, kind, arguments, command):
    index, number, paths = difference
    print(f'  differs {step_name(journey, index)} ({names[0]} vs {names[number]}):')
    for path, left, right in paths[:10]:
        print(f'    {path}: {short(left)} vs {short(right)}')
    if len(paths) > 10:
        print(f'    (+{len(paths) - 10} more)')
    out = journeys.finding_path(kind, arguments.out)
    repro = finding_journey(journey, f'{kind}: {journey.name}'[:120],
                            f'State differs {step_name(journey, index)}; reproduce with `{command} {{file}}`',
                            journey.steps[:max(index, 1)], settings)
    repro.goal = repro.goal.replace('{file}', relative(out))
    journeys.write_journey(repro, out, f'Found by `{command}`.')
    print(f'  wrote {relative(out)}')


def determinism_command(arguments):
    journey = load(arguments)
    if journey is None:
        return 2
    try:
        opener = opener_for(arguments, [journey.path])
    except journeys.targets.TargetError as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    settings = journeys.Settings.for_journey(journey, arguments.network, arguments.seed, arguments.wait_ms)
    reporter = journeys.Reporter(arguments.report)
    try:
        runs = [run_once(opener, journey, settings, reporter, label=f'{journey.name} (run {n + 1})')
                for n in range(arguments.runs)]
    finally:
        opener.close()
        reporter.close()
    failed = [r for r in runs if not r.passed]
    difference = first_difference(runs)
    status = 'FAIL' if difference or failed else 'PASS'
    print(f'{status}  determinism: {journey.name}  {arguments.runs} runs, seed {settings.seed}')
    if failed:
        print('  ' + journeys.summarize(failed[0], str(journey.path)).replace('\n', '\n  '))
    if difference:
        report_difference(journey, settings, difference, [f'run {n + 1}' for n in range(len(runs))], 'nondeterminism',
                          arguments, f'tca determinism --seed {settings.seed}')
    journeys.print_notes()
    return 1 if status == 'FAIL' else 0


def diff_command(arguments):
    journey = load(arguments)
    if journey is None:
        return 2
    try:
        openers = [journeys.Opener.from_arguments(name, None, [journey.path]) for name in arguments.targets]
    except journeys.targets.TargetError as error:
        print(f'error: {error}', file=sys.stderr)
        return 2
    settings = journeys.Settings.for_journey(journey, arguments.network, arguments.seed, arguments.wait_ms)
    reporter = journeys.Reporter(arguments.report)
    runs = []
    try:
        for opener in openers:
            runs.append(run_once(opener, journey, settings, reporter, label=f'{journey.name} ({opener.name})'))
            opener.close()
    finally:
        for opener in openers:
            opener.close()
        reporter.close()
    failed = [(name, r) for name, r in zip(arguments.targets, runs) if not r.passed]
    difference = first_difference(runs)
    status = 'FAIL' if difference or failed else 'PASS'
    print(f'{status}  diff: {journey.name}  {arguments.targets[0]} vs {arguments.targets[1]}')
    for name, result in failed:
        print(f'  on {name}: ' + journeys.summarize(result, str(journey.path)).replace('\n', '\n  '))
    if difference:
        report_difference(journey, settings, difference, arguments.targets, 'diff', arguments,
                          f'tca diff --targets {",".join(arguments.targets)}')
    journeys.print_notes()
    return 1 if status == 'FAIL' else 0
