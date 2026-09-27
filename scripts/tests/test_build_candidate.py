import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('build_candidate', Path(__file__).parents[1] / 'build_candidate.py')
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class CandidateCleanupTests(unittest.TestCase):
    def test_preserves_diagnostics_and_unrelated_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'ApexTerm Candidate.app').mkdir()
            (root / 'ApexTerm-Candidate-arm64.dmg').write_text('generated')
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
