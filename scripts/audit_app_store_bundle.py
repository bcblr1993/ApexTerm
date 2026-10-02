#!/usr/bin/env python3
"""Read-only technical readiness audit, not an App Store approval verdict."""
import argparse
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def run(*args):
    result = subprocess.run(args, capture_output=True, timeout=30)
    return result.returncode, result.stdout, result.stderr


def entitlements(path):
    status, stdout, _ = run('codesign', '-d', '--entitlements', ':-', str(path))
    if status or not stdout.strip():
        return {}
    try:
        return plistlib.loads(stdout)
    except plistlib.InvalidFileException:
        return {}


def allows_debugging(values):
    return any(bool(values.get(key)) for key in
               ('get-task-allow', 'com.apple.security.get-task-allow'))


def signer_matches_profile(path, profile):
    certificates = profile.get('DeveloperCertificates', [])
    allowed = {hashlib.sha256(value).digest() for value in certificates
               if isinstance(value, bytes)}
    with tempfile.TemporaryDirectory(prefix='apexterm-signature-audit-') as directory:
        prefix = str(Path(directory) / 'signer-')
        status, _, _ = run('codesign', '-d', '--extract-certificates=' + prefix, str(path))
        leaf = Path(prefix + '0')
        return status == 0 and leaf.is_file() and hashlib.sha256(leaf.read_bytes()).digest() in allowed


