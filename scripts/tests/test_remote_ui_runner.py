import importlib.util
import json
import os
from pathlib import Path
import subprocess
import signal
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
                return execution.call_args.kwargs['input']

    def test_cleanup_refuses_a_product_or_another_workspace(self):
        script = self.execute(0)
        cleanup = script.split("python3 - <<'PY_CLEANUP'\n", 1)[1].split('\nPY_CLEANUP\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'reports').mkdir()
            for app, identifier in [(root / 'Product.app', 'com.apexterm'),
                                    (root.parent / 'Other.app', 'com.apexterm.qa.other')]:
                with self.subTest(identifier=identifier):
                    (root / 'reports/qa-host.json').write_text(json.dumps({'path': str(app), 'bundleIdentifier': identifier}))
                    with patch.object(Path, 'cwd', return_value=root), patch('os.kill') as kill, patch('subprocess.check_output') as processes:
                        with self.assertRaises(SystemExit):
                            exec(cleanup, {})
                        kill.assert_not_called()
                        processes.assert_not_called()

    def test_cleanup_stops_only_owned_host_and_ssh_descendants(self):
        script = self.execute(0)
        cleanup = script.split("python3 - <<'PY_CLEANUP'\n", 1)[1].split('\nPY_CLEANUP\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = root / 'Verification.app'
            (root / 'reports').mkdir()
            (root / 'reports/qa-host.json').write_text(json.dumps({'path': str(app), 'bundleIdentifier': 'com.apexterm.qa.synthetic'}))
            rows = f'100 1 {app}/Contents/MacOS/Verification\n110 100 /usr/bin/ssh\n130 110 /usr/bin/scp\n140 100 /usr/bin/cat\n200 1 /Applications/Product.app/Contents/MacOS/Verification\n210 200 /usr/bin/ssh\n'
            with patch.object(Path, 'cwd', return_value=root), patch('os.kill') as kill, patch('subprocess.check_output', return_value=rows):
                exec(cleanup, {})
                self.assertEqual(kill.call_args_list, [unittest.mock.call(110, signal.SIGKILL), unittest.mock.call(130, signal.SIGKILL), unittest.mock.call(100, signal.SIGTERM)])
            record = json.loads((root / 'reports/qa-cleanup.json').read_text())
            self.assertEqual(record['ownedHostPIDs'], [100])
            self.assertEqual(record['ownedChildPIDs'], [110, 130])

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

    def test_missing_or_empty_report_stops_before_transport(self):
        for arguments in [['runner'], ['runner', ''], ['runner', '   ']]:
            with self.subTest(arguments=arguments), patch.object(runner.sys, 'argv', arguments), patch.object(runner, 'run') as transport:
                with self.assertRaises(ValueError):
                    runner.main()
                transport.assert_not_called()

    def test_repository_report_stops_before_transport(self):
        root = Path(runner.__file__).resolve().parents[1]
        with patch.object(runner.sys, 'argv', ['runner', str(root)]), patch.object(runner, 'run') as transport:
            with self.assertRaises(ValueError):
                runner.main()
            transport.assert_not_called()
