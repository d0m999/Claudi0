#!/usr/bin/env python3
"""Exercise the workflow publication step with isolated GitHub/readback fixtures."""
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
COMMIT = 'a' * 40
TAG = 'preview-v0.0.1'
REPO = 'd0m999/Claudi0'

FAKE_GH = r'''
import json
import os
from pathlib import Path
import sys

state_path = Path(os.environ['PREVIEW_FIXTURE_STATE'])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
with Path(os.environ['PREVIEW_FIXTURE_LOG']).open('a') as log:
    log.write(json.dumps(args) + '\n')
if args[:2] == ['release', 'create']:
    assert args[2] == 'preview-v0.0.1' and '--prerelease' in args
    assert args[args.index('--repo') + 1] == 'd0m999/Claudi0'
    assert args[args.index('--target') + 1] == os.environ['TARGET_COMMIT']
    assert args[-3:] == ['candidate/claudi0-0.0.1.dmg', 'candidate/SHA256SUMS.txt',
        'candidate/PREVIEW_MANIFEST.json']
    if state['release'] is not None:
        sys.exit('release already exists')
    state['release'] = state['new_release']
    if state['tag'] is None:
        state['tag'] = {'object': {'type': 'commit', 'sha': os.environ['TARGET_COMMIT']}}
    state_path.write_text(json.dumps(state))
    sys.exit(0)
assert args[0] == 'api', args
endpoint = next(arg for arg in args[1:] if arg.startswith('repos/'))
resource = endpoint.removeprefix('repos/d0m999/Claudi0/')
if resource.startswith('releases/assets/'):
    sys.stdout.buffer.write(bytes.fromhex(state['bytes'][resource.rsplit('/', 1)[1]]))
    sys.exit(0)
if resource.startswith('releases/tags/'):
    payload = state['release']
elif resource.startswith('git/ref/tags/'):
    payload = state['tag']
elif resource.startswith('git/tags/'):
    payload = state['annotated_tags'].get(resource.rsplit('/', 1)[1])
else:
    raise AssertionError(resource)
status = state.get('api_status', 200 if payload is not None else 404)
if '--include' in args:
    print(f'HTTP/2.0 {status} Fixture\nContent-Type: application/json\n')
print(json.dumps(payload if status == 200 else {'message': 'fixture API error'}))
sys.exit(0 if status == 200 else 1)
'''

FAKE_PYTHON = r'''
import os
from pathlib import Path
import sys

if Path(sys.argv[1]).name == 'verify-public-preview.py':
    with Path(os.environ['PREVIEW_FIXTURE_LOG']).open('a') as log:
        log.write('["public-readback"]\n')
    sys.exit(int(os.environ.get('PREVIEW_FIXTURE_READBACK_FAILURE', '0')))
os.execv(os.environ['PREVIEW_FIXTURE_PYTHON'], [os.environ['PREVIEW_FIXTURE_PYTHON'], *sys.argv[1:]])
'''