parser = argparse.ArgumentParser()
parser.add_argument('bundle', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
bundle = args.bundle.resolve()
info_path = bundle / 'Contents/Info.plist'
report = {'timeUTC': datetime.now(timezone.utc).isoformat(), 'bundle': str(bundle),
          'scope': 'Technical inspection only; uploaded build, VM acceptance and review remain independent gates.',
          'checks': [], 'technicalRequirementsMet': False}


def check(name, passed, evidence, gate=True):
    report['checks'].append({'name': name, 'passed': bool(passed), 'evidence': evidence,
                            'blocksTechnicalReadiness': gate})


if not info_path.is_file():
    check('bundle-present', False, 'Bundle Info.plist is missing; no candidate was inspected.')
else:
    original = info_path.read_bytes()
    info = plistlib.loads(original)
    report['version'] = info.get('CFBundleShortVersionString')
    report['build'] = info.get('CFBundleVersion')
    check('registered-bundle-id', info.get('CFBundleIdentifier') == 'com.apexterm.app', info.get('CFBundleIdentifier'))
    check('store-update-channel', info.get('ApexDistributionChannel') == 'appStore', info.get('ApexDistributionChannel'))
    app_entitlements = entitlements(bundle)
    check('app-sandbox', app_entitlements.get('com.apple.security.app-sandbox') is True,
          {'appSandbox': app_entitlements.get('com.apple.security.app-sandbox')})
    check('outbound-network', app_entitlements.get('com.apple.security.network.client') is True,
          {'networkClient': app_entitlements.get('com.apple.security.network.client')})
    check('user-selected-files', app_entitlements.get('com.apple.security.files.user-selected.read-write') is True,
          {'userSelectedReadWrite': app_entitlements.get('com.apple.security.files.user-selected.read-write')})
    check('persistent-bookmarks', app_entitlements.get('com.apple.security.files.bookmarks.app-scope') is True,
          {'bookmarksAppScope': app_entitlements.get('com.apple.security.files.bookmarks.app-scope')})
    code, _, stderr = run('codesign', '--verify', '--deep', '--strict', str(bundle))
    check('signature-verifies', code == 0, {'exitCode': code})
    code, _, metadata = run('codesign', '-dv', str(bundle))
    authorities = [line.partition('=')[2] for line in metadata.decode(errors='replace').splitlines() if line.startswith('Authority=')]
    check('store-distribution-signature', code == 0 and any(a.startswith(('Apple Distribution:', '3rd Party Mac Developer Application:')) for a in authorities), authorities)
    team_lines = [line.partition('=')[2] for line in metadata.decode(errors='replace').splitlines() if line.startswith('TeamIdentifier=')]
    check('expected-signing-team', team_lines == ['5984KQD4D7'], {'matchingTeam': team_lines == ['5984KQD4D7']})
    profile = bundle / 'Contents/embedded.provisionprofile'
    profile_data = {}
    if profile.is_file():
        code, decoded, _ = run('security', 'cms', '-D', '-i', str(profile))
        if code == 0:
            try:
                profile_data = plistlib.loads(decoded)
            except plistlib.InvalidFileException:
                pass
    profile_ent = profile_data.get('Entitlements', {})
    identifier = profile_ent.get('com.apple.application-identifier', profile_ent.get('application-identifier'))
    expiry = profile_data.get('ExpirationDate')
    if expiry and expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    check('matching-valid-store-profile', identifier == '5984KQD4D7.com.apexterm.app' and expiry and expiry > datetime.now(timezone.utc) and not allows_debugging(profile_ent),
          {'present': profile.is_file(), 'matchingIdentifier': identifier == '5984KQD4D7.com.apexterm.app', 'expiryUTC': expiry.isoformat() if expiry else None})
    check('store-profile-distribution', profile_data.get('TeamIdentifier') == ['5984KQD4D7']
          and profile_data.get('Platform') == ['OSX']
          and not profile_data.get('ProvisionedDevices')
          and not profile_data.get('ProvisionsAllDevices'),
          {'matchingTeam': profile_data.get('TeamIdentifier') == ['5984KQD4D7'],
           'platform': profile_data.get('Platform'),
           'deviceLimited': bool(profile_data.get('ProvisionedDevices')),
           'allDevices': bool(profile_data.get('ProvisionsAllDevices'))})
    app_identifier = app_entitlements.get('com.apple.application-identifier', app_entitlements.get('application-identifier'))
    check('matching-app-profile-entitlements', app_identifier == identifier == '5984KQD4D7.com.apexterm.app' and not allows_debugging(app_entitlements),
          {'matchingIdentifier': app_identifier == identifier == '5984KQD4D7.com.apexterm.app', 'developmentDebugging': allows_debugging(app_entitlements)})
    team_key = 'com.apple.developer.team-identifier'
    check('matching-team-entitlements', app_entitlements.get(team_key) == profile_ent.get(team_key) == '5984KQD4D7',
          {'matchingTeam': app_entitlements.get(team_key) == profile_ent.get(team_key) == '5984KQD4D7'})
    check('signer-authorized-by-profile', signer_matches_profile(bundle, profile_data),
          'The extracted leaf certificate must match a DeveloperCertificates entry in the embedded profile.')
    manifests = list((bundle / 'Contents/Resources').rglob('PrivacyInfo.xcprivacy'))
    categories = set()
    for manifest in manifests:
        try:
            for api in plistlib.loads(manifest.read_bytes()).get('NSPrivacyAccessedAPITypes', []):
                if api.get('NSPrivacyAccessedAPITypeReasons'):
                    categories.add(api.get('NSPrivacyAccessedAPIType'))
        except (plistlib.InvalidFileException, OSError):
            pass
    check('user-defaults-reason-declared', 'NSPrivacyAccessedAPICategoryUserDefaults' in categories,
          {'manifestCount': len(manifests), 'declaredCategories': sorted(c for c in categories if c),
           'scopeNote': 'Prepare an accurate declaration; a missing manifest alone is not an observed macOS upload rejection.'}, gate=False)
    for helper_name in ('ApexSSHBridge', 'sshpass'):
        helper = bundle / 'Contents/MacOS' / helper_name
        check(helper_name + '-bundled', helper.is_file(), {'present': helper.is_file()})
        if helper.is_file():
            helper_ent = entitlements(helper)
            inheritance_keys = {'com.apple.security.app-sandbox', 'com.apple.security.inherit'}
            enabled_keys = {key for key, value in helper_ent.items()
                            if key.startswith('com.apple.security.') and value is not False}
            check(helper_name + '-inherits-sandbox', helper_ent.get('com.apple.security.app-sandbox') is True and helper_ent.get('com.apple.security.inherit') is True and enabled_keys == inheritance_keys and not allows_debugging(helper_ent),
                  {'appSandbox': helper_ent.get('com.apple.security.app-sandbox'), 'inherit': helper_ent.get('com.apple.security.inherit'), 'unexpectedEntitlementCount': len(enabled_keys - inheritance_keys)})
            check(helper_name + '-signature-verifies', run('codesign', '--verify', '--strict', str(helper))[0] == 0, 'Helper signature verified independently.')
            code, _, metadata = run('codesign', '-dv', str(helper))
            helper_authorities = [line.partition('=')[2] for line in metadata.decode(errors='replace').splitlines() if line.startswith('Authority=')]
            helper_teams = [line.partition('=')[2] for line in metadata.decode(errors='replace').splitlines() if line.startswith('TeamIdentifier=')]
            check(helper_name + '-store-distribution-signature', code == 0
                  and any(a.startswith(('Apple Distribution:', '3rd Party Mac Developer Application:')) for a in helper_authorities)
                  and helper_teams == ['5984KQD4D7'],
                  {'authorities': helper_authorities, 'matchingTeam': helper_teams == ['5984KQD4D7']})
            check(helper_name + '-signer-authorized-by-profile', signer_matches_profile(helper, profile_data),
                  'Bundled helpers must use a distribution certificate authorized by the application profile.')
    check('file-metadata-reason-declared', 'NSPrivacyAccessedAPICategoryFileTimestamp' in categories,
          {'declared': 'NSPrivacyAccessedAPICategoryFileTimestamp' in categories, 'scopeNote': 'Source uses fstat and user-selected transfer file metadata; final helper API audit remains required.'}, gate=False)
    check('plist-stable-during-audit', hashlib.sha256(info_path.read_bytes()).digest() == hashlib.sha256(original).digest(),
          'Metadata was read before and after inspection; this does not prove stability of an in-flight build.')
    report['technicalRequirementsMet'] = all(c['passed'] for c in report['checks'] if c['blocksTechnicalReadiness'])

args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'version': report.get('version'), 'build': report.get('build'),
                  'technicalRequirementsMet': report['technicalRequirementsMet'],
                  'blockingFailedChecks': [c['name'] for c in report['checks'] if not c['passed'] and c['blocksTechnicalReadiness']],
                  'informationalMissingChecks': [c['name'] for c in report['checks'] if not c['passed'] and not c['blocksTechnicalReadiness']],
                  'output': str(args.output)}, ensure_ascii=False))
sys.exit(0 if report['technicalRequirementsMet'] else 1)
