#!/usr/bin/env python3
"""Scan tracked files and every reachable history blob before public pushes."""
import re
import subprocess
from pathlib import Path

def git(*args):
    return subprocess.check_output(['git', *args])

patterns = [rb'gh[pousr]_[A-Za-z0-9_]{20,}', rb'AKIA[0-9A-Z]{16}', rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', rb'sk-[A-Za-z0-9]{30,}']

def inspect(name, data):
    if name.endswith(('.jsonl', '.log', '.zip', '.pem', '.p12', '.key')) and name != 'fixtures/synthetic.jsonl':
        raise SystemExit(f'Forbidden tracked artifact: {name}')
    if name.startswith(('.build/', 'dist/', 'recordings/', 'exports/')) or Path(name).name.startswith('.env'):
        raise SystemExit(f'Forbidden path: {name}')
    for pattern in patterns:
        if re.search(pattern, data):
            raise SystemExit(f'Potential secret in {name}; inspect locally without printing it')
    if name == 'fixtures/synthetic.jsonl':
        for line in data.splitlines():
            import json
            r = json.loads(line)
            if r.get('synthetic') is not True:
                raise SystemExit('Fixture lacks explicit synthetic marker')

files = git('ls-files', '-z').decode().split('\0')
for name in filter(None, files):
    inspect(name, Path(name).read_bytes())
seen = set()
for commit in git('rev-list', '--all').decode().split():
    for row in git('ls-tree', '-rz', commit).split(b'\0'):
        if not row:
            continue
        meta, path = row.split(b'\t', 1)
        _, kind, oid = meta.split()
        if kind != b'blob':
            continue
        key = (oid, path)
        if key in seen:
            continue
        seen.add(key)
        inspect(path.decode(), git('cat-file', 'blob', oid.decode()))
print(f'AUDIT PASS: {len(list(filter(None, files)))} tracked paths; {len(seen)} reachable history path/blobs. Heuristic scan plus human inspection required; never proof of no secrets.')
