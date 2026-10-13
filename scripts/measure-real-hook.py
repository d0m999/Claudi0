#!/usr/bin/env python3
"""Opt-in real-host callbacks against an exact Release helper and existing GUI intent.

Leaves installed host settings unchanged. Audio can play. Raw stdin and model output are not saved.
Supports Claude Code and the engine bundled with WorkBuddy. A bundled-engine session
does not establish desktop UI delivery. This is not interactive/async acceptance.
"""
import argparse
from collections import Counter
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import plistlib

replay_spec = importlib.util.spec_from_file_location(
    'claudio_release_replay', Path(__file__).with_name('measure-release-hooks.py'))
replay = importlib.util.module_from_spec(replay_spec)
replay_spec.loader.exec_module(replay)
live_gui_metadata = replay.live_gui_metadata


def archive_files(root, host):
    folder = root / 'integrations/receipt-history' / host
    return set(folder.glob('*.json'))


def host_environment(home):
    """Reuse configured API settings in memory; never copy credentials to evidence files."""
    environment = os.environ.copy()
    settings = home / '.claude/settings.json'
    if settings.exists():
        configured = json.loads(settings.read_text()).get('env', {})
        for key, value in configured.items():
            if isinstance(value, str) and (key.startswith('ANTHROPIC_') or key in {
                'API_TIMEOUT_MS', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
                'CLAUDE_CODE_EFFORT_LEVEL',
            }):
                environment[key] = value
    return environment


def snapshot_state(root, host, destination):
    """Private before/after evidence, without config, credentials, or raw host payloads."""
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    folders = [root / 'integrations/receipts' / host,
               root / 'integrations/receipt-history' / host,
               root / 'integrations/activity']
    files = sorted({path for folder in folders for path in folder.rglob('*.json')})
    manifest = {}
    for path in files:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            status = os.fstat(descriptor)
            if not stat.S_ISREG(status.st_mode) or status.st_size > 65536:
                raise RuntimeError('state snapshot requires bounded regular files')
            with os.fdopen(descriptor, 'rb', closefd=False) as source:
                data = source.read(65537)
            if len(data) > 65536:
                raise RuntimeError('state snapshot exceeded its bound')
            relative = path.relative_to(root)
            target = destination / relative
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with target.open('xb') as copy:
                copy.write(data)
            target.chmod(0o600)
            manifest[str(relative)] = {'sha256': hashlib.sha256(data).hexdigest(),
                                       'mtime_ns': status.st_mtime_ns}
        finally:
            os.close(descriptor)
    current_files = sorted({path for folder in folders for path in folder.rglob('*.json')})
    stable = files == current_files and all(
        hashlib.sha256(path.read_bytes()).hexdigest() == manifest[str(path.relative_to(root))]['sha256']
        for path in files)
    value = {'files': manifest, 'stable_during_copy': stable,
             'config_sha256': hashlib.sha256((root / 'config.json').read_bytes()).hexdigest(),
             'installation_sha256': hashlib.sha256(
                 (root / 'integrations/installations' / (host + '.json')).read_bytes()).hexdigest()}
    publish_record(destination / 'manifest.json', value)
    return value


