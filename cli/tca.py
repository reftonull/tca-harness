#!/usr/bin/env python3
"""Inspect, drive and test a TCA app through its embedded harness: ls, do, doctor, journey, explore, ..."""
import argparse
import importlib
from datetime import datetime
import json
import itertools
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
HERE = ROOT / "prototypes/tca-harness"
BINARY = HERE / '.build/Build/Products/Debug/TCAHarnessPrototype'


def build(force=False):
    sources = list((HERE / 'Sources').glob('*.swift')) + list((ROOT / 'DecisionsPackage').rglob('*.swift'))
    sources += list((ROOT / 'TCAHarness').rglob('*.swift')) + list((ROOT / 'TCAHarnessTCA2' / 'Sources').rglob('*.swift'))
    sources += [HERE / 'project.yml']
    if not force and BINARY.exists() and all(p.stat().st_mtime <= BINARY.stat().st_mtime for p in sources):
        return
    subprocess.run(['xcodegen', 'generate', '--spec', 'project.yml'], cwd=HERE, check=True, stdout=sys.stderr)
    subprocess.run(['flowdeck', 'build', '--config', 'flowdeck.json', '-D', 'My Mac',
                    '--derived-data-path', '.build'], cwd=HERE, check=True, stdout=sys.stderr)


def route(candidate_id):
    """A candidate ID without its `@<instance>` suffix, e.g. `root/resetButtonTapped`."""
    return candidate_id.split('@', 1)[0]


class Host:
    def __init__(self, port=None):
        self.process = None
        self.connection = None
        self.stream = None
        self.inspected = {}  # path -> the latest `inspect` entry seen on this connection (`tca exposure`)
        if port is not None:
            try:
                self.connection = socket.create_connection(('127.0.0.1', port), timeout=15)
                self.stream = self.connection.makefile('rb')
            except OSError:
                raise RuntimeError(f'Cannot connect to app harness on 127.0.0.1:{port}; launch the app with TCA_HARNESS=1 and TCA_HARNESS_PORT={port}; retain the store.harness attachment') from None
        else:
            self.process = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            text=True, bufsize=1)
        try:
            response = self.call('observe')
            if not response.get('ok') or not isinstance(response.get('observation'), dict):
                raise RuntimeError('Endpoint did not provide a harness observation; check the port and attach store.harness(...) to the app store')
            self.observation = response['observation']
        except Exception:
            self.close()
            raise
        self.last_operation = None

    def candidate(self, name):
        """The current candidate ID for a route (or the ID itself); unchanged when not offered."""
        ids = [c['id'] for c in self.observation['candidates']]
        return name if name in ids else next((i for i in ids if route(i) == name), name)

    def call(self, method, **arguments):
        request = dict(method=method, **arguments)
        if hasattr(self, 'observation'):
            request.setdefault('sessionID', self.observation['sessionID'])
        if self.connection:
            try:
                self.connection.sendall((json.dumps(request) + '\n').encode())
                line = self.stream.readline(262144).decode()
            except OSError:
                raise RuntimeError('App harness connection interrupted or timed out; keep the app running and retain its store.harness attachment') from None
        else:
            self.process.stdin.write(json.dumps(request) + '\n')
            self.process.stdin.flush()
            if not select.select([self.process.stdout], [], [], 15)[0]:
                raise RuntimeError('Host response timed out')
            line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('Host disconnected before responding')
        try:
            response = json.loads(line)
        except ValueError:
            raise RuntimeError('Endpoint did not return valid harness JSON; check the selected port and embedded listener') from None
        if not isinstance(response, dict):
            raise RuntimeError('Endpoint returned an invalid harness response; check the selected port')
        if 'observation' in response:
            self.observation = response['observation']
        return response

    def dispatch(self, candidate, **overrides):
        arguments = dict(candidateID=self.candidate(candidate), revision=self.observation['revision'], requestID=str(uuid.uuid4()))
        arguments.update(overrides)
        response = self.call('dispatch', **arguments)
        if response.get('receipt'):
            self.last_operation = response['receipt']['requestID']
        return response

    def close(self):
        if self.connection:
            self.stream.close()
            self.connection.close()
            return
        self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()


# Model providers ------------------------------------------------------------
#
# The optional model loop (`run`, `shell` goals, the isowords scripts) needs two calls per step:
# choose one offered operation, then fill the chosen operation's typed arguments. Two providers:
#   router     Router's /systemone choice classifier and /responses argument filling.
#   responses  Any OpenAI Responses API-compatible endpoint (POST {base}/responses) for both.
# Credentials come from the environment or ~/.config/tca-harness/model.env (written by
# `tca setup`); environment variables override the file. Keys are never printed or traced.

PROVIDERS = ('router', 'responses')
DEFAULT_BASE_URLS = {'router': 'https://api.router.com/v1', 'responses': 'https://api.openai.com/v1'}
PROVIDER_KEYS = {
    'router': ('RAMP_ROUTER_BASE_URL', 'RAMP_ROUTER_API_KEY'),
    'responses': ('TCA_HARNESS_MODEL_BASE_URL', 'TCA_HARNESS_MODEL_API_KEY'),
}
CONFIG_KEYS = ('TCA_HARNESS_MODEL_PROVIDER', 'TCA_HARNESS_MODEL', 'RAMP_ROUTER_API_KEY', 'RAMP_ROUTER_BASE_URL',
               'TCA_HARNESS_MODEL_API_KEY', 'TCA_HARNESS_MODEL_BASE_URL')
# Router-specific defaults: its choice classifier, and the argument model it serves.
ROUTER_CHOICE_MODEL = 'jev-1.14.0'
ROUTER_ARGUMENT_MODEL = 'claude-haiku-5-5'
USER_AGENT = 'tca-harness/0.1'


def config_path():
    base = os.environ.get('XDG_CONFIG_HOME') or str(Path.home() / '.config')
    return Path(base) / 'tca-harness' / 'model.env'


def read_config_file(path=None):
    path = Path(path) if path else config_path()
    config = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip().removeprefix('export ')
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.strip()] = value.strip().strip('"\'')
    return config


