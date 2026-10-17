#!/usr/bin/env python3
"""Install a pinned, signed official compiler on disposable macOS CI runners."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

PACKAGE_SHA256 = 'c34e7e5fb0be4bcd61decfd40db1766434d8952d68e37aed90bcff4e8547951c'
PACKAGE_URL = ('https://download.swift.org/swift-6.4.1-release/xcode/'
               'swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-osx.pkg')
TOOLCHAIN_NAME = 'swift-6.4.1-RELEASE.xctoolchain'
DEVELOPER_DIRECTORY = '/Applications/Xcode_26.6.app/Contents/Developer'


def execute(args):
    return subprocess.run([str(x) for x in args], check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout


def file_identity(path):
    real = Path(path).resolve(strict=True)
    descriptor = os.open(real, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise RuntimeError(f'Expected a regular tool or package: {real}')
        hasher = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
        digest = hasher.hexdigest()
    return dict(real_path=str(real), sha256=digest, mode=oct(stat.S_IMODE(metadata.st_mode)))


def installed_tool_identity():
    paths = ['/usr/bin/swift', '/usr/bin/xcrun', '/usr/bin/codesign', '/usr/bin/strip',
             '/usr/sbin/pkgutil', '/usr/sbin/installer']
    paths += [execute(['/usr/bin/xcrun', '--find', name]).strip()
              for name in ['swiftc', 'clang', 'ld']]
    return {path: file_identity(path) for path in paths}


def install(toolchain_root, download_dir):
    target = toolchain_root / TOOLCHAIN_NAME
    if toolchain_root.is_symlink():
        raise RuntimeError('Toolchain root must not be a symbolic link')
    if target.exists() or target.is_symlink():
        raise RuntimeError(f'Toolchain already exists; refusing to overwrite: {target}')
    if not re.fullmatch('[0-9a-f]{64}', PACKAGE_SHA256):
        raise RuntimeError('Pinned toolchain package SHA-256 is invalid')
    before = installed_tool_identity()
    download_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    package = download_dir / 'swift-6.4.1.pkg'
    if package.exists() or package.is_symlink():
        raise RuntimeError('Package download destination already exists')
    execute(['/usr/bin/curl', '--proto', '=https', '--tlsv1.2', '--fail', '--location',
             '--retry', '3', '--output', package, PACKAGE_URL])
    if package.is_symlink() or file_identity(package)['sha256'] != PACKAGE_SHA256:
        raise RuntimeError('Toolchain package SHA-256 mismatch; installation refused')
    signature = execute(['/usr/sbin/pkgutil', '--check-signature', package])
    required_signature = {
        'Status: signed by a developer certificate issued by Apple for distribution',
        'Notarization: trusted by the Apple notary service',
        '1. Developer ID Installer: Swift Open Source (V9AUD2URP3)',
    }
    if not required_signature.issubset({line.strip() for line in signature.splitlines()}):
        raise RuntimeError('Toolchain package signature is not the trusted Swift Open Source identity')
    if target.exists() or target.is_symlink():
        raise RuntimeError(f'Toolchain already exists; refusing to overwrite: {target}')
    execute(['/usr/sbin/installer', '-target', 'CurrentUserHomeDirectory', '-pkg', package])
    compiler = target / 'usr/bin/swift'
    version = execute([compiler, '--version'])
    if not re.search(r'\bSwift version 6\.4\.1(?:\s|$)', version):
        raise RuntimeError(f'Installed compiler version mismatch: {version.strip()}')
    execute(['/usr/bin/codesign', '--verify', '--strict', target / 'usr/bin/swift-frontend'])
    after = installed_tool_identity()
    if before != after:
        raise RuntimeError('Existing tool content or POSIX mode changed during installation')
    with (target / 'Info.plist').open('rb') as stream:
        identifier = plistlib.load(stream)['CFBundleIdentifier']
    if not isinstance(identifier, str) or not re.fullmatch(r'[A-Za-z0-9._-]+', identifier):
        raise RuntimeError('Invalid installed toolchain identifier')
    return dict(TOOLCHAINS=identifier, bin_path=str(target / 'usr/bin'),
                package_sha256=PACKAGE_SHA256, package_url=PACKAGE_URL,
                compiler_version=version.strip(),
                existing_tool_hashes_and_modes_unchanged=True)


def main():
    if (os.environ.get('GITHUB_ACTIONS') != 'true'
            or os.environ.get('RUNNER_OS') != 'macOS'
            or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'):
        raise RuntimeError('Toolchain installation is restricted to disposable macOS GitHub Actions runners')
    if os.environ.get('DEVELOPER_DIR') != DEVELOPER_DIRECTORY:
        raise RuntimeError('Xcode 26.6 must be selected before installing Swift 6.4.1')
    if not execute(['/usr/bin/xcodebuild', '-version']).startswith('Xcode 26.6\n'):
        raise RuntimeError('Selected Xcode version mismatch')
    if execute(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version']).strip() != '26.5':
        raise RuntimeError('Expected the pinned macOS 26.5 SDK')
    sdk = execute(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip()
    if not Path(sdk).is_absolute() or '\n' in sdk:
        raise RuntimeError('Invalid SDK path')
    # Open runner-owned export files without following links before installation.
    descriptors = []
    try:
        for name in ['GITHUB_ENV', 'GITHUB_PATH']:
            descriptor = os.open(os.environ[name], os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
            descriptors.append(descriptor)
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise RuntimeError(f'{name} must be a regular runner export file')
        with tempfile.TemporaryDirectory(prefix='claudio-swift-', dir=os.environ['RUNNER_TEMP']) as temporary:
            result = install(Path.home() / 'Library/Developer/Toolchains', Path(temporary))
        os.write(descriptors[0], f'TOOLCHAINS={result["TOOLCHAINS"]}\nCLAUDIO_BUILD_SDK={sdk}\n'.encode())
        os.write(descriptors[1], (result['bin_path'] + '\n').encode())
        print(json.dumps(dict(result, sdk=sdk), sort_keys=True))
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


if __name__ == '__main__':
    main()
