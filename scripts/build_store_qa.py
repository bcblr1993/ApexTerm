#!/usr/bin/env python3
"""Prepare an isolated optimized App Sandbox bundle for macos27; never release/install it."""
import hashlib
import json
import pathlib
import platform
import plistlib
import re
import shutil
import subprocess
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def metadata(identifier):
    if not identifier.startswith('com.apexterm.qa.store.'):
        raise ValueError('Sandbox QA must use a separate QA bundle identifier.')
    return {
        'CFBundleExecutable': 'ApexTerm', 'CFBundleIdentifier': identifier,
        'CFBundleName': 'AetherTerm Store QA', 'CFBundleDisplayName': 'AetherTerm Store QA',
        'CFBundleIconFile': 'ApexTerm', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.0.0', 'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True,
        'NSRequiresAquaSystemAppearance': False,
        'NSLocalNetworkUsageDescription': '连接你选择的 SSH 测试服务器，验证沙盒文件传输。',
        'ApexDistributionChannel': 'appStore', 'ApexBuildPurpose': 'sandboxQA',
    }


def assemble(destination, binaries, sshpass, identifier):
    info = metadata(identifier)
    # Exclusive directory creation prevents overwriting previous artifacts or user files.
    destination.mkdir(parents=True, exist_ok=False)
    app = destination / 'ApexTerm Store QA.app'
    macos = app / 'Contents/MacOS'
    resources = app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    for name in ('ApexTerm', 'ApexSSHBridge'):
        shutil.copyfile(binaries / name, macos / name)
        (macos / name).chmod(0o755)
    shutil.copyfile(sshpass, macos / 'sshpass')
    (macos / 'sshpass').chmod(0o755)
    shutil.copyfile(ROOT / 'Resources/ApexTerm.icns', resources / 'ApexTerm.icns')
    shutil.copyfile(ROOT / 'Resources/AppStore/PrivacyInfo.xcprivacy', resources / 'PrivacyInfo.xcprivacy')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    return app


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This QA bundle requires an Apple Silicon Mac.')
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT):
        raise SystemExit('Commit QA source changes before building.')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    sshpass = pathlib.Path('/opt/homebrew/bin/sshpass')
    if not sshpass.is_file():
        raise SystemExit('The existing arm64 sshpass helper is required; nothing was installed.')
    # Optimized QA matches production compilation, but retains the isolated QA ID,
    # 0.0.0 metadata and ad hoc signing. Formal distribution remains separate.
    for product in ('ApexTerm', 'ApexSSHBridge'):
        run('swift', 'build', '--configuration', 'release', '--product', product, '--jobs', '2')
    binaries = pathlib.Path(subprocess.check_output(
        ['swift', 'build', '--configuration', 'release', '--show-bin-path'], cwd=ROOT, text=True).strip())
    for binary in (binaries / 'ApexTerm', binaries / 'ApexSSHBridge', sshpass):
        run('lipo', '-verify_arch', 'arm64', str(binary))
    nonce = uuid.uuid4().hex
    identifier = 'com.apexterm.qa.store.' + nonce
    destination = ROOT / 'outputs/store-qa' / (head[:12] + '-' + nonce[:8])
    app = assemble(destination, binaries, sshpass, identifier)
    for name in ('ApexTerm', 'ApexSSHBridge', 'sshpass'):
        executable = app / 'Contents/MacOS' / name
        run('codesign', '--remove-signature', str(executable))
        # SwiftPM's Debug framework search directory is developer-local. All
        # bundled dependencies are statically linked; keep system rpaths only.
        load_commands = subprocess.check_output(['otool', '-l', str(executable)], text=True)
        for path in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', load_commands):
            if path.startswith(str(ROOT) + '/'):
                run('install_name_tool', '-delete_rpath', path, str(executable))
        run('/usr/bin/strip', '-S', str(executable))
    for name in ('ApexSSHBridge', 'sshpass'):
        run('codesign', '--force', '--sign', '-', '--identifier', identifier + '.' + name,
            '--entitlements', str(ROOT / 'Resources/AppStore/SSHHelper.entitlements'), str(app / 'Contents/MacOS' / name))
    run('python3', 'scripts/verify_bundle_security.py', str(app))
    run('codesign', '--force', '--sign', '-', '--entitlements',
        str(ROOT / 'Resources/AppStore/ApexTerm.entitlements'), str(app))
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
    actual = plistlib.loads(subprocess.check_output(
        ['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
    expected = plistlib.loads((ROOT / 'Resources/AppStore/ApexTerm.entitlements').read_bytes())
    if any(actual.get(key) != value for key, value in expected.items()):
        raise SystemExit('Signed QA sandbox entitlements do not match the application template.')
    for name in ('ApexSSHBridge', 'sshpass'):
        helper = plistlib.loads(subprocess.check_output(
            ['codesign', '-d', '--entitlements', ':-', str(app / 'Contents/MacOS' / name)], stderr=subprocess.DEVNULL))
        expected_helper = plistlib.loads((ROOT / 'Resources/AppStore/SSHHelper.entitlements').read_bytes())
        if helper != expected_helper:
            raise SystemExit('Signed QA helper sandbox entitlements do not match inheritance template.')
    manifest = {
        'scope': 'Internal optimized sandbox QA; not a release, Store-signed build, or uploaded package.',
        'sourceCommit': head, 'configuration': 'release', 'signature': 'ad hoc',
        'bundleIdentifier': identifier, 'app': str(app), 'launched': False,
        'binarySHA256': {name: hashlib.sha256((app / 'Contents/MacOS' / name).read_bytes()).hexdigest()
                         for name in ('ApexTerm', 'ApexSSHBridge', 'sshpass')},
    }
    (destination / 'qa-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
