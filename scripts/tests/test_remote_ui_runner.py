import importlib.util
import contextlib
import json
import os
import plistlib
from pathlib import Path
import subprocess
import signal
import tempfile
import tarfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('remote_ui', Path(__file__).resolve().parents[1] / 'run_ui_tests_remotely.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RemoteUIRunnerTests(unittest.TestCase):
    @staticmethod
    def transport_result(arguments, **kwargs):
        if arguments[:2] == ['tart', 'ip']:
            return subprocess.CompletedProcess(arguments, 0, '192.0.2.10\n')
        if arguments[-1] == '/usr/sbin/sysctl -n hw.model':
            return subprocess.CompletedProcess(arguments, 0, 'VirtualMac2,1\n')
        return subprocess.CompletedProcess(arguments, 0, '/Users/synthetic/apex-ui-run.test\n')

    def test_external_report_fixture_survives_archive_round_trip(self):
        actual_run = subprocess.run
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, report, guest = base / 'repo', base / 'external-reports', base / 'guest'
            for name in ['UITests', 'outputs/ui-acceptance/DerivedData/Build/Products',
                         'outputs/macos27/qa/Verification.app', 'outputs/ui-acceptance/PhysicalKeyQA.app']:
                (root / name).mkdir(parents=True)
            executable = report / 'ApexTerm-Reopen.app/Contents/MacOS/ApexTerm'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'isolated reopen fixture')
            guest.mkdir()
            def transport(arguments, **kwargs):
                if arguments[0] == 'tar' and '-czf' in arguments:
                    return actual_run(arguments, **kwargs)
                return self.transport_result(arguments, **kwargs)
            with patch.dict(os.environ, {'APEX_UI_TEST_VM': 'macos27', 'APEX_UI_RUNNER_HOST': '192.0.2.10', 'APEX_UI_RUNNER_USER': 'synthetic'}), \
                 patch.object(runner, '__file__', str(root / 'scripts/run_ui_tests_remotely.py')), \
                 patch.object(runner.sys, 'argv', ['runner', str(report)]), \
                 patch.object(runner, 'run', side_effect=transport), \
                 patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
                runner.main()
            with tarfile.open(report / 'vm-input.tar.gz') as archive:
                archive.extractall(guest, filter='data')
            self.assertEqual((guest / 'ApexTerm-Reopen.app/Contents/MacOS/ApexTerm').read_bytes(), executable.read_bytes())

    def test_missing_or_other_vm_stops_before_any_transport(self):
        for vm in ('', 'macos26', 'another-vm'):
            with self.subTest(vm=vm), tempfile.TemporaryDirectory() as directory, \
                 patch.dict(os.environ, {'APEX_UI_TEST_VM': vm, 'APEX_UI_RUNNER_HOST': '192.0.2.10', 'APEX_UI_RUNNER_USER': 'synthetic'}), \
                 patch.object(runner.sys, 'argv', ['runner', directory]), \
                 patch.object(runner, 'run') as transport:
                with self.assertRaisesRegex(ValueError, 'macos27'):
                    runner.main()
                transport.assert_not_called()
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_selected_vm_refuses_conflicting_runner_before_transfer(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, {'APEX_UI_TEST_VM': 'macos27', 'APEX_UI_RUNNER_HOST': '192.0.2.10', 'APEX_UI_RUNNER_USER': 'synthetic'}), \
             patch.object(runner.sys, 'argv', ['runner', directory]), \
             patch.object(runner, 'run', return_value=subprocess.CompletedProcess([], 0, '192.0.2.11\n')) as transport:
            with self.assertRaisesRegex(ValueError, 'does not match'):
                runner.main()
            self.assertEqual(transport.call_count, 1)
            self.assertEqual(transport.call_args.args[0], ['tart', 'ip', 'macos27'])
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_selected_vm_refuses_physical_host_before_workspace_creation(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, {'APEX_UI_TEST_VM': 'macos27', 'APEX_UI_RUNNER_HOST': '', 'APEX_UI_RUNNER_USER': 'synthetic'}), \
             patch.object(runner.sys, 'argv', ['runner', directory]), \
             patch.object(runner, 'run', side_effect=[subprocess.CompletedProcess([], 0, '192.0.2.11\n'),
                                                   subprocess.CompletedProcess([], 0, 'Mac15,12\n')]) as transport:
            with self.assertRaisesRegex(ValueError, 'not a macOS virtual machine'):
                runner.main()
            self.assertEqual(transport.call_count, 2)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_explicit_real_target_transfers_only_required_values(self):
        with patch.dict(os.environ, {'APEX_UI_TEST_HOST': '192.0.2.25', 'APEX_UI_TEST_USER': 'synthetic',
                                    'APEX_PRIVATE_TOKEN': 'must-not-be-transferred'}):
            with tempfile.TemporaryDirectory() as directory, \
                 patch.object(runner.sys, 'argv', ['runner', directory]), \
                 patch.dict(os.environ, {'APEX_UI_TEST_VM': 'macos27', 'APEX_UI_RUNNER_HOST': '192.0.2.10', 'APEX_UI_RUNNER_USER': 'synthetic'}), \
                 patch.object(runner, 'run', side_effect=self.transport_result), \
                 patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
                runner.main()
                self.assertEqual(json.loads((Path(directory) / 'ui-test-environment.json').read_text()),
                                 {'APEX_UI_TEST_HOST': '192.0.2.25', 'APEX_UI_TEST_USER': 'synthetic'})

    def test_launch_services_preflight_requires_helper_completion(self):
        script = self.execute(0).split('# Launch Services makes the signed helper, rather than sshd, responsible for TCC.\n', 1)[1].split('\nPY_KEY_FIXTURE', 1)[0]
        for outcome in ('success', 'denied', 'missing', 'launch-failed'):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory) / 'PhysicalKeyQA.app'
                def launch(arguments, **kwargs):
                    self.assertEqual(arguments[:4], ['/usr/bin/open', '-n', '-g', '-W'])
                    self.assertEqual(arguments[-4:], ['-a', str(destination), '--args', '--preflight'])
                    if outcome == 'launch-failed':
                        raise subprocess.CalledProcessError(1, arguments)
                    if outcome != 'missing':
                        Path(arguments[arguments.index('--stdout') + 1]).write_text(
                            'APEX_PHYSICAL_KEY_OK --preflight\n' if outcome == 'success' else '')
                        Path(arguments[arguments.index('--stderr') + 1]).write_text(
                            '' if outcome == 'success' else 'Accessibility denied')
                    return subprocess.CompletedProcess(arguments, 0)
                with patch('subprocess.run', side_effect=launch):
                    context = {'pathlib': __import__('pathlib'), 'subprocess': subprocess, 'destination': destination}
                    if outcome == 'success':
                        exec(script, context)
                    elif outcome == 'launch-failed':
                        with self.assertRaises(subprocess.CalledProcessError):
                            exec(script, context)
                    else:
                        with self.assertRaises(RuntimeError):
                            exec(script, context)

    def test_ssh_preflight_rejects_missing_identity_and_failed_authentication(self):
        script = self.execute(0).split("python3 - <<'PY_SSH_PREFLIGHT'\n", 1)[1].split('\nPY_SSH_PREFLIGHT', 1)[0]
        for outcome in ('missing-socket', 'empty-agent', 'agent-timeout', 'denied', 'target-timeout', 'wrong-proof', 'success'):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
                Path('reports').mkdir()
                Path('ui-test-environment.json').write_text(json.dumps({
                    'APEX_UI_TEST_HOST': '192.0.2.25', 'APEX_UI_TEST_USER': 'synthetic',
                    'APEX_PRIVATE_TOKEN': 'must-not-be-reported'}))
                def command(arguments, **kwargs):
                    self.assertTrue(kwargs['capture_output'])
                    if arguments == ['ssh-add', '-l']:
                        if outcome == 'agent-timeout':
                            raise subprocess.TimeoutExpired(arguments, kwargs['timeout'])
                        return subprocess.CompletedProcess(arguments, 1 if outcome == 'empty-agent' else 0)
                    self.assertEqual(arguments[-2:], ['synthetic@192.0.2.25', 'printf APEX_UI_REAL_TARGET_OK'])
                    self.assertIn('BatchMode=yes', arguments)
                    self.assertIn('IdentityAgent=/synthetic/agent.sock', arguments)
                    if outcome == 'target-timeout':
                        raise subprocess.TimeoutExpired(arguments, kwargs['timeout'])
                    return subprocess.CompletedProcess(arguments, 255 if outcome == 'denied' else 0,
                        b'APEX_UI_REAL_TARGET_OK' if outcome == 'success' else b'')
                environment = {} if outcome == 'missing-socket' else {'SSH_AUTH_SOCK': '/synthetic/agent.sock'}
                with patch.dict(os.environ, environment, clear=True), patch('subprocess.run', side_effect=command) as commands:
                    if outcome == 'success':
                        exec(script, {})
                    else:
                        with self.assertRaises(RuntimeError):
                            exec(script, {})
                report = json.loads(Path('reports/ssh-preflight.json').read_text())
                self.assertEqual(report['targetAuthenticated'], outcome == 'success')
                self.assertEqual(commands.call_count, 0 if outcome == 'missing-socket' else
                    1 if outcome in ('empty-agent', 'agent-timeout') else 2)
                self.assertEqual(set(report), {'agentAvailable', 'targetAuthenticated'})

    def permission_script(self):
        script = self.execute(0)
        return script.split("# Xcode's macOS UI runner", 1)[1].split('\nPY\n', 1)[0].split('import subprocess, tempfile', 1)[1]

    def test_physical_fixture_refuses_foreign_app_before_deleting_it(self):
        script = self.execute(0).split("python3 - <<'PY_KEY_FIXTURE'\n", 1)[1].split('\nPY_KEY_FIXTURE', 1)[0]
        with tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
            root = Path(directory).resolve()
            source = root / 'outputs/ui-acceptance/PhysicalKeyQA.app'
            (source / 'Contents').mkdir(parents=True)
            (source / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.apexterm.qa.physicalkeys'}))
            destination = root / '.apexterm-ui-tools/PhysicalKeyQA.app'
            (destination / 'Contents').mkdir(parents=True)
            (destination / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'user.application'}))
            note = destination / 'user-data'
            note.write_bytes(b'preserve existing data')
            with patch.object(Path, 'home', return_value=root), patch('subprocess.run') as commands:
                with self.assertRaises(AssertionError):
                    exec(script, {})
            self.assertEqual(note.read_bytes(), b'preserve existing data')
            self.assertEqual(commands.call_count, 1)

    def test_physical_fixture_refuses_source_symlink_before_signature_check(self):
        script = self.execute(0).split("python3 - <<'PY_KEY_FIXTURE'\n", 1)[1].split('\nPY_KEY_FIXTURE', 1)[0]
        with tempfile.TemporaryDirectory() as directory, contextlib.chdir(directory):
            root = Path(directory).resolve()
            actual = root / 'another-signed-app'
            actual.mkdir()
            source = root / 'outputs/ui-acceptance/PhysicalKeyQA.app'
            source.parent.mkdir(parents=True)
            source.symlink_to(actual, target_is_directory=True)
            with patch('subprocess.run') as commands:
                with self.assertRaises(AssertionError):
                    exec(script, {})
            commands.assert_not_called()
            self.assertFalse((root / '.apexterm-ui-tools').exists())

    def test_physical_fixture_refuses_tools_symlink(self):
        script = self.execute(0).split("python3 - <<'PY_KEY_FIXTURE'\n", 1)[1].split('\nPY_KEY_FIXTURE', 1)[0]
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as external, contextlib.chdir(directory):
            root = Path(directory).resolve()
            source = root / 'outputs/ui-acceptance/PhysicalKeyQA.app'
            (source / 'Contents').mkdir(parents=True)
            (source / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.apexterm.qa.physicalkeys'}))
            (root / '.apexterm-ui-tools').symlink_to(external, target_is_directory=True)
            with patch.object(Path, 'home', return_value=root), patch('subprocess.run') as commands:
                with self.assertRaises(AssertionError):
                    exec(script, {})
            self.assertEqual(list(Path(external).iterdir()), [])
            self.assertEqual(commands.call_count, 1)

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
            with patch.dict(os.environ, {'APEX_UI_TEST_VM': 'macos27', 'APEX_UI_RUNNER_HOST': '192.0.2.10', 'APEX_UI_RUNNER_USER': 'synthetic'}), \
                 patch.object(runner.sys, 'argv', ['runner', directory]), \
                 patch.object(runner, 'run', side_effect=self.transport_result) as transport, \
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
        with patch.dict(os.environ, {'APEX_UI_TEST_VM': 'macos27', 'APEX_UI_RUNNER_HOST': 'invalid;command', 'APEX_UI_RUNNER_USER': 'synthetic'}), \
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
