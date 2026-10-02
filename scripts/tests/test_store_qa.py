import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('store_qa', pathlib.Path(__file__).parents[1] / 'build_store_qa.py')
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class StoreQATests(unittest.TestCase):
    def test_product_identifier_cannot_be_used_for_qa(self):
        for identifier in ('com.apexterm.app', 'com.apexterm.candidate'):
            with self.assertRaises(ValueError):
                qa.metadata(identifier)

    def test_existing_directory_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory)
            sentinel = destination / 'user-file'
            sentinel.write_text('preserve')
            with self.assertRaises(FileExistsError):
                qa.assemble(destination, destination, destination, 'com.apexterm.qa.store.fixture')
            self.assertEqual(sentinel.read_text(), 'preserve')

    def test_invalid_identifier_stops_before_creating_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            destination = root / 'out'
            with self.assertRaises(ValueError):
                qa.assemble(destination, root, root, 'com.apexterm.app')
            self.assertFalse(destination.exists())

    def test_symlink_destination_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            original = root / 'existing'
            original.mkdir()
            link = root / 'link'
            link.symlink_to(original)
            with self.assertRaises(FileExistsError):
                qa.assemble(link, root, root, 'com.apexterm.qa.store.fixture')
            self.assertEqual(list(original.iterdir()), [])

    def test_bundle_uses_only_explicit_inputs_and_qa_channel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            binaries = root / 'binaries'
            binaries.mkdir()
            for name in ('ApexTerm', 'ApexSSHBridge', 'sessions.json', 'id_rsa'):
                (binaries / name).write_bytes(b'synthetic fixture')
            sshpass = root / 'sshpass'
            sshpass.write_bytes(b'synthetic fixture')
            app = qa.assemble(root / 'out', binaries, sshpass, 'com.apexterm.qa.store.fixture')
            self.assertEqual(sorted(p.name for p in (app / 'Contents/MacOS').iterdir()),
                             ['ApexSSHBridge', 'ApexTerm', 'sshpass'])
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['ApexDistributionChannel'], 'appStore')
            self.assertEqual(info['ApexBuildPurpose'], 'sandboxQA')
            self.assertEqual(info['CFBundleIdentifier'], 'com.apexterm.qa.store.fixture')
            self.assertFalse((app / 'Contents/embedded.provisionprofile').exists())
            self.assertTrue((app / 'Contents/Resources/PrivacyInfo.xcprivacy').is_file())

    def test_dirty_source_stops_before_build_or_packaging(self):
        with patch.object(qa.platform, 'system', return_value='Darwin'), \
                patch.object(qa.platform, 'machine', return_value='arm64'), \
                patch.object(qa.subprocess, 'check_output', return_value=b' M source.swift'), \
                patch.object(qa, 'run') as run, patch.object(qa, 'assemble') as assemble:
            with self.assertRaises(SystemExit):
                qa.main()
            run.assert_not_called()
            assemble.assert_not_called()