def model_config(provider=None):
    """Resolve provider, endpoint, key and default models. Environment overrides the file."""
    config = read_config_file()
    config.update({key: os.environ[key] for key in CONFIG_KEYS if os.environ.get(key)})
    if not provider:
        provider = config.get('TCA_HARNESS_MODEL_PROVIDER')
    if not provider:
        # Infer from whichever credential is present; Router keeps working without new settings.
        provider = 'router' if config.get('RAMP_ROUTER_API_KEY') and not config.get('TCA_HARNESS_MODEL_API_KEY') else 'responses'
    if provider not in PROVIDERS:
        raise RuntimeError(f'Unknown model provider {provider!r}; use one of: ' + ', '.join(PROVIDERS))
    base_key, api_key = PROVIDER_KEYS[provider]
    if not config.get(api_key):
        raise RuntimeError(f'No API key for the {provider} provider; run `tca setup` or set {api_key}')
    model = config.get('TCA_HARNESS_MODEL')
    return dict(provider=provider, base_url=(config.get(base_key) or DEFAULT_BASE_URLS[provider]).rstrip('/'),
                api_key=config[api_key],
                choice_model=ROUTER_CHOICE_MODEL if provider == 'router' else model,
                argument_model=model or (ROUTER_ARGUMENT_MODEL if provider == 'router' else None))


def require_model(model, config, flag):
    if not model:
        raise RuntimeError(f"No model configured for the {config['provider']} provider; pass {flag} or set TCA_HARNESS_MODEL")
    return model


def post_json(config, endpoint, payload, timeout, what):
    """POST to the provider. Errors report only a status: response bodies may echo request metadata."""
    request = urllib.request.Request(
        config['base_url'] + endpoint, data=json.dumps(payload).encode(), headers={
            'Authorization': 'Bearer ' + config['api_key'],
            'Content-Type': 'application/json', 'Accept': 'application/json', 'User-Agent': USER_AGENT,
        })
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        error.close()
        raise RuntimeError(f'{what} returned HTTP {error.code}') from None
    except urllib.error.URLError:
        raise RuntimeError(f'{what} connection failed') from None
    except (ValueError, OSError):
        raise RuntimeError(f'{what} returned an unreadable response') from None


def response_text(data, what):
    """The concatenated `output_text` of a Responses API result."""
    if not isinstance(data, dict) or data.get('status') not in (None, 'completed'):
        raise RuntimeError(f'{what} did not complete')
    return ''.join(part.get('text', '') for output in (data.get('output') or []) if isinstance(output, dict)
                   for part in (output.get('content') or []) if isinstance(part, dict) and part.get('type') == 'output_text')


CHOICE_INSTRUCTIONS = (
    'Choose one available operation that advances the goal from the current application state. '
    'Inspect current state to avoid repeating operations that already succeeded. '
    'Choose none if the goal is satisfied, unclear, or no available operation helps. '
    'Do not reset, dismiss, or alter unrelated features unless the goal requires it.'
)


def decide(observation, goal, model=None, provider=None):
    """Choose one offered candidate ID, or `none`. Anything else is rejected."""
    config = model_config(provider)
    # Send domain evidence, never credentials or transport/session bookkeeping.
    criteria = {c['id']: c['label'] for c in observation['candidates']}
    criteria['none'] = 'No currently available operation advances the goal, or the goal is already satisfied'
    model = require_model(model or config['choice_model'], config, '--model')
    start = time.monotonic()
    if config['provider'] == 'router':
        payload = {
            'model': model,
            'state': {'goal': goal, 'application': observation['state']},
            'questions': {'next_action': {'type': 'choice', 'instructions': CHOICE_INSTRUCTIONS, 'criteria': criteria}},
        }
        data = post_json(config, '/systemone', payload, 20, 'Choice model')
        try:
            answer = data['answers']['next_action']
            choice = answer['choice']
        except (KeyError, TypeError):
            raise RuntimeError('Choice model returned no choice') from None
        confidence = answer.get('confidence')
        probabilities = answer.get('probabilities')
        probability = probabilities.get(choice) if isinstance(probabilities, dict) and isinstance(choice, str) else None
    else:
        payload = {
            'model': model,
            'instructions': CHOICE_INSTRUCTIONS + ' Answer with the ID of exactly one offered operation, or none.',
            'input': json.dumps({'goal': goal, 'application': observation['state'], 'operations': criteria}),
            'text': {'format': {'type': 'json_schema', 'name': 'next_action', 'strict': True, 'schema': {
                'type': 'object', 'additionalProperties': False, 'required': ['choice'],
                'properties': {'choice': {'type': 'string', 'enum': list(criteria)}},
            }}},
            'max_output_tokens': 200,
        }
        data = post_json(config, '/responses', payload, 20, 'Choice model')
        try:
            choice = json.loads(response_text(data, 'Choice model')).get('choice')
        except (ValueError, TypeError, AttributeError):
            raise RuntimeError('Choice model returned no valid JSON choice') from None
        confidence = probability = None
    if not isinstance(choice, str) or choice not in criteria:
        raise RuntimeError('Choice model returned an unoffered candidate')
    return dict(choice=choice, confidence=confidence, probability=probability,
                latencyMs=round((time.monotonic() - start) * 1000),
                model=data.get('model', model) if isinstance(data, dict) else model, provider=config['provider'])


ARGUMENT_INSTRUCTIONS = (
    'Fill arguments for the selected app operation from the user goal and current state. '
    'Return only the schema-constrained argument object; do not choose another operation. '
    'Use the selected operation schema and field descriptions to determine valid units and bounds. '
    'For edits, preserve every field not explicitly changed using the existing item in state. '
    'For task creation default priority to normal, project to personal, notes and dueDate '
    'to empty unless requested. Preserve explicitly quoted text exactly. '
    'Write original notes when the user asks for prose, reminders, or a checklist. '
    'Resolve relative dates against the supplied local time; use YYYY-MM-DD. '
    'Do not invent dates or claim an action was executed.'
)


def extract_arguments(observation, candidate, goal, model=None, provider=None):
    """Generate only the selected operation's typed arguments, not a tool choice."""
    config = model_config(provider)
    model = require_model(model or config['argument_model'], config, '--argument-model')
    schema = candidate['argumentSchema']
    payload = {
        'model': model,
        'instructions': ARGUMENT_INSTRUCTIONS,
        'input': json.dumps({'goal': goal, 'operation': candidate,
                             'application': observation['state'],
                             'localTime': datetime.now().astimezone().isoformat()}),
        'text': {'format': {'type': 'json_schema', 'name': 'action_arguments', 'strict': True, 'schema': schema}},
        'max_output_tokens': 800,
    }
    start = time.monotonic()
    what = 'Argument model'
    try:
        data = post_json(config, '/responses', payload, 30, what)
        text = response_text(data, what)
    except RuntimeError as error:
        raise RuntimeError(f'{error}; no action dispatched') from None
    try:
        arguments = json.loads(text)
    except (ValueError, TypeError):
        raise RuntimeError('Argument model returned no valid JSON object; no action dispatched') from None
    if not isinstance(arguments, dict) or set(arguments) != set(schema.get('required', [])):
        raise RuntimeError('Argument model returned the wrong fields/types; no action dispatched')
    return dict(arguments=arguments, latencyMs=round((time.monotonic() - start) * 1000),
                model=data.get('model', model), usage=data.get('usage', {}), provider=config['provider'])