class PreviewReleaseSuite(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='claudio-preview-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.candidate = self.root / 'candidate'
        self.candidate.mkdir()
        dmg = b'accepted original DMG fixture'
        digest = hashlib.sha256(dmg).hexdigest()
        manifest = dict(schema=1, channel='public-preview', source_commit=COMMIT,
            version='0.0.1', dmg='claudi0-0.0.1.dmg', sha256=digest, size=len(dmg),
            sparkle_version='2.10.0', signing='ad-hoc', notarized=False,
            architectures=['arm64', 'x86_64'],
            public_key=(ROOT / 'config/sparkle-public-key.txt').read_text().strip())
        self.files = {'claudi0-0.0.1.dmg': dmg,
            'SHA256SUMS.txt': f'{digest}  claudi0-0.0.1.dmg\n'.encode(),
            'PREVIEW_MANIFEST.json': json.dumps(manifest).encode()}
        for name, data in self.files.items():
            (self.candidate / name).write_bytes(data)
        (self.candidate / 'RELEASE_NOTES.md').write_text('fixture notes')
        release = dict(tag_name=TAG, draft=False, prerelease=True, assets=[
            dict(id=index, name=name, size=len(data), state='uploaded')
            for index, (name, data) in enumerate(self.files.items(), 1)])
        self.state = dict(release=release, new_release=copy.deepcopy(release),
            tag={'object': {'type': 'commit', 'sha': COMMIT}}, annotated_tags={},
            bytes={str(index): data.hex() for index, data in enumerate(self.files.values(), 1)})
        self.state_path = self.root / 'state.json'
        self.log = self.root / 'calls.jsonl'
        (self.root / 'scripts').symlink_to(ROOT / 'scripts', target_is_directory=True)
        binary_dir = self.root / 'bin'
        binary_dir.mkdir()
        for name, source in [('gh', FAKE_GH), ('python3', FAKE_PYTHON)]:
            executable = binary_dir / name
            executable.write_text(f'#!{sys.executable}\n' + source)
            executable.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary_dir) + os.pathsep + os.environ['PATH'],
            GITHUB_REPOSITORY=REPO, TARGET_COMMIT=COMMIT, VERSION='0.0.1',
            PREVIEW_FIXTURE_STATE=str(self.state_path), PREVIEW_FIXTURE_LOG=str(self.log),
            PREVIEW_FIXTURE_PYTHON=sys.executable)
        workflow = (ROOT / '.github/workflows/preview.yml').read_text()
        match = re.search(r'      - name: Publish original DMG and verify public bytes\n'
            r'        run: \|\n((?:          .*\n)+)', workflow)
        self.assertIsNotNone(match, 'publication step must remain in the workflow')
        self.command = '\n'.join(line[10:] for line in match[1].splitlines())

    def publish(self, *, readback_failure=False):
        self.state_path.write_text(json.dumps(self.state))
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', self.command],
            cwd=self.root, env=dict(self.env,
                PREVIEW_FIXTURE_READBACK_FAILURE=str(int(readback_failure))),
            capture_output=True, text=True)
        self.state = json.loads(self.state_path.read_text())
        return result

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_rejected_without_mutation(self):
        before = copy.deepcopy(self.state)
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state, before)
        self.assertFalse(any(call[:2] == ['release', 'create'] or call == ['public-readback']
            for call in self.calls()))

    def test_reuse_exact_release_continues_to_public_readback(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(['public-readback'], self.calls())
        self.assertFalse(any(call[:2] == ['release', 'create'] for call in self.calls()))

    def test_retry_after_public_readback_failure_preserves_original_release(self):
        self.state['release'] = None
        self.state['tag'] = None
        first = self.publish(readback_failure=True)
        self.assertNotEqual(first.returncode, 0)
        self.assertIsNotNone(self.state['release'])
        created = copy.deepcopy(self.state)
        retry = self.publish()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual(self.state, created)
        self.assertEqual(sum(call[:2] == ['release', 'create'] for call in self.calls()), 1)
        self.assertEqual(self.calls().count(['public-readback']), 2)

    def test_reuse_resolves_annotated_tag_to_commit(self):
        self.state['tag']['object'] = dict(type='tag', sha='b' * 40)
        self.state['annotated_tags']['b' * 40] = dict(object=dict(type='commit', sha=COMMIT))
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_retry_after_later_pages_failure_reuses_verified_release(self):
        self.state['release'] = None
        self.state['tag'] = None
        command = self.command
        self.command += '\nexit 1'  # Simulate failure after the publication step completed.
        first = self.publish()
        self.assertNotEqual(first.returncode, 0)
        self.assertIn(['public-readback'], self.calls())
        created = copy.deepcopy(self.state)
        self.command = command
        retry = self.publish()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual(self.state, created)
        self.assertEqual(sum(call[:2] == ['release', 'create'] for call in self.calls()), 1)
        self.assertEqual(self.calls().count(['public-readback']), 2)
        for name, data in self.files.items():
            self.assertEqual((self.candidate / name).read_bytes(), data)

    def test_different_tag_commit_is_rejected(self):
        self.state['tag']['object']['sha'] = 'c' * 40
        self.assert_rejected_without_mutation()

    def test_existing_tag_without_release_must_match_before_creation(self):
        self.state['release'] = None
        self.state['tag']['object']['sha'] = 'c' * 40
        self.assert_rejected_without_mutation()

    def test_changed_asset_bytes_are_rejected_even_at_the_same_size(self):
        for asset in self.state['release']['assets']:
            with self.subTest(asset=asset['name']):
                asset_id = str(asset['id'])
                original = self.state['bytes'][asset_id]
                data = bytes.fromhex(original)
                self.state['bytes'][asset_id] = (bytes([data[0] ^ 1]) + data[1:]).hex()
                self.assert_rejected_without_mutation()
                self.state['bytes'][asset_id] = original

    def test_missing_or_extra_assets_are_rejected(self):
        original = copy.deepcopy(self.state['release']['assets'])
        for assets in [original[:-1], original + [dict(id=4, name='extra', size=1, state='uploaded')]]:
            with self.subTest(assets=assets):
                self.state['release']['assets'] = assets
                self.assert_rejected_without_mutation()

    def test_draft_or_non_prerelease_is_rejected(self):
        for field, invalid in [('draft', True), ('prerelease', False)]:
            with self.subTest(field=field):
                original = self.state['release'][field]
                self.state['release'][field] = invalid
                self.assert_rejected_without_mutation()
                self.state['release'][field] = original

    def test_api_failure_does_not_trigger_release_creation(self):
        self.state['release'] = None
        self.state['api_status'] = 503
        self.assert_rejected_without_mutation()


if __name__ == '__main__':
    unittest.main()
