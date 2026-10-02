import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseBuildGateTests(unittest.TestCase):
    def test_preflight_only_cannot_start_or_modify_release_build(self):
        for bash in ['bash', '/bin/bash']:
            with self.subTest(bash=bash), tempfile.TemporaryDirectory() as directory:
                workspace = Path(directory)
                artifact = workspace / '.build' / 'ApexTerm.app' / 'user-file'
                artifact.parent.mkdir(parents=True)
                artifact.write_text('preserve existing artifact')
                marker = workspace / 'command-started'
                for name in ['git', 'swift', 'codesign']:
                    tool = workspace / name
                    tool.write_text(f'#!/bin/sh\ntouch "{marker}"\nexit 0\n')
                    tool.chmod(0o755)
                environment = os.environ.copy()
                environment['PATH'] = str(workspace) + os.pathsep + environment.get('PATH', '')
                environment['APEX_UI_ACCEPTANCE_PREFLIGHT_ONLY'] = '1'
                result = subprocess.run([bash, str(ROOT / 'scripts/build_app.sh'), '1.6.0', '2026100201'],
                                        cwd=workspace, env=environment, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('full UI acceptance', result.stderr)
                self.assertFalse(marker.exists())
                self.assertEqual(artifact.read_text(), 'preserve existing artifact')


if __name__ == '__main__':
    unittest.main()
