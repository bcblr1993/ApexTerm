import importlib.util
import contextlib
import json
import os
import plistlib
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
    def permission_script(self):
        script = self.execute(0)
        return script.split("# Xcode's macOS UI runner", 1)[1].split('\nPY\n', 1)[0].split('import subprocess, tempfile', 1)[1]

    def test_runner_permissions_preserve_other_entitlements_and_product(self):
        script = self.permission_script()
        original = {'com.apple.security.app-sandbox': True, 'com.apple.security.get-task-allow': True,
                    'com.apple.security.temporary-exception.mach-lookup.local-name': ['com.apple.axserver']}
        expected = dict(original, **{'com.apple.security.app-sandbox': False})
        with tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
            root = Path(directory).resolve()
            (root / 'reports').mkdir()
            app = root / 'outputs/ui-acceptance/RemoteDerivedData/Build/Products/Debug/ApexTermUITests-Runner.app'
            app.mkdir(parents=True)
            product = root / 'Product.app'
            product.write_bytes(b'unchanged signed product')
            def sign(arguments, **kwargs):
                self.assertEqual(arguments[-1], str(app))
                if '--entitlements' in arguments:
                    payload = plistlib.loads(Path(arguments[arguments.index('--entitlements') + 1]).read_bytes())
                    self.assertEqual(payload, expected)
                return subprocess.CompletedProcess(arguments, 0)
            with patch('subprocess.check_output', side_effect=[plistlib.dumps(original), plistlib.dumps(expected)]), \
                 patch('subprocess.run', side_effect=sign) as commands:
                exec(script, {'pathlib': __import__('pathlib'), 'plistlib': plistlib, 'json': json,
                              'subprocess': subprocess, 'tempfile': tempfile})
            self.assertEqual(commands.call_count, 2)
            self.assertEqual(product.read_bytes(), b'unchanged signed product')
            self.assertFalse(json.loads((root / 'reports/ui-runner-entitlements.json').read_text())['sandboxed'])

    def test_runner_permissions_refuse_symlink_outside_workspace(self):
        script = self.permission_script()
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as external, contextlib.chdir(directory):
            app = Path('outputs/ui-acceptance/RemoteDerivedData/Build/Products/Debug/ApexTermUITests-Runner.app')
            app.parent.mkdir(parents=True)
            app.symlink_to(external, target_is_directory=True)
            with patch('subprocess.check_output') as inspect, patch('subprocess.run') as commands:
                with self.assertRaises(AssertionError):
                    exec(script, {'pathlib': __import__('pathlib'), 'plistlib': plistlib, 'json': json,
                                  'subprocess': subprocess, 'tempfile': tempfile})
            inspect.assert_not_called()
            commands.assert_not_called()

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
                self.assertIn("target['EnvironmentVariables']['APEX_UI_AGENT_SOCKET'] = os.environ['SSH_AUTH_SOCK']", execution.call_args.kwargs['input'])
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

    def test_desktop_lock_refuses_a_second_run_without_replacing_owner(self):
        script = self.execute(0)
        acquisition = script.split('LOCK_DIR=', 1)[1].split('cleanup_qa_host()', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, HOME=directory)
            command = ['bash', '-c', 'LOCK_DIR=' + acquisition + '\ntrap - EXIT']
            first = subprocess.run(command, env=environment, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            owner = Path(directory) / '.apexterm-ui-automation.lock/owner'
            original = owner.read_text()
            second = subprocess.run(command, env=environment, capture_output=True, text=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn('Another ApexTerm UI run', second.stderr)
            self.assertEqual(owner.read_text(), original)

    def test_desktop_lock_is_released_on_normal_exit(self):
        script = self.execute(0)
        acquisition = script.split('LOCK_DIR=', 1)[1].split('cleanup_qa_host()', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', '-c', 'LOCK_DIR=' + acquisition],
                                    env=dict(os.environ, HOME=directory), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((Path(directory) / '.apexterm-ui-automation.lock').exists())

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
