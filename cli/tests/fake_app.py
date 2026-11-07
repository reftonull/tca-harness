#!/usr/bin/env python3
"""A fake harnessed app speaking protocol v3 over loopback newline JSON, for end-to-end CLI tests.

A tiny bookshelf: `root/shelf` lists books and opens `root/shelf/editor`. Saving and refreshing go
through a fake network (fixtures, faults, a request log); invariants are reported as issues.

    python3 fake_app.py --port 8790 [--bug] [--strand-on-error] [--crashy] [--stuck] [--unseeded-ids] [--ui] [--v2]

--bug             "Add sample book" stays offered and adds a duplicate (invariant: no duplicate books)
--strand-on-error a failed save leaves the editor saving forever and hides every other operation
--crashy          offers "Crash", which exits the process without replying
--stuck           offers "Sync forever", whose receipt never finishes
--unseeded-ids    new book IDs ignore TCA_HARNESS_SEED (nondeterministic)
--ui              behaves like the app with views: opening the editor focuses its title field
--v2              protocol v2: no `issues`/`network` methods and no issueCount
--launch-load     a book arrives 150 ms after launch, like a first fetch that answers after the listener is up
--launch-fetch    GET /books at launch, before listening; a failure shows an error and "Retry"
--fragile-launch  like --launch-fetch, but a failure hides every other operation (a stranded user)
--race-save       Save stays offered while the POST is in flight, and resends the same book (a double tap duplicates it)
--search          offers "Search" (GET /search); a newer search cancels the one in flight
--stale-search    like --search, but every response is applied, so an older one can overwrite a newer one
--quiet-search    no "results are for the search field" invariant (only a final-state comparison sees a stale response)

Replay honours TCA_HARNESS_LATENCY (or `network` `latency`): responses take that long, plus a seeded
jitter, and requests are logged when they finish, with `pending` counting the rest.

Faults in TCA_HARNESS_FAULTS (a JSON array) apply from the first request, like HarnessNetwork. Replayed
requests log `match` and `cassette`; in record mode each request is saved as a cassette.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import random
import socketserver
import sys
import threading
import time
import uuid
from urllib.parse import urlsplit

API = 'http://api.shelf.test'


class FakeShelf:
    def __init__(self, bug=False, strand=False, crashy=False, stuck=False, unseeded=False, ui=False, v2=False,
                 network=None, cassettes=None, seed=None, late=False, faults=None, fragile=False, race_save=False,
                 search=None, latency=None):
        self.bug, self.strand, self.crashy, self.stuck, self.unseeded, self.ui, self.v2 = bug, strand, crashy, stuck, unseeded, ui, v2
        self.late = late  # Bug: closing the editor leaves an effect that reports an issue 150 ms later.
        self.session_id = str(uuid.uuid4())
        self.revision = 0
        self.previous = None
        self.state = {'shelf': {'books': [], 'isLoading': False, 'unreadCount': 0, 'error': None}, 'editor': None}
        self.editor_instance = 0
        self.receipts = {}
        self.pending = []           # (due, function)
        self.issues = []
        self.violated = set()
        self.mode = network or 'live'
        self.cassettes = cassettes
        self.faults = [dict(f, match=dict(f.get('match') or {})) for f in faults or []]
        self.fragile = fragile
        self.race_save = race_save
        self.sampling = False     # "Add sample book" in flight: hidden, like a disabled button.
        self.search = search      # None, 'ok' or 'stale'
        self.searches = 0
        self.quiet_search = False
        self.latency = latency or {}
        self.seed = seed
        self.inflight = []        # Requests started and not yet logged (they're logged when answered).
        self.occurrences = {}
        if search:
            self.state['shelf'].update(query='', resultsFor='', searching=False)
        self.recorded = {}
        self.requests = []
        self.random = random.Random(seed if seed is not None else time.time_ns())
        self.counter = 0
        self.lock = threading.RLock()

    # Network ------------------------------------------------------------------------------------
    def latency_ms(self, method, path):
        """Replay latency for this request: `ms` +/- a jitter drawn from the seed and the occurrence."""
        if self.mode != 'replay' or not self.latency:
            return 0
        key = f'{method} {path}'
        occurrence = self.occurrences[key] = self.occurrences.get(key, -1) + 1
        rule = (self.latency.get('paths') or {}).get(path) or {}
        base, jitter = rule.get('ms', self.latency.get('ms', 0)), rule.get('jitter_ms', self.latency.get('jitter_ms', 0))
        draw = random.Random(f"{self.latency.get('seed', self.seed or 0)}:{key}:{occurrence}").randint(-jitter, jitter) if jitter else 0
        return max(base + draw, 0)

    def request(self, method, path):
        """Returns (ok, entry). Starts the request, logged when it's answered (after `entry['ms']`);
        applies faults, fixtures and the mode."""
        url = API + path.partition('?')[0] + ('?' + path.partition('?')[2] if '?' in path else '')
        path = path.partition('?')[0]
        entry = {'method': method, 'url': url, 'status': None, 'source': None, 'fault': None, 'ms': 1}
        ok, entry = self.answer(method, path, url, entry)
        entry['ms'] += self.latency_ms(method, path)
        self.inflight.append(entry)
        self.later(entry['ms'] / 1000 - 0.0005, lambda: self.logged(entry))
        return ok, entry

    def logged(self, entry):
        self.inflight.remove(entry)
        entry['seq'] = len(self.requests) + 1
        self.requests.append(entry)

    def answer(self, method, path, url, entry):
        for fault in list(self.faults):
            match = fault.get('match') or {}
            if match.get('method', method) != method or match.get('path', path) != path:
                continue
            if fault.get('skip', 0) > 0:
                fault['skip'] -= 1
                continue
            times = fault.get('times', 1)
            if times == 0:
                continue
            if times > 0:
                fault['times'] = times - 1
            entry['fault'] = fault['kind']
            if fault['kind'] == 'delay':
                entry['ms'] += fault.get('delayMs', 0)
                break  # Then the normal response.
            entry['source'] = entry['match'] = 'fault'
            entry['status'] = fault.get('status') if fault['kind'] == 'status' else 200 if fault['kind'] == 'malformed' else None
            return False, entry
        name = f"{method}_{path.strip('/').replace('/', '_')}_"
        if self.mode == 'block':
            entry['source'] = entry['match'] = 'blocked'
            self.report('network', f'{method} {url} attempted with the network blocked')
            return False, entry
        if self.mode == 'replay':
            directory = Path(self.cassettes) if self.cassettes else None
            matches = sorted(directory.glob(name + '*.json')) if directory and directory.is_dir() else []
            if not matches:
                entry['source'] = entry['match'] = 'blocked'
                self.report('network', f'{method} {url} has no fixture')
                return False, entry
            status = json.loads(matches[-1].read_text())['response']['status']
            entry.update(source='fixture', status=status, match='exact', cassette=matches[-1].name)
            return 200 <= status < 300, entry
        entry.update(source='live', status=200, match='live')
        if self.mode == 'record' and self.cassettes:
            number = self.recorded[name] = self.recorded.get(name, 0) + 1
            Path(self.cassettes).mkdir(parents=True, exist_ok=True)
            (Path(self.cassettes) / f'{name}{number}.json').write_text(json.dumps({
                'request': {'method': method, 'url': url, 'body': None},
                'response': {'status': 201 if method == 'POST' else 200, 'headers': {}, 'body': {}}}))
            entry['cassette'] = f'{name}{number}.json'
        return True, entry

    def report(self, kind, message):
        self.issues.append({'seq': len(self.issues) + 1, 'kind': kind, 'message': message, 'file': 'Shelf.swift',
                            'line': 42, 'action': None})

    # State --------------------------------------------------------------------------------------
    def new_id(self):
        if self.unseeded:
            return uuid.uuid4().hex[:8]
        self.counter += 1
        return f'book-{self.counter}'

    def recount(self):
        shelf = self.state['shelf']
        shelf['unreadCount'] = sum(1 for b in shelf['books'] if not b['isRead'])

    def check_invariants(self):
        books = self.state['shelf']['books']
        shelf = self.state['shelf']
        rules = {'no duplicate books': len({b['id'] for b in books}) == len(books),
                 'unread badge matches the list': shelf['unreadCount'] == sum(not b['isRead'] for b in books)}
        if self.search and not self.quiet_search:
            rules['results are for the search field'] = shelf['searching'] or shelf['resultsFor'] == shelf['query']
        for name, holds in rules.items():
            if not holds and name not in self.violated:
                self.report('invariant', name)
            (self.violated.discard if holds else self.violated.add)(name)

    def tick(self):
        now = time.monotonic()
        due = sorted((p for p in self.pending if p[0] <= now), key=lambda p: p[0])
        self.pending = [p for p in self.pending if p[0] > now]
        for _, function in due:
            function()
        if due:
            self.recount()
            self.check_invariants()

    def later(self, seconds, function):
        self.pending.append((time.monotonic() + seconds, function))

    def observe(self):
        self.tick()
        snapshot = json.dumps(self.state, sort_keys=True)
        if self.previous is not None and snapshot != self.previous:
            self.revision += 1
        self.previous = snapshot
        observation = {'sessionID': self.session_id, 'revision': self.revision, 'state': copy.deepcopy(self.state),
                       'candidates': self.candidates()}
        if not self.v2:
            observation['issueCount'] = len(self.issues)
        return observation

    def features(self):
        features = [('root', 'Shelf app', 'I-ROOT'), ('root/shelf', 'Shelf', 'I-SHELF')]
        if self.state['editor'] is not None:
            features.append(('root/shelf/editor', 'Editor', f'I-EDITOR-{self.editor_instance}'))
        return features

    def candidates(self):
        shelf, editor = self.state['shelf'], self.state['editor']
        stranded = (editor is not None and editor.get('stranded')) or shelf.get('stranded')
        result = []

        def offer(feature, instance, name, label, schema=None):
            item = {'id': f'{feature}/{name}@{instance}', 'feature': feature, 'instanceID': instance, 'label': label}
            if schema:
                item['argumentSchema'] = schema
            result.append(item)

        if not stranded:
            if editor is None:
                offer('root/shelf', 'I-SHELF', 'addBook', 'Add book')
            else:
                offer('root/shelf', 'I-SHELF', 'closeEditor', 'Close editor')
            if self.bug or not (self.sampling or any(b['id'] == 'sample' for b in shelf['books'])):
                offer('root/shelf', 'I-SHELF', 'addSample', 'Add sample book')
            offer('root/shelf', 'I-SHELF', 'refresh', 'Refresh')
            for book in shelf['books']:
                verb = 'unread' if book['isRead'] else 'read'
                offer('root/shelf', 'I-SHELF', f"toggleRead/{book['id']}", f"Mark {book['title']} {verb}")
            if shelf['error']:
                offer('root/shelf', 'I-SHELF', 'dismissError', 'Dismiss error')
            if self.crashy:
                offer('root/shelf', 'I-SHELF', 'crash', 'Crash')
            if self.stuck:
                offer('root/shelf', 'I-SHELF', 'syncForever', 'Sync forever')
            if self.search and editor is None:
                offer('root/shelf', 'I-SHELF', 'search', 'Search',
                      {'type': 'object', 'additionalProperties': False, 'required': ['value'],
                       'properties': {'value': {'type': 'string', 'maxLength': 200}}})
        if shelf.get('stranded'):
            offer('root/shelf', 'I-SHELF', 'dismissError', 'Dismiss error')
        if editor is not None:
            instance = f'I-EDITOR-{self.editor_instance}'
            string = {'type': 'string', 'maxLength': 200}
            offer('root/shelf/editor', instance, 'setTitle', 'Set title',
                  {'type': 'object', 'additionalProperties': False, 'required': ['value'], 'properties': {'value': string}})
            if not stranded:
                offer('root/shelf/editor', instance, 'setRating', 'Set rating',
                      {'type': 'object', 'additionalProperties': False, 'required': ['value'],
                       'properties': {'value': {'type': 'number', 'minimum': 0, 'maximum': 5}}})
                offer('root/shelf/editor', instance, 'setDetails', 'Set details', {
                    'type': 'object', 'additionalProperties': False, 'required': ['copies', 'featured', 'note', 'tags'],
                    'properties': {'copies': {'type': 'integer'}, 'featured': {'type': 'boolean'},
                                   'note': {'anyOf': [{'type': 'string'}, {'type': 'null'}]},
                                   'tags': {'type': 'array', 'items': {'type': 'string', 'enum': ['fiction', 'classic']}}}})
                if editor['title'].strip() and (not editor['isSaving'] or self.race_save):
                    offer('root/shelf/editor', instance, 'save', 'Save')
        return result

    # Operations ---------------------------------------------------------------------------------
    def perform(self, name, arguments, receipt):
        shelf, editor = self.state['shelf'], self.state['editor']

        def finish(status):
            receipt['status'] = status

        if name == 'addBook':
            self.editor_instance += 1
            self.state['editor'] = {'title': '', 'rating': 0, 'isSaving': False, 'error': None, 'details': None}
            if self.ui:
                self.state['editor']['focusedField'] = 'title'  # What the view's onAppear does.
        elif name == 'closeEditor':
            self.state['editor'] = None
            if self.late:
                self.later(0.15, lambda: self.report('issue', 'late response sent to the closed editor'))
        elif name == 'setTitle':
            editor['title'] = arguments['value']
        elif name == 'setRating':
            editor['rating'] = arguments['value']
        elif name == 'setDetails':
            editor['details'] = arguments
        elif name == 'dismissError':
            shelf['error'] = None
        elif name.startswith('toggleRead/'):
            book = next(b for b in shelf['books'] if b['id'] == name.split('/', 1)[1])
            book['isRead'] = not book['isRead']
        elif name == 'addSample':
            ok, entry = self.request('POST', '/books')
            self.sampling = True

            def done():
                self.sampling = False
                if ok:
                    shelf['books'].append({'id': 'sample', 'title': 'Sample', 'isRead': False})
                    finish('succeeded')
                else:
                    shelf['error'] = "Couldn't add the sample book"
                    finish('failed')
            receipt['status'] = 'running'
            self.later(0.02 + entry['ms'] / 1000, done)
        elif name == 'refresh':
            shelf['isLoading'] = True
            ok, entry = self.request('GET', '/books')

            def done():
                shelf['isLoading'] = False
                if not ok:
                    shelf['error'] = "Couldn't refresh"
                finish('succeeded' if ok else 'failed')
            receipt['status'] = 'running'
            self.later(0.02 + entry['ms'] / 1000, done)
        elif name == 'save':
            editor['isSaving'] = True
            ok, entry = self.request('POST', '/books')
            title = editor['title']
            pending = editor.get('pending') if self.race_save else None  # The bug resends the book in flight.
            if self.race_save and pending is None:
                pending = editor['pending'] = self.new_id()

            def done():
                current = self.state['editor']
                if ok:
                    shelf['books'].append({'id': pending or self.new_id(), 'title': title, 'isRead': False})
                    self.state['editor'] = None
                    finish('succeeded')
                elif current is None:
                    finish('failed')
                elif self.strand:
                    current['stranded'] = True  # Bug: the spinner never stops and nothing is offered.
                    finish('failed')
                else:
                    current['isSaving'] = False
                    current['error'] = "Couldn't save"
                    finish('failed')
            receipt['status'] = 'running'
            self.later(0.02 + entry['ms'] / 1000, done)
        elif name == 'search':
            query = arguments['value']
            self.searches += 1
            token = self.searches
            shelf['query'], shelf['searching'] = query, True
            ok, entry = self.request('GET', '/search?q=' + query.replace(' ', '+')[:40])

            def done():
                if self.search == 'ok' and token != self.searches:
                    finish('cancelled')  # A newer search replaced this one.
                    return
                shelf['resultsFor'], shelf['searching'] = query, False
                finish('succeeded' if ok else 'failed')
            receipt['status'] = 'running'
            self.later(0.005 + entry['ms'] / 1000, done)
        elif name == 'crash':
            os._exit(3)
        elif name == 'syncForever':
            receipt['status'] = 'running'
            return
        else:
            raise KeyError(name)
        self.recount()
        self.check_invariants()

    # Protocol -----------------------------------------------------------------------------------
    def handle(self, request):
        with self.lock:
            method = request.get('method')
            if method == 'observe':
                return {'ok': True, 'observation': self.observe()}
            if method == 'inspect':
                observation = self.observe()
                return {'ok': True, 'protocolVersion': 2 if self.v2 else 3, 'diagnostics': [], 'observation': observation,
                        'features': [{'path': p, 'name': n, 'instanceID': i,
                                      'operations': [c for c in observation['candidates'] if c['feature'] == p]}
                                     for p, n, i in self.features()]}
            if method == 'issues' and not self.v2:
                since = request.get('since', 0)
                return {'ok': True, 'issues': [i for i in self.issues if i['seq'] > since], 'observation': self.observe()}
            if method == 'network' and not self.v2:
                settings = request.get('network') or {}
                if 'mode' in settings:
                    self.mode = settings['mode']
                if 'cassettes' in settings:
                    self.cassettes = settings['cassettes']
                if 'faults' in settings:
                    self.faults = [dict(f, match=dict(f.get('match') or {})) for f in settings['faults']]
                if 'latency' in settings:
                    self.latency = settings['latency'] or {}
                observation = self.observe()  # Ticks, so answered requests are logged first.
                since = request.get('since', 0)
                return {'ok': True, 'network': {'mode': self.mode, 'cassettes': self.cassettes,
                                                'requests': [r for r in self.requests if r['seq'] > since],
                                                'faults': self.faults, 'pending': len(self.inflight),
                                                **({'latency': self.latency} if self.latency else {})},
                        'observation': observation}
            if method == 'dispatch':
                if request.get('sessionID') != self.session_id:
                    return {'ok': False, 'error': 'wrong_session', 'observation': self.observe()}
                current = self.observe()
                if request.get('revision') != current['revision']:
                    return {'ok': False, 'error': 'stale_revision', 'observation': current}
                candidate = next((c for c in current['candidates'] if c['id'] == request.get('candidateID')), None)
                if candidate is None:
                    return {'ok': False, 'error': 'unavailable_candidate', 'observation': current}
                arguments = request.get('arguments') or {}
                problem = validate(candidate.get('argumentSchema'), arguments) if candidate.get('argumentSchema') else (
                    'This operation accepts no arguments' if arguments else None)
                if problem:
                    return {'ok': False, 'error': 'invalid_arguments', 'detail': problem, 'observation': current}
                receipt = {'requestID': request['requestID'], 'candidateID': candidate['id'], 'status': 'succeeded'}
                self.receipts[request['requestID']] = receipt
                name = candidate['id'].split('@')[0][len(candidate['feature']) + 1:]
                self.perform(name, arguments, receipt)
                return {'ok': True, 'receipt': dict(receipt), 'observation': self.observe()}
            if method == 'wait':
                receipt = self.receipts.get(request.get('requestID'))
                if receipt is None:
                    return {'ok': False, 'error': 'unknown_operation', 'observation': self.observe()}
                deadline = time.monotonic() + min(max(request.get('timeoutMs', 3000), 1), 10000) / 1000
        if method == 'wait':
            while True:
                with self.lock:
                    self.tick()
                    if receipt['status'] != 'running' or time.monotonic() >= deadline:
                        status = receipt['status']
                        return {'ok': status == 'succeeded', 'receipt': dict(receipt), 'observation': self.observe(),
                                'error': None if status == 'succeeded' else 'wait_timeout' if status == 'running' else status}
                time.sleep(0.005)
        with self.lock:
            return {'ok': False, 'error': 'unknown_method', 'observation': self.observe()}


def validate(schema, value, path='arguments'):
    """Mirror of HarnessJSONSchema.validate; returns a problem string or None."""
    if 'anyOf' in schema:
        if value is None:
            return None
        return validate(schema['anyOf'][0], value, path)
    kind = schema.get('type')
    if kind == 'string':
        if not isinstance(value, str):
            return f'{path}: wrong JSON type'
        if 'enum' in schema and value not in schema['enum']:
            return f'{path}: invalid choice'
        if len(value) < schema.get('minLength', 0) or len(value) > schema.get('maxLength', 10**9):
            return f'{path}: wrong length'
        return None
    if kind in ('number', 'integer'):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return f'{path}: wrong JSON type'
        if kind == 'integer' and float(value) != int(value):
            return f'{path}: not an integer'
        if 'minimum' in schema and not schema['minimum'] <= value <= schema['maximum']:
            return f'{path}: out of range'
        return None
    if kind == 'boolean':
        return None if isinstance(value, bool) else f'{path}: wrong JSON type'
    if kind == 'array':
        if not isinstance(value, list):
            return f'{path}: wrong JSON type'
        return next((p for i, v in enumerate(value) if (p := validate(schema['items'], v, f'{path}[{i}]'))), None)
    if kind == 'object':
        if not isinstance(value, dict) or set(value) != set(schema.get('properties', {})):
            return f'{path}: fields must match schema'
        return next((p for k, s in schema['properties'].items() if (p := validate(s, value[k], f'{path}.{k}'))), None)
    return f'{path}: unsupported schema'


def serve(app, port=0):
    """Start a threaded loopback server for `app`; returns the server (port in server_address[1])."""
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            for line in self.rfile:
                try:
                    request = json.loads(line)
                    response = app.handle(request)
                except ValueError:
                    response = {'ok': False, 'error': 'invalid_json_request'}
                self.wfile.write((json.dumps(response) + '\n').encode())
                self.wfile.flush()

    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = Server(('127.0.0.1', port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=int(os.environ.get('TCA_HARNESS_PORT', '0')))
    for flag in ('bug', 'strand-on-error', 'crashy', 'stuck', 'unseeded-ids', 'ui', 'v2', 'late-issue', 'launch-load',
                 'launch-fetch', 'fragile-launch', 'race-save', 'search', 'stale-search', 'quiet-search'):
        parser.add_argument('--' + flag, action='store_true')
    arguments = parser.parse_args()
    seed = os.environ.get('TCA_HARNESS_SEED')
    app = FakeShelf(bug=arguments.bug, strand=arguments.strand_on_error, crashy=arguments.crashy, stuck=arguments.stuck,
                    unseeded=arguments.unseeded_ids, ui=arguments.ui, v2=arguments.v2,
                    network=os.environ.get('TCA_HARNESS_NETWORK'), cassettes=os.environ.get('TCA_HARNESS_CASSETTES'),
                    seed=int(seed) if seed else None, late=arguments.late_issue,
                    faults=json.loads(os.environ.get('TCA_HARNESS_FAULTS') or '[]'), race_save=arguments.race_save,
                    search='stale' if arguments.stale_search else 'ok' if arguments.search else None,
                    latency=json.loads(os.environ.get('TCA_HARNESS_LATENCY') or 'null'))
    app.quiet_search = arguments.quiet_search
    if arguments.launch_fetch or arguments.fragile_launch:
        ok, _ = app.request('GET', '/books')  # Before listening, like a host that loads first.
        if not ok:
            app.state['shelf']['error'] = "Couldn't load"
            app.state['shelf']['stranded'] = arguments.fragile_launch
    if arguments.launch_load:
        app.later(0.15, lambda: app.state['shelf']['books'].append({'id': 'launch', 'title': 'Launch', 'isRead': False}))
    server = serve(app, arguments.port)
    print('some startup noise', file=sys.stderr, flush=True)
    print(f'TCA harness listening on 127.0.0.1:{server.server_address[1]}', file=sys.stderr, flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
