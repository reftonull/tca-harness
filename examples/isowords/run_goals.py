#!/usr/bin/env python3
"""Bounded Jev/LLM goal suite against the running, original isowords app.

Navigation/settings use a model loop. Gameplay uses a deterministic dictionary
planner plus Jev face/action selection; gesture release is mechanical. No UI taps.
Launch a fresh harness-enabled app before running this suite.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sqlite3
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('tca_cli', HERE.parents[1] / 'cli/tca.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


def word_plan(game, max_length=6):
    """Find a new legal face path using observed geometry and bootstrap dictionary."""
    played = {item['word'].upper() for item in game['playedWords']}
    with sqlite3.connect(HERE / '.upstream/Sources/DictionarySqliteClient/Dictionaries/Words.en.db') as db:
        words = {row[0] for row in db.execute('SELECT word FROM words WHERE length(word) BETWEEN 3 AND ?', (max_length,))} - played
    prefixes = {word[:n] for word in words for n in range(1, len(word) + 1)}
    faces = {face['id']: face for face in game['faces']}
    found = {}

    def search(path=(), text=''):
        for key in (faces[path[-1]]['neighbors'] if path else faces):
            if key in path:
                continue
            next_text = text + faces[key]['letter'].upper()
            if next_text not in prefixes:
                continue
            next_path = path + (key,)
            if next_text in words:
                found.setdefault(next_text, next_path)
            if len(next_text) < max_length:
                search(next_path, next_text)
    search()
    if not found:
        raise RuntimeError('No unplayed dictionary word found within the search bound')
    word = min(found, key=lambda value: (-len(value), value))
    return word, found[word]


def evidence(state):
    """Compact transcript; full face geometry is emitted with each word plan."""
    result = dict(state)
    if result.get('game'):
        result['game'] = {k: v for k, v in result['game'].items() if k != 'faces'}
        result['game']['faceCount'] = len(state['game']['faces'])
    return result


class Suite:
    def __init__(self, args):
        self.args = args
        self.host = cli.Host(port=args.port)
        self.results = []
        self.decisions = []
        self.arguments = []
        self.rpc_ms = []
        self.dispatches = 0
        self.current = None
        self.saved_candidate = None

    def observe(self):
        return self.host.call('observe')['observation']

    def send(self, candidate, **kwargs):
        start = time.monotonic()
        response = self.host.dispatch(candidate, **kwargs)
        latency = round((time.monotonic() - start) * 1000, 2)
        self.rpc_ms.append(latency)
        self.dispatches += 1
        cli.emit('dispatch', goal=self.current, candidate=candidate, arguments=kwargs.get('arguments', {}),
                 observation=response.get('observation'), ok=response['ok'],
                 error=response.get('error'), latencyMs=latency, receipt=response.get('receipt'))
        if not response['ok']:
            raise RuntimeError(f"Dispatch rejected: {response.get('error')}")
        if response.get('receipt', {}).get('status') == 'running':
            waited = self.host.call('wait', requestID=response['receipt']['requestID'], timeoutMs=3000)
            if not waited['ok']:
                raise RuntimeError('Operation wait failed')
        if self.args.step_delay:
            cli.emit('pacing', goal=self.current, durationMs=round(self.args.step_delay * 1000))
            time.sleep(self.args.step_delay)
        return response

    def step(self, goal, expected=None):
        observation = self.observe()
        decision = cli.decide(observation, goal, self.args.model)
        self.decisions.append(decision)
        cli.emit('decision', goal=self.current, instruction=goal, observation=observation, **decision)
        if decision['choice'] == 'none':
            raise RuntimeError('Jev abstained before the goal was verified')
        candidate = next(c for c in observation['candidates'] if c['id'] == decision['choice'])
        if expected and f'/{expected}@' not in candidate['id']:
            raise RuntimeError(f"Jev chose an unexpected operation: {candidate['id']}")
        arguments = {}
        if candidate.get('argumentSchema'):
            generated = cli.extract_arguments(observation, candidate, goal, self.args.argument_model)
            self.arguments.append(generated)
            cli.emit('arguments_generated', goal=self.current, candidateID=candidate['id'], **generated)
            arguments = generated['arguments']
        return self.send(candidate['id'], revision=observation['revision'], arguments=arguments)

    def achieve(self, goal, predicate, max_steps=10):
        for _ in range(max_steps):
            state = self.observe()['state']
            if state.get('game') and not state['game']['ready']:
                waiting_started = time.monotonic()
                cli.emit('readiness_wait_started', goal=self.current, observation=self.host.observation,
                         reason='Waiting for game initialization', timeoutMs=10000)
                deadline = time.monotonic() + 10
                while not state['game']['ready'] and time.monotonic() < deadline:
                    time.sleep(.1)
                    state = self.observe()['state']
                cli.emit('readiness_wait_finished', goal=self.current, observation=self.host.observation,
                         durationMs=round((time.monotonic() - waiting_started) * 1000), ready=state['game']['ready'])
                if not state['game']['ready']:
                    raise RuntimeError('Game renderer did not become ready within 10 seconds')
            if predicate(state):
                cli.emit('predicate_verified', goal=self.current, condition=goal, observation=self.host.observation)
                return
            self.step(goal)
        if not predicate(self.observe()['state']):
            raise RuntimeError(f'Goal not satisfied after {max_steps} model decisions')

    def run(self, name, description, body):
        self.current = name
        cli.emit('goal_started', goal=name, description=description, observation=self.observe())
        start = time.monotonic()
        before = (len(self.decisions), len(self.arguments), self.dispatches)
        try:
            body()
            result = dict(goal=name, status='passed')
        except Exception as error:
            result = dict(goal=name, status='failed', reason=str(error))
        result.update(elapsedMs=round((time.monotonic() - start) * 1000),
                      classifierCalls=len(self.decisions) - before[0],
                      argumentCalls=len(self.arguments) - before[1], dispatches=self.dispatches - before[2],
                      state=evidence(self.observe()['state']))
        self.results.append(result)
        cli.emit('goal_finished', **result)
        return result['status'] == 'passed'

    def configure(self):
        self.achieve('Open Settings from Home.', lambda s: s['settings'] is not None)
        def configured(s):
            settings = s['settings']
            return settings is not None and settings['colorScheme'] == 'dark' and settings['reducedAnimation'] and not settings['haptics'] and abs(settings['musicVolume'] - .25) < .001
        self.achieve('In Settings set dark color scheme, enable reduced animation, disable haptics, and set music volume to exactly 25% (0.25). Preserve other settings.', configured)
        observation = self.observe()
        self.saved_candidate = next(c['id'] for c in observation['candidates'] if '/musicVolume@' in c['id'])
        rejected = self.host.dispatch(self.saved_candidate, revision=observation['revision'], arguments={'value': 1.5})
        cli.emit('invalid_volume_probe', goal=self.current, candidate=self.saved_candidate, arguments={'value': 1.5},
                 observation=self.host.observation, ok=rejected['ok'], error=rejected.get('error'))
        assert not rejected['ok'] and rejected.get('error') == 'invalid_arguments', 'Out-of-range numeric input was accepted'
        assert self.observe()['state'] == observation['state'], 'Rejected argument changed state'
        self.achieve('Close Settings and return Home.', lambda s: s['settings'] is None)

    def start(self):
        self.achieve('Open Solo modes and start or resume an unlimited solo game.',
                     lambda s: s['game'] is not None and s['game']['ready'] and s['game']['mode'] == 'unlimited' and not s['game']['menuOpen'] and not s['game']['settingsOpen'], 6)

    def release(self):
        observation = self.observe()
        candidate = next(c for c in observation['candidates'] if '/release@' in c['id'])
        cli.emit('mechanical_gesture_release', goal=self.current)
        self.send(candidate['id'], revision=observation['revision'])

    def select(self, face, word):
        self.step(f'Select cube face {face} to build {word}.', expected='select-' + face)
        self.release()

    def recovery(self):
        before = self.observe()['state']['game']
        face = before['faces'][0]['id']
        self.select(face, 'an intentionally unfinished word')
        assert self.observe()['state']['game']['selectedWord'], 'Selection did not appear'
        self.achieve('Clear the mistaken selected word without submitting it or leaving the game.',
                     lambda s: s['game']['selectedWord'] == '', 3)
        after = self.observe()['state']['game']
        assert after['score'] == before['score'] and after['playedWords'] == before['playedWords'], 'Recovery changed progress'

    def multiword(self):
        initial = self.observe()['state']['game']
        for _ in range(3):
            before = self.observe()['state']['game']
            word, path = word_plan(before)
            cli.emit('word_plan', goal=self.current, word=word, path=path,
                     source='deterministic bootstrap dictionary search', faces=before['faces'])
            for face in path:
                self.select(face, word)
            selected = self.observe()['state']['game']
            assert selected['selectedWord'].upper() == word and selected['valid'], 'Planned word not valid in reducer'
            self.achieve(f'Submit the selected valid word {word}.',
                         lambda s: any(w['word'].upper() == word for w in s['game']['playedWords']), 3)
            after = self.observe()['state']['game']
            assert after['score'] > before['score'], 'Accepted word did not increase score'
            cli.emit('word_verified', goal=self.current, word=word, score=after['score'], delta=after['score'] - before['score'])
        after = self.observe()['state']['game']
        assert len(after['playedWords']) == len(initial['playedWords']) + 3
        assert len({w['word'].upper() for w in after['playedWords']}) == len(after['playedWords'])

    def game_settings(self):
        before = self.observe()['state']['game']
        self.achieve('Open the game menu, then open Settings to change music volume.', lambda s: s['settings'] is not None, 5)
        self.achieve('Set music volume to exactly 12% (0.12) without changing other settings.',
                     lambda s: s['settings'] is not None and abs(s['settings']['musicVolume'] - .12) < .001, 3)
        self.achieve('Close Settings and return to the current game board.', lambda s: s['settings'] is None and not s['game']['menuOpen'], 3)
        after = self.observe()['state']['game']
        assert (after['score'], after['playedWords']) == (before['score'], before['playedWords'])

    def resume(self):
        before = self.observe()['state']['game']
        old_id = next(c['instanceID'] for c in self.observe()['candidates'] if c['feature'] == 'root/game')
        self.achieve('Open the game menu and return to Home, keeping this unlimited game for later.', lambda s: s['game'] is None, 5)
        assert self.observe()['state']['home']['hasSavedUnlimited'], 'No in-memory saved game'
        # This upstream SwiftUI transition can retain the outgoing GameView. If
        # resumed immediately, the new reducer may never receive its .task action.
        # This measured fixture workaround is not a generic completion signal.
        cli.emit('presentation_settle', goal=self.current, seconds=self.args.transition_delay)
        time.sleep(self.args.transition_delay)
        self.start()
        after = self.observe()['state']['game']
        assert (after['score'], after['playedWords'], after['faces']) == (before['score'], before['playedWords'], before['faces']), 'Resumed game differs'
        new_id = next(c['instanceID'] for c in self.observe()['candidates'] if c['feature'] == 'root/game')
        assert old_id != new_id, 'Recreated reducer did not get a new instance identity'
        cli.emit('resume_verified', score=after['score'], words=len(after['playedWords']), oldInstance=old_id, newInstance=new_id)

    def unsupported(self):
        before = self.observe()
        decision = cli.decide(before, 'Rename my player to "Cube Wizard" by typing that exact text into a player-name text field. Do not change game progress or settings.', self.args.model)
        self.decisions.append(decision)
        cli.emit('unsupported_decision', goal=self.current,
                 instruction='Rename my player to Cube Wizard; preserve game progress and settings.',
                 observation=before, **decision)
        assert decision['choice'] == 'none', 'Classifier tried an unrelated capability for unsupported typing'
        assert self.observe()['state'] == before['state'], 'Read-only unsupported probe changed state'

    def stale_scope(self):
        if not self.saved_candidate:
            raise RuntimeError('No dismissed Settings candidate captured')
        observation = self.observe()
        before = observation['state']
        response = self.host.dispatch(self.saved_candidate, revision=observation['revision'], arguments={'value': .99})
        cli.emit('stale_scope_probe', goal=self.current, candidate=self.saved_candidate,
                 observation=self.host.observation, ok=response['ok'], error=response.get('error'))
        assert not response['ok'], 'Dismissed feature operation was accepted'
        assert self.observe()['state'] == before, 'Rejected stale scope changed state'

    def summary(self):
        def stats(values):
            if not values:
                return None
            values = sorted(values)
            return dict(count=len(values), medianMs=round(values[len(values)//2], 2), maxMs=max(values))
        return dict(results=self.results, classifier=stats([v['latencyMs'] for v in self.decisions]),
                    argumentModel=stats([v['latencyMs'] for v in self.arguments]), dispatchRPC=stats(self.rpc_ms),
                    boundaries=['Author-written goal decomposition and verification predicates',
                                'Deterministic word search, Jev operation selection, mechanical gesture release',
                                'Offline dependencies and in-memory resume; no durable persistence or network services'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8767)
    parser.add_argument('--model', default='jev-1.14.0')
    parser.add_argument('--argument-model', default='claude-haiku-5-5')
    parser.add_argument('--step-delay', type=float, default=.8)
    parser.add_argument('--transition-delay', type=float, default=3, help='Upstream exit animation settling time before resume')
    parser.add_argument('--report', type=Path, default=HERE / 'recordings/complex-goals-report.json')
    args = parser.parse_args()
    suite = Suite(args)
    try:
        goals = [
            ('comfortable-settings', 'Dark mode, reduced animation, haptics off, 25% volume, then Home', suite.configure),
            ('navigate-unlimited', 'Home → Solo → Unlimited, wait for game readiness', suite.start),
            ('recover-selection', 'Make and clear a mistaken selection, preserving progress', suite.recovery),
            ('three-distinct-words', 'Plan and submit three distinct words on the changing board', suite.multiword),
            ('in-game-settings', 'Game menu → Settings → 12% volume → board; preserve progress', suite.game_settings),
            ('leave-and-resume', 'Leave to Home and resume with identical score, words and board', suite.resume),
            ('unsupported-typing', 'Abstain when asked to type a player name with no exposed text capability', suite.unsupported),
            ('dismissed-scope', 'Reject a candidate captured from a dismissed Settings reducer', suite.stale_scope),
        ]
        # Continue after a failure to expose independent limitations; dependent goals
        # may also fail, and remain visible rather than being silently skipped.
        for name, description, body in goals:
            suite.run(name, description, body)
        report = suite.summary()
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
        cli.emit('suite_finished', report=str(args.report), passed=sum(r['status'] == 'passed' for r in suite.results), total=len(goals),
                 classifier=report['classifier'], argumentModel=report['argumentModel'], dispatchRPC=report['dispatchRPC'])
        return 0 if all(r['status'] == 'passed' for r in suite.results) else 1
    finally:
        suite.host.close()


if __name__ == '__main__':
    raise SystemExit(main())