def write_config(path, values):
    """Write KEY=value lines readable only by the user (0600, directory 0700), atomically."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + '.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, 'w') as handle:
            handle.write('# tca-harness model settings; environment variables override these.\n')
            for key in CONFIG_KEYS:
                if values.get(key):
                    handle.write(f'{key}={values[key]}\n')
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    os.replace(temporary, path)
    return path


def setup(provider=None, base_url=None, model=None, api_key_stdin=False, stdin=None, prompt=input, secret=None):
    """Store provider, endpoint, model and key in the config file. The key is never echoed or printed."""
    import getpass
    stdin = stdin or sys.stdin
    secret = secret or getpass.getpass
    path = config_path()
    values = read_config_file(path)
    interactive = not api_key_stdin and stdin.isatty()

    def ask(question, default=''):
        if not interactive:
            return default
        answer = prompt(f'{question} [{default}]: ' if default else f'{question}: ').strip()
        return answer or default

    if not provider:
        if not interactive:
            raise RuntimeError('setup needs --provider when not run interactively')
        provider = ask('Provider (router or responses)', values.get('TCA_HARNESS_MODEL_PROVIDER') or 'responses')
    if provider not in PROVIDERS:
        raise RuntimeError(f'Unknown model provider {provider!r}; use one of: ' + ', '.join(PROVIDERS))
    base_key, api_key = PROVIDER_KEYS[provider]
    base_url = base_url or ask('Base URL', values.get(base_key) or DEFAULT_BASE_URLS[provider])
    if not base_url.startswith(('https://', 'http://')):
        raise RuntimeError('Base URL must start with https:// or http://')
    if model is None:
        default_model = values.get('TCA_HARNESS_MODEL', '')
        hint = 'Model ID (blank for Router defaults)' if provider == 'router' else 'Model ID'
        model = ask(hint, default_model)
    if api_key_stdin:
        key = stdin.read().strip()
    elif interactive:
        key = secret('API key (input hidden; blank keeps the saved key): ').strip() or values.get(api_key, '')
    else:
        key = values.get(api_key, '')
    if not key:
        raise RuntimeError('No API key provided; pass it on standard input with --api-key-stdin')
    for value in (base_url, model, key):
        if any(c in value for c in '\r\n\0'):
            raise RuntimeError('Settings cannot contain line breaks')
    if provider == 'responses' and not model:
        print('Note: no model saved; pass --model and --argument-model or set TCA_HARNESS_MODEL', file=sys.stderr)
    values.update({'TCA_HARNESS_MODEL_PROVIDER': provider, base_key: base_url.rstrip('/'), api_key: key,
                   'TCA_HARNESS_MODEL': model})
    if not model:
        values.pop('TCA_HARNESS_MODEL', None)
    return write_config(path, values)


def matches_task(observation, expectation):
    fields = expectation['fields']
    for task in observation['state']['tasks']:
        if all(task.get(key) == value for key, value in fields.items()):
            notes = task.get('notes', '')
            if len(notes) >= expectation.get('notesMinLength', 0) and all(
                word.casefold() in notes.casefold() for word in expectation.get('notesContain', [])
            ):
                return True
    return False


_TRACE_STARTED = time.monotonic()
_TRACE_SEQUENCE = itertools.count(1)


def emit(event, **data):
    print(json.dumps(dict(event=event, traceVersion=1, seq=next(_TRACE_SEQUENCE),
                          timestamp=datetime.now().astimezone().isoformat(),
                          tMs=round((time.monotonic() - _TRACE_STARTED) * 1000, 2), **data)), flush=True)


def run_goal(host, goal, model, condition, max_steps, step_delay=0, argument_model=None, expectation=None, provider=None):
    """Bounded model loop. Only a deterministic host predicate proves completion."""
    started = time.monotonic()
    emit('goal_started', goal='run', description=goal)
    for step in range(max_steps):
        observed = host.call('observe')['observation']
        if expectation and matches_task(observed, expectation):
            emit('verified', condition='expectedTask', steps=step,
                 elapsedMs=round((time.monotonic() - started) * 1000), observation=host.observation)
            return True
        if condition:
            verification = host.call('verify', condition=condition)
            if not verification['ok']:
                raise RuntimeError(verification['error'])
            if verification.get('verified'):
                emit('verified', condition=condition, steps=step,
                     elapsedMs=round((time.monotonic() - started) * 1000), observation=host.observation)
                return True
        decision = decide(observed, goal, model, provider)
        emit('decision', step=step + 1, instruction=goal, observation=observed, **decision)
        if decision['choice'] == 'none':
            emit('stopped', reason='model_abstained', verified=False, observation=host.observation)
            return False
        candidate = next(c for c in observed['candidates'] if c['id'] == decision['choice'])
        arguments = {}
        if candidate.get('argumentSchema'):
            generated = extract_arguments(observed, candidate, goal, argument_model, provider)
            emit('arguments_generated', step=step + 1, candidateID=candidate['id'], **generated)
            arguments = generated['arguments']
        dispatch_started = time.monotonic()
        response = host.dispatch(decision['choice'], revision=observed['revision'], arguments=arguments)
        emit('dispatch', candidate=decision['choice'], arguments=arguments,
             latencyMs=round((time.monotonic() - dispatch_started) * 1000, 2), **response)
        if not response['ok']:
            if response.get('error') == 'stale_revision':
                continue  # Refresh and classify again; never force a stale command.
            raise RuntimeError(response['error'])
        if response['receipt']['status'] == 'running':
            wait_started = time.monotonic()
            result = host.call('wait', requestID=response['receipt']['requestID'], timeoutMs=3000)
            emit('wait', latencyMs=round((time.monotonic() - wait_started) * 1000, 2), **result)
            if not result['ok']:
                return False
        if step_delay:
            emit('pacing', durationMs=round(step_delay * 1000))
            time.sleep(step_delay)
    if expectation and matches_task(host.call('observe')['observation'], expectation):
        emit('verified', condition='expectedTask', steps=max_steps, observation=host.observation)
        return True
    if condition:
        verification = host.call('verify', condition=condition)
        if verification.get('verified'):
            emit('verified', condition=condition, steps=max_steps, observation=host.observation)
            return True
    emit('stopped', reason='step_limit', verified=False, observation=host.observation)
    return False


def demo(host):
    """A scripted scenario, no model required. Exercise the design's failure cases."""
    emit('initial', observation=host.observation)
    old_revision = host.observation['revision']
    groceries = host.candidate('root/completeButtonTapped/groceries')
    first = host.dispatch(groceries, requestID='complete-once')
    assert first['ok']
    duplicate = host.dispatch(groceries, requestID='complete-once', revision=old_revision)
    assert duplicate['ok'] and duplicate['observation']['revision'] == first['observation']['revision']
    emit('retry_deduplicated', **duplicate)
    stale = host.dispatch('root/completeButtonTapped/laundry', revision=old_revision)
    assert stale.get('error') == 'stale_revision'
    emit('stale_rejected', **stale)
    conflict = host.dispatch('root/completeButtonTapped/laundry', requestID='complete-once', revision=old_revision)
    assert conflict.get('error') == 'request_id_conflict'
    emit('request_conflict_rejected', **conflict)
    assert host.dispatch('root/openArchiveButtonTapped')['ok']
    old_save = host.candidate('root/archive/saveButtonTapped')
    saving = host.dispatch(old_save)
    assert saving['receipt']['status'] == 'running'
    emit('async_save_started', **saving)
    short = host.call('wait', requestID=host.last_operation, timeoutMs=1)
    assert short.get('error') == 'wait_timeout'
    emit('bounded_wait', **short)
    # No wait request drives completion: the runtime progresses while stdin is idle.
    time.sleep(0.5)
    completed = host.call('wait', requestID=host.last_operation)
    assert completed['ok'] and completed['observation']['revision'] > saving['observation']['revision']
    assert host.call('verify', condition='archiveSaved')['verified']
    emit('async_state_write_observed', **completed)
    saved_operation = host.last_operation
    assert host.dispatch('root/closeArchiveButtonTapped')['ok']
    assert host.call('wait', requestID=saved_operation)['receipt']['status'] == 'succeeded'
    assert host.dispatch('root/openArchiveButtonTapped')['ok']
    # The re-spawned archive is a new instance; the old save candidate cannot reach it.
    expired = host.dispatch(old_save)
    assert expired.get('error') == 'unavailable_candidate'
    emit('old_child_rejected', **expired)
    assert host.dispatch('root/archive/saveButtonTapped')['ok']
    operation = host.last_operation
    assert host.dispatch('root/closeArchiveButtonTapped')['ok']
    cancelled = host.call('wait', requestID=operation)
    assert cancelled['receipt']['status'] == 'cancelled'
    emit('dismount_cancelled_save', **cancelled)
    for candidate in list(host.observation['candidates']):
        if route(candidate['id']).startswith('root/completeButtonTapped/'):
            assert host.dispatch(candidate['id'])['ok']
    assert host.dispatch('root/openArchiveButtonTapped')['ok']
    assert host.dispatch('root/archive/saveButtonTapped')['ok']
    assert host.call('wait', requestID=host.last_operation)['ok']
    result = host.call('verify', condition='allCompletedAndArchived')
    assert result['verified']
    emit('demo_passed', **result)


