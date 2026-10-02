import copy
import hashlib
import importlib.util
import pathlib
import plistlib
import unittest
from datetime import datetime, timedelta
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('store_candidate', pathlib.Path(__file__).parents[1] / 'prepare_app_store_candidate.py')
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class StoreCandidateProfileTests(unittest.TestCase):
    def setUp(self):
        self.leaf = b'public synthetic distribution certificate'
        self.sha1 = hashlib.sha1(self.leaf).hexdigest()
        self.profile = {
            'TeamIdentifier': ['5984KQD4D7'], 'Platform': ['OSX'],
            'ExpirationDate': datetime.utcnow() + timedelta(days=1),
            'DeveloperCertificates': [self.leaf],
            'Entitlements': {'com.apple.application-identifier': '5984KQD4D7.com.apexterm.app'},
        }

    def validate(self, profile):
        with patch.object(candidate.subprocess, 'check_output', return_value=plistlib.dumps(profile)):
            return candidate.validate_profile(pathlib.Path('synthetic-profile'), self.sha1)

    def test_matching_distribution_profile_is_accepted(self):
        self.assertEqual(self.validate(self.profile), self.profile['Entitlements'])

    def test_other_apps_and_teams_are_rejected(self):
        for key, value in [('TeamIdentifier', ['OTHERTEAM']), ('Platform', ['iOS'])]:
            profile = copy.deepcopy(self.profile)
            profile[key] = value
            with self.assertRaises(ValueError):
                self.validate(profile)
        profile = copy.deepcopy(self.profile)
        profile['Entitlements']['com.apple.application-identifier'] = '5984KQD4D7.other.app'
        with self.assertRaises(ValueError):
            self.validate(profile)

    def test_debug_profiles_are_rejected_for_both_entitlement_names(self):
        for key in ('get-task-allow', 'com.apple.security.get-task-allow'):
            profile = copy.deepcopy(self.profile)
            profile['Entitlements'][key] = True
            with self.assertRaises(ValueError):
                self.validate(profile)

    def test_development_and_outside_store_distribution_are_rejected(self):
        for key, value in [('ProvisionedDevices', ['synthetic-device']), ('ProvisionsAllDevices', True)]:
            profile = copy.deepcopy(self.profile)
            profile[key] = value
            with self.assertRaises(ValueError):
                self.validate(profile)

    def test_expired_profile_is_rejected(self):
        self.profile['ExpirationDate'] = datetime.utcnow() - timedelta(days=1)
        with self.assertRaises(ValueError):
            self.validate(self.profile)

    def test_signer_not_authorized_by_profile_is_rejected(self):
        self.profile['DeveloperCertificates'] = [b'other synthetic certificate']
        with self.assertRaises(ValueError):
            self.validate(self.profile)
