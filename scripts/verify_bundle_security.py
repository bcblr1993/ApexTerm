#!/usr/bin/env python3
"""Fail release packaging on credentials, session stores or private endpoints."""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]) / 'Contents'
private_ip = re.compile(rb'(?<![\d.])(?:10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)(?![\d.])')
key_marker = re.compile(rb'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')
failed = False
for directory in ('MacOS', 'Resources'):
    for path in (root / directory).rglob('*'):
        if not path.is_file():
            continue
        forbidden_name = path.suffix in ('.pem', '.key') or 'id_rsa' in path.name or (path.name.startswith('sessions') and path.suffix == '.json')
        data = path.read_bytes()
        if forbidden_name or key_marker.search(data) or private_ip.search(data):
            print(f'Forbidden credential or private endpoint in {path.relative_to(root)}', file=sys.stderr)
            failed = True
if failed:
    sys.exit(1)
print('Bundle credential and private endpoint scan passed')