def arguments_demo(host):
    """Scripted typed-argument exploration, no model calls."""
    original = host.call('observe')['observation']
    valid = dict(title='Typed argument task', notes='Draft notes', priority='high', project='work', dueDate='2026-10-30')
    invalid = [dict(valid, title='   '), dict(valid, dueDate='2026-02-30'),
               dict(valid, priority='urgent'), dict(valid, notes='x' * 1001),
               dict(valid, unexpected='extra')]
    invalid.append({key: value for key, value in valid.items() if key != 'title'})
    for arguments in invalid:
        result = host.dispatch('root/createTaskSubmitted', arguments=arguments)
        assert result.get('error') == 'invalid_arguments'
        assert host.observation['state'] == original['state']
        assert host.observation['revision'] == original['revision']
        emit('invalid_arguments_rejected', detail=result.get('detail'))
    created = host.dispatch('root/createTaskSubmitted', requestID='typed-create-once', arguments=valid)
    assert created['ok']
    duplicate = host.dispatch('root/createTaskSubmitted', requestID='typed-create-once', revision=original['revision'], arguments=valid)
    assert duplicate['ok'] and len(host.observation['state']['tasks']) == len(original['state']['tasks']) + 1
    conflict = host.dispatch('root/createTaskSubmitted', requestID='typed-create-once', revision=original['revision'], arguments=dict(valid, notes='Different'))
    assert conflict.get('error') == 'request_id_conflict'
    task = next(t for t in host.observation['state']['tasks'] if t['title'] == valid['title'])
    edited = dict(valid, title='Edited typed task', notes='Edited notes', priority='low')
    result = host.dispatch('root/editTaskSubmitted/' + task['id'], arguments=edited)
    assert result['ok']
    task = next(t for t in host.observation['state']['tasks'] if t['id'] == task['id'])
    assert all(task[k] == v for k, v in edited.items())
    emit('arguments_demo_passed', observation=host.observation)


def hybrid_demo(host, model, argument_model, step_delay=0, provider=None):
    """Live three-phase example: generated create, generated edit, finite operations."""
    started = time.monotonic()
    reset = host.dispatch('root/resetButtonTapped')
    if not reset['ok']:
        raise RuntimeError(reset['error'])
    phases = [
        ('create', 'Create a new task titled exactly "Email Sarah about launch", high priority, in Work, due October 30, 2026. Write two friendly sentences of notes addressed to Sarah about coordinating the launch.', 'launch-task.json', None),
        ('edit', 'Edit the existing task "Email Sarah about launch". Change priority to low, move it to Personal, and reschedule it to November 2, 2026. Replace the notes with a short checklist mentioning preparing slides and sending the agenda. Keep its title unchanged.', 'launch-task-edited.json', None),
        ('complete_and_archive', 'Mark only the task "Email Sarah about launch" complete, then open the archive and save a snapshot of completed tasks. Leave the saved archive open. Do not complete other tasks.', None, 'archiveSaved'),
    ]
    for name, goal, fixture, condition in phases:
        emit('phase', name=name, goal=goal)
        expectation = json.loads((HERE / 'fixtures' / fixture).read_text()) if fixture else None
        if not run_goal(host, goal, model, condition, 4, step_delay, argument_model, expectation, provider):
            return False
    emit('hybrid_demo_passed', elapsedMs=round((time.monotonic() - started) * 1000), observation=host.observation)
    return True


