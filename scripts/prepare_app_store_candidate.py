#!/usr/bin/env python3
"""Prepare a distribution-signed Store candidate; no installation, upload or release."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEAM = '5984KQD4D7'
APP_ID = TEAM + '.com.apexterm.app'


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def validate_profile(profile, certificate):
    values = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(profile)]))
    ent = values.get('Entitlements', {})
    expiry = values.get('ExpirationDate')
    if expiry is not None and expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    if (values.get('TeamIdentifier') != [TEAM] or values.get('Platform') != ['OSX']
            or values.get('ProvisionedDevices') or values.get('ProvisionsAllDevices')
            or ent.get('com.apple.application-identifier', ent.get('application-identifier')) != APP_ID
            or not expiry or expiry <= datetime.now(timezone.utc)
            or ent.get('get-task-allow') or ent.get('com.apple.security.get-task-allow')
            or certificate.upper() not in {hashlib.sha1(c).hexdigest().upper()
                                          for c in values.get('DeveloperCertificates', [])}):
        raise ValueError('Profile must authorize this app, team and distribution certificate.')
    return ent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    parser.add_argument('build')
    parser.add_argument('--profile', type=pathlib.Path, required=True)
    parser.add_argument('--certificate-sha1', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or not re.fullmatch(r'\d{10}', args.build):
        parser.error('Use a semantic version and YYYYMMDDNN build number.')
    if not re.fullmatch(r'[a-fA-F0-9]{40}', args.certificate_sha1):
        parser.error('Identify the profile-authorized signing certificate by SHA1.')
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT):
        raise SystemExit('A committed clean tree is required.')
    if subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip() not in ('master', 'main'):
        raise SystemExit('Formal Store candidates must be prepared from main or master.')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    top_version = re.search(r'^## .*?v?(\d+\.\d+\.\d+)', (ROOT / 'CHANGELOG.md').read_text(), re.M)
    if not top_version or top_version.group(1) != args.version:
        raise SystemExit('CHANGELOG must match the candidate version.')
    profile_ent = validate_profile(args.profile, args.certificate_sha1)
    destination = ROOT / 'outputs/app-store' / (args.version + '-' + args.build)
    destination.mkdir(parents=True, exist_ok=False)
    # Always retain diagnostics when a mandatory functional gate fails.
    with (destination / 'quality-gates.log').open('w') as log:
        run('bash', 'scripts/test_vm_acceptance.sh', stdout=log, stderr=subprocess.STDOUT)
    for product in ('ApexTerm', 'ApexSSHBridge'):
        run('swift', 'build', '-c', 'release', '--product', product, '--jobs', '2')
    binaries = pathlib.Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=ROOT, text=True).strip())
    app = destination / 'AetherTerm.app'
    macos = app / 'Contents/MacOS'
    resources = app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    for name in ('ApexTerm', 'ApexSSHBridge'):
        shutil.copyfile(binaries / name, macos / name)
    shutil.copyfile('/opt/homebrew/bin/sshpass', macos / 'sshpass')
    for executable in macos.iterdir():
        executable.chmod(0o755)
        run('lipo', '-verify_arch', 'arm64', str(executable))
        run('codesign', '--remove-signature', str(executable))
        run('/usr/bin/strip', '-S', str(executable))
    for name, source in (('ApexTerm.icns', 'Resources/ApexTerm.icns'),
                         ('PrivacyInfo.xcprivacy', 'Resources/AppStore/PrivacyInfo.xcprivacy')):
        shutil.copyfile(ROOT / source, resources / name)
    info = {
        'CFBundleExecutable': 'ApexTerm', 'CFBundleIdentifier': 'com.apexterm.app',
        'CFBundleName': 'AetherTerm', 'CFBundleDisplayName': 'AetherTerm',
        'CFBundleIconFile': 'ApexTerm', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': args.version, 'CFBundleVersion': args.build,
        'CFBundleSupportedPlatforms': ['MacOSX'], 'LSMinimumSystemVersion': '14.0',
        'LSApplicationCategoryType': 'public.app-category.developer-tools',
        'NSHighResolutionCapable': True, 'NSRequiresAquaSystemAppearance': False,
        'NSHumanReadableCopyright': '2026 YanNan Chen',
        'NSLocalNetworkUsageDescription': '连接你选择的局域网 SSH 服务器，并进行 SFTP 文件传输和系统监控。',
        'ApexDistributionChannel': 'appStore',
    }
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copyfile(args.profile, app / 'Contents/embedded.provisionprofile')
    ent = plistlib.loads((ROOT / 'Resources/AppStore/ApexTerm.entitlements').read_bytes())
    for key in ('com.apple.application-identifier', 'application-identifier',
                'com.apple.developer.team-identifier', 'keychain-access-groups'):
        if key in profile_ent:
            ent[key] = profile_ent[key]
    ent_path = destination / 'signing-entitlements.plist'
    ent_path.write_bytes(plistlib.dumps(ent))
    run('python3', 'scripts/verify_bundle_security.py', str(app))
    for name in ('ApexSSHBridge', 'sshpass'):
        run('codesign', '--force', '--sign', args.certificate_sha1,
            '--identifier', 'com.apexterm.app.' + name,
            '--entitlements', str(ROOT / 'Resources/AppStore/SSHHelper.entitlements'), str(macos / name))
    run('codesign', '--force', '--sign', args.certificate_sha1, '--entitlements', str(ent_path), str(app))
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
    run('python3', 'scripts/audit_app_store_bundle.py', str(app), '--output', str(destination / 'store-audit.json'))
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() != head or subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT):
        raise SystemExit('Source changed during candidate preparation.')
    manifest = {'sourceCommit': head, 'version': args.version, 'build': args.build,
                'app': str(app), 'signature': 'Mac App Distribution',
                'profileSHA256': hashlib.sha256(args.profile.read_bytes()).hexdigest(),
                'binarySHA256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in macos.iterdir()},
                'vmAcceptanceRequired': True, 'uploaded': False,
                'scope': 'Signed candidate only. Verify this exact sandbox product in macos27 before packaging/upload.'}
    (destination / 'candidate-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
