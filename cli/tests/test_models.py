"""Model providers and `tca setup`, with the network mocked; no credentials or live calls."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location('tca_models', Path(__file__).parents[1] / 'tca.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

SECRET = 'sk-test-never-printed'
OBSERVATION = {'revision': 1, 'sessionID': 's', 'state': {'volume': 0.5}, 'candidates': [
    {'id': 'root/save@i', 'feature': 'root', 'label': 'Save'},
    {'id': 'root/setVolume@i', 'feature': 'root', 'label': 'Set volume', 'argumentSchema': {
        'type': 'object', 'additionalProperties': False, 'required': ['value'], 'properties': {'value': {'type': 'number'}}}},
]}


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def responses_body(value, model='served-model'):
    return {'status': 'completed', 'model': model, 'usage': {'output_tokens': 3},
            'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': json.dumps(value)}]}]}


class Network:
    """Records requests and replies with queued JSON bodies (or exceptions)."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.requests = []

    def __call__(self, request, timeout):
        self.requests.append(dict(url=request.full_url, headers=dict(request.header_items()),
                                  body=json.loads(request.data)))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return Response(json.dumps(reply).encode())


class ConfiguredTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        environment = patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.home), 'HOME': str(self.home)}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)

    def network(self, *replies):
        network = Network(*replies)
        patcher = patch.object(cli.urllib.request, 'urlopen', network)
        patcher.start()
        self.addCleanup(patcher.stop)
        return network


class RouterProviderTests(ConfiguredTest):
    def setUp(self):
        super().setUp()
        os.environ['RAMP_ROUTER_API_KEY'] = SECRET

    def test_choice_uses_the_classifier_and_keeps_confidence(self):
        network = self.network({'model': 'classifier-x', 'answers': {'next_action': {
            'choice': 'root/save@i', 'confidence': 0.9, 'probabilities': {'root/save@i': 0.8}}}})
        decision = cli.decide(OBSERVATION, 'Save it')
        request = network.requests[0]
        self.assertEqual(request['url'], 'https://api.router.com/v1/systemone')
        self.assertEqual(request['headers']['Authorization'], 'Bearer ' + SECRET)
        self.assertEqual(request['body']['model'], cli.ROUTER_CHOICE_MODEL)
        question = request['body']['questions']['next_action']
        self.assertEqual(question['type'], 'choice')
        self.assertEqual(set(question['criteria']), {'root/save@i', 'root/setVolume@i', 'none'})
        self.assertEqual(request['body']['state'], {'goal': 'Save it', 'application': {'volume': 0.5}})
        self.assertEqual((decision['choice'], decision['confidence'], decision['probability'], decision['model']),
                         ('root/save@i', 0.9, 0.8, 'classifier-x'))
        self.assertEqual(decision['provider'], 'router')
        self.assertIn('latencyMs', decision)

    def test_unoffered_choice_is_rejected(self):
        self.network({'answers': {'next_action': {'choice': 'root/delete@i'}}})
        with self.assertRaisesRegex(RuntimeError, 'unoffered'):
            cli.decide(OBSERVATION, 'Delete it')

    def test_base_url_override_and_argument_model_default(self):
        os.environ['RAMP_ROUTER_BASE_URL'] = 'https://router.example/v2/'
        network = self.network(responses_body({'value': 0.25}))
        generated = cli.extract_arguments(OBSERVATION, OBSERVATION['candidates'][1], 'Quarter volume')
        request = network.requests[0]
        self.assertEqual(request['url'], 'https://router.example/v2/responses')
        self.assertEqual(request['body']['model'], cli.ROUTER_ARGUMENT_MODEL)
        self.assertEqual(request['body']['text']['format']['schema'], OBSERVATION['candidates'][1]['argumentSchema'])
        self.assertTrue(request['body']['text']['format']['strict'])
        self.assertEqual(generated['arguments'], {'value': 0.25})

    def test_http_errors_never_include_bodies_or_credentials(self):
        body = io.BytesIO(('{"echo": "Bearer ' + SECRET + '"}').encode())
        self.network(urllib.error.HTTPError('https://api.router.com/v1/systemone', 401, 'Unauthorized', {}, body))
        with self.assertRaises(RuntimeError) as raised:
            cli.decide(OBSERVATION, 'Save')
        self.assertEqual(str(raised.exception), 'Choice model returned HTTP 401')
        self.assertIsNone(raised.exception.__cause__)


