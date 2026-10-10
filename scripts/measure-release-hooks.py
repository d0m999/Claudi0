#!/usr/bin/env python3
"""Explicitly authorized live-state helper replay using current intent and GUI identity.

This is a driver replay, not a real-host callback. Lock-busy samples hold the existing
nonblocking playback lock so they cannot play audio, but they still send banner notices,
write receipts/history, and increment activity counts in the current user's Claudio state.
No config or installation is changed. Use benchmark-hooks.py for isolated measurements.
Live-state replay requires --allow-live-state-replay; use a disposable test account or VM.
Reject samples must preserve receipts byte-for-byte; accepted samples must archive exactly
one matching result. Concurrent host activity invalidates a sample instead of being ignored.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import stat
import subprocess
import tempfile
import time
import uuid


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def receipt_files(root, host):
    history = root / 'integrations/receipt-history' / host
    current = root / 'integrations/receipts' / (host + '.json')
    files = list(history.glob('*.json'))
    if current.exists():
        files.append(current)
    return {p: digest(p) for p in files}


def percentile(values, q):
    return sorted(values)[max(0, math.ceil(len(values) * q) - 1)] / 1e6


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--host', choices=['claude-code', 'codex', 'workbuddy'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build-metadata', type=Path,
                        help='Benchmark build metadata whose helper SHA-256 must match')
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--warmup', type=int, default=10)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--allow-live-state-replay', action='store_true',
                        help='Allow real banner notices, receipt/history writes, and activity counts; '
                             'the playback lock only prevents audio')
    args = parser.parse_args()
    if args.samples < 1 or args.warmup < 0 or args.rounds < 1:
        parser.error('invalid sample dimensions')
    if not args.allow_live_state_replay:
        parser.error(
            'live-state replay is disabled by default: this run would submit '
            f'{(args.samples + args.warmup) * args.rounds} accepted events, including warmup, '
            'with real banner notices, receipts/history writes, and activity counts. '
            'Use scripts/benchmark-hooks.py for isolated measurements. '
            'Use --allow-live-state-replay only for explicitly authorized live-state testing '
            'in a disposable test account or VM.')
    helper = args.helper.resolve()
    assert b'CLAUDIO_TEST_ROOT' not in helper.read_bytes(), 'requires a production Release helper'
    helper_hash = digest(helper)
    driver_hash = digest(Path(__file__))
    build_metadata = json.loads(args.build_metadata.read_text()) if args.build_metadata else {}
    if build_metadata:
        assert build_metadata['helper_sha256'] == helper_hash, 'build metadata does not identify this helper'
        for name, expected in build_metadata['source_sha256'].items():
            assert digest(Path(name)) == expected, 'compiled input changed since benchmark build'
    host_version = (
        subprocess.check_output(['claude' if args.host == 'claude-code' else 'codex', '--version'], text=True).strip()
        if args.host != 'workbuddy' else subprocess.check_output(
            ['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString',
             '/Applications/WorkBuddy.app/Contents/Info.plist'], text=True).strip())
    root = Path.home() / '.claudio'
    config_file = root / 'config.json'
    config_hash = digest(config_file)
    config = json.loads(config_file.read_text())
    assert config['host_integrations']['surfaces'][args.host]['enabled'], 'source disabled'
    run = json.loads((root / 'gui-run.json').read_text())
    os.kill(run['process']['pid'], 0)  # Each helper additionally validates exact kernel identity.
    marker = root / 'integrations/installations' / (args.host + '.json')
    marker_hash = digest(marker)
    installation = json.loads(marker.read_text())['installation_id']
    stale = str(uuid.uuid4())
    assert stale.lower() != installation.lower()
    args.output.mkdir(parents=True, exist_ok=False)
    samples = []
    rng = random.Random(0xC1A0D10)
    with tempfile.TemporaryDirectory(prefix='claudio-release-replay-') as directory:
        payload = json.dumps({'hook_event_name': 'UserPromptSubmit', 'cwd': directory,
                              'session_id': str(uuid.uuid4())}).encode()
        lock_path = root / 'integrations' / (args.host + '-play.lock')
        # Acquire once for this bounded run. No waiting and no play-state reset.
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode) or status.st_uid != os.getuid() or status.st_nlink != 1:
            os.close(descriptor)
            raise RuntimeError('unsafe playback lock')
        with os.fdopen(descriptor, 'r+b') as lock, (args.output / 'samples.jsonl').open('w') as output:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for round_index in range(args.rounds):
                for index in range(-args.warmup, args.samples):
                    order = ['lock-busy', 'stale-installation']
                    if rng.getrandbits(1):
                        order.reverse()
                    for scenario in order:
                        before = receipt_files(root, args.host)
                        start_wall = time.time()
                        started = time.perf_counter_ns()
                        result = subprocess.run(
                            [str(helper), 'hook', args.host, 'UserPromptSubmit', '--installation-id',
                             installation if scenario == 'lock-busy' else stale],
                            input=payload, capture_output=True, timeout=10)
                        elapsed = time.perf_counter_ns() - started
                        assert result.returncode == 0 and not result.stdout and not result.stderr, 'CLI zero-output contract'
                        after = receipt_files(root, args.host)
                        outcomes = []
                        if scenario == 'stale-installation':
                            assert after == before, 'rejected event modified receipts or concurrent host event'
                        else:
                            new_history = [p for p in after if p not in before and p.parent.name == args.host]
                            assert len(new_history) == 1, 'accepted event must create one archive; concurrency invalidates'
                            receipt = json.loads(new_history[0].read_text())
                            assert receipt['installation_id'].lower() == installation.lower()
                            assert receipt['native_event'] == 'UserPromptSubmit'
                            assert receipt['playback_result'] == 'debounced', 'must execute the lock-busy branch'
                            stamp = float(receipt['timestamp'])
                            assert start_wall <= stamp <= time.time(), 'new archive must belong to this invocation'
                            outcomes = [receipt['playback_result']]
                        assert digest(marker) == marker_hash and digest(config_file) == config_hash, 'intent/installation changed'
                        if index >= 0:
                            sample = dict(round=round_index, pair=index, scenario=scenario,
                                          elapsed_ns=elapsed, driver_events_initiated=1,
                                          archive_results=outcomes, stdout_bytes=0, stderr_bytes=0,
                                          exit=0, valid=True)
                            samples.append(sample)
                            output.write(json.dumps(sample) + '\n')
                            output.flush()
            fcntl.flock(lock, fcntl.LOCK_UN)
    assert digest(helper) == helper_hash, 'binary changed during measurement'
    assert digest(Path(__file__)) == driver_hash, 'measurement driver changed during measurement'
    if build_metadata:
        for name, expected in build_metadata['source_sha256'].items():
            assert digest(Path(name)) == expected, 'compiled input changed during measurement'
    summary = {}
    for scenario in ['lock-busy', 'stale-installation']:
        rows = [s for s in samples if s['scenario'] == scenario]
        values = [s['elapsed_ns'] for s in rows]
        summary[scenario] = dict(n=len(rows), driver_events=len(rows),
                                results=dict(Counter(v for s in rows for v in s['archive_results'])),
                                p50_ms=percentile(values, .5), p90_ms=percentile(values, .9),
                                p95_ms=percentile(values, .95), max_ms=max(values) / 1e6)
        summary[scenario]['round_p95_ms'] = [
            percentile([s['elapsed_ns'] for s in rows if s['round'] == r], .95)
            for r in range(args.rounds)]
    metadata = dict(evidence='production-release-helper-driver-replay', real_host_callback=False,
                    host=args.host, helper_sha256=helper_hash, utc=datetime.now(timezone.utc).isoformat(),
                    source_sha=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                    dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'])),
                    architecture=platform.machine(), macos=platform.mac_ver()[0],
                    samples_per_cell=args.samples, warmup=args.warmup, rounds=args.rounds,
                    seed=0xC1A0D10, playback='nonblocking lock held; no player starts',
                    driver_sha256=driver_hash, host_version=host_version,
                    build=build_metadata.get('build', 'unverified; supply --build-metadata'),
                    compiled_source_sha256=build_metadata.get('source_sha256'),
                    current_authorization='real source intent, installation and live GUI; validated by every helper',
                    history='current production state; empty/full not artificially reset', complete=True)
    (args.output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
