"""`tca ls` and `tca do` against a fake harness host; no app, network or model needed."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('tca_short_commands', Path(__file__).parents[1] / 'tca.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

ROOT, HOME, SETTINGS = 'I-ROOT', 'I-HOME', 'I-SETTINGS'


def candidate(feature, instance, name, label, schema=None):
    item = {'id': f'{feature}/{name}@{instance}', 'feature': feature, 'instanceID': instance, 'label': label}
    if schema:
        item['argumentSchema'] = schema
    return item


VOLUME = {'type': 'object', 'additionalProperties': False, 'required': ['value'],
          'properties': {'value': {'type': 'number'}}}


class FakeHost:
    """Isowords-shaped: Home presents a Settings sheet; Home lends the sheet's close operation."""

    def __init__(self, settings_open=True, wait_status='succeeded'):
        self.settings_open = settings_open
        self.wait_status = wait_status
        self.revision = 3
        self.calls = []
        self.observation = self.observe()

    def features(self):
        features = [('root', 'isowords', ROOT), ('root/home', 'Home', HOME)]
        if self.settings_open:
            features.append(('root/home/settings', 'Settings', SETTINGS))
        return features

    def observe(self):
        candidates = []
        if self.settings_open:
            candidates += [
                candidate('root/home/settings', SETTINGS, 'setMusicVolume', 'Set music volume', VOLUME),
                candidate('root/home/settings', SETTINGS, 'disableHaptics', 'Disable haptics'),
                candidate('root/home/settings', SETTINGS, 'binding/colorScheme/dark', 'Set color scheme to dark'),
                candidate('root/home', HOME, 'dismissSheet', 'Close the current Home sheet and return Home'),
            ]
        else:
            candidates += [candidate('root/home', HOME, 'openSolo', 'Open Solo game modes'),
                           candidate('root/home', HOME, 'openSettings', 'Open Settings')]
        state = {'game': None, 'home': {'soloOpen': False, 'settingsOpen': self.settings_open,
                                        'settings': {'musicVolume': 0.5, 'haptics': True} if self.settings_open else None}}
        self.observation = {'sessionID': 'session', 'revision': self.revision, 'state': state, 'candidates': candidates}
        return self.observation

    def call(self, method, **arguments):
        self.calls.append((method, arguments))
        if method == 'observe':
            return {'ok': True, 'observation': self.observe()}
        if method == 'inspect':
            observation = self.observe()
            return {'ok': True, 'protocolVersion': 2, 'diagnostics': [], 'features': [
                {'path': path, 'name': name, 'instanceID': instance,
                 'operations': [c for c in observation['candidates'] if c['feature'] == path]}
                for path, name, instance in self.features()]}
        if method == 'dispatch':
            assert arguments['revision'] == self.revision, 'do must dispatch at the observed revision'
            ids = [c['id'] for c in self.observe()['candidates']]
            if arguments['candidateID'] not in ids:
                return {'ok': False, 'error': 'unavailable_candidate'}
            if arguments['candidateID'].startswith('root/home/dismissSheet'):
                self.settings_open = False
            self.revision += 1
            status = 'running' if 'setMusicVolume' in arguments['candidateID'] else 'succeeded'
            return {'ok': True, 'observation': self.observe(),
                    'receipt': {'requestID': arguments['requestID'], 'candidateID': arguments['candidateID'], 'status': status}}
        if method == 'wait':
            if self.wait_status == 'timeout':
                return {'ok': False, 'error': 'wait_timeout', 'observation': self.observe(),
                        'receipt': {'requestID': arguments['requestID'], 'status': 'running'}}
            return {'ok': True, 'observation': self.observe(),
                    'receipt': {'requestID': arguments['requestID'], 'status': self.wait_status}}
        raise AssertionError(method)

    def close(self):
        self.closed = True


def run(function, *arguments, **keywords):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = function(*arguments, **keywords)
    return code, out.getvalue(), err.getvalue()


def dispatched(host):
    return [arguments for method, arguments in host.calls if method == 'dispatch']