def publish_record(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def callback(context_file):
    callback_started = time.perf_counter_ns()
    context = json.loads(context_file.read_text())
    record_file = Path(context['records']) / (str(uuid.uuid4()) + '.json')
    host = context['host']
    record = {'schema': 1, 'evidence': 'release-helper-under-real-host', 'host': host,
              'mode': 'short-noninteractive', 'native_event': 'UserPromptSubmit',
              'initiated_callback': 1, 'callback_completed': False}
    # Publish invocation before input/helper work so cancellation cannot erase the denominator.
    publish_record(record_file, record)
    root = Path.home() / '.claudio'
    before = archive_files(root, host)
    payload = sys.stdin.buffer.read(65537)
    if len(payload) > 65536:
        record.update(rejected_input=True, callback_completed=True)
        publish_record(record_file, record)
        return 1
    start_wall, start = time.time(), time.perf_counter_ns()
    try:
        result = subprocess.run([context['helper'], 'hook', host, 'UserPromptSubmit',
                                 '--installation-id', context['installation']], input=payload,
                                capture_output=True, timeout=15)
    except subprocess.TimeoutExpired as error:
        record.update(helper_ns=time.perf_counter_ns() - start, helper_exit=None,
                      helper_timed_out=True, stdout_bytes=len(error.stdout or b''),
                      stderr_bytes=len(error.stderr or b''), callback_completed=True)
        publish_record(record_file, record)
        return 1
    elapsed = time.perf_counter_ns() - start
    # New archives are supporting observations, not a latest-receipt-derived delivery rate.
    receipts = []
    for file in archive_files(root, host) - before:
        try:
            receipt = json.loads(file.read_text())
            if receipt.get('native_event') == 'UserPromptSubmit' and receipt.get('installation_id', '').lower() == context['installation'].lower():
                receipts.append(receipt['playback_result'])
        except (OSError, ValueError, KeyError):
            pass
    record.update(helper_ns=elapsed, callback_ns=time.perf_counter_ns() - callback_started,
                  helper_exit=result.returncode,
                  stdout_bytes=len(result.stdout), stderr_bytes=len(result.stderr),
                  new_archive_results=receipts, callback_completed=True, helper_timed_out=False,
                  archive_correlation='new archives observed during helper invocation; concurrent callbacks can confound',
                  start_epoch=start_wall)
    publish_record(record_file, record)
    return 0 if result.returncode == 0 and not result.stdout and not result.stderr else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--callback', type=Path)
    parser.add_argument('--helper', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--host', choices=['claude-code', 'workbuddy'], default='claude-code')
    parser.add_argument('--samples', type=int, default=1)
    parser.add_argument('--allow-live-state-batch', action='store_true',
                        help='Allow repeated real receipt/activity/notice effects; use an explicitly authorized disposable account or VM')
    parser.add_argument('--hold-playback-lock', action='store_true',
                        help='Measure the accepted lock-busy path without playing audio')
    args = parser.parse_args()
    if not __debug__:
        parser.error('measurement requires Python assertions; do not use python -O')
    if args.callback:
        return callback(args.callback)
    if args.helper is None or args.output is None:
        parser.error('--helper and --output required')
    if args.samples < 1:
        parser.error('--samples must be positive')
    if args.samples > 1 and not args.allow_live_state_batch:
        parser.error('multiple live callbacks write real receipts/history and activity and send notices; '
                     'use an isolated account or VM and explicit --allow-live-state-batch')
    helper = args.helper.resolve()
    helper_hash = hashlib.sha256(helper.read_bytes()).hexdigest()
    driver_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    imported_driver_hash = hashlib.sha256(Path(replay.__file__).read_bytes()).hexdigest()
    if b'CLAUDIO_TEST_ROOT' in helper.read_bytes():
        raise RuntimeError('Debug helper is not production evidence')
    root = Path.home() / '.claudio'
    config = json.loads((root / 'config.json').read_text())
    assert config['host_integrations']['surfaces'][args.host]['enabled'], 'source is disabled'
    gui = live_gui_metadata(root)  # Helper additionally validates exact kernel start identity.
    installation = json.loads((root / 'integrations/installations' / (args.host + '.json')).read_text())['installation_id']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        raise FileExistsError('refusing to overwrite prior evidence')
    with tempfile.TemporaryDirectory(prefix='claudio-real-hook-') as temporary:
        directory = Path(temporary)
        context, settings, records = directory / 'context.json', directory / 'settings.json', directory / 'records'
        records.mkdir()
        context.write_text(json.dumps({'host': args.host, 'helper': str(helper), 'installation': installation, 'records': str(records)}))
        command = shlex.join([sys.executable, str(Path(__file__).resolve()), '--callback', str(context)])
        settings.write_text(json.dumps({'hooks': {'UserPromptSubmit': [{'hooks': [{'type': 'command', 'command': command}]}]}}))
        # No permission/trust bypass, no tools, no persistent session or raw output artifact.
        environment = host_environment(Path.home()) if args.host == 'claude-code' else os.environ.copy()
        if args.host == 'claude-code':
            prefix = ['claude']
            host_version = subprocess.check_output(prefix + ['--version'], text=True).strip()
            extra = ['--max-budget-usd', '0.03']
        else:
            bundle = Path('/Applications/WorkBuddy.app')
            cli = bundle / 'Contents/Resources/app.asar.unpacked/cli/bin/codebuddy'
            assert cli.is_file(), 'bundled WorkBuddy engine is unavailable'
            prefix = ['node', str(cli)]
            host_version = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
            extra = ['--max-turns', '1']
            environment['CODEBUDDY_FORCE_LITE_WB_BUNDLE'] = '1'
        command = prefix + ['-p', '--output-format', 'json', '--no-session-persistence',
                            '--setting-sources', '', '--settings', str(settings),
                            '--strict-mcp-config', '--tools', ''] + extra + [
                            'This is an authorized hook baseline check. Reply only OK. Do not use tools.']
        sessions = []
        state_directory = args.output.with_suffix('.state')
        before_state = snapshot_state(root, args.host, state_directory / 'before')
        if not before_state['stable_during_copy']:
            raise RuntimeError('state changed while capturing the pre-test snapshot; no host was started')
        lock = None
        try:
            if args.hold_playback_lock:
                descriptor = os.open(root / 'integrations' / (args.host + '-play.lock'),
                                     os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                status = os.fstat(descriptor)
                if not stat.S_ISREG(status.st_mode) or status.st_uid != os.getuid() or status.st_nlink != 1:
                    os.close(descriptor)
                    raise RuntimeError('unsafe playback lock')
                lock = os.fdopen(descriptor, 'r+b')
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for index in range(args.samples):
                prior_records = set(records.glob('*.json'))
                started = time.perf_counter_ns()
                process = subprocess.Popen(command, cwd=directory, env=environment, stdin=subprocess.DEVNULL,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                timed_out = False
                try:
                    stdout, stderr = process.communicate(timeout=45)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        stdout, stderr = process.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        stdout, stderr = process.communicate()
                session_ns = time.perf_counter_ns() - started
                callbacks = [json.loads(record.read_text()) for record in sorted(set(records.glob('*.json')) - prior_records)]
                value = dict(callbacks[0]) if len(callbacks) == 1 else {'callbacks': callbacks}
                combined = (stdout + stderr).decode(errors='replace').lower()
                # Retain only known error categories, never prompts/model output/auth fields.
                error = 'unclassified'
                if 'oauth session expired' in combined:
                    error = 'oauth-expired-refresh-failed'
                elif 'not logged in' in combined or 'authentication required' in combined:
                    error = 'authentication-required'
                try:
                    host_result = json.loads(stdout)
                    host_failed = (not isinstance(host_result, dict)
                                   or bool(host_result.get('is_error')) or error != 'unclassified')
                    terminal_reason = host_result.get('terminal_reason') if isinstance(host_result, dict) else None
                except ValueError:
                    host_failed = True
                    terminal_reason = None
                value.update(sample=index, driver_events_initiated=1, initiated_callback=len(callbacks),
                             session_ns=session_ns, session_exit=process.returncode, session_timed_out=timed_out,
                             host_stdout_bytes=len(stdout), host_stderr_bytes=len(stderr),
                             host_result_failed=host_failed, host_error_category=error,
                             terminal_reason=terminal_reason,
                             normal_session_completed=process.returncode == 0 and not timed_out and not host_failed)
                sessions.append(value)
                # Preserve every observed invocation, including failure/cancellation, before
                # validation can raise and the temporary callback records are removed.
                args.output.write_text(json.dumps({'sessions': sessions, 'complete': False}, indent=2) + '\n')
                if args.hold_playback_lock:
                    assert value.get('new_archive_results') == ['debounced'], 'must execute accepted lock-busy path'
        finally:
            if lock is not None:
                lock.close()
            after_state = snapshot_state(root, args.host, state_directory / 'after')
        assert hashlib.sha256(helper.read_bytes()).hexdigest() == helper_hash, 'helper changed during measurement'
        assert hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == driver_hash, 'driver changed during measurement'
        assert hashlib.sha256(Path(replay.__file__).read_bytes()).hexdigest() == imported_driver_hash, 'imported driver changed during measurement'
        callbacks_valid = all(s.get('initiated_callback') == 1 and s.get('helper_exit') == 0
                              and s.get('stdout_bytes') == 0 and s.get('stderr_bytes') == 0
                              for s in sessions)
        value = dict(sessions[0]) if len(sessions) == 1 else {'sessions': sessions}
        value.update(helper_sha256=helper_hash, driver_sha256=driver_hash, host_version=host_version,
                     host=args.host, mode='short-noninteractive', warmup=0,
                     driver_events_initiated=args.samples,
                     initiated_callback=sum(s.get('initiated_callback', 0) for s in sessions),
                     normal_sessions=sum(s['normal_session_completed'] for s in sessions),
                     host_error_counts=dict(Counter(s['host_error_category'] for s in sessions)),
                     human_audibility='not-applicable-lock-busy' if args.hold_playback_lock else 'pending',
                     host_settings_modified=False, host_trust_bypassed=False,
                     host_variant='bundled-lite-wb-engine' if args.host == 'workbuddy' else 'native-cli',
                     blocking_boundary='callback entry to completed record: a lower bound; excludes host dispatch and shell launch',
                     sample_limit='only this mode/event/playback branch; not interactive/async acceptance', complete=callbacks_valid)
        value.update(gui)
        value['state_snapshot'] = {'before_stable': before_state['stable_during_copy'],
                                   'after_stable': after_state['stable_during_copy'],
                                   'config_unchanged': before_state['config_sha256'] == after_state['config_sha256'],
                                   'installation_unchanged': before_state['installation_sha256'] == after_state['installation_sha256']}
        value['imported_driver_sha256'] = imported_driver_hash
        args.output.write_text(json.dumps(value, indent=2) + '\n')
        print(json.dumps(value, indent=2))
        return 0 if callbacks_valid else 1


if __name__ == '__main__':
    sys.exit(main())
