import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class UIReleaseGateTests(unittest.TestCase):
    def run_gate(self, configured):
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)
            marker = tools / 'build-started'
            for name, content in {
                'xcodebuild': '#!/bin/sh\nexit 0\n',
                'automationmodetool': '#!/bin/sh\necho "Automation Mode is disabled."\n',
                'swift': f'#!/bin/sh\ntouch "{marker}"\nexit 0\n',
            }.items():
                path = tools / name
                path.write_text(content)
                path.chmod(0o755)
            environment = os.environ.copy()
            environment['PATH'] = str(tools) + os.pathsep + environment.get('PATH', '')
            environment['APEX_UI_REPORT_ROOT'] = str(tools / 'reports')
            environment.pop('APEX_UI_TEST_HOST', None)
            environment.pop('APEX_UI_TEST_USER', None)
            if configured:
                environment.update(APEX_UI_TEST_HOST='example.com', APEX_UI_TEST_USER='synthetic')
            result = subprocess.run(['bash', str(ROOT / 'scripts/test_ui_acceptance.sh')],
                                    env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists(), 'Failed UI prerequisites must stop before building')
            reports = list((tools / 'reports').glob('*'))
            self.assertEqual(len(reports), 1)
            self.assertEqual((reports[0] / 'run-status.txt').read_text(),
                             f'stage=prerequisites\nexit_code={result.returncode}\n')
            self.assertTrue((reports[0] / 'source-commit.txt').read_text().strip())
            return result.stdout + result.stderr

    def test_missing_real_host_stops_gate(self):
        self.assertIn('APEX_UI_TEST_HOST', self.run_gate(False))

    def test_disabled_automation_stops_gate(self):
        self.assertIn('requires Automation Mode', self.run_gate(True))


if __name__ == '__main__':
    unittest.main()
