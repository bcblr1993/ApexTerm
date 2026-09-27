import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('remote_ui', Path(__file__).resolve().parents[1] / 'run_ui_tests_remotely.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RemoteUIRunnerTests(unittest.TestCase):
    def execute(self, exit_code):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {'APEX_UI_RUNNER_HOST': '192.0.2.10', 'APEX_UI_RUNNER_USER': 'synthetic'}), \
                 patch.object(runner.sys, 'argv', ['runner', directory]), \
                 patch.object(runner, 'run', return_value=subprocess.CompletedProcess([], 0, '/Users/synthetic/apex-ui-run.test\n')) as transport, \
                 patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], exit_code)) as execution:
                if exit_code:
                    with self.assertRaises(subprocess.CalledProcessError):
                        runner.main()
                else:
                    runner.main()
                command = execution.call_args.args[0]
                self.assertIn('-A', command)
                self.assertIn('test-without-building', execution.call_args.kwargs['input'])
                self.assertIn('SSH_AUTH_SOCK', execution.call_args.kwargs['input'])
                collections = [call.args[0] for call in transport.call_args_list if call.args[0][0] == 'scp']
                self.assertIn('/results.tar.gz', collections[-1][-2])
                self.assertEqual(collections[-1][-1], str(Path(directory).resolve() / 'remote-results.tar.gz'))
                self.assertEqual(transport.call_args.args[0][0], 'tar')
                self.assertTrue((Path(directory) / 'guest-workspace.txt').exists())

    def test_success_collects_result_bundle(self):
        self.execute(0)

    def test_failure_collects_result_bundle_and_stops_gate(self):
        self.execute(65)

    def test_invalid_target_stops_before_creating_guest_files(self):
        with patch.dict(os.environ, {'APEX_UI_RUNNER_HOST': 'invalid;command', 'APEX_UI_RUNNER_USER': 'synthetic'}), \
             patch.object(runner.sys, 'argv', ['runner', '/tmp/synthetic']), \
             patch.object(runner, 'run') as transport:
            with self.assertRaises(ValueError):
                runner.main()
            transport.assert_not_called()
