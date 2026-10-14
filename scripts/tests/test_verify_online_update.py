from pathlib import Path
import json
import os
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch, MagicMock

class OnlineUpdateVerificationTests(unittest.TestCase):
    def test_script_requires_version_argument(self):
        script = Path(__file__).parents[1] / 'verify_online_update.py'
        res = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("usage", res.stderr.lower())

    def test_script_accepts_clean_or_prefixed_version(self):
        import importlib.util
        script = Path(__file__).parents[1] / 'verify_online_update.py'
        spec = importlib.util.spec_from_file_location("verify_online_update", script)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        with tempfile.TemporaryDirectory() as tmp:
            # Create synthetic app bundle and tar.gz
            app_dir = Path(tmp) / "AetherTerm.app"
            contents = app_dir / "Contents"
            macos = contents / "MacOS"
            macos.mkdir(parents=True)
            executable = macos / "ApexTerm"
            executable.write_bytes(b"synthetic binary")
            executable.chmod(0o755)

            plist_path = contents / "Info.plist"
            with open(plist_path, "wb") as f:
                plistlib.dump({
                    "CFBundleIdentifier": "com.apexterm.app",
                    "CFBundleShortVersionString": "1.7.0"
                }, f)

            archive = Path(tmp) / "archive.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(app_dir, arcname="AetherTerm.app")

            mock_resp_data = {
                "tag_name": "v1.7.0",
                "assets": [
                    {"name": "AetherTerm-v1.7.0-macos-arm64.dmg", "size": 3000000, "browser_download_url": "https://example.com/dmg"},
                    {"name": "AetherTerm-v1.7.0-macos-arm64.tar.gz", "size": 2500000, "browser_download_url": "https://example.com/tar"},
                    {"name": "SHA256SUMS.txt", "size": 200, "browser_download_url": "https://example.com/sums"}
                ]
            }

            def fake_urlopen(req, *args, **kwargs):
                mock_cm = MagicMock()
                mock_cm.status = 200
                mock_cm.read.return_value = json.dumps(mock_resp_data).encode("utf-8")
                mock_cm.__enter__.return_value = mock_cm
                return mock_cm

            def fake_urlretrieve(url, filename, *args, **kwargs):
                with open(archive, "rb") as src, open(filename, "wb") as dst:
                    dst.write(src.read())

            with patch("urllib.request.urlopen", side_effect=fake_urlopen), \
                 patch("urllib.request.urlretrieve", side_effect=fake_urlretrieve):
                mod.verify_release("1.7.0", local_build_dir="/nonexistent")
                mod.verify_release("v1.7.0", local_build_dir="/nonexistent")

    def test_mismatched_tag_aborts(self):
        import importlib.util
        script = Path(__file__).parents[1] / 'verify_online_update.py'
        spec = importlib.util.spec_from_file_location("verify_online_update", script)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        mock_resp_data = {"tag_name": "v1.6.3", "assets": []}
        with patch("urllib.request.urlopen") as mock_url:
            mock_cm = MagicMock()
            mock_cm.status = 200
            mock_cm.read.return_value = json.dumps(mock_resp_data).encode("utf-8")
            mock_cm.__enter__.return_value = mock_cm
            mock_url.return_value = mock_cm

            with self.assertRaises(SystemExit) as cm:
                mod.verify_release("1.7.0")
            self.assertEqual(cm.exception.code, 1)

if __name__ == '__main__':
    unittest.main()
