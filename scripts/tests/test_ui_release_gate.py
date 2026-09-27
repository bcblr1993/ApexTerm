import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class UIReleaseGateTests(unittest.TestCase):
    def run_gate(self, configured, enabled=False, preflight=True):
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)
            marker = tools / 'build-started'
            for name, content in {
                'xcodebuild': '#!/bin/sh\nexit 0\n',
                'automationmodetool': '#!/bin/sh\necho "Automation Mode is ' + ('ENABLED' if enabled else 'disabled') + '."\n',
                'swift': f'#!/bin/sh\ntouch "{marker}"\nexit 0\n',
            }.items():
                path = tools / name
                path.write_text(content)
                path.chmod(0o755)
            environment = os.environ.copy()
            environment['PATH'] = str(tools) + os.pathsep + environment.get('PATH', '')
            environment['APEX_UI_REPORT_ROOT'] = str(tools / 'reports')
            environment['APEX_UI_CONFIG_FILE'] = '/dev/null'
            environment.pop('APEX_UI_TEST_HOST', None)
            environment.pop('APEX_UI_TEST_USER', None)
            if configured:
                environment.update(APEX_UI_TEST_HOST='example.com', APEX_UI_TEST_USER='synthetic')
            command = ['bash', str(ROOT / 'scripts/test_ui_acceptance.sh')]
            if preflight:
                command.append('--preflight-only')
            result = subprocess.run(command,
                                    env=environment, capture_output=True, text=True)
            successful = configured and preflight
            if successful:
                self.assertEqual(result.returncode, 0)
            else:
                self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists(), 'Failed UI prerequisites must stop before building')
            reports = list((tools / 'reports').glob('*'))
            self.assertEqual(len(reports), 1)
            self.assertEqual((reports[0] / 'run-status.txt').read_text(),
                             f'stage={"prerequisites-passed" if successful else "prerequisites"}\nexit_code={result.returncode}\n')
            self.assertTrue((reports[0] / 'source-commit.txt').read_text().strip())
            self.assertEqual((reports[0] / 'ApexTermUITests.swift').read_bytes(),
                             (ROOT / 'UITests/ApexTermUITests.swift').read_bytes())
            self.assertTrue((reports[0] / 'test-source-sha256.txt').read_text().strip())
            return result.stdout + result.stderr

    def test_missing_real_host_stops_gate(self):
        self.assertIn('APEX_UI_TEST_HOST', self.run_gate(False))

    def test_idle_disabled_mode_requires_activation_at_execution(self):
        self.assertIn('authenticated activation', self.run_gate(True))

    def test_preflight_success_does_not_claim_ui_execution(self):
        self.assertIn('full UI execution is still required', self.run_gate(True, enabled=True, preflight=True))

    def test_preflight_never_counts_as_authenticated_ui_acceptance(self):
        self.assertIn('authenticated full UI execution', self.run_gate(True, preflight=True))


if __name__ == '__main__':
    unittest.main()
