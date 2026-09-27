#!/usr/bin/env python3
"""Remove generated distribution outputs before rebuilding; preserve source and the newest install rollback."""
import argparse
import re
import shutil
import subprocess
from pathlib import Path

PACKAGE = re.compile(r'ApexTerm-v\d+\.\d+\.\d+-macos-arm64\.(dmg|tar\.gz)$')
PREVIOUS_APP = re.compile(r'ApexTerm-previous-\d+\.app$')
FIXED = {'ApexTerm.app', 'ApexTerm-notarization.zip', 'SHA256SUMS.txt',
         'notarization-app.json', 'notarization-dmg.json'}


def artifact_candidates(build_dir, installed_backups_only=False):
    if not build_dir.is_dir() or build_dir.is_symlink():
        return []
    children = list(build_dir.iterdir())
    candidates = [] if installed_backups_only else [p for p in children if p.name in FIXED or PACKAGE.fullmatch(p.name) or PREVIOUS_APP.fullmatch(p.name)]
    backups = sorted((p for p in children if re.fullmatch(r'installed-backup-\d+', p.name)), key=lambda p: p.name)
    candidates.extend(backups[:-1])
    return sorted(candidates)


def prune(build_dir, running_executables=(), dry_run=False, installed_backups_only=False):
    candidates = artifact_candidates(build_dir, installed_backups_only)
    # Do not partially clear a package while an app or its bundled helper still uses it.
    for path in candidates:
        prefix = str(path.absolute()) + '/'
        if any(executable.startswith(prefix) for executable in running_executables):
            raise RuntimeError(f'Previous generated package is still running: {path.name}')
    reclaimed = 0
    for path in candidates:
        entries = [path] if not path.is_dir() or path.is_symlink() else [path, *path.rglob('*')]
        reclaimed += sum(p.lstat().st_size for p in entries if p.is_file() or p.is_symlink())
        print(('Would remove: ' if dry_run else 'Removing: ') + path.name)
        if dry_run:
            continue
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    return reclaimed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--installed-backups-only', action='store_true')
    args = parser.parse_args()
    build_dir = Path(__file__).resolve().parent.parent / '.build'
    processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    try:
        reclaimed = prune(build_dir, [p.strip() for p in processes], args.dry_run, args.installed_backups_only)
    except RuntimeError as error:
        parser.exit(1, str(error) + '\n')
    print(f'Generated artifacts: {reclaimed / 1048576:.1f} MB ' + ('eligible for cleanup' if args.dry_run else 'removed'))


if __name__ == '__main__':
    main()