class ResponsesProviderTests(ConfiguredTest):
    def setUp(self):
        super().setUp()
        os.environ.update(TCA_HARNESS_MODEL_API_KEY=SECRET, TCA_HARNESS_MODEL='gpt-test',
                          TCA_HARNESS_MODEL_BASE_URL='https://llm.example/v1')

    def test_choice_is_a_strict_enum_of_offered_ids_plus_none(self):
        network = self.network(responses_body({'choice': 'none'}))
        decision = cli.decide(OBSERVATION, 'Already done')
        request = network.requests[0]
        self.assertEqual(request['url'], 'https://llm.example/v1/responses')
        self.assertEqual(request['body']['model'], 'gpt-test')
        response_format = request['body']['text']['format']
        self.assertEqual(response_format['type'], 'json_schema')
        self.assertTrue(response_format['strict'])
        self.assertEqual(response_format['schema']['properties']['choice']['enum'],
                         ['root/save@i', 'root/setVolume@i', 'none'])
        self.assertFalse(response_format['schema']['additionalProperties'])
        self.assertEqual(decision['choice'], 'none')
        self.assertIsNone(decision['confidence'])
        self.assertIsNone(decision['probability'])
        self.assertEqual(decision['model'], 'served-model')

    def test_unoffered_or_malformed_choices_are_rejected(self):
        self.network(responses_body({'choice': 'root/delete@i'}), {'status': 'completed', 'output': []},
                     {'status': 'incomplete', 'output': []})
        with self.assertRaisesRegex(RuntimeError, 'unoffered'):
            cli.decide(OBSERVATION, 'Delete')
        with self.assertRaisesRegex(RuntimeError, 'no valid JSON'):
            cli.decide(OBSERVATION, 'Delete')
        with self.assertRaisesRegex(RuntimeError, 'did not complete'):
            cli.decide(OBSERVATION, 'Delete')

    def test_explicit_models_override_the_configured_one(self):
        network = self.network(responses_body({'choice': 'root/save@i'}), responses_body({'value': 1}))
        cli.decide(OBSERVATION, 'Save', model='chooser')
        cli.extract_arguments(OBSERVATION, OBSERVATION['candidates'][1], 'Max', model='filler')
        self.assertEqual([r['body']['model'] for r in network.requests], ['chooser', 'filler'])

    def test_invalid_arguments_never_dispatch(self):
        class Host:
            observation = OBSERVATION

            def call(self, method, **_):
                return {'ok': True, 'observation': OBSERVATION}

            def dispatch(self, *_, **__):
                raise AssertionError('dispatched despite failed argument generation')

        self.network(responses_body({'choice': 'root/setVolume@i'}), responses_body({'wrong': 1}))
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, 'no action dispatched'):
            cli.run_goal(Host(), 'Set volume', None, None, 1)
        self.network(urllib.error.URLError('down'))
        with self.assertRaisesRegex(RuntimeError, 'connection failed; no action dispatched'):
            cli.extract_arguments(OBSERVATION, OBSERVATION['candidates'][1], 'Max')

    def test_missing_model_is_explained(self):
        del os.environ['TCA_HARNESS_MODEL']
        with self.assertRaisesRegex(RuntimeError, '--model or set TCA_HARNESS_MODEL'):
            cli.decide(OBSERVATION, 'Save')


class ConfigurationTests(ConfiguredTest):
    def test_missing_key_points_to_setup(self):
        with self.assertRaisesRegex(RuntimeError, 'tca setup.*TCA_HARNESS_MODEL_API_KEY'):
            cli.model_config()
        with self.assertRaisesRegex(RuntimeError, 'RAMP_ROUTER_API_KEY'):
            cli.model_config('router')

    def test_environment_overrides_the_file(self):
        cli.write_config(cli.config_path(), {'TCA_HARNESS_MODEL_PROVIDER': 'responses', 'TCA_HARNESS_MODEL_API_KEY': 'file-key',
                                             'TCA_HARNESS_MODEL': 'file-model', 'RAMP_ROUTER_API_KEY': 'router-file-key'})
        config = cli.model_config()
        self.assertEqual((config['provider'], config['api_key'], config['choice_model']), ('responses', 'file-key', 'file-model'))
        self.assertEqual(config['base_url'], cli.DEFAULT_BASE_URLS['responses'])
        os.environ.update(TCA_HARNESS_MODEL_PROVIDER='router', RAMP_ROUTER_API_KEY='env-key')
        config = cli.model_config()
        self.assertEqual((config['provider'], config['api_key'], config['choice_model']),
                         ('router', 'env-key', cli.ROUTER_CHOICE_MODEL))
        self.assertEqual(cli.model_config('responses')['api_key'], 'file-key')

    def test_router_is_inferred_from_an_existing_router_key(self):
        os.environ['RAMP_ROUTER_API_KEY'] = SECRET
        self.assertEqual(cli.model_config()['provider'], 'router')


