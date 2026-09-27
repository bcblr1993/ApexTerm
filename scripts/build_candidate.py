#!/usr/bin/env python3
"""Build a notarized internal candidate without replacing the installed product."""
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'outputs/macos27/candidate'
APP = OUT / 'ApexTerm Candidate.app'
IDENTITY = 'Developer ID Application: YanNan Chen (5984KQD4D7)'


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def clean_generated(output):
    # Exact generated paths only; diagnostics and unrelated files are retained.
    names = ['ApexTerm Candidate.app', 'ApexTerm-Candidate-arm64.dmg',
                 'ApexTerm-Candidate-arm64.tar.gz', 'notarization.zip',
                 'notarization.json', 'notarization-dmg.json', 'SHA256SUMS.txt', 'candidate-manifest.txt']
    for name in names:
        path = output / name
        if path.is_symlink():
            raise SystemExit(f'Refusing generated path symlink: {name}')
    for name in names:
        path = output / name
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()

def main():
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT):
        raise SystemExit('Commit candidate source changes before building.')
    version = re.search(r'## \[v(\d+\.\d+\.\d+)\]', (ROOT / 'CHANGELOG.md').read_text()).group(1)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    running = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    if any('/candidate/ApexTerm Candidate.app/' in line for line in running):
        raise SystemExit('Close the previous candidate before rebuilding.')
    build = int(datetime.date.today().strftime("%Y%m%d") + "01")
    if (APP / 'Contents/Info.plist').is_file():
        with (APP / 'Contents/Info.plist').open('rb') as file:
            build = max(build, int(plistlib.load(file)['CFBundleVersion']) + 1)
    OUT.mkdir(parents=True, exist_ok=True)
    clean_generated(OUT)
    run('./scripts/test_vm_acceptance.sh')
    run('swift', 'build', '-c', 'release')
    (APP / 'Contents/MacOS').mkdir(parents=True)
    (APP / 'Contents/Resources').mkdir()
    shutil.copy2(ROOT / '.build/out/Products/Release/ApexTerm', APP / 'Contents/MacOS/ApexTerm')
    shutil.copy2(ROOT / 'Resources/ApexTerm.icns', APP / 'Contents/Resources/ApexTerm.icns')
    helper = pathlib.Path('/opt/homebrew/bin/sshpass')
    if helper.is_file():
        shutil.copy2(helper, APP / 'Contents/MacOS/sshpass')
        run('codesign', '--force', '--sign', IDENTITY, '--options', 'runtime', '--timestamp', str(APP / 'Contents/MacOS/sshpass'))
    with (APP / 'Contents/Info.plist').open('wb') as file:
        plistlib.dump({'CFBundleExecutable': 'ApexTerm', 'CFBundleIdentifier': 'com.apexterm.candidate',
                      'CFBundleName': 'ApexTerm Candidate', 'CFBundleDisplayName': 'ApexTerm Candidate',
                      'CFBundleIconFile': 'ApexTerm', 'CFBundlePackageType': 'APPL',
                      'CFBundleShortVersionString': version, 'CFBundleVersion': str(build),
                      'NSLocalNetworkUsageDescription': '连接你选择的局域网 SSH 服务器，并进行 SFTP 文件传输和系统监控。',
                      'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True, 'NSRequiresAquaSystemAppearance': False}, file)
    run('python3', 'scripts/verify_bundle_security.py', str(APP))
    run('codesign', '--force', '--deep', '--sign', IDENTITY, '--options', 'runtime', '--timestamp', str(APP))
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(APP))
    archive = OUT / 'notarization.zip'
    run('ditto', '-c', '-k', '--keepParent', str(APP), str(archive))
    notarize(archive, OUT / 'notarization.json')
    run('xcrun', 'stapler', 'staple', str(APP))
    run('xcrun', 'stapler', 'validate', str(APP))
    tar = OUT / 'ApexTerm-Candidate-arm64.tar.gz'
    run('tar', '-czf', str(tar), '-C', str(OUT), APP.name)
    dmg = OUT / 'ApexTerm-Candidate-arm64.dmg'
    with tempfile.TemporaryDirectory(prefix='apex-candidate-') as tmp:
        shutil.copytree(APP, pathlib.Path(tmp) / APP.name)
        (pathlib.Path(tmp) / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-volname', 'ApexTerm Candidate', '-srcfolder', tmp, '-format', 'UDZO', str(dmg))
    run('codesign', '--force', '--sign', IDENTITY, '--timestamp', str(dmg))
    notarize(dmg, OUT / 'notarization-dmg.json')
    run('xcrun', 'stapler', 'staple', str(dmg))
    run('xcrun', 'stapler', 'validate', str(dmg))
    (OUT / 'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in [dmg, tar]))
    (OUT / 'candidate-manifest.txt').write_text(f'Internal candidate; not a published version.\nSource commit: {head}\nBuild: {build}\n')


def notarize(path, report):
    with report.open('w') as file:
        run('xcrun', 'notarytool', 'submit', str(path), '--keychain-profile', 'AetherRoute-Notary', '--wait', '--output-format', 'json', stdout=file)
    if json.loads(report.read_text()).get('status') != 'Accepted':
        raise SystemExit('Apple notarization did not accept the candidate.')


if __name__ == '__main__':
    main()
