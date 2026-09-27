import importlib.util
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('build_candidate', Path(__file__).parents[1] / 'build_candidate.py')
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class CandidateCleanupTests(unittest.TestCase):
    def test_failed_ui_preflight_preserves_candidate_and_stops_vm(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'CHANGELOG.md').write_text('## [v1.3.0]\n')
            app = root / 'ApexTerm Candidate.app'
            app.mkdir()
            (app / 'existing-artifact').write_text('preserve')
            def read_command(command, **kwargs):
                if command == ['git', 'status', '--porcelain']:
                    return b''
                if command == ['git', 'rev-parse', 'HEAD']:
                    return 'synthetic-source\n'
                if command == ['ps', '-axo', 'comm=']:
                    return ''
                self.fail(f'Unexpected work before UI preflight: {command}')
            with patch.object(candidate, 'ROOT', root), patch.object(candidate, 'APP', app), \
                 patch.object(candidate.subprocess, 'check_output', side_effect=read_command), \
                 patch.object(candidate, 'clean_generated') as cleanup, \
                 patch.object(candidate, 'run', side_effect=subprocess.CalledProcessError(1, 'ui-preflight')) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    candidate.main()
                run.assert_called_once_with('bash', 'scripts/test_ui_acceptance.sh', '--preflight-only')
                cleanup.assert_not_called()
            self.assertEqual((app / 'existing-artifact').read_text(), 'preserve')

    def test_preserves_diagnostics_and_unrelated_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'ApexTerm Candidate.app').mkdir()
            (root / 'ApexTerm-Candidate-arm64.dmg').write_text('generated')
            (root / 'candidate-manifest.txt').write_text('old provenance')
            (root / 'runtime.log').write_text('diagnostic')
            (root / 'notes.txt').write_text('user notes')
            candidate.clean_generated(root)
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['notes.txt', 'runtime.log'])

    def test_symlink_aborts_before_any_deletion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / 'ApexTerm Candidate.app'
            app.mkdir()
            target = root / 'user-data'
            target.write_text('preserve')
            (root / 'SHA256SUMS.txt').symlink_to(target)
            with self.assertRaises(SystemExit):
                candidate.clean_generated(root)
            self.assertTrue(app.is_dir())
            self.assertEqual(target.read_text(), 'preserve')
