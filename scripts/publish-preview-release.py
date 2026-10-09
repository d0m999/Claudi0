#!/usr/bin/env python3
"""Create or reuse a prerelease without replacing any accepted candidate bytes."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPO = 'd0m999/Claudi0'


def api(resource, *, allow_missing=False):
    result = subprocess.run(['gh', 'api', '--include', f'repos/{REPO}/{resource}'],
        capture_output=True, text=True)
    headers, separator, body = result.stdout.partition('\n\n')
    status = re.match(r'HTTP/\S+\s+(\d{3})(?:\s|$)', headers)
    if allow_missing and status and status[1] == '404':
        return None
    result.check_returncode()
    assert separator and status and status[1] == '200', 'unexpected GitHub response'
    return json.loads(body)


def tag_commit(tag, *, allow_missing=False):
    ref = api(f'git/ref/tags/{tag}', allow_missing=allow_missing)
    if ref is None:
        return None
    obj = ref['object']
    seen = set()
    while obj['type'] == 'tag':
        sha = obj['sha']
        assert re.fullmatch(r'[0-9a-f]{40}', sha) and sha not in seen and len(seen) < 32
        seen.add(sha)
        obj = api(f'git/tags/{sha}')['object']
    assert obj['type'] == 'commit', 'release tag does not resolve to a commit'
    return obj['sha']


def publish(directory, repository, commit, version):
    assert repository == REPO, 'unexpected preview repository'
    spec = importlib.util.spec_from_file_location('preview_artifact', ROOT / 'scripts/preview-artifact.py')
    artifact = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(artifact)
    manifest = artifact.validate(directory, commit, version)
    names = [manifest['dmg'], 'SHA256SUMS.txt', 'PREVIEW_MANIFEST.json']
    tag = f'preview-v{version}'
    release = api(f'releases/tags/{tag}', allow_missing=True)
    existing_commit = tag_commit(tag, allow_missing=True)
    if existing_commit is not None:
        assert existing_commit == commit, 'existing tag source commit differs'
    if release is None:
        subprocess.run(['gh', 'release', 'create', tag, '--repo', repository,
            '--target', commit, '--prerelease', '--title', f'claudi0 {version} — 公开预览',
            '--notes-file', str(directory / 'RELEASE_NOTES.md'),
            *[str(directory / name) for name in names]], check=True)
        release = api(f'releases/tags/{tag}')
        existing_commit = tag_commit(tag)
    assert existing_commit == commit, 'release tag source commit differs'
    assert release['tag_name'] == tag and release['draft'] is False and release['prerelease'] is True
    assets = release['assets']
    assert len(assets) == len(names) and {a['name'] for a in assets} == set(names), 'release assets differ'
    with tempfile.TemporaryDirectory(prefix='claudio-preview-release-readback-') as temp:
        for asset in assets:
            original = directory / asset['name']
            assert asset['state'] == 'uploaded' and asset['size'] == original.stat().st_size
            assert isinstance(asset['id'], int) and asset['id'] > 0
            downloaded = Path(temp) / asset['name']
            with downloaded.open('wb') as output:
                subprocess.run(['gh', 'api', f'repos/{REPO}/releases/assets/{asset["id"]}',
                    '--header', 'Accept: application/octet-stream'], stdout=output, check=True)
            assert downloaded.read_bytes() == original.read_bytes(), 'release asset bytes differ'
    print(f'Preview release {tag} matches the original accepted candidate')


if __name__ == '__main__':
    directory, repository, commit, version = sys.argv[1:]
    publish(Path(directory), repository, commit, version)
