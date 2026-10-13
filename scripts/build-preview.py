#!/usr/bin/env python3
"""Build one clean, commit-bound arm64-only preview. Never publish from this entry point."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

def run(*args, **kwargs):
    return subprocess.check_output([str(a) for a in args], cwd=ROOT, text=True, **kwargs).strip()

def source_digest():
    paths = run('git', 'ls-files', '--cached', '--others', '--exclude-standard').splitlines()
    digest = hashlib.sha256()
    for name in sorted(set(paths)):
        path = ROOT / name
        # Evidence bookkeeping can be updated after compilation without changing product bytes.
        if name == 'docs/preview-acceptance.md': continue
        digest.update(name.encode() + b'\0')
        if path.is_symlink(): digest.update(os.readlink(path).encode())
        elif path.is_file(): digest.update(path.read_bytes())
        else: digest.update(b'<absent>')
    return digest.hexdigest()

INSPECTION_DIGEST = None

def stable(commit):
    assert run('git', 'rev-parse', 'HEAD') == commit, 'source HEAD changed'
    if INSPECTION_DIGEST is not None:
        assert source_digest() == INSPECTION_DIGEST, 'inspection source changed during build'
    else:
        assert not run('git', 'status', '--porcelain', '--untracked-files=all'), 'candidate requires clean source'

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('version'); parser.add_argument('commit')
    parser.add_argument('--inspection', action='store_true', help='uncommitted local source; cannot publish')
    args = parser.parse_args()
    version, commit = args.version, args.commit
    if args.inspection: INSPECTION_DIGEST = source_digest()

    assert re.fullmatch(r'0\.0\.[1-9][0-9]*', version), 'preview version must be 0.0.N'
    assert re.fullmatch(r'[0-9a-f]{40}', commit), 'exact commit required'
    stable(commit)
    env = dict(os.environ, CLAUDIO_VERSION=version)
    subprocess.run(['bash', 'scripts/dev-bundle.sh', '--public-preview'], cwd=ROOT, env=env, check=True)
    stable(commit)
    app = ROOT / 'dist/claudi0.app'
    # dev-bundle owns the arm64 build, resources, strip and inside-out signing.
    subprocess.run(['python3', 'scripts/verify-preview.py', 'app', str(app), version], cwd=ROOT, check=True)
    staging = ROOT / 'dist/preview-dmg'
    staging.mkdir(exist_ok=False)
    subprocess.run(['ditto', str(app), str(staging / 'claudi0.app')], check=True)
    (staging / 'Applications').symlink_to('/Applications')
    shutil.copyfile(ROOT / 'docs/preview-install.txt', staging / 'READ ME.txt')
    dmg = ROOT / f'dist/claudi0-{version}.dmg'
    subprocess.run(['hdiutil', 'create', '-volname', f'claudi0 {version} Public Preview', '-srcfolder', str(staging), '-ov', '-format', 'UDZO', str(dmg)], check=True)
    subprocess.run(['python3', 'scripts/verify-preview.py', 'dmg', str(dmg), version], cwd=ROOT, check=True)
    stable(commit)
    sha = hashlib.sha256(dmg.read_bytes()).hexdigest()
    manifest = dict(schema=1, channel='local-inspection' if args.inspection else 'public-preview', source_commit=commit, version=version,
                    dmg=dmg.name, sha256=sha, size=dmg.stat().st_size,
                    sparkle_version='2.10.0', public_key=(ROOT / 'config/sparkle-public-key.txt').read_text().strip(),
                    run_id=os.environ.get('GITHUB_RUN_ID'), repository=os.environ.get('GITHUB_REPOSITORY'),
                    signing='ad-hoc', notarized=False, architectures=['arm64'])
    if args.inspection: manifest['source_tree_sha256'] = INSPECTION_DIGEST
    (ROOT / 'dist/PREVIEW_MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (ROOT / 'dist/SHA256SUMS.txt').write_text(f'{sha}  {dmg.name}\n')