class SetupTests(ConfiguredTest):
    def run_main(self, argv, stdin_text):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(cli.sys, 'stdin', io.StringIO(stdin_text)), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_non_interactive_setup_writes_a_private_file_and_prints_only_the_path(self):
        code, out, err = self.run_main(['setup', '--provider', 'responses', '--base-url', 'https://llm.example/v1/',
                                        '--model', 'gpt-test', '--api-key-stdin'], SECRET + '\n')
        path = self.home / 'tca-harness' / 'model.env'
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), str(path))
        self.assertNotIn(SECRET, out + err)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertEqual(cli.read_config_file(path), {
            'TCA_HARNESS_MODEL_PROVIDER': 'responses', 'TCA_HARNESS_MODEL': 'gpt-test',
            'TCA_HARNESS_MODEL_API_KEY': SECRET, 'TCA_HARNESS_MODEL_BASE_URL': 'https://llm.example/v1'})
        config = cli.model_config()
        self.assertEqual((config['provider'], config['base_url'], config['api_key']),
                         ('responses', 'https://llm.example/v1', SECRET))

    def test_router_setup_uses_the_default_url_and_keeps_other_settings(self):
        self.run_main(['setup', '--provider', 'responses', '--model', 'gpt-test', '--api-key-stdin'], 'responses-key')
        code, _, _ = self.run_main(['setup', '--provider', 'router', '--api-key-stdin'], 'router-key')
        values = cli.read_config_file(cli.config_path())
        self.assertEqual(code, 0)
        self.assertEqual(values['TCA_HARNESS_MODEL_PROVIDER'], 'router')
        self.assertEqual(values['RAMP_ROUTER_BASE_URL'], 'https://api.router.com/v1')
        self.assertEqual(values['RAMP_ROUTER_API_KEY'], 'router-key')
        self.assertEqual(values['TCA_HARNESS_MODEL_API_KEY'], 'responses-key')
        self.assertEqual(cli.model_config()['provider'], 'router')

    def test_non_interactive_setup_requires_provider_and_key(self):
        with self.assertRaisesRegex(RuntimeError, '--provider'):
            self.run_main(['setup', '--api-key-stdin'], 'key')
        with self.assertRaisesRegex(RuntimeError, 'No API key'):
            self.run_main(['setup', '--provider', 'router', '--api-key-stdin'], '\n')
        with self.assertRaisesRegex(RuntimeError, 'https://'):
            self.run_main(['setup', '--provider', 'router', '--base-url', 'ftp://x', '--api-key-stdin'], 'key')
        self.assertFalse(cli.config_path().exists())

    def test_interactive_setup_prompts_with_defaults_and_hides_the_key(self):
        class Terminal(io.StringIO):
            def isatty(self):
                return True

        questions, answers = [], iter(['router', '', ''])

        def prompt(question):
            questions.append(question)
            return next(answers)

        secret_prompts = []
        path = cli.setup(stdin=Terminal(), prompt=prompt, secret=lambda q: secret_prompts.append(q) or SECRET)
        self.assertEqual(questions, ['Provider (router or responses) [responses]: ',
                                     'Base URL [https://api.router.com/v1]: ',
                                     'Model ID (blank for Router defaults): '])
        self.assertEqual(len(secret_prompts), 1)
        self.assertEqual(cli.read_config_file(path)['RAMP_ROUTER_API_KEY'], SECRET)
        self.assertNotIn('TCA_HARNESS_MODEL', cli.read_config_file(path))


if __name__ == '__main__':
    unittest.main()
