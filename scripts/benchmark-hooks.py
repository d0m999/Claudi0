#!/usr/bin/env python3
"""Reproducible Core-only hook measurements; no production-root override or host config writes."""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import platform
import subprocess

REPO = Path(__file__).resolve().parents[1]
EVIDENCE_PATH = Path(__file__).with_name('hook-cache-evidence.py')
SPEC = spec_from_file_location('hook_cache_statistics', EVIDENCE_PATH)
STATISTICS = module_from_spec(SPEC)
SPEC.loader.exec_module(STATISTICS)
stats = STATISTICS.stats


def output(command):
    return subprocess.check_output(command, cwd=REPO, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_binary_identity(binary, helper, metadata):
    for path, key in [(binary, 'binary_sha256'), (helper, 'helper_sha256')]:
        if digest(path) != metadata[key]:
            raise RuntimeError(f'{path.name} changed during measurement; discard comparison')


def source_identity():
    paths = [REPO / 'helper/Package.swift', REPO / 'helper/Package.resolved', REPO / 'scripts/benchmark-hooks.py', EVIDENCE_PATH]
    paths += sorted((REPO / 'helper/Sources').rglob('*.swift'))
    paths += sorted((REPO / 'helper/Sources').rglob('*.c'))
    paths += sorted((REPO / 'helper/Sources').rglob('*.h'))
    return {str(path.relative_to(REPO)): digest(path) for path in paths}


def summarize(samples):
    groups = defaultdict(list)
    for row in samples:
        groups[(row['scenario'], row['probe'], row['observer'])].append(row)
    summaries = []
    for (scenario, probe, observer), rows in sorted(groups.items()):
        stages = defaultdict(list)
        results = defaultdict(int)
        measured_results = defaultdict(int)
        probe_results = defaultdict(int)
        for row in rows:
            results[row['playback']] += 1
            probe_results[row['probeResult']] += 1
            for record in row['stages']:
                if record['result'] != 'completed':
                    measured_results[record['stage'] + ':' + record['result']] += 1
                if 'nanoseconds' in record:
                    stages[record['stage']].append(record['nanoseconds'])
        summaries.append(dict(scenario=scenario, probe=probe, observer=observer,
            **stats([r['nanoseconds'] for r in rows]),
            counts={key: sum(r[key] for r in rows) for key in (
                'accepted', 'playerStarts', 'receipts', 'archives', 'notices', 'activity', 'probeCalls')},
            results=dict(results), probe_results=dict(probe_results), measured_results=dict(measured_results), inclusive_stages={stage: stats(values) for stage, values in stages.items()}))
    paired = defaultdict(dict)
    for row in samples:
        paired[(row['scenario'], row['probe'], row['round'], row['pair'])][row['observer']] = row['nanoseconds']
    deltas = defaultdict(list)
    for (scenario, probe, _, _), pair in paired.items():
        if set(pair) != {True, False}:
            raise AssertionError('incomplete observer A/B pair')
        deltas[(scenario, probe)].append(pair[True] - pair[False])
    return {'groups': summaries, 'observer_paired_deltas': [dict(scenario=s, probe=p, **stats(values))
            for (s, p), values in sorted(deltas.items())]}


SCENARIOS = ['full-empty', 'full-steady', 'muted', 'debounced', 'not-ready',
             'authorization-off', 'gui-exited', 'stale-installation', 'lock-busy',
             'workspace-plain', 'workspace-git', 'git-damaged']


def validate(samples, probe, scenario, count, rounds):
    scenarios = SCENARIOS if scenario == 'all' else [scenario]
    probes = ['normal', 'instant', 'delayed', 'real'] if probe == 'compare' else [probe]
    expected = {(s, p, r, i, observer) for s in scenarios for p in probes
                for r in range(rounds) for i in range(count) for observer in [False, True]}
    seen = set()
    for row in samples:
        key = (row['scenario'], row['probe'], row['round'], row['pair'], row['observer'])
        if key not in expected or key in seen or type(row['observer']) is not bool:
            raise AssertionError('unexpected or duplicate sample coordinate')
        seen.add(key)
        denied = row['scenario'] in ['authorization-off', 'gui-exited']
        rejected = denied or row['scenario'] == 'stale-installation' or row['probe'] == 'timeout'
        playback = {'muted': 'muted', 'debounced': 'debounced', 'lock-busy': 'debounced',
                    'not-ready': 'not_ready', 'git-damaged': 'not_ready'}.get(row['scenario'], 'played')
        accepted = int(not rejected)
        counts = dict(accepted=accepted, playerStarts=int(not rejected and playback == 'played'),
                      receipts=accepted, archives=accepted, notices=accepted, activity=accepted,
                      probeCalls=int(not denied))
        result = 'not-invoked' if denied else 'timed-out' if row['probe'] == 'timeout' else 'completed'
        if (row['evidence'] != 'core-isolated' or row['host'] != 'claude-code'
                or row['playback'] != ('rejected' if rejected else playback)
                or row['probeResult'] != result or row['nanoseconds'] <= 0
                or any(row[k] != value for k, value in counts.items())):
            raise AssertionError('sample branch/result mismatch')
    if seen != expected:
        raise AssertionError('missing driver samples')


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--warmup', type=int, default=10)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--skip-probe-comparison', action='store_true')
    parser.add_argument('--skip-timeout-diagnostic', action='store_true')
    args = parser.parse_args()
    if not __debug__:
        parser.error('measurement requires Python assertions; do not use python -O')
    run_probe_comparison = not args.skip_probe_comparison
    if args.samples < 1 or args.warmup < 0 or args.rounds < 1:
        parser.error('samples and rounds must be positive; warmup must be nonnegative')
    destination = args.output or REPO / 'dist' / ('hook-baseline-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    destination.mkdir(parents=True, exist_ok=False)
    source = source_identity()
    build = ['swift', 'build', '--package-path', 'helper', '--scratch-path', 'helper/.build/hook-benchmark',
             '-c', 'release', '--arch', 'arm64', '--experimental-lto-mode', 'full', '-Xswiftc', '-Osize']
    with (destination / 'build.log').open('w') as log:
        for product in ['claudio-hook-benchmark', 'claudio']:
            subprocess.run(build + ['--product', product], cwd=REPO, stdout=log, stderr=log, check=True)
    directory = Path(output(build + ['--show-bin-path']))
    binary, helper = directory / 'claudio-hook-benchmark', directory / 'claudio'
    assert source_identity() == source, 'source changed during build; discard binaries'
    metadata = {
        'schema': 1, 'evidence': 'core-isolated', 'complete': False, 'utc': datetime.now(timezone.utc).isoformat(),
        'sha': output(['git', 'rev-parse', 'HEAD']), 'dirty': bool(output(['git', 'status', '--porcelain'])),
        'source_sha256': source, 'binary_sha256': digest(binary), 'helper_sha256': digest(helper),
        'build': list(build),
        'swift': output(['swift', '--version']), 'system': platform.system(),
        'macos': platform.mac_ver()[0], 'architecture': platform.machine(), 'hardware_model': output(['sysctl', '-n', 'hw.model']),
        'helper_version': output([str(helper), '--version']), 'host_version': None,
        'cache': 'no persistent host-version cache; fresh scope snapshot per event; warm OS caches',
        'warmup_per_cell': args.warmup, 'samples_per_cell': args.samples, 'rounds': args.rounds,
        'seed': '0xC1A0D10', 'order': 'alternating observer AB/BA and probe forward/reverse per pair',
        'audio': 'synthetic ProcessSpawning success; never afplay', 'notice': 'in-memory successful sender',
        'production_helper_measured': False, 'host_callbacks_measured': False,
        'temporary_object_lifetime': 'per-fixture setup and per-event autorelease pool; hook inner pool drains inside timed span; validation/output pool drains outside',
        'probe_comparison': run_probe_comparison,
        'timeout_diagnostic': None if args.skip_timeout_diagnostic else {'samples': 10, 'warmup': 1, 'rounds': 1},
    }
    if run_probe_comparison:
        # Explicit missing-host failure, not a silent substitution of a stub for real evidence.
        metadata['host_version'] = output(['claude', '--version'])
    (destination / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    batches = [('scenarios', 'normal', 'all'), ('probe-comparison', 'compare', 'full-steady'),
               ('version-timeout', 'timeout', 'full-steady')]
    for name, probe, scenario in batches:
        if name == 'probe-comparison' and not run_probe_comparison:
            continue
        if name == 'version-timeout' and args.skip_timeout_diagnostic:
            continue
        samples_count, warmup_count, rounds_count = (10, 1, 1) if name == 'version-timeout' else (args.samples, args.warmup, args.rounds)
        with (destination / (name + '.jsonl')).open('w') as raw, (destination / (name + '.stderr')).open('w') as errors:
            subprocess.run([str(binary), '--samples', str(samples_count), '--warmup', str(warmup_count),
                '--rounds', str(rounds_count), '--probe', probe, '--scenario', scenario],
                cwd=REPO, stdout=raw, stderr=errors, check=True)
        assert (destination / (name + '.stderr')).stat().st_size == 0, 'Core measurement emitted stderr'
        samples = [json.loads(line) for line in (destination / (name + '.jsonl')).read_text().splitlines()]
        validate(samples, probe, scenario, samples_count, rounds_count)
        summary = summarize(samples)
        if name == 'version-timeout':
            summary['approved_maximum_ms'] = 2000
            summary['within_budget'] = all(row['nanoseconds'] <= 2_000_000_000 for row in samples)
        (destination / (name + '-summary.json')).write_text(json.dumps(summary, indent=2) + '\n')
        print(f'{name}: {len(samples)} validated measured events', flush=True)
    assert source_identity() == source, 'source changed during measurement; discard comparison'
    verify_binary_identity(binary, helper, metadata)
    metadata['complete'] = True
    (destination / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Core baseline complete. Real CLI/host/audibility evidence remains separate.', flush=True)


if __name__ == '__main__':
    main()
