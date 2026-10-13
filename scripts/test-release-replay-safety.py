#!/usr/bin/env python3
"""Exercise the replay CLI without invoking a real host or reading live Claudio state."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name('measure-release-hooks.py')
PYTHON_MODES = [('normal', [], None), ('-O', ['-O'], None),
                ('PYTHONOPTIMIZE', [], '1')]

# Run the actual authorized CLI in a child interpreter. Only external discovery and
# kernel process identity are substituted; paths, snapshots, helper execution and
# sample validation all use the production driver and a disposable filesystem.
ISOLATED_DRIVER = '''
import ctypes
import importlib.util
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import Mock, patch

script, fixture = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location('release_replay', script)
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)
sys.argv = [str(script), *sys.argv[3:]]

def process_path(pid, buffer, size):
    identity = os.environ.get('CLAUDIO_REPLAY_TEST_GUI', 'valid')
    if identity == 'unavailable':
        return 0
    executable = fixture / ('harness' if identity == 'harness' else 'claudi0-app')
    buffer.value = os.fsencode(executable)
    return len(buffer.value)

def check_output(command, **kwargs):
    outputs = {('claude', '--version'): 'Claude Code 2.1.0',
               ('codex', '--version'): 'codex-cli 0.1.0',
               ('git', 'rev-parse', 'HEAD'): 'fixture-sha',
               ('git', 'status', '--porcelain'): ''}
    if tuple(command) not in outputs:
        raise RuntimeError('unexpected external command in isolated replay')
    value = outputs[tuple(command)]
    return value if kwargs.get('text') else value.encode()

library = SimpleNamespace(proc_pidpath=Mock(side_effect=process_path))
with patch.object(Path, 'home', return_value=fixture), \\
     patch.object(replay.os, 'kill'), \\
     patch.object(replay.ctypes, 'CDLL', return_value=library), \\
     patch.object(replay.subprocess, 'check_output', side_effect=check_output):
    replay.main()
'''

ISOLATED_HELPER = '''
import json
import os
from pathlib import Path
import sys
import time
import uuid

fixture = Path(os.environ['CLAUDIO_REPLAY_TEST_DIRECTORY'])
root = fixture / '.claudio'
host, event, supplied_installation = sys.argv[2], sys.argv[3], sys.argv[-1]
marker = root / 'integrations/installations' / (host + '.json')
installation = json.loads(marker.read_text())['installation_id']
accepted = supplied_installation == installation
scenario = 'lock-busy' if accepted else 'stale-installation'
with (fixture / 'helper-calls').open('a') as trace:
    trace.write(scenario + '\\n')
mode = os.environ.get('CLAUDIO_REPLAY_TEST_CASE', 'valid')
current = root / 'integrations/receipts' / host
history = root / 'integrations/receipt-history' / host
receipt = dict(installation_id=installation, native_event=event,
               playback_result='debounced', timestamp=time.time())

def archive():
    (history / (str(uuid.uuid4()) + '.json')).write_text(json.dumps(receipt))

if accepted:
    if mode == 'wrong-result':
        receipt['playback_result'] = 'muted'
    elif mode == 'wrong-installation':
        receipt['installation_id'] = str(uuid.uuid4())
    elif mode == 'wrong-event':
        receipt['native_event'] = 'Stop'
    elif mode == 'old-timestamp':
        receipt['timestamp'] = 0
    (current / (event + '.json')).write_text(json.dumps(receipt))
    if mode != 'missing-archive':
        archive()
    if mode == 'extra-archive':
        archive()
    if mode == 'config-change':
        (root / 'config.json').write_text('{}')
    elif mode == 'marker-change':
        marker.write_text(json.dumps({'installation_id': str(uuid.uuid4())}))
    elif mode == 'helper-drift':
        with Path(sys.argv[0]).open('a') as helper:
            helper.write('\\n# changed\\n')
    elif mode == 'source-drift':
        (fixture / 'compiled-source').write_text('changed')
else:
    if mode == 'rejected-history':
        archive()
    elif mode == 'rejected-current':
        (current / 'Stop.json').write_text('changed')
    elif mode == 'rejected-current-created':
        (current / 'Notification.json').write_text('{}')
    elif mode == 'rejected-current-deleted':
        (current / 'Stop.json').unlink()
if mode == 'stdout':
    print('unexpected output')
elif mode == 'nonzero':
    sys.exit(1)
'''


class ReleaseReplaySafetyTests(unittest.TestCase):
    def test_real_host_environment_reuses_api_settings_without_persisting_them(self):
        spec = importlib.util.spec_from_file_location(
            'real_hook', SCRIPT.with_name('measure-real-hook.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='claudio-api-environment-') as directory:
            home = Path(directory)
            settings = home / '.claude/settings.json'
            settings.parent.mkdir()
            settings.write_text(json.dumps({'env': {
                'ANTHROPIC_API_KEY': 'fixture-only-key', 'ANTHROPIC_MODEL': 'fixture-model',
                'API_TIMEOUT_MS': '1000', 'CLAUDIO_UNRELATED_FIELD': 'must-not-import'}}))
            environment = module.host_environment(home)
            self.assertEqual(environment['ANTHROPIC_API_KEY'], 'fixture-only-key')
            self.assertEqual(environment['ANTHROPIC_MODEL'], 'fixture-model')
            self.assertNotIn('CLAUDIO_UNRELATED_FIELD', environment)
            self.assertEqual(list(home.rglob('*')), [settings.parent, settings])

    def test_timeout_snapshot_covers_real_activity_summary_and_pending(self):
        spec = importlib.util.spec_from_file_location(
            'release_timeout', SCRIPT.with_name('measure-release-hook-timeout.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='claudio-timeout-snapshot-') as directory:
            root = Path(directory)
            pending = root / 'integrations/activity/pending'
            pending.mkdir(parents=True)
            summary = pending.parent / 'summary.json'
            delta = pending / 'delta.json'
            summary.write_text('{"buckets":[]}')
            delta.write_text('{"event":"task_start"}')
            decoy = root / 'activity'
            decoy.mkdir()
            (decoy / 'summary.json').write_text('legacy decoy')
            before = module.activity_files(root)
            self.assertEqual(set(before), {summary, delta})
            summary.write_text('{"buckets":[{}]}')
            self.assertNotEqual(module.activity_files(root), before)
            delta.unlink()
            self.assertEqual(set(module.activity_files(root)), {summary})
            delta.symlink_to(summary)
            with self.assertRaisesRegex(RuntimeError, 'regular files'):
                module.activity_files(root)

    def test_real_host_batch_and_optimized_diagnostics_stop_before_live_state(self):
        with tempfile.TemporaryDirectory(prefix='claudio-measurement-safety-') as directory:
            fixture = Path(directory)
            commands = [
                [sys.executable, str(SCRIPT.with_name('measure-real-hook.py')),
                 '--helper', str(fixture / 'missing-helper'), '--output', str(fixture / 'output'),
                 '--samples', '2', '--hold-playback-lock'],
                [sys.executable, '-O', str(SCRIPT.with_name('measure-release-hook-timeout.py')),
                 '--helper', str(fixture / 'missing-helper'), '--build-metadata', str(fixture / 'missing-build'),
                 '--output', str(fixture / 'output')],
            ]
            for command in commands:
                with self.subTest(script=command[1:3]):
                    result = subprocess.run(command, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertNotIn('Traceback', result.stderr)
                    self.assertFalse((fixture / 'output').exists())

    def test_default_rejects_before_any_external_process_or_output(self):
        with tempfile.TemporaryDirectory(prefix='claudio-replay-safety-') as directory:
            fixture = Path(directory)
            marker = fixture / 'external-process-called'
            # An old driver stops at this host-version probe, before it can read ~/.claudio.
            # The same tripwire stands in for the helper; no real hook can be invoked.
            tripwire = '#!/bin/sh\n: > "$CLAUDIO_REPLAY_TEST_MARKER"\nexit 97\n'
            for name in ['claude', 'helper']:
                path = fixture / name
                path.write_text(tripwire)
                path.chmod(0o755)
            environment = dict(os.environ, PATH=str(fixture),
                               CLAUDIO_REPLAY_TEST_MARKER=str(marker))
            destination = fixture / 'output'
            result = subprocess.run(
                [sys.executable, str(SCRIPT), '--helper', str(fixture / 'helper'),
                 '--host', 'claude-code', '--output', str(destination)],
                env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('live-state replay is disabled by default', result.stderr)
            self.assertIn('banner notices', result.stderr)
            self.assertIn('receipts', result.stderr)
            self.assertIn('activity counts', result.stderr)
            self.assertIn('benchmark-hooks.py', result.stderr)
            self.assertFalse(marker.exists(), 'default invocation must not spawn host/helper')
            self.assertFalse(destination.exists(), 'rejection must not create output artifacts')
            self.assertEqual(result.stdout, '')

    def test_all_hosts_reject_before_helper_access_even_with_python_optimization(self):
        with tempfile.TemporaryDirectory(prefix='claudio-replay-safety-') as directory:
            fixture = Path(directory)
            for host in ['claude-code', 'codex', 'workbuddy']:
                for name, options, optimize in PYTHON_MODES:
                    with self.subTest(host=host, python=name):
                        environment = dict(os.environ)
                        environment.pop('PYTHONOPTIMIZE', None)
                        if optimize:
                            environment['PYTHONOPTIMIZE'] = optimize
                        destination = fixture / 'output'
                        result = subprocess.run(
                            [sys.executable, *options, str(SCRIPT), '--helper',
                             str(fixture / 'missing-helper'), '--host', host,
                             '--output', str(destination), '--samples', '2',
                             '--warmup', '1', '--rounds', '2'],
                            env=environment, capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn('live-state replay is disabled by default', result.stderr)
                        self.assertIn('6 accepted events, including warmup', result.stderr)
                        self.assertNotIn('Traceback', result.stderr)
                        self.assertFalse(destination.exists())

    def test_opt_in_must_be_explicit_and_complete(self):
        with tempfile.TemporaryDirectory(prefix='claudio-replay-safety-') as directory:
            fixture = Path(directory)
            command = [sys.executable, str(SCRIPT), '--helper', str(fixture / 'missing-helper'),
                       '--host', 'claude-code', '--output', str(fixture / 'output')]
            abbreviated = subprocess.run(command + ['--allow-live'],
                                         capture_output=True, text=True, timeout=10)
            self.assertEqual(abbreviated.returncode, 2, abbreviated.stderr)
            self.assertIn('unrecognized arguments: --allow-live', abbreviated.stderr)
            # The full opt-in reaches preflight, then the missing fake helper stops the run
            # before host discovery or user-state access. No real replay is authorized here.
            for _, options, optimize in PYTHON_MODES:
                environment = dict(os.environ)
                environment.pop('PYTHONOPTIMIZE', None)
                if optimize:
                    environment['PYTHONOPTIMIZE'] = optimize
                with self.subTest(options=options, optimize=optimize):
                    explicit = subprocess.run(
                        [command[0], *options, *command[1:], '--allow-live-state-replay'],
                        env=environment, capture_output=True, text=True, timeout=10)
                    self.assertEqual(explicit.returncode, 1, explicit.stderr)
                    self.assertIn('FileNotFoundError', explicit.stderr)
                    self.assertIn('missing-helper', explicit.stderr)
                    self.assertNotIn('live-state replay is disabled by default', explicit.stderr)
                    self.assertFalse((fixture / 'output').exists())


class AuthorizedReleaseReplayTests(unittest.TestCase):
    def prepare_fixture(self, fixture, host='codex'):
        root = fixture / '.claudio'
        for folder in ['installations', 'receipts/' + host, 'receipt-history/' + host]:
            (root / 'integrations' / folder).mkdir(parents=True, exist_ok=True)
        (root / 'config.json').write_text(json.dumps({
            'host_integrations': {'surfaces': {host: {'enabled': True}}}}))
        (root / 'gui-run.json').write_text(json.dumps({'process': {'pid': 123}}))
        (root / 'integrations/installations' / (host + '.json')).write_text(json.dumps({
            'installation_id': '10000000-0000-4000-8000-000000000001'}))
        (root / 'integrations/receipts' / host / 'Stop.json').write_text('{}')
        (fixture / 'claudi0-app').write_bytes(b'fixture GUI')
        (fixture / 'harness').write_bytes(b'fixture harness')
        helper = fixture / 'helper'
        helper.write_text('#!' + sys.executable + '\n' + ISOLATED_HELPER)
        helper.chmod(0o700)
        source = fixture / 'compiled-source'
        source.write_text('fixture compiled input')
        (fixture / 'build.json').write_text(json.dumps({
            'helper_sha256': hashlib.sha256(helper.read_bytes()).hexdigest(),
            'source_sha256': {str(source): hashlib.sha256(source.read_bytes()).hexdigest()},
            'build': 'isolated fixture'}))
        return root

    def run_replay(self, fixture, python_mode, host='codex', case='valid', extra=(), gui='valid'):
        _, options, optimize = python_mode
        environment = dict(os.environ, CLAUDIO_REPLAY_TEST_DIRECTORY=str(fixture),
                           CLAUDIO_REPLAY_TEST_CASE=case, CLAUDIO_REPLAY_TEST_GUI=gui)
        environment.pop('PYTHONOPTIMIZE', None)
        if optimize:
            environment['PYTHONOPTIMIZE'] = optimize
        return subprocess.run(
            [sys.executable, *options, '-c', ISOLATED_DRIVER, str(SCRIPT), str(fixture),
             '--allow-live-state-replay', '--helper', str(fixture / 'helper'), '--host', host,
             '--output', str(fixture / 'output'), '--build-metadata', str(fixture / 'build.json'),
             '--samples', '1', '--warmup', '0', '--rounds', '1', *extra],
            env=environment, capture_output=True, text=True, timeout=10)

    def assert_incomplete(self, fixture, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((fixture / 'output/metadata.json').exists())
        self.assertFalse((fixture / 'output/summary.json').exists())

    def test_snapshot_includes_each_stable_event_and_archive(self):
        spec = importlib.util.spec_from_file_location('release_replay_snapshot', SCRIPT)
        replay = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(replay)
        with tempfile.TemporaryDirectory(prefix='claudio-receipt-snapshot-') as directory:
            root = self.prepare_fixture(Path(directory))
            current = root / 'integrations/receipts/codex'
            event = current / 'UserPromptSubmit.json'
            event.write_text('{}')
            archive = root / 'integrations/receipt-history/codex/archive.json'
            archive.write_text('{}')
            unrelated = root / 'integrations/receipts/claude-code'
            unrelated.mkdir()
            (unrelated / 'Stop.json').write_text('{}')
            before = replay.receipt_files(root, 'codex')
            self.assertEqual(set(before), {current / 'Stop.json', event, archive})
            event.write_text('changed')
            self.assertNotEqual(before, replay.receipt_files(root, 'codex'))
            before = replay.receipt_files(root, 'codex')
            event.unlink()
            self.assertNotEqual(before, replay.receipt_files(root, 'codex'))

    def test_valid_authorized_replay_succeeds_in_all_python_modes(self):
        for host in ['claude-code', 'codex']:
            for mode in PYTHON_MODES:
                with self.subTest(host=host, python=mode[0]), tempfile.TemporaryDirectory() as directory:
                    fixture = Path(directory)
                    self.prepare_fixture(fixture, host)
                    result = self.run_replay(fixture, mode, host=host)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    metadata = json.loads((fixture / 'output/metadata.json').read_text())
                    self.assertTrue(metadata['complete'])
                    rows = [json.loads(line) for line in (fixture / 'output/samples.jsonl').read_text().splitlines()]
                    self.assertEqual(len(rows), 2)
                    self.assertTrue(all(row['valid'] for row in rows))
                    accepted = [row for row in rows if row['scenario'] == 'lock-busy']
                    self.assertEqual(accepted[0]['archive_results'], ['debounced'])

    def test_invalid_samples_never_publish_success_in_all_python_modes(self):
        cases = {'wrong-result': ('lock-busy', 'lock-busy branch'),
                 'missing-archive': ('lock-busy', 'one archive'),
                 'extra-archive': ('lock-busy', 'one archive'),
                 'wrong-installation': ('lock-busy', 'installation'),
                 'wrong-event': ('lock-busy', 'event'),
                 'old-timestamp': ('lock-busy', 'invocation'),
                 'rejected-history': ('stale-installation', 'modified receipts'),
                 'rejected-current': ('stale-installation', 'modified receipts'),
                 'rejected-current-created': ('stale-installation', 'modified receipts'),
                 'rejected-current-deleted': ('stale-installation', 'modified receipts'),
                 'stdout': (None, 'zero-output'), 'nonzero': (None, 'zero-output'),
                 'config-change': ('lock-busy', 'intent/installation changed'),
                 'marker-change': ('lock-busy', 'intent/installation changed')}
        for case, (scenario, message) in cases.items():
            for mode in PYTHON_MODES:
                with self.subTest(case=case, python=mode[0]), tempfile.TemporaryDirectory() as directory:
                    fixture = Path(directory)
                    self.prepare_fixture(fixture)
                    result = self.run_replay(fixture, mode, case=case)
                    self.assert_incomplete(fixture, result)
                    self.assertIn(message, result.stderr)
                    samples = fixture / 'output/samples.jsonl'
                    rows = [json.loads(line) for line in samples.read_text().splitlines()] if samples.exists() else []
                    self.assertFalse(any(row['valid'] and (scenario is None or row['scenario'] == scenario)
                                         for row in rows))

    def test_preflight_rejects_invalid_identity_before_helper_in_all_python_modes(self):
        cases = ['debug-helper', 'helper-hash', 'source-hash', 'disabled', 'unavailable', 'harness']
        for case in cases:
            for mode in PYTHON_MODES:
                with self.subTest(case=case, python=mode[0]), tempfile.TemporaryDirectory() as directory:
                    fixture = Path(directory)
                    root = self.prepare_fixture(fixture)
                    if case == 'debug-helper':
                        with (fixture / 'helper').open('a') as helper:
                            helper.write('\n# CLAUDIO_TEST_ROOT\n')
                    elif case == 'helper-hash':
                        build = json.loads((fixture / 'build.json').read_text())
                        build['helper_sha256'] = 'invalid'
                        (fixture / 'build.json').write_text(json.dumps(build))
                    elif case == 'source-hash':
                        (fixture / 'compiled-source').write_text('changed')
                    elif case == 'disabled':
                        (root / 'config.json').write_text(json.dumps({
                            'host_integrations': {'surfaces': {'codex': {'enabled': False}}}}))
                    result = self.run_replay(fixture, mode, gui=case)
                    self.assert_incomplete(fixture, result)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn('RuntimeError', result.stderr)
                    self.assertFalse((fixture / 'helper-calls').exists())
                    self.assertFalse((fixture / 'output').exists())

    def test_identity_drift_prevents_completion_in_all_python_modes(self):
        for case in ['helper-drift', 'source-drift']:
            for mode in PYTHON_MODES:
                with self.subTest(case=case, python=mode[0]), tempfile.TemporaryDirectory() as directory:
                    fixture = Path(directory)
                    self.prepare_fixture(fixture)
                    result = self.run_replay(fixture, mode, case=case)
                    self.assert_incomplete(fixture, result)
                    self.assertIn('changed during measurement', result.stderr)

    def test_invalid_warmup_is_checked_before_samples_are_published(self):
        for mode in PYTHON_MODES:
            with self.subTest(python=mode[0]), tempfile.TemporaryDirectory() as directory:
                fixture = Path(directory)
                self.prepare_fixture(fixture)
                result = self.run_replay(fixture, mode, case='wrong-result', extra=['--warmup', '1'])
                self.assert_incomplete(fixture, result)
                self.assertIn('lock-busy branch', result.stderr)
                self.assertEqual((fixture / 'output/samples.jsonl').read_text(), '')

    def test_explicit_workbuddy_installation_paths_in_all_python_modes(self):
        for relative in ['Applications/WorkBuddy.app', 'Registered Apps/WorkBuddy.app']:
            for mode in PYTHON_MODES:
                with self.subTest(path=relative, python=mode[0]), tempfile.TemporaryDirectory() as directory:
                    fixture = Path(directory)
                    self.prepare_fixture(fixture, 'workbuddy')
                    app = fixture / relative
                    (app / 'Contents').mkdir(parents=True)
                    with (app / 'Contents/Info.plist').open('wb') as info:
                        plistlib.dump({'CFBundleIdentifier': 'com.tencent.workbuddy.mac',
                                       'CFBundleShortVersionString': '5.7.7'}, info,
                                      fmt=plistlib.FMT_BINARY)
                    result = self.run_replay(fixture, mode, host='workbuddy',
                                             extra=['--workbuddy-app', str(app)])
                    self.assertEqual(result.returncode, 0, result.stderr)
                    metadata = json.loads((fixture / 'output/metadata.json').read_text())
                    self.assertEqual(metadata['host_version'], '5.7.7')
                    self.assertTrue(metadata['complete'])

    def test_invalid_workbuddy_bundle_rejects_before_helper(self):
        for case in ['missing-plist', 'wrong-bundle', 'missing-version']:
            for mode in PYTHON_MODES:
                with self.subTest(case=case, python=mode[0]), tempfile.TemporaryDirectory() as directory:
                    fixture = Path(directory)
                    self.prepare_fixture(fixture, 'workbuddy')
                    app = fixture / 'Applications/WorkBuddy.app'
                    if case != 'missing-plist':
                        (app / 'Contents').mkdir(parents=True)
                        bundle = {'CFBundleIdentifier': 'com.tencent.workbuddy.mac',
                                  'CFBundleShortVersionString': '5.7.7'}
                        if case == 'wrong-bundle':
                            bundle['CFBundleIdentifier'] = 'fixture.unrelated-app'
                        else:
                            del bundle['CFBundleShortVersionString']
                        with (app / 'Contents/Info.plist').open('wb') as info:
                            plistlib.dump(bundle, info)
                    result = self.run_replay(fixture, mode, host='workbuddy',
                                             extra=['--workbuddy-app', str(app)])
                    self.assert_incomplete(fixture, result)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertFalse((fixture / 'helper-calls').exists())
                    self.assertFalse((fixture / 'output').exists())


if __name__ == '__main__':
    unittest.main()
