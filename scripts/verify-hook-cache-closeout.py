#!/usr/bin/env python3
"""Read-only verification of listed closeout digests; never build or run hooks.

Input roots are explicit. Results go to stdout; no package or verdict is written.
Matching hashes establish saved file identity, not performance or acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat

if not __debug__:
    raise SystemExit('closeout verification requires assertions; do not use python -O or -OO')


class VerificationError(ValueError):
    """A listed file or manifest could not be verified."""


def safe_file(root, name):
    if (not isinstance(name, str) or '\\' in name
            or any(part in ['', '.', '..'] for part in name.split('/'))):
        raise VerificationError('unsafe manifest path')
    path = root
    for part in name.split('/'):
        path = path / part
        if path.is_symlink():
            raise VerificationError('unsafe manifest path: symlink')
    try:
        if not stat.S_ISREG(path.stat().st_mode):
            raise VerificationError('manifest path is not a regular file: ' + name)
    except OSError as error:
        raise VerificationError('manifest file is missing or unreadable: ' + name) from error
    return path


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError('duplicate manifest entry')
        result[key] = value
    return result


def read_manifest(root, name):
    path = safe_file(root, name)
    try:
        manifest = json.loads(path.read_text(), object_pairs_hook=unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError('invalid JSON manifest: ' + name) from error
    if not isinstance(manifest, dict) or not manifest:
        raise VerificationError('manifest must be a nonempty digest map: ' + name)
    if any(not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)
           for value in manifest.values()):
        raise VerificationError('invalid SHA256 digest: ' + name)
    return manifest


def verify_files(root, manifest):
    for name, expected in manifest.items():
        path = safe_file(root, name)
        try:
            actual = digest(path)
        except OSError as error:
            raise VerificationError('manifest file is unreadable: ' + name) from error
        if actual != expected:
            raise VerificationError('digest mismatch: ' + name)
    return len(manifest)


def directory(path, label):
    try:
        resolved = path.resolve(strict=True)
        if not resolved.is_dir():
            raise VerificationError(label + ' must be a directory')
        return resolved
    except OSError as error:
        raise VerificationError(label + ' directory is unavailable') from error


def verify(package, evidence_root=None):
    package = directory(package, 'package')
    manifest = read_manifest(package, 'package-sha256.json')
    package_count = verify_files(package, manifest)
    external_count = 0
    index = package / 'evidence-index.json'
    if 'evidence-index.json' in manifest:
        if evidence_root is None:
            raise VerificationError('--evidence-root is required for the external evidence index')
        external = read_manifest(package, 'evidence-index.json')
        external_count = verify_files(directory(evidence_root, 'evidence root'), external)
    elif index.exists() or index.is_symlink():
        raise VerificationError('external evidence index is missing from the package manifest')
    return dict(schema_version=1, verification='listed-sha256-digests',
                package_files_verified=package_count, external_files_verified=external_count)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True,
                        help='Frozen directory containing package-sha256.json')
    parser.add_argument('--evidence-root', type=Path,
                        help='Explicit root of paths in evidence-index.json, when present')
    args = parser.parse_args()
    try:
        result = verify(args.package, args.evidence_root)
    except VerificationError as error:
        parser.error(str(error))
    print(json.dumps(result))


if __name__ == '__main__':
    main()
