#!/usr/bin/env python3
"""Reproducible Core-only hook measurements; no production-root override or host config writes."""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess

REPO = Path(__file__).resolve().parents[1]


def output(command):
    return subprocess.check_output(command, cwd=REPO, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_binary_identity(binary, helper, metadata):
    for path, key in [(binary, 'binary_sha256'), (helper, 'helper_sha256')]:
        if digest(path) != metadata[key]:
            raise RuntimeError(f'{path.name} changed during measurement; discard comparison')


def source_identity():
    paths = [REPO / 'helper/Package.swift', REPO / 'helper/Package.resolved', REPO / 'scripts/benchmark-hooks.py']
    paths += sorted((REPO / 'helper/Sources').rglob('*.swift'))
    paths += sorted((REPO / 'helper/Sources').rglob('*.c'))
    paths += sorted((REPO / 'helper/Sources').rglob('*.h'))
    return {str(path.relative_to(REPO)): digest(path) for path in paths}


def stats(values):
    ordered = sorted(values)
    return {'n': len(values), **{name: ordered[max(0, math.ceil(p * len(ordered)) - 1)] / 1e6
            for name, p in [('p50_ms', .5), ('p90_ms', .9), ('p95_ms', .95), ('max_ms', 1)]}}


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--warmup', type=int, default=10)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--skip-probe-comparison', action='store_true')
    parser.add_argument('--skip-timeout-diagnostic', action='store_true')
    parser.add_argument('--cache-comparison', action='store_true')
    parser.add_argument('--git-timeout-only', action='store_true',
                        help='Component failure diagnostic only; not a complete hook/CLI measurement')
    args = parser.parse_args()
    if not __debug__:
        parser.error('measurement requires Python assertions; do not use python -O')
    run_probe_comparison = not args.skip_probe_comparison and not args.git_timeout_only and not args.cache_comparison
    if args.samples < 1 or args.warmup < 0 or args.rounds < 1:
        parser.error('samples and rounds must be positive; warmup must be nonnegative')
    destination = args.output or REPO / 'dist' / ('hook-baseline-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    destination.mkdir(parents=True, exist_ok=False)
    source = source_identity()
    build = ['swift', 'build', '--package-path', 'helper', '--scratch-path', 'helper/.build/hook-benchmark',
             '-c', 'release', '--experimental-lto-mode', 'full', '-Xswiftc', '-Osize']
    with (destination / 'build.log').open('w') as log:
        for product in ['claudio-hook-benchmark', 'claudio']:
            subprocess.run(build + ['--product', product], cwd=REPO, stdout=log, stderr=log, check=True)
    directory = Path(output(build + ['--show-bin-path']))
    binary, helper = directory / 'claudio-hook-benchmark', directory / 'claudio'
    assert source_identity() == source, 'source changed during build; discard binaries'
    metadata = {
        'schema': 1, 'evidence': 'core-isolated', 'utc': datetime.now(timezone.utc).isoformat(),
        'sha': output(['git', 'rev-parse', 'HEAD']), 'dirty': bool(output(['git', 'status', '--porcelain'])),
        'source_sha256': source, 'binary_sha256': digest(binary), 'helper_sha256': digest(helper),
        'build': ['swift', 'build', '-c', 'release', '--experimental-lto-mode', 'full', '-Xswiftc', '-Osize'],
        'swift': output(['swift', '--version']), 'system': platform.system(),
        'macos': platform.mac_ver()[0], 'architecture': platform.machine(), 'hardware_model': output(['sysctl', '-n', 'hw.model']),
        'helper_version': output([str(helper), '--version']), 'host_version': None,
        'cache': ('explicit temporary cache; synthetic signature eligibility; warm OS caches' if args.cache_comparison
                  else 'no persistent host-version cache; fresh scope snapshot per event; warm OS caches'),
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
    if args.git_timeout_only:
        metadata.update(evidence='core-component-failure-diagnostic',
                        boundary='version-resolution-plus-workspace-profile; not hook or CLI',
                        samples_per_cell=10, warmup_per_cell=1, rounds=1,
                        probe_comparison=False, timeout_diagnostic=None,
                        fixture_preflight='one untimed version-script preparation with 2s runner timeout; measured probes remain 1s',
                        version_fixture_delay_s=0.9)
        # Classify failed diagnostic runs correctly too; complete remains absent.
        (destination / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
        with (destination / 'git-timeout.jsonl').open('w') as raw, (destination / 'git-timeout.stderr').open('w') as errors:
            subprocess.run([str(binary), '--git-timeout-diagnostic', '--samples', '10',
                            '--warmup', '1', '--rounds', '1'], cwd=REPO,
                           stdout=raw, stderr=errors, check=True)
        rows = [json.loads(line) for line in (destination / 'git-timeout.jsonl').read_text().splitlines()]
        assert len(rows) == 20 and (destination / 'git-timeout.stderr').stat().st_size == 0
        summary = {'groups': [dict(observer=enabled, **stats([r['nanoseconds'] for r in rows if r['observer'] == enabled]))
                              for enabled in [False, True]],
                   'all_children_reaped': all(r['childrenReaped'] for r in rows),
                   'all_workspace_failed_closed': all(r['workspaceFailedClosed'] for r in rows)}
        (destination / 'git-timeout-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        assert source_identity() == source, 'source changed during diagnostic'
        verify_binary_identity(binary, helper, metadata)
        metadata['complete'] = True
        (destination / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
        print('20 validated component failure samples; not a full hook or CLI budget.', flush=True)
        return
    batches = ([('cache-scenarios', 'cache-compare', 'all'), ('cache-miss', 'cache-miss', 'full-steady'),
                ('cache-force', 'cache-force', 'full-steady'), ('cache-unknown', 'cache-unknown', 'full-steady'),
                ('cache-timeout', 'cache-timeout', 'full-steady'),
                ('version-timeout', 'timeout', 'full-steady')] if args.cache_comparison else
               [('scenarios', 'normal', 'all'), ('probe-comparison', 'compare', 'full-steady'),
                ('version-timeout', 'timeout', 'full-steady')])
    for name, probe, scenario in batches:
        if name == 'probe-comparison' and not run_probe_comparison:
            continue
        if name == 'version-timeout' and args.skip_timeout_diagnostic:
            continue
        samples_count, warmup_count, rounds_count = (10, 1, 1) if name in ('version-timeout', 'cache-timeout') else (args.samples, args.warmup, args.rounds)
        with (destination / (name + '.jsonl')).open('w') as raw, (destination / (name + '.stderr')).open('w') as errors:
            subprocess.run([str(binary), '--samples', str(samples_count), '--warmup', str(warmup_count),
                '--rounds', str(rounds_count), '--probe', probe, '--scenario', scenario],
                cwd=REPO, stdout=raw, stderr=errors, check=True)
        assert (destination / (name + '.stderr')).stat().st_size == 0, 'Core measurement emitted stderr'
        samples = [json.loads(line) for line in (destination / (name + '.jsonl')).read_text().splitlines()]
        cells = {'scenarios': 12, 'probe-comparison': 4, 'cache-scenarios': 24}.get(name, 1)
        assert len(samples) == samples_count * rounds_count * 2 * cells, 'missing driver samples'
        summary = summarize(samples)
        if name in ('version-timeout', 'cache-timeout'):
            summary['approved_maximum_ms'] = 2000
            summary['within_budget'] = all(row['nanoseconds'] <= 2_000_000_000 for row in samples)
        if name == 'cache-scenarios':
            budgets = {'full-empty':15.50, 'full-steady':27.29, 'muted':30.12, 'debounced':21.42,
                       'not-ready':18.52, 'authorization-off':0.13, 'gui-exited':0.22,
                       'stale-installation':8.41, 'lock-busy':39.04, 'workspace-plain':18.62,
                       'workspace-git':35.01, 'git-damaged':31.10}
            summary['budget_checks'] = []
            for scenario_name, budget in budgets.items():
                for mode in ['cache-bypass', 'cache-hit']:
                    rows = [r for r in samples if r['scenario'] == scenario_name and r['probe'] == mode and not r['observer']]
                    rounds = [stats([r['nanoseconds'] for r in rows if r['round'] == n]) for n in range(args.rounds)]
                    summary['budget_checks'].append(dict(scenario=scenario_name, probe=mode,
                        approved_p95_ms=budget, rounds=rounds, passed=all(r['p95_ms'] <= budget for r in rounds)))
            pairs = defaultdict(dict)
            for r in samples:
                if not r['observer']:
                    pairs[(r['scenario'], r['round'], r['pair'])][r['probe']] = r
            deltas = defaultdict(list)
            for (scenario_name, _, _), pair in pairs.items():
                assert set(pair) == {'cache-bypass', 'cache-hit'}
                for key in ['accepted', 'playback', 'playerStarts', 'receipts', 'archives', 'notices', 'activity']:
                    assert pair['cache-bypass'][key] == pair['cache-hit'][key], 'paired semantic outcome drift'
                deltas[scenario_name].append(pair['cache-hit']['nanoseconds'] - pair['cache-bypass']['nanoseconds'])
            summary['cache_paired_deltas'] = [dict(scenario=k, **stats(v)) for k,v in sorted(deltas.items())]
        (destination / (name + '-summary.json')).write_text(json.dumps(summary, indent=2) + '\n')
        print(f'{name}: {len(samples)} validated measured events', flush=True)
    assert source_identity() == source, 'source changed during measurement; discard comparison'
    verify_binary_identity(binary, helper, metadata)
    metadata['complete'] = True
    (destination / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Core baseline complete. Real CLI/host/audibility evidence remains separate.', flush=True)


if __name__ == '__main__':
    main()
