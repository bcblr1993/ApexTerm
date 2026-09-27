import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('prune', Path(__file__).resolve().parents[1] / 'prune_build_artifacts.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PruneBuildArtifactsTests(unittest.TestCase):
    def test_removes_old_generated_outputs_preserves_unrelated_files_and_latest_rollback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / '.build'
            root.mkdir()
            for name in ['ApexTerm-v1.3.0-macos-arm64.dmg', 'ApexTerm-notarization.zip', 'sessions.json', 'source.swift']:
                (root / name).write_text('data')
            for name in ['ApexTerm.app', 'ApexTerm-previous-2026092601.app', 'installed-backup-2026092601', 'installed-backup-2026092701']:
                (root / name).mkdir()
                (root / name / 'data').write_text('data')
            module.prune(root)
            self.assertEqual({p.name for p in root.iterdir()}, {'sessions.json', 'source.swift', 'installed-backup-2026092701'})

    def test_backup_rotation_does_not_delete_the_new_distribution(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / '.build'
            root.mkdir()
            (root / 'ApexTerm.app').mkdir()
            for name in ['installed-backup-2026092601', 'installed-backup-2026092701']:
                (root / name).mkdir()
            module.prune(root, installed_backups_only=True)
            self.assertEqual({p.name for p in root.iterdir()}, {'ApexTerm.app', 'installed-backup-2026092701'})

    def test_running_package_aborts_before_deleting_anything(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / '.build'
            root.mkdir()
            app = root / 'ApexTerm.app'
            app.mkdir()
            archive = root / 'ApexTerm-v1.3.0-macos-arm64.dmg'
            archive.write_text('data')
            with self.assertRaises(RuntimeError):
                module.prune(root, [str(app / 'Contents/MacOS/ApexTerm')])
            self.assertTrue(app.exists())
            self.assertTrue(archive.exists())

    def test_dry_run_and_symlinks_never_modify_external_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / '.build'
            root.mkdir()
            external = Path(tmp) / 'external'
            external.mkdir()
            (external / 'keep').write_text('keep')
            (root / 'ApexTerm.app').symlink_to(external, target_is_directory=True)
            module.prune(root, dry_run=True)
            self.assertTrue((root / 'ApexTerm.app').is_symlink())
            module.prune(root)
            self.assertTrue((external / 'keep').exists())


if __name__ == '__main__':
    unittest.main()
