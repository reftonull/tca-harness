#!/usr/bin/env python3
"""Exercise discovery, nested routing, typed bindings and stale child IDs in a running host."""
import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('harness_cli', root / 'cli/tca.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
host = cli.Host(port=8766)
transcript = []

def record(label, response):
    transcript.append(dict(step=label, response=response))
    return response

def choose(fragment):
    matches = [c['id'] for c in host.observation['candidates'] if fragment in c['id']]
    assert len(matches) == 1, (fragment, matches)
    return matches[0]

def dispatch(fragment, **kwargs):
    for _ in range(4):
        response = record(fragment, host.dispatch(choose(fragment), **kwargs))
        if response.get('error') != 'stale_revision': break
    assert response['ok'], response
    return response

def verify(condition):
    response = record(condition, host.call('verify', condition=condition))
    assert response.get('verified') is True, response

try:
    record('initial', host.call('observe'))
    inspection = record('initial-inspection', host.call('inspect'))
    assert inspection['protocolVersion'] == 2
    assert [f['path'] for f in inspection['features']] == ['root', 'root/home']
    # Starting with a fresh app avoids carrying state from a previous test.
    verify('settingsClosed')
    assert not any('/settings/' in c['id'] for c in host.observation['candidates'])
    dispatch('settingsButtonTapped')
    verify('settingsOpen')
    mounted = record('mounted-inspection', host.call('inspect', path='root/home/settings'))
    assert [f['name'] for f in mounted['features']] == ['Settings', 'Stats']
    stale = choose('binding/userSettings/enableHaptics/false')
    dispatch('binding/userSettings/enableHaptics/false')
    verify('hapticsOff')
    dispatch('binding/userSettings/enableReducedAnimation/true')
    verify('reducedAnimationOn')
    before = host.observation['state']
    invalid = record('out-of-range-volume', host.dispatch(choose('binding/userSettings/musicVolume'), arguments={'value': 2}))
    assert invalid['ok'] is False, invalid
    assert host.observation['state'] == before
    dispatch('binding/userSettings/musicVolume', arguments={'value': 0})
    verify('musicMuted')
    # A grandchild action must embed through Home -> PresentationAction -> Settings -> Stats.
    dispatch('/stats/vocabButtonTapped')
    assert 'vocab' in json.dumps(host.observation['state'])
    # The root presentation dismisses the whole settings tree.
    dismiss = next(c['id'] for c in host.observation['candidates'] if '/dismissSettings@' in c['id'])
    assert record('dismiss', host.dispatch(dismiss))['ok']
    verify('settingsClosed')
    assert not any('/settings/' in c['id'] for c in host.observation['candidates'])
    dispatch('settingsButtonTapped')
    rejected = record('old-child-id', host.dispatch(stale))
    assert rejected['ok'] is False, rejected
    verify('settingsOpen')
finally:
    host.close()
    out = Path(__file__).parent / 'recordings/runtime-live-check.json'
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(transcript, indent=2) + '\n')
print('PASS: discovery, optional scopes, nested routing, bindings and stale child rejection')