def shell(host, model, argument_model, provider=None):
    notice = ''
    while True:
        host.call('observe')
        if sys.stdout.isatty():
            print('\033[2J\033[H', end='')
        print('TCA harness prototype — ' + ('LIVE iOS app store' if host.connection else 'independent headless session'))
        print(json.dumps(host.observation['state'], indent=2))
        print(f"Revision {host.observation['revision']} | session {host.observation['sessionID'][:8]}")
        for i, candidate in enumerate(host.observation['candidates'], 1):
            print(f"[{i}] {candidate['label']}  ({candidate['id']})")
        print('Commands: number | observe | wait | verify CONDITION | goal TEXT | quit')
        if notice:
            print(notice)
        try:
            command = input('> ').strip()
        except EOFError:
            break
        if command in ('quit', 'q', 'exit'):
            break
        try:
            if command.isdigit() and 1 <= int(command) <= len(host.observation['candidates']):
                candidate = host.observation['candidates'][int(command) - 1]
                if candidate.get('argumentSchema'):
                    print(json.dumps(candidate['argumentSchema'], indent=2))
                    arguments = json.loads(input('Arguments JSON > '))
                    response = host.dispatch(candidate['id'], arguments=arguments)
                else:
                    response = host.dispatch(candidate['id'])
            elif command.startswith('verify '):
                response = host.call('verify', condition=command[7:])
            elif command == 'wait' and host.last_operation:
                response = host.call('wait', requestID=host.last_operation)
            elif command.startswith('goal '):
                # Human inspects one model-selected step; run mode offers the bounded loop.
                decision = decide(host.observation, command[5:], model, provider)
                emit('decision', **decision)
                if decision['choice'] != 'none':
                    candidate = next(c for c in host.observation['candidates'] if c['id'] == decision['choice'])
                    arguments = {}
                    if candidate.get('argumentSchema'):
                        generated = extract_arguments(host.observation, candidate, command[5:], argument_model, provider)
                        emit('arguments_generated', candidateID=candidate['id'], **generated)
                        arguments = generated['arguments']
                    response = host.dispatch(candidate['id'], arguments=arguments)
                else:
                    response = decision
            else:
                response = host.call('observe')
            notice = json.dumps({k: v for k, v in response.items() if k != 'observation'})
        except (RuntimeError, KeyError) as error:
            notice = str(error)


# Short commands: `ls` and `do` -------------------------------------------------
#
# `ls` shows the focused feature (the deepest mounted one), its state, its operations, and the
# operations "lent" by its ancestors (dismiss, back, tab selection). `do` resolves a name to one
# of those operations, dispatches it at the current revision, waits, and shows the new focus.

def depth(path):
    return path.count('/')


def is_ancestor(ancestor, path):
    return path.startswith(ancestor + '/')


def operation_name(candidate):
    """The operation route relative to its feature, e.g. `dismiss` or `completeButtonTapped/groceries`."""
    identifier = route(candidate['id'])
    prefix = candidate.get('feature', '') + '/'
    return identifier[len(prefix):] if candidate.get('feature') and identifier.startswith(prefix) else identifier


def mounted_features(host):
    """Mounted feature paths (with names) in mount order; falls back to candidate features."""
    features = []
    response = host.call('inspect')
    if response.get('ok') and isinstance(response.get('features'), list):
        inspected = getattr(host, 'inspected', None)
        if isinstance(inspected, dict):
            inspected.update((f['path'], f) for f in response['features'] if isinstance(f, dict) and isinstance(f.get('path'), str))
        features = [(f['path'], f.get('name') or f['path'].rsplit('/', 1)[-1]) for f in response['features']
                    if isinstance(f, dict) and isinstance(f.get('path'), str)]
    known = {path for path, _ in features}
    for candidate in host.observation['candidates']:
        path = candidate.get('feature')
        if isinstance(path, str) and path not in known:
            known.add(path)
            features.append((path, path.rsplit('/', 1)[-1]))
    return features


def choose_focus(paths, offered):
    """(focus, focused paths). Deepest wins; ties prefer the only one with operations, else their common ancestor."""
    deepest = max(map(depth, paths))
    tied = [p for p in paths if depth(p) == deepest]
    if len(tied) > 1:
        tied = [p for p in tied if p in offered] or tied
    if len(tied) == 1:
        return tied[0], {tied[0]}
    segments = [p.split('/') for p in tied]
    common = []
    for parts in zip(*segments):
        if len(set(parts)) != 1:
            break
        common.append(parts[0])
    focus = '/'.join(common) or tied[0].split('/')[0]
    # The ambiguous branches and the features between them and the common ancestor stay in focus.
    focused = {focus} | set(tied) | {p for p in paths if is_ancestor(focus, p) and any(is_ancestor(p, t) for t in tied)}
    return focus, focused


def state_at(state, path):
    """Best-effort state for a feature path: (value, resolved path). Stops at the deepest resolvable segment."""
    segments = path.split('/')
    value, resolved = state, segments[0]
    for raw in segments[1:]:
        segment = urllib.parse.unquote(raw)
        found, next_value = step_state(value, segment)
        if not found:
            break
        value, resolved = next_value, resolved + '/' + raw
    return value, resolved


def step_state(value, segment):
    if isinstance(value, dict):
        if segment in value:
            return True, value[segment]
        if set(value) == {'case', 'value'}:  # Enum snapshot, e.g. a destination.
            if value['case'] == segment:
                return True, value['value']
            return step_state(value['value'], segment)
    if isinstance(value, list):
        for element in value:
            if isinstance(element, dict) and str(element.get('id')) == segment:
                return True, element
        if segment.isdigit() and int(segment) < len(value):
            return True, value[int(segment)]
    return False, None


def focus_view(observation, features, path=None, show_all=False):
    """The `ls` view of an observation: focused feature, its state and available operations."""
    candidates = observation['candidates']
    names = dict(features)
    paths = [p for p, _ in features]
    offered = {c.get('feature') for c in candidates}
    if not paths:
        raise RuntimeError('No mounted features; check `tca doctor`')
    if path:
        if path not in names:
            raise RuntimeError(f'No mounted feature at {path}; mounted: ' + ', '.join(paths))
        focus, focused = path, {path}
    else:
        focus, focused = choose_focus(paths, offered)
    state, state_path = state_at(observation['state'], focus)

    def entry(candidate, scope):
        item = dict(name=operation_name(candidate), label=candidate.get('label', ''), id=candidate['id'],
                    feature=candidate.get('feature'), scope=scope)
        if candidate.get('argumentSchema'):
            item['argumentSchema'] = candidate['argumentSchema']
        return item

    operations = [entry(c, 'focused') for c in candidates if c.get('feature') in focused]
    # Lent operations, nearest ancestor first.
    for ancestor in sorted((p for p in set(offered) if isinstance(p, str) and is_ancestor(p, focus)), key=depth, reverse=True):
        operations += [entry(c, 'lent') for c in candidates if c.get('feature') == ancestor]
    if show_all:
        shown = {o['id'] for o in operations}
        operations += [entry(c, 'other') for c in candidates if c['id'] not in shown]
    view = dict(revision=observation['revision'], focus=focus, name=names.get(focus, focus.rsplit('/', 1)[-1]),
                statePath=state_path, state=state, operations=operations,
                hidden=0 if show_all else len(candidates) - len(operations))
    if show_all:
        view['features'] = paths
        view['rootState'] = observation['state']
    return view