class FocusTests(unittest.TestCase):
    def test_focuses_the_deepest_feature_with_lent_ancestor_operations(self):
        host = FakeHost()
        view = cli.focus_view(host.observe(), cli.mounted_features(host))
        self.assertEqual(view['focus'], 'root/home/settings')
        self.assertEqual(view['name'], 'Settings')
        self.assertEqual(view['state'], {'musicVolume': 0.5, 'haptics': True})
        self.assertEqual([(o['name'], o['scope']) for o in view['operations']], [
            ('setMusicVolume', 'focused'), ('disableHaptics', 'focused'),
            ('binding/colorScheme/dark', 'focused'), ('dismissSheet', 'lent')])
        self.assertEqual(view['hidden'], 0)

    def test_text_output_lists_state_actions_and_lent_actions(self):
        code, out, _ = run(cli.list_command, FakeHost())
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith('Settings (root/home/settings)  revision 3'))
        self.assertIn('"musicVolume": 0.5', out)
        self.assertIn('  setMusicVolume  - Set music volume  {value: number}', out)
        self.assertIn('From root/home:\n  dismissSheet  - Close the current Home sheet and return Home', out)
        self.assertNotIn('\033', out)

    def test_json_output_is_machine_readable(self):
        code, out, _ = run(cli.list_command, FakeHost(), as_json=True)
        view = json.loads(out)
        self.assertEqual(code, 0)
        self.assertEqual(view['focus'], 'root/home/settings')
        self.assertEqual(view['operations'][0]['argumentSchema'], VOLUME)

    def test_explicit_path_and_all(self):
        host = FakeHost()
        view = cli.focus_view(host.observe(), cli.mounted_features(host), path='root/home', show_all=True)
        self.assertEqual(view['focus'], 'root/home')
        self.assertEqual([o['scope'] for o in view['operations']], ['focused', 'other', 'other', 'other'])
        self.assertIn('rootState', view)
        with self.assertRaisesRegex(RuntimeError, 'No mounted feature at root/nope'):
            cli.focus_view(host.observe(), cli.mounted_features(host), path='root/nope')

    def test_hidden_operations_are_counted(self):
        observation = FakeHost().observe()
        features = [('root', 'Root'), ('root/home', 'Home'), ('root/home/settings', 'Settings'), ('root/game', 'Game')]
        observation['candidates'].append(candidate('root/game', 'I-GAME', 'menu', 'Open the game menu'))
        view = cli.focus_view(observation, features)
        self.assertEqual(view['hidden'], 1)
        self.assertIn('1 more operation(s) elsewhere; use --all', cli.format_view(view))

    def test_ties_prefer_the_feature_with_operations_else_the_common_ancestor(self):
        self.assertEqual(cli.choose_focus(['root', 'root/home', 'root/game'], {'root/game'}), ('root/game', {'root/game'}))
        focus, focused = cli.choose_focus(['root', 'root/todos/a', 'root/todos/b'], {'root/todos/a', 'root/todos/b'})
        self.assertEqual(focus, 'root/todos')
        self.assertEqual(focused, {'root/todos', 'root/todos/a', 'root/todos/b'})

    def test_state_lookup_handles_collections_enums_and_missing_paths(self):
        state = {'todos': [{'id': 'a b', 'title': 'A'}], 'destination': {'case': 'edit', 'value': {'draft': 'x'}},
                 'path': [{'case': 'detail', 'value': {'id': 1}}]}
        self.assertEqual(cli.state_at(state, 'root/todos/a%20b'), ({'id': 'a b', 'title': 'A'}, 'root/todos/a%20b'))
        self.assertEqual(cli.state_at(state, 'root/destination/edit'), ({'draft': 'x'}, 'root/destination/edit'))
        self.assertEqual(cli.state_at(state, 'root/destination'), (state['destination'], 'root/destination'))
        self.assertEqual(cli.state_at(state, 'root/path/0')[1], 'root/path/0')
        self.assertEqual(cli.state_at(state, 'root/missing/x'), (state, 'root'))

    def test_falls_back_to_candidate_features_without_inspection(self):
        class NoInspect(FakeHost):
            def call(self, method, **arguments):
                if method == 'inspect':
                    return {'ok': False, 'error': 'inspection_unavailable'}
                return super().call(method, **arguments)
        host = NoInspect()
        self.assertEqual(cli.focus_view(host.observe(), cli.mounted_features(host))['focus'], 'root/home/settings')


