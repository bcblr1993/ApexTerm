import contextlib
import io
import json
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / 'audit_app_store_bundle.py'


class AuditTests(unittest.TestCase):
    def inspect(self, app_change=None, profile_change=None, helper_change=None,
                leaf=b'permitted-leaf', extraction_status=0, missing_leaf=False,
                profile_metadata=None, helper_signers=None):
        app_ent = {
            'com.apple.security.app-sandbox': True,
            'com.apple.security.network.client': True,
            'com.apple.security.files.user-selected.read-write': True,
            'com.apple.security.files.bookmarks.app-scope': True,
            'com.apple.application-identifier': '5984KQD4D7.com.apexterm.app',
            'com.apple.developer.team-identifier': '5984KQD4D7',
        }
        profile = {
            'Entitlements': {'com.apple.application-identifier': '5984KQD4D7.com.apexterm.app',
                             'com.apple.developer.team-identifier': '5984KQD4D7'},
            'ExpirationDate': datetime.now() + timedelta(days=1),
            'DeveloperCertificates': [b'other-leaf', b'permitted-leaf'],
            'TeamIdentifier': ['5984KQD4D7'], 'Platform': ['OSX'],
        }
        helper_ent = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
        if app_change:
            app_ent.update(app_change)
        if profile_change:
            profile['Entitlements'].update(profile_change)
        if helper_change:
            helper_ent.update(helper_change)
        if profile_metadata:
            profile.update(profile_metadata)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = root / 'ApexTerm.app'
            macos = app / 'Contents/MacOS'
            macos.mkdir(parents=True)
            (app / 'Contents/Resources').mkdir()
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.apexterm.app', 'ApexDistributionChannel': 'appStore',
                'CFBundleShortVersionString': '1.6.0', 'CFBundleVersion': '2026100201'}))
            (app / 'Contents/embedded.provisionprofile').write_bytes(b'synthetic-profile')
            for helper in ('ApexSSHBridge', 'sshpass'):
                (macos / helper).write_bytes(b'synthetic-helper')
            output = root / 'report.json'

            def execute(args, **kwargs):
                if args[:4] == ('codesign', '-d', '--entitlements', ':-'):
                    values = app_ent if Path(args[-1]) == app else helper_ent
                    return subprocess.CompletedProcess(args, 0, plistlib.dumps(values), b'')
                if args[:2] == ('codesign', '-dv'):
                    signer = (helper_signers or {}).get(Path(args[-1]).name, {})
                    return subprocess.CompletedProcess(args, 0, b'',
                        ('Authority=' + signer.get('authority', 'Apple Distribution: QA')
                         + '\nTeamIdentifier=' + signer.get('team', '5984KQD4D7') + '\n').encode())
                if args[:2] == ('security', 'cms'):
                    return subprocess.CompletedProcess(args, 0, plistlib.dumps(profile), b'')
                if args[:2] == ('codesign', '-d') and args[2].startswith('--extract-certificates='):
                    certificate = Path(args[2].split('=', 1)[1] + '0')
                    if not missing_leaf:
                        signer = (helper_signers or {}).get(Path(args[-1]).name, {})
                        certificate.write_bytes(signer.get('leaf', leaf))
                    return subprocess.CompletedProcess(args, extraction_status, b'', b'')
                if args[:2] == ('codesign', '--verify'):
                    return subprocess.CompletedProcess(args, 0, b'', b'')
                raise AssertionError(args)

            with patch.object(sys, 'argv', [str(SCRIPT), str(app), '--output', str(output)]), \
                    patch('subprocess.run', side_effect=execute), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as termination:
                    runpy.run_path(str(SCRIPT), run_name='__main__')
            report = json.loads(output.read_text())
            self.assertEqual(termination.exception.code, 0 if report['technicalRequirementsMet'] else 1)
            return report

    def test_valid_fixture_matches_any_profile_certificate(self):
        self.assertTrue(self.inspect()['technicalRequirementsMet'])

    def test_both_app_debugging_keys_block(self):
        for key in ('get-task-allow', 'com.apple.security.get-task-allow'):
            with self.subTest(key=key):
                self.assertFalse(self.inspect(app_change={key: True})['technicalRequirementsMet'])

    def test_both_profile_debugging_keys_block(self):
        for key in ('get-task-allow', 'com.apple.security.get-task-allow'):
            with self.subTest(key=key):
                self.assertFalse(self.inspect(profile_change={key: True})['technicalRequirementsMet'])

    def test_disabled_debugging_is_allowed(self):
        self.assertTrue(self.inspect(app_change={'com.apple.security.get-task-allow': False},
                                     profile_change={'get-task-allow': False})['technicalRequirementsMet'])

    def test_different_signer_blocks(self):
        self.assertFalse(self.inspect(leaf=b'wrong-leaf')['technicalRequirementsMet'])

    def test_failed_extraction_blocks_even_if_file_exists(self):
        self.assertFalse(self.inspect(extraction_status=1)['technicalRequirementsMet'])

    def test_missing_certificate_blocks(self):
        self.assertFalse(self.inspect(missing_leaf=True)['technicalRequirementsMet'])

    def test_helper_identity_metadata_allowed(self):
        self.assertTrue(self.inspect(helper_change={
            'com.apple.application-identifier': '5984KQD4D7.com.apexterm.helper',
            'com.apple.developer.team-identifier': '5984KQD4D7'})['technicalRequirementsMet'])

    def test_each_helper_foreign_team_blocks(self):
        for helper in ('ApexSSHBridge', 'sshpass'):
            with self.subTest(helper=helper):
                report = self.inspect(helper_signers={helper: {'team': 'OTHERTEAM'}})
                self.assertFalse(report['technicalRequirementsMet'])
                self.assertFalse(next(c['passed'] for c in report['checks'] if c['name'] == helper + '-store-distribution-signature'))

    def test_each_helper_non_store_identity_blocks(self):
        for helper in ('ApexSSHBridge', 'sshpass'):
            for authority in ('adhoc', 'Developer ID Application: QA', 'Apple Development: QA'):
                with self.subTest(helper=helper, authority=authority):
                    self.assertFalse(self.inspect(helper_signers={helper: {'authority': authority}})['technicalRequirementsMet'])

    def test_each_helper_certificate_outside_profile_blocks(self):
        for helper in ('ApexSSHBridge', 'sshpass'):
            with self.subTest(helper=helper):
                report = self.inspect(helper_signers={helper: {'leaf': b'foreign-helper-leaf'}})
                self.assertFalse(report['technicalRequirementsMet'])
                self.assertFalse(next(c['passed'] for c in report['checks'] if c['name'] == helper + '-signer-authorized-by-profile'))

    def test_permitted_alternative_helper_distribution_certificate_passes(self):
        self.assertTrue(self.inspect(helper_signers={
            'ApexSSHBridge': {'authority': '3rd Party Mac Developer Application: QA', 'leaf': b'other-leaf'},
            'sshpass': {'leaf': b'permitted-leaf'}})['technicalRequirementsMet'])

    def test_extra_helper_sandbox_capability_blocks(self):
        self.assertFalse(self.inspect(helper_change={
            'com.apple.security.network.client': True})['technicalRequirementsMet'])

    def test_helper_debugging_blocks(self):
        for key in ('get-task-allow', 'com.apple.security.get-task-allow'):
            with self.subTest(key=key):
                self.assertFalse(self.inspect(helper_change={key: True})['technicalRequirementsMet'])

    def test_wrong_profile_team_or_platform_blocks(self):
        for value in ({'TeamIdentifier': ['OTHERTEAM']}, {'Platform': ['iOS']}):
            with self.subTest(value=value):
                self.assertFalse(self.inspect(profile_metadata=value)['technicalRequirementsMet'])

    def test_device_limited_and_developer_id_profiles_block(self):
        for value in ({'ProvisionedDevices': ['synthetic-device']}, {'ProvisionsAllDevices': True}):
            with self.subTest(value=value):
                self.assertFalse(self.inspect(profile_metadata=value)['technicalRequirementsMet'])

    def test_expired_profile_blocks(self):
        self.assertFalse(self.inspect(profile_metadata={
            'ExpirationDate': datetime.now() - timedelta(days=1)})['technicalRequirementsMet'])

    def test_team_entitlement_mismatch_blocks(self):
        key = 'com.apple.developer.team-identifier'
        self.assertFalse(self.inspect(app_change={key: 'OTHERTEAM'})['technicalRequirementsMet'])
        self.assertFalse(self.inspect(profile_change={key: 'OTHERTEAM'})['technicalRequirementsMet'])

    def test_missing_bundle_returns_failure_and_writes_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / 'report.json'
            result = subprocess.run([sys.executable, str(SCRIPT), str(root / 'missing.app'),
                                     '--output', str(output)], capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(json.loads(output.read_text())['technicalRequirementsMet'])


if __name__ == '__main__':
    unittest.main()