def describe_schema(schema):
    """A compact one-line argument summary, e.g. `title: string, priority: low|normal|high`."""
    if not isinstance(schema, dict):
        return '{}'
    properties = schema.get('properties') or {}
    required = set(schema.get('required') or [])
    parts = []
    for key, field in properties.items():
        field = field if isinstance(field, dict) else {}
        kind = '|'.join(map(str, field['enum'])) if 'enum' in field else field.get('type', 'value')
        if isinstance(kind, list):
            kind = '|'.join(map(str, kind))
        parts.append(f"{key}{'' if key in required else '?'}: {kind}")
    return ', '.join(parts) or '{}'


def format_view(view):
    lines = [f"{view['name']} ({view['focus']})  revision {view['revision']}"]
    if view['statePath'] != view['focus']:
        lines.append(f"state shown from {view['statePath']}")
    lines += ['', 'State:', json.dumps(view['state'], indent=2, sort_keys=True), '']
    groups = [('focused', 'Actions:'), ('lent', None), ('other', None)]
    # Rows of a collection offer the same action under the same label; show each one's route, which
    # `tca do` accepts, so a specific row can be picked.
    seen = {}
    for operation in view['operations']:
        seen[(operation['name'], operation['label'])] = seen.get((operation['name'], operation['label']), 0) + 1
    for scope, title in groups:
        operations = [o for o in view['operations'] if o['scope'] == scope]
        if scope == 'focused':
            lines.append(title)
            if not operations:
                lines.append('  (none)')
        for feature in dict.fromkeys(o['feature'] for o in operations):
            if scope != 'focused':
                lines.append(('From ' if scope == 'lent' else 'Elsewhere at ') + f'{feature}:')
            for operation in (o for o in operations if o['feature'] == feature):
                line = f"  {operation['name']}"
                if operation['label'] and operation['label'] != operation['name']:
                    line += f"  - {operation['label']}"
                if 'argumentSchema' in operation:
                    line += f"  {{{describe_schema(operation['argumentSchema'])}}}"
                if seen[(operation['name'], operation['label'])] > 1:
                    line += f"  [{route(operation['id'])}]"
                lines.append(line)
    if view['hidden']:
        lines.append(f"({view['hidden']} more operation(s) elsewhere; use --all)")
    return '\n'.join(lines)


def resolve_operation(view, observation, query):
    """Exact ID (or ID without the @instance) first, then case-insensitive name or label in the view."""
    candidates = observation['candidates']
    exact = [c for c in candidates if c['id'] == query] or [c for c in candidates if route(c['id']) == query]
    if len(exact) == 1:
        return exact[0], []
    folded = query.casefold()
    scoped = {o['id'] for o in view['operations']}
    matches = [c for c in candidates if c['id'] in scoped and
               folded in (operation_name(c).casefold(), str(c.get('label', '')).casefold())]
    if len(matches) == 1:
        return matches[0], []
    return None, matches


def list_command(host, path=None, show_all=False, as_json=False):
    observation = host.call('observe')['observation']
    view = focus_view(observation, mounted_features(host), path, show_all)
    print(json.dumps(view, indent=2) if as_json else format_view(view))
    return 0


def instance_mounted(host, observation, candidate):
    instance = candidate.get('instanceID') or candidate['id'].rpartition('@')[2]
    response = host.call('inspect')
    if response.get('ok') and isinstance(response.get('features'), list):
        return any(isinstance(f, dict) and f.get('instanceID') == instance for f in response['features'])
    return any(c['id'].rpartition('@')[2] == instance for c in observation['candidates'])


def do_operation(host, query, arguments=None, path=None, show_all=False, timeout_ms=5000, wait=True):
    """Resolve and dispatch like `tca do`, returning the outcome instead of printing it. With
    `wait=False` a running receipt is returned as is (a race: the caller dispatches again first).

    Keys: ok, error (`no_match`/`ambiguous` when nothing was dispatched), detail, query, candidate,
    choices, before (the view resolved against), observation (the observation dispatched at),
    dispatched, response, receipt, view (the new focused view after dispatching).
    """
    observation = host.call('observe')['observation']
    view = focus_view(observation, mounted_features(host), path, show_all)
    candidate, matches = resolve_operation(view, observation, query)
    result = dict(query=query, candidate=candidate, before=view, observation=observation, dispatched=False,
                  response=None, receipt=None, view=None, choices=[], detail=None)
    if candidate is None:
        result['choices'] = matches or [c for c in observation['candidates'] if c['id'] in {o['id'] for o in view['operations']}]
        return dict(result, ok=False, error='ambiguous' if matches else 'no_match')
    response = host.call('dispatch', candidateID=candidate['id'], revision=observation['revision'],
                         requestID=str(uuid.uuid4()), arguments=arguments or {})
    receipt = response.get('receipt')
    dispatched = bool(response.get('ok'))
    if wait and dispatched and receipt and receipt.get('status') == 'running':
        waited = host.call('wait', requestID=receipt['requestID'], timeoutMs=timeout_ms)
        if waited.get('receipt'):
            receipt = waited['receipt']
        if not waited.get('ok'):
            response = dict(response, ok=False, error=waited.get('error'), detail=waited.get('detail'))
    ok = bool(response.get('ok')) and (receipt or {}).get('status') in ('succeeded', 'running')
    after = None
    if dispatched:
        current = host.call('observe')['observation']
        after = focus_view(current, mounted_features(host), None, show_all)
        # Navigation that unmounts the dispatching feature (e.g. Solo -> Game) reports `cancelled`
        # because the runtime can no longer read that instance; the action itself was sent.
        if (receipt or {}).get('status') == 'cancelled' and not instance_mounted(host, current, candidate):
            ok = True
            response = dict(response, ok=True, error=None, detail=None)
            receipt = dict(receipt, featureClosed=True)
    return dict(result, ok=ok, dispatched=dispatched, response=response, receipt=receipt, view=after,
                error=response.get('error'), detail=response.get('detail'))


