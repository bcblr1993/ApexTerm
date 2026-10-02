from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class BundleSecurityTests(unittest.TestCase):
    def scan(self, app):
        script = Path(__file__).parents[1] / 'verify_bundle_security.py'
        return subprocess.run([sys.executable, str(script), str(app)], capture_output=True)

    def test_missing_and_empty_bundles_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Test.app'
            self.assertNotEqual(self.scan(app).returncode, 0)
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Resources').mkdir()
            self.assertNotEqual(self.scan(app).returncode, 0)

    def test_valid_fixture_passes_and_sensitive_resources_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Test.app'
            binary = app / 'Contents/MacOS/App'
            binary.parent.mkdir(parents=True)
            resources = app / 'Contents/Resources'
            resources.mkdir()
            binary.write_bytes(b'synthetic application fixture')
            self.assertEqual(self.scan(app).returncode, 0)
            for name, data in [
                ('secret.key', b'synthetic fixture'),
                ('debug-path.txt', str(Path.home()).encode() + b'/private-build/source.swift'),
                ('sessions.json', b'[]'),
                ('config.txt', b'192.168.1.123'),
                ('key.txt', b'-----BEGIN OPENSSH PRIVATE KEY-----'),
            ]:
                with self.subTest(name=name):
                    file = resources / name
                    file.write_bytes(data)
                    self.assertNotEqual(self.scan(app).returncode, 0)
                    file.unlink()


if __name__ == '__main__':
    unittest.main()
