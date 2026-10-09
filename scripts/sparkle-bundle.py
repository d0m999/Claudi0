#!/usr/bin/env python3
"""Pinned Sparkle assembly, inside-out signing and Mach-O verification."""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
FRAMEWORK_REL = Path('Contents/Frameworks/Sparkle.framework')
PUBLIC_KEY = (ROOT / 'config/sparkle-public-key.txt').read_text().strip()
FEEDS = {
    'preview': 'https://d0m999.github.io/Claudi0/preview/appcast.xml',
    'release': 'https://d0m999.github.io/Claudi0/release/appcast.xml',
}

def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()

def macho(path):
    return path.is_file() and not path.is_symlink() and 'Mach-O' in run('file', '-b', path)

def files(framework):
    return sorted((p for p in framework.rglob('*') if macho(p)), key=str)

def embed(app, source):
    destination = app / FRAMEWORK_REL
    assert not destination.exists(), 'refuse an existing Sparkle framework'
    assert run('plutil', '-extract', 'CFBundleShortVersionString', 'raw', source / 'Resources/Info.plist') == '2.10.0'
    shutil.copytree(source, destination, symlinks=True)
    # Non-sandbox app retains upstream tools and XPC services; preserve all versioned links.
    for p in destination.rglob('*'):
        if p.is_symlink():
            assert p.resolve().is_relative_to(destination.resolve()), 'escaping framework link'

def configure(app, channel):
    assert len(base64.b64decode(PUBLIC_KEY, validate=True)) == 32
    plist = app / 'Contents/Info.plist'
    data = plistlib.loads(plist.read_bytes())
    data['ClaudioPublicPreview'] = channel == 'preview'
    if channel != 'development':
        data.update(SUFeedURL=FEEDS[channel], SUPublicEDKey=PUBLIC_KEY,
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                    SUSignedFeedFailureExpirationInterval=0, SUScheduledCheckInterval=86400,
                    SUAllowsAutomaticUpdates=False, SUAutomaticallyUpdate=False,
                    SUEnableSystemProfiling=False)
        # Absence asks consent on second launch. Do not enable checks by default.
        data.pop('SUEnableAutomaticChecks', None)
    plist.write_bytes(plistlib.dumps(data))

def sign(app, identity):
    framework = app / FRAMEWORK_REL
    flags = ['--force', '--sign', identity]
    if identity != '-':
        flags += ['--options', 'runtime', '--timestamp']
    for p in files(framework):
        subprocess.run(['codesign', *flags, str(p)], check=True)
    nested = [p for p in framework.rglob('*') if p.suffix in ('.app', '.xpc') and p.is_dir() and not p.is_symlink()]
    for p in sorted(nested, key=lambda p: len(p.parts), reverse=True):
        subprocess.run(['codesign', *flags, str(p)], check=True)
    subprocess.run(['codesign', *flags, str(framework)], check=True)

def verify(app, required_archs, team=None):
    framework = app / FRAMEWORK_REL
    assert framework.is_dir() and not framework.is_symlink()
    expected = set(required_archs.split(','))
    assert run('plutil', '-extract', 'CFBundleShortVersionString', 'raw', framework / 'Resources/Info.plist') == '2.10.0'
    binaries = files(framework)
    assert len(binaries) == 5, 'unexpected Sparkle Mach-O inventory'
    for p in framework.rglob('*'):
        if p.is_symlink():
            assert p.resolve().is_relative_to(framework.resolve()), 'escaping/broken framework link'
    binaries += [app / 'Contents/MacOS/claudi0-app']
    for p in binaries:
        assert expected <= set(run('lipo', '-archs', p).split()), f'missing architectures: {p}'
        subprocess.run(['codesign', '--verify', '--strict', str(p)], check=True)
        if team:
            subprocess.run([str(ROOT / 'scripts/verify-release-signature.sh'), 'executable', team, str(p)], check=True)
        links = run('otool', '-L', p)
        assert '.build/' not in links and str(ROOT) not in links, f'build-path linkage: {p}'
        for line in links.splitlines():
            if '(compatibility version ' not in line:
                continue
            link = line.strip().split(' (')[0]
            assert link.startswith(('@rpath/', '@loader_path/', '@executable_path/', '/System/Library/', '/usr/lib/')), f'non-portable linkage: {link}'
    gui = app / 'Contents/MacOS/claudi0-app'
    assert '@rpath/Sparkle.framework/Versions/B/Sparkle' in run('otool', '-L', gui)
    assert '@executable_path/../Frameworks' in run('otool', '-l', gui)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(framework)], check=True)
    print('Sparkle 2.10.0 framework, links, architectures and signatures verified')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['embed', 'configure', 'sign', 'verify'])
    parser.add_argument('app', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--channel', choices=['development', 'preview', 'release'], default='development')
    parser.add_argument('--identity', default='-')
    parser.add_argument('--team')
    parser.add_argument('--archs', default='arm64,x86_64')
    args = parser.parse_args()
    if args.action == 'embed': embed(args.app, args.source)
    elif args.action == 'configure': configure(args.app, args.channel)
    elif args.action == 'sign': sign(args.app, args.identity)
    else: verify(args.app, args.archs, args.team)