class DoTests(unittest.TestCase):
    def test_label_is_resolved_case_insensitively_and_lent_actions_dispatch(self):
        host = FakeHost()
        code, out, _ = run(cli.do_command, host, 'close the current home sheet and return home')
        self.assertEqual(code, 0)
        self.assertEqual(dispatched(host)[0]['candidateID'], 'root/home/dismissSheet@I-HOME')
        self.assertEqual(dispatched(host)[0]['revision'], 3)
        self.assertEqual(dispatched(host)[0]['arguments'], {})
        self.assertTrue(out.startswith('dismissSheet: succeeded\n\nHome (root/home)  revision 4'))
        self.assertIn('openSettings  - Open Settings', out)

    def test_name_with_arguments_waits_for_the_receipt(self):
        host = FakeHost()
        code, out, _ = run(cli.do_command, host, 'SETMUSICVOLUME', {'value': 0.25}, as_json=True)
        result = json.loads(out)
        self.assertEqual(code, 0)
        self.assertEqual(dispatched(host)[0]['arguments'], {'value': 0.25})
        self.assertIn('wait', [method for method, _ in host.calls])
        self.assertEqual(result['receipt']['status'], 'succeeded')
        self.assertEqual(result['view']['focus'], 'root/home/settings')

    def test_exact_id_and_route_resolve_even_outside_the_focus(self):
        host = FakeHost()
        observation = host.observe()
        view = cli.focus_view(observation, cli.mounted_features(host))
        self.assertEqual(cli.resolve_operation(view, observation, 'root/home/settings/disableHaptics')[0]['id'],
                         'root/home/settings/disableHaptics@I-SETTINGS')
        self.assertEqual(cli.resolve_operation(view, observation, 'root/home/dismissSheet@I-HOME')[0]['feature'], 'root/home')

    def test_no_match_lists_choices_and_never_dispatches(self):
        host = FakeHost()
        code, out, err = run(cli.do_command, host, 'openSolo')
        self.assertEqual(code, 2)
        self.assertEqual(out, '')
        self.assertIn("No action matching 'openSolo'", err)
        self.assertIn('dismissSheet  - Close the current Home sheet', err)
        self.assertEqual(dispatched(host), [])

    def test_ambiguity_lists_matches_and_never_dispatches(self):
        host = FakeHost()
        host.call = lambda method, _call=host.call, **kw: self.duplicate(_call(method, **kw))
        code, out, _ = run(cli.do_command, host, 'disablehaptics', as_json=True)
        result = json.loads(out)
        self.assertEqual(code, 2)
        self.assertEqual(result['error'], 'ambiguous')
        self.assertEqual(len(result['choices']), 2)
        self.assertEqual(dispatched(host), [])

    @staticmethod
    def duplicate(response):
        # A second instance offering the same operation name (e.g. two list rows).
        observation = response.get('observation')
        if observation:
            extra = copy.deepcopy(observation['candidates'][1])
            extra['id'] = extra['id'].replace('I-SETTINGS', 'I-OTHER')
            observation['candidates'].append(extra)
        return response

    def test_failed_receipt_and_wait_timeout_exit_nonzero(self):
        code, _, err = run(cli.do_command, FakeHost(wait_status='failed'), 'setMusicVolume', {'value': 1})
        self.assertEqual(code, 2)
        code, out, err = run(cli.do_command, FakeHost(wait_status='timeout'), 'setMusicVolume', {'value': 1})
        self.assertEqual(code, 2)
        self.assertIn('wait_timeout', err)
        self.assertIn('Settings (root/home/settings)', out)

    def test_navigation_that_closes_the_dispatching_feature_is_not_a_failure(self):
        # Real isowords: Solo's startUnlimited mounts Game and unmounts Solo, so the receipt reads `cancelled`.
        class Navigating(FakeHost):
            def call(self, method, **arguments):
                response = super().call(method, **arguments)
                if method == 'dispatch' and 'disableHaptics' in arguments['candidateID']:
                    self.settings_open = False
                    response = dict(response, observation=self.observe(), receipt=dict(response['receipt'], status='cancelled'))
                return response
        code, out, err = run(cli.do_command, Navigating(), 'disableHaptics')
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('disableHaptics: sent; root/home/settings closed (receipt cancelled)\n\nHome (root/home)'))
        code, out, _ = run(cli.do_command, Navigating(), 'disableHaptics', as_json=True)
        result = json.loads(out)
        self.assertEqual((code, result['ok'], result['receipt']['featureClosed']), (0, True, True))
        # A cancelled receipt while the feature stays mounted is still a failure.
        code, _, _ = run(cli.do_command, FakeHost(wait_status='cancelled'), 'setMusicVolume', {'value': 1})
        self.assertEqual(code, 2)

    def test_rejected_dispatch_reports_the_error(self):
        class Rejecting(FakeHost):
            def call(self, method, **arguments):
                if method == 'dispatch':
                    self.calls.append((method, arguments))
                    return {'ok': False, 'error': 'invalid_arguments', 'detail': 'value is required'}
                return super().call(method, **arguments)
        code, out, err = run(cli.do_command, Rejecting(), 'setMusicVolume')
        self.assertEqual(code, 2)
        self.assertIn('setMusicVolume: invalid_arguments: value is required', err)
        self.assertEqual(out, '')


class ArgumentParsingTests(unittest.TestCase):
    def main(self, argv, host):
        from unittest.mock import patch
        with patch.object(cli, 'Host', return_value=host), patch.object(cli, 'build') as build:
            code, out, err = run(cli.main, argv)
        build.assert_not_called()
        self.assertTrue(host.closed)
        return code, out, err

    def test_do_accepts_positional_json_and_options_in_any_order(self):
        host = FakeHost()
        code, _, _ = self.main(['do', 'setMusicVolume', '--port', '8767', '{"value": 0.75}'], host)
        self.assertEqual(code, 0)
        self.assertEqual(dispatched(host)[0]['arguments'], {'value': 0.75})

    def test_ls_connects_to_the_app(self):
        code, out, _ = self.main(['ls', '--json'], FakeHost())
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)['focus'], 'root/home/settings')

    def test_do_rejects_non_object_arguments(self):
        with self.assertRaises(SystemExit):
            self.main(['do', 'setMusicVolume', '[1]'], FakeHost())


if __name__ == '__main__':
    unittest.main()
