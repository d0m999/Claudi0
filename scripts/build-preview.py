#!/usr/bin/env python3
"""Build one clean, commit-bound universal preview. Never publish from this entry point."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
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
    sdk = ['--build-system', 'native', '--sdk', env['CLAUDIO_BUILD_SDK']] if env.get('CLAUDIO_BUILD_SDK') else []
    products = [('gui', 'ClaudioGUI'), ('gui', 'ClaudioLoginItem'), ('helper', 'claudio')]
    outputs = {}
    for package, product in products:
        flags = ['-Xswiftc', '-Osize', '-Xswiftc', '-DCLAUDIO_PUBLIC_PREVIEW']
        if product == 'ClaudioGUI': flags += ['--experimental-lto-mode', 'full']
        for arch in ['arm64', 'x86_64']:
            command = ['swift', 'build', '-c', 'release', '--package-path', package, '--product', product, '--arch', arch, *flags, *sdk]
            subprocess.run(command, cwd=ROOT, env=env, check=True)
            outputs[product, arch] = Path(run(*command, '--show-bin-path', env=env)) / product
            stable(commit)
    app = ROOT / 'dist/claudi0.app'
    binaries = {'ClaudioGUI': app / 'Contents/MacOS/claudi0-app',
                'ClaudioLoginItem': app / 'Contents/Library/LoginItems/claudi0 LoginItem.app/Contents/MacOS/claudi0-login-item',
                'claudio': app / 'Contents/Resources/bin/claudi0'}
    for product, destination in binaries.items():
        subprocess.run(['lipo', '-create', str(outputs[product, 'arm64']), str(outputs[product, 'x86_64']), '-output', str(destination)], check=True)
        subprocess.run(['strip', *([] if product == 'ClaudioGUI' else ['-x']), str(destination)], check=True)
    # Resources must be identical across architectures. Never take an unchecked first match.
    arm_dir, x86_dir = outputs['ClaudioGUI', 'arm64'].parent, outputs['ClaudioGUI', 'x86_64'].parent
    for suffix in ['ClaudioGUI.bundle', 'ClaudioLocalization.bundle']:
        arm = list(arm_dir.glob('*_' + suffix)); x86 = list(x86_dir.glob('*_' + suffix))
        assert len(arm) == len(x86) == 1
        subprocess.run(['diff', '-qr', str(arm[0]), str(x86[0])], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(binaries['claudio'])], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app / 'Contents/Library/LoginItems/claudi0 LoginItem.app')], check=True)
    subprocess.run(['python3', 'scripts/sparkle-bundle.py', 'sign', str(app)], cwd=ROOT, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
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
                    signing='ad-hoc', notarized=False, architectures=['arm64', 'x86_64'])
    if args.inspection: manifest['source_tree_sha256'] = INSPECTION_DIGEST
    (ROOT / 'dist/PREVIEW_MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (ROOT / 'dist/SHA256SUMS.txt').write_text(f'{sha}  {dmg.name}\n')