def do_command(host, query, arguments=None, path=None, show_all=False, as_json=False, timeout_ms=5000, record=False, port=None):
    """Resolve, dispatch at the current revision, wait for the receipt, then print the new focus."""
    recording = record and Path(RECORDING).exists()
    if recording:
        sibling('journeys').record_requests(host, port)  # What the previous step made, up to now.
    result = do_operation(host, query, arguments, path, show_all, timeout_ms)
    candidate = result['candidate']
    if candidate is None:
        choices = result['choices']
        if as_json:
            print(json.dumps({'ok': False, 'error': result['error'], 'query': query,
                              'choices': [dict(name=operation_name(c), label=c.get('label', ''), id=c['id']) for c in choices]}, indent=2))
        else:
            ambiguous = result['error'] == 'ambiguous'
            print(f"{'Ambiguous' if ambiguous else 'No'} action matching {query!r}. "
                  f"{'Use one of these IDs' if ambiguous else 'Available'}:", file=sys.stderr)
            for c in choices:
                print(f"  {operation_name(c)}  - {c.get('label', '')}  ({c['id']})", file=sys.stderr)
        return 2
    response, receipt, after, ok = result['response'], result['receipt'], result['view'], result['ok']
    if as_json:
        print(json.dumps({'ok': ok, 'candidateID': candidate['id'], 'receipt': receipt,
                          'error': response.get('error'), 'detail': response.get('detail'), 'view': after}, indent=2))
    else:
        if response.get('ok') and (receipt or {}).get('featureClosed'):
            print(f"{operation_name(candidate)}: sent; {candidate.get('feature')} closed (receipt cancelled)")
        elif response.get('ok'):
            print(f"{operation_name(candidate)}: {(receipt or {}).get('status', 'dispatched')}")
        else:
            if result['dispatched']:
                print(f"{operation_name(candidate)}: dispatched, {(receipt or {}).get('status', 'unknown')}", file=sys.stderr)
            detail = f": {response['detail']}" if response.get('detail') else ''
            print(f"{operation_name(candidate)}: {response.get('error', 'failed')}{detail}", file=sys.stderr)
        if after:
            print()
            print(format_view(after))
    if ok and recording:
        number, name = sibling('journeys').record_step(result, arguments or {}, path)
        print(f'recorded step {number}: {name}', file=sys.stderr)
    return 0 if ok else 2


def doctor(host):
    """Read-only integration checks; never classify, dispatch, or load credentials."""
    response = host.call('inspect')
    errors = []
    warnings = []
    if not response.get('ok'):
        return {'ok': False, 'errors': ['Capability inspection is unavailable. Attach a HarnessRuntime or store.harness(...) to the existing store.'],
                'serverError': response.get('error')}
    if response.get('protocolVersion') not in (2, 3):
        errors.append('Unsupported harness protocol version; update the client and embedded package together.')
    diagnostics = response.get('diagnostics', [])
    if not isinstance(diagnostics, list) or not all(isinstance(x, str) for x in diagnostics):
        errors.append('Invalid runtime diagnostics response.')
    else:
        errors.extend(diagnostics)
    features = response.get('features')
    if not isinstance(features, list) or not features:
        errors.append('No mounted root feature. Retain the attachment and inspect runtime diagnostics.')
        features = []
    paths = set()
    ids = set()
    operation_count = 0
    for feature in features:
        if not isinstance(feature, dict) or not all(isinstance(feature.get(key), str) and feature[key] for key in ('path', 'name', 'instanceID')):
            errors.append('A mounted feature has invalid identity metadata.')
            continue
        if feature['path'] in paths:
            errors.append('Duplicate feature path: ' + feature['path'])
        paths.add(feature['path'])
        operations = feature.get('operations')
        if not isinstance(operations, list):
            errors.append('Missing operation list for ' + feature['path'])
            continue
        for operation in operations:
            if not isinstance(operation, dict) or not isinstance(operation.get('id'), str):
                errors.append('Invalid operation metadata for ' + feature['path'])
                continue
            operation_count += 1
            if operation['id'] in ids:
                errors.append('Duplicate operation ID: ' + operation['id'])
            ids.add(operation['id'])
            if operation.get('instanceID') != feature['instanceID'] or operation.get('feature') != feature['path']:
                errors.append('Operation is not bound to its mounted feature: ' + operation['id'])
    if features and operation_count == 0 and not errors:
        warnings.append('Connected, but no operations are currently available. Check exposure and availability rules or navigate to a feature.')
    # Optional: report whether `tca devtools` has a timeline to read. A cursor past every entry returns none.
    timeline = host.call('timeline', since=2**53).get('timeline')
    return {'ok': not errors, 'protocolVersion': response.get('protocolVersion'),
            'features': len(features), 'operations': operation_count,
            'timeline': f"recording ({timeline['detail']})" if isinstance(timeline, dict) else 'not recording',
            'errors': errors, 'warnings': warnings}


RECORDING = '.tca/recording.json'  # `tca record start` writes this; `tca do` appends steps to it.
TEST_COMMANDS = ('journey', 'record', 'explore', 'chaos', 'determinism', 'diff', 'fixtures', 'exposure')  # Handled in journeys.py.
COMMANDS = ['doctor', 'ls', 'do', 'setup', 'shell', 'observe', 'inspect', 'dispatch', 'wait', 'cancel', 'demo',
            'arguments-demo', 'hybrid-demo', 'run', 'trace', 'devtools', 'protocol', 'build', *TEST_COMMANDS]
APP_ONLY = ('doctor', 'ls', 'do')


