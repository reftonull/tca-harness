"""Normalize JSONL evidence and render a portable, offline run viewer."""
import json
import base64
import gzip
from pathlib import Path


KINDS = {
    'decision': 'model', 'unsupported_decision': 'model', 'arguments_generated': 'arguments',
    'dispatch': 'action', 'wait': 'wait', 'cancel': 'action',
    'readiness_wait_started': 'wait', 'readiness_wait_finished': 'wait',
    'presentation_settle': 'wait', 'pacing': 'pacing',
    'verified': 'verification', 'predicate_verified': 'verification', 'word_verified': 'verification',
    'resume_verified': 'verification', 'gameplay_verified': 'verification',
    'demo_passed': 'verification', 'arguments_demo_passed': 'verification', 'hybrid_demo_passed': 'verification',
    'invalid_volume_probe': 'guard', 'stale_scope_probe': 'guard',
    'word_plan': 'planner', 'mechanical_gesture_release': 'mechanical', 'gesture_release': 'mechanical',
    'goal_started': 'boundary', 'goal_finished': 'boundary', 'stopped': 'boundary',
}


def state_of(event):
    observation = event.get('observation')
    if isinstance(observation, dict) and 'state' in observation:
        return observation['state']
    if event.get('event') == 'goal_finished' and isinstance(event.get('state'), dict):
        return event['state']
    return None


def normalize(events, source='Run trace', warnings=None):
    goals = []
    active = None
    previous_state = None
    observed = 0
    for index, raw in enumerate(events):
        name = raw['event']
        if name == 'suite_finished':
            continue
        if name == 'goal_started' or active is None:
            active = dict(id=f'goal-{len(goals)}', name=raw.get('goal') or 'run',
                          description=raw.get('description') or 'Application run',
                          status='incomplete', durationMs=None, events=[])
            goals.append(active)
        # A completed goal remains open for attached evidence until a new start.
        kind = KINDS.get(name, 'evidence')
        candidate = raw.get('candidate') or raw.get('candidateID') or raw.get('choice')
        if not candidate and isinstance(raw.get('receipt'), dict):
            candidate = raw['receipt'].get('candidateID')
        observation = raw.get('observation')
        alternatives = observation.get('candidates', []) if isinstance(observation, dict) else None
        after = state_of(raw)
        before = previous_state
        # Summary snapshots can intentionally omit fields (e.g. cube geometry).
        # Never interpret that lossy projection as an actual state deletion.
        comparable = after is not None and before is not None and name != 'goal_finished'
        if after is not None:
            observed += 1
            if name != 'goal_finished':
                previous_state = after
        timing = None
        t_ms = raw.get('tMs')
        if isinstance(t_ms, (int, float)):
            duration = raw.get('latencyMs', 0)
            if name == 'readiness_wait_finished':
                duration = raw.get('durationMs', 0)
            duration = duration if isinstance(duration, (int, float)) else 0
            timing = dict(startMs=max(0, t_ms - max(0, duration)), endMs=t_ms)
            if name in ('pacing', 'presentation_settle'):
                configured = raw.get('durationMs', raw.get('seconds', 0) * 1000)
                timing = dict(startMs=t_ms, endMs=t_ms + max(0, configured), configured=True)
        entry = dict(id=f'event-{index}', kind=kind, name=name, candidate=candidate,
                     raw=raw, timing=timing, alternatives=alternatives,
                     before=before if comparable else None, after=after,
                     stateEvidence='summary' if name == 'goal_finished' else 'snapshot' if after is not None else 'missing')
        active['events'].append(entry)
        if name == 'goal_finished':
            active['status'] = raw.get('status', 'incomplete')
            active['durationMs'] = raw.get('elapsedMs')
            active['reason'] = raw.get('reason')
        elif name in ('verified', 'gameplay_verified', 'demo_passed', 'arguments_demo_passed', 'hybrid_demo_passed'):
            active['status'] = 'passed'
            active['durationMs'] = raw.get('elapsedMs')
        elif name == 'stopped':
            active['status'] = 'failed'
            active['reason'] = raw.get('reason')
    return dict(source=source, goals=goals, eventCount=len(events), snapshotCount=observed,
                timed=any(e.get('tMs') is not None for e in events), warnings=warnings or [])


def load_trace(path):
    events, warnings = [], []
    lines = Path(path).read_text().splitlines()
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            if not isinstance(record, dict) or not isinstance(record.get('event'), str):
                raise ValueError('expected an event object')
        except ValueError:
            warnings.append(f'Line {number}: ignored an invalid or incomplete event.')
            continue
        events.append(record)
    if not events:
        raise ValueError('No run events found in the input JSONL file.')
    data = normalize(events, Path(path).name, warnings)
    if not data['goals']:
        raise ValueError('No inspectable run events found in the input JSONL file.')
    return data


def render_trace(source, output=None):
    source = Path(source)
    output = Path(output) if output else source.with_suffix('.html')
    if output.resolve() == source.resolve():
        raise ValueError('Viewer output must differ from the input trace.')
    data = load_trace(source)
    # Base64 contains no markup. Decoded evidence is rendered only as text.
    # Gzip keeps repeated candidate/state snapshots small in portable artifacts.
    # Derived state/alternative references are hydrated from raw evidence in the
    # browser, avoiding multiple serialized copies of each large state snapshot.
    for goal in data['goals']:
        for event in goal['events']:
            for key in ('before', 'after', 'alternatives'):
                event.pop(key, None)
    payload = base64.b64encode(gzip.compress(json.dumps(data, ensure_ascii=True).encode(), mtime=0)).decode('ascii')
    template = Path(__file__).with_name('trace_viewer.html').read_text()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(template.replace('__TRACE_DATA__', payload))
    return output.resolve()
