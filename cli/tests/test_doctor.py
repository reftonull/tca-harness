import copy
import io
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('tca_cli', Path(__file__).parents[1] / 'tca.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class Host:
    def __init__(self, response, timeline=None):
        self.response = response
        self.timeline = timeline or {'ok': False, 'error': 'timeline_unavailable'}
        self.calls = []

    def call(self, method, **_):
        self.calls.append(method)
        return self.timeline if method == 'timeline' else self.response


def healthy():
    return {'ok': True, 'protocolVersion': 2, 'diagnostics': [], 'features': [
        {'path': 'root', 'name': 'Root', 'instanceID': 'instance-1', 'operations': [
            {'id': 'root/increment@instance-1', 'feature': 'root', 'instanceID': 'instance-1'}]}]}


class DoctorTests(unittest.TestCase):
    def test_inspection_never_mutates_or_calls_models(self):
        host = Host(healthy())
        result = cli.doctor(host)
        self.assertTrue(result['ok'])
        self.assertEqual(host.calls, ['inspect', 'timeline'])
        self.assertEqual(result['operations'], 1)
        self.assertEqual(result['timeline'], 'not recording')

    def test_reports_a_recording_timeline(self):
        page = {'ok': True, 'timeline': {'detail': 'projected', 'entries': []}}
        result = cli.doctor(Host(healthy(), timeline=page))
        self.assertTrue(result['ok'])
        self.assertEqual(result['timeline'], 'recording (projected)')

    def test_server_diagnostics_reach_the_integrator(self):
        response = healthy()
        response['diagnostics'] = ['Duplicate operation: root/edit']
        result = cli.doctor(Host(response))
        self.assertFalse(result['ok'])
        self.assertIn('Duplicate operation: root/edit', result['errors'])

    def test_missing_runtime_explains_attachment(self):
        result = cli.doctor(Host({'ok': False, 'error': 'inspection_unavailable'}))
        self.assertFalse(result['ok'])
        self.assertIn('store.harness', result['errors'][0])

    def test_wrong_instance_and_duplicate_operations_are_rejected(self):
        response = healthy()
        operations = response['features'][0]['operations']
        operations.append(copy.deepcopy(operations[0]))
        operations[0]['instanceID'] = 'old-instance'
        result = cli.doctor(Host(response))
        self.assertFalse(result['ok'])
        self.assertTrue(any('Duplicate operation' in x for x in result['errors']))
        self.assertTrue(any('mounted feature' in x for x in result['errors']))

    def test_empty_available_operations_is_a_warning(self):
        response = healthy()
        response['features'][0]['operations'] = []
        result = cli.doctor(Host(response))
        self.assertTrue(result['ok'])
        self.assertTrue(result['warnings'])

    def test_missing_root_and_unknown_protocol_fail(self):
        response = healthy()
        response['features'] = []
        response['protocolVersion'] = 999
        self.assertFalse(cli.doctor(Host(response))['ok'])


class ConnectionDiagnosisTests(unittest.TestCase):
    def test_non_harness_endpoint_is_explained_and_closed(self):
        for data, message in [(b'HTTP/1.1 200 OK\r\n', 'valid harness JSON'),
                              (b'{"ok":true}\n', 'harness observation')]:
            connection = Mock()
            connection.makefile.return_value = io.BytesIO(data)
            with patch.object(cli.socket, 'create_connection', return_value=connection):
                with self.assertRaisesRegex(RuntimeError, message):
                    cli.Host(port=8767)
            connection.close.assert_called_once()

    def test_connection_failure_suggests_launch_and_retention(self):
        with patch.object(cli.socket, 'create_connection', side_effect=ConnectionRefusedError()):
            with self.assertRaisesRegex(RuntimeError, 'TCA_HARNESS=1.*retain'):
                cli.Host(port=8767)