def main(argv=None):
    argv = sys.argv[1:] if argv is None else list(argv)
    if argv and argv[0] in TEST_COMMANDS:
        return sibling('journeys').main(argv)
    parser = argparse.ArgumentParser(prog='tca', description=__doc__)
    parser.add_argument('command', nargs='?', choices=COMMANDS, default='doctor', metavar='command',
                        help='One of: ' + ', '.join(COMMANDS) + ' (default: doctor)')
    parser.add_argument('params', nargs='*', help="For do: ACTION ['{json arguments}']")
    parser.add_argument('--app', action='store_true', help='Connect to the running app instead of creating a headless store')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--step-delay', type=float, default=0, help='Optional pacing between steps, in seconds')
    parser.add_argument('--goal')
    parser.add_argument('--path', help='Feature path for inspect, or the feature to focus for ls/do')
    parser.add_argument('--all', action='store_true', help='ls/do: show every mounted operation and the whole state')
    parser.add_argument('--json', action='store_true', help='ls/do: machine-readable output')
    parser.add_argument('--candidate', help='Exact operation ID from observe or inspect')
    parser.add_argument('--arguments', default=None, help='JSON argument object for dispatch/do')
    parser.add_argument('--request-id', help='Operation request ID for wait/cancel or dispatch deduplication')
    parser.add_argument('--revision', type=int, help='Expected observation revision for dispatch')
    parser.add_argument('--verify', dest='condition')
    parser.add_argument('--max-steps', type=int, default=8)
    parser.add_argument('--provider', choices=PROVIDERS, help='Model provider (default: configured, else inferred)')
    parser.add_argument('--model', help='Choice model ID (setup: model saved for both calls)')
    parser.add_argument('--argument-model', help='Argument-filling model ID')
    parser.add_argument('--base-url', help='setup: provider base URL')
    parser.add_argument('--api-key-stdin', action='store_true', help='setup: read the API key from standard input')
    parser.add_argument('--expect-task', type=Path, help='Local JSON fixture for deterministic task-field verification')
    parser.add_argument('--input', type=Path, help='JSONL run trace for the trace viewer')
    parser.add_argument('--output', type=Path, help='Standalone viewer output (defaults beside the input)')
    parser.add_argument('--http-port', type=int, default=8780, help='Local port for the devtools panel')
    args = parser.parse_intermixed_args(argv)
    if args.params and args.command != 'do':
        parser.error(f'{args.command} takes no positional arguments')
    if args.command == 'setup':
        path = setup(args.provider, args.base_url, args.model, args.api_key_stdin)
        print(str(path))
        return 0
    if args.command == 'devtools':
        if not 1 <= args.port <= 65535 or not 0 <= args.http_port <= 65535:
            parser.error('Invalid --port or --http-port')
        serve = sibling('devtools').serve
        try:
            serve(args.port, args.http_port)
        except OSError as error:
            parser.error(f'Cannot serve devtools on 127.0.0.1:{args.http_port}: {error}')
        return 0
    if args.command == 'trace':
        if not args.input:
            parser.error('trace requires --input PATH.jsonl')
        render_trace = sibling('trace_view').render_trace
        try:
            output = render_trace(args.input, args.output)
        except (OSError, ValueError) as error:
            parser.error(str(error))
        print(str(output))
        return 0
    if args.command in APP_ONLY or not HERE.exists():
        args.app = True  # These never build the optional headless demo; installs have no demo to build.
    arguments = {}
    if args.command in ('dispatch', 'do'):
        text = args.arguments
        if args.command == 'do':
            if not 1 <= len(args.params) <= 2:
                parser.error("do requires ACTION and optionally a JSON object, e.g. tca do save '{\"value\":1}'")
            if len(args.params) == 2:
                if text is not None:
                    parser.error('Pass arguments positionally or with --arguments, not both')
                text = args.params[1]
        try:
            arguments = json.loads(text or '{}')
            if not isinstance(arguments, dict):
                raise ValueError()
        except ValueError:
            parser.error('Arguments must be a JSON object')
    if args.command == 'dispatch' and not args.candidate:
        parser.error('dispatch requires --candidate')
    if args.command in ('wait', 'cancel') and not args.request_id:
        parser.error('wait/cancel require --request-id')
    if args.command == 'run' and not args.goal:
        parser.error('run requires --goal')
    if not 1 <= args.max_steps <= 20:
        parser.error('--max-steps must be between 1 and 20')
    if args.app and args.command in ('build', 'protocol'):
        parser.error('build and protocol are for the headless demo in a repository checkout; drop --app')
    if not 1 <= args.port <= 65535 or not 0 <= args.step_delay <= 5:
        parser.error('Invalid port or --step-delay (0–5 seconds)')
    if not args.app:
        build(force=args.command == 'build')
    if args.command == 'build':
        return 0
    if args.command == 'protocol':
        os.execv(str(BINARY), [str(BINARY)])
    expectation = None
    if args.expect_task:
        expectation = json.loads(args.expect_task.read_text())
        allowed = {'title', 'notes', 'priority', 'project', 'dueDate', 'isComplete'}
        if not isinstance(expectation.get('fields'), dict) or not expectation['fields'] or not set(expectation['fields']) <= allowed:
            parser.error('--expect-task requires nonempty task fields')
        if args.condition:
            parser.error('Use either --verify or --expect-task')
    host = Host(port=args.port if args.app else None)
    try:
        if args.command == 'doctor':
            result = doctor(host)
            emit('doctor', endpoint=f'127.0.0.1:{args.port}', **result)
            return 0 if result['ok'] else 2
        elif args.command == 'ls':
            return list_command(host, args.path, args.all, args.json)
        elif args.command == 'do':
            return do_command(host, args.params[0], arguments, args.path, args.all, args.json, record=True, port=args.port)
        elif args.command == 'observe':
            emit('observation', observation=host.observation)
        elif args.command == 'inspect':
            response = host.call('inspect', **({'path': args.path} if args.path else {}))
            emit('inspection', **response)
            return 0 if response.get('ok') else 2
        elif args.command == 'dispatch':
            fields = {'arguments': arguments}
            if args.request_id: fields['requestID'] = args.request_id
            if args.revision is not None: fields['revision'] = args.revision
            response = host.dispatch(args.candidate, **fields)
            emit('dispatch', **response)
            return 0 if response.get('ok') else 2
        elif args.command in ('wait', 'cancel'):
            response = host.call(args.command, requestID=args.request_id)
            emit(args.command, **response)
            return 0 if response.get('ok') else 2
        elif args.command == 'hybrid-demo':
            return 0 if hybrid_demo(host, args.model, args.argument_model, args.step_delay, args.provider) else 2
        elif args.command == 'arguments-demo':
            if args.app:
                host.dispatch('root/resetButtonTapped')
            arguments_demo(host)
        elif args.command == 'demo':
            if args.app:
                host.dispatch('root/resetButtonTapped')
            demo(host)
        elif args.command == 'run':
            return 0 if run_goal(host, args.goal, args.model, args.condition, args.max_steps, args.step_delay,
                                 args.argument_model, expectation, args.provider) else 2
        else:
            shell(host, args.model, args.argument_model, args.provider)
    finally:
        host.close()
    return 0


def sibling(name):
    """Import a sibling module whether running from the checkout (cli/tca.py) or as the installed package."""
    if __package__:
        return importlib.import_module(f'{__package__}.{name}')
    if name in sys.modules:
        return sys.modules[name]
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    return importlib.import_module(name)


def entry():
    """Console-script entry point (`tca`)."""
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Harness stopped: {error}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    entry()
