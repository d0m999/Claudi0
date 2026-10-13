#!/usr/bin/env python3
"""Opt-in Release CLI version-timeout diagnostic; no host session or audio.

Uses current intent, installation and live GUI. A private PATH shim ignores TERM;
every invocation must reject without receipt/activity changes and reap that shim.
This measures observed launch-to-exit time, not a hard wall-clock guarantee.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
import uuid

replay_spec = importlib.util.spec_from_file_location(
    'claudio_release_replay', Path(__file__).with_name('measure-release-hooks.py'))
replay = importlib.util.module_from_spec(replay_spec)
replay_spec.loader.exec_module(replay)
digest, live_gui_metadata = replay.digest, replay.live_gui_metadata
percentile, receipt_files = replay.percentile, replay.receipt_files


def activity_files(root):
    directory = root / 'integrations/activity'
    if directory.is_symlink():
        raise RuntimeError('activity directory must not be a symlink')
    files = {}
    for path in directory.rglob('*.json'):
        if path.is_symlink() or not path.is_file():
            raise RuntimeError('activity snapshot requires regular files')
        files[path] = digest(path)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--build-metadata', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=20)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error('--samples must be positive')
    if not __debug__:
        parser.error('measurement requires Python assertions; do not use python -O')
    helper = args.helper.resolve()
    assert b'CLAUDIO_TEST_ROOT' not in helper.read_bytes(), 'production Release required'
    build = json.loads(args.build_metadata.read_text())
    assert digest(helper) == build['helper_sha256'], 'build identity mismatch'
    inputs = dict(build['source_sha256'])
    inputs.update({str(Path(__file__)): digest(Path(__file__)),
                   'scripts/measure-release-hooks.py': digest(Path('scripts/measure-release-hooks.py'))})
    for name, expected in inputs.items():
        assert digest(Path(name)) == expected, 'measurement input changed'
    root = Path.home() / '.claudio'
    config_file = root / 'config.json'
    marker_file = root / 'integrations/installations/claude-code.json'
    config_hash, marker_hash = digest(config_file), digest(marker_file)
    assert json.loads(config_file.read_text())['host_integrations']['surfaces']['claude-code']['enabled']
    gui = live_gui_metadata(root)
    installation = json.loads(marker_file.read_text())['installation_id']
    host_version = subprocess.check_output(['claude', '--version'], text=True).strip()
    args.output.mkdir(parents=True, exist_ok=False)
    rows = []
    with tempfile.TemporaryDirectory(prefix='claudio-timeout-probe-') as temporary:
        directory = Path(temporary)
        trace = directory / 'probe-pid'
        shim = directory / 'claude'
        shim.write_text('#!' + sys.executable + '\n'
                        'import os, signal, time\n'
                        'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                        f'with open({str(trace)!r}, "w") as trace: trace.write(str(os.getpid()))\n'
                        'time.sleep(3)\n')
        shim.chmod(0o700)
        environment = dict(os.environ, PATH=str(directory) + ':' + os.environ.get('PATH', ''))
        payload = json.dumps({'hook_event_name': 'UserPromptSubmit', 'cwd': str(directory),
                              'session_id': str(uuid.uuid4())}).encode()
        with (args.output / 'samples.jsonl').open('w') as output:
            for index in range(-1, args.samples):
                if trace.exists():
                    trace.unlink()
                before = receipt_files(root, 'claude-code'), activity_files(root)
                started = time.perf_counter_ns()
                result = subprocess.run([str(helper), 'hook', 'claude-code', 'UserPromptSubmit',
                                         '--installation-id', installation], input=payload,
                                        env=environment, capture_output=True, timeout=10)
                elapsed = time.perf_counter_ns() - started
                assert result.returncode == 0 and not result.stdout and not result.stderr, 'zero output'
                assert trace.exists(), 'version probe must execute this shim'
                pid = int(trace.read_text())
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError('timed-out version probe was not reaped')
                assert before == (receipt_files(root, 'claude-code'), activity_files(root)), 'rejection effects or concurrent event'
                assert digest(config_file) == config_hash and digest(marker_file) == marker_hash
                if index >= 0:
                    row = dict(sample=index, elapsed_ns=elapsed, driver_events_initiated=1,
                               version_probe_invocations=1, probe_alive_after_helper=False,
                               receipt_activity_unchanged=True, stdout_bytes=0, stderr_bytes=0,
                               helper_exit=0, valid=True)
                    rows.append(row)
                    output.write(json.dumps(row) + '\n')
                    output.flush()
    for name, expected in inputs.items():
        assert digest(Path(name)) == expected, 'measurement input changed during run'
    assert digest(helper) == build['helper_sha256'], 'helper changed during run'
    values = [r['elapsed_ns'] for r in rows]
    summary = dict(n=len(rows), driver_events=len(rows), rejected_no_effects=len(rows),
                   p50_ms=percentile(values, .5), p90_ms=percentile(values, .9),
                   p95_ms=percentile(values, .95), max_ms=max(values) / 1e6)
    metadata = dict(evidence='production-release-helper-timeout-diagnostic',
                    real_host_callback=False, host='claude-code', host_version=host_version,
                    helper_sha256=build['helper_sha256'], driver_sha256=digest(Path(__file__)),
                    imported_driver_sha256=digest(Path('scripts/measure-release-hooks.py')),
                    source_sha=build['sha'], dirty=True, compiled_source_sha256=build['source_sha256'],
                    build=build['build'], architecture=platform.machine(), macos=platform.mac_ver()[0],
                    warmup=1, samples=len(rows), rounds=1, probe='private PATH shim; ignores TERM; sleep 3s',
                    boundary='helper launch to exit, including child cleanup; no hard maximum inferred',
                    utc=datetime.now(timezone.utc).isoformat(), complete=True)
    metadata.update(gui)
    (args.output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
