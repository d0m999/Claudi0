#!/usr/bin/env python3
"""Pure validation and summaries of supplied hook samples; performs no I/O.

Core reference comparisons are evidence labels, not approved production budgets.
The caller must validate the complete sample set before producing its summary.
"""
from collections import defaultdict
import math

MODES = ['native-bypass', 'native-cold', 'native-hit', 'native-expired',
         'native-force', 'native-failed', 'native-identity', 'native-unknown']


def stats(values):
    """Nearest-rank statistics in milliseconds, including signed paired deltas."""
    ordered = sorted(values)
    if not ordered:
        raise ValueError('statistics require at least one sample')
    return {'n': len(values),
            **{name: ordered[max(0, math.ceil(p * len(ordered)) - 1)] / 1e6
               for name, p in [('p50_ms', .5), ('p90_ms', .9), ('p95_ms', .95), ('max_ms', 1)]}}


def summarize(rows):
    groups = defaultdict(list)
    pairs = defaultdict(dict)
    for row in rows:
        groups[(row['host'], row['scenario'], row['probe'], row['observer'])].append(row)
        pairs[(row['host'], row['scenario'], row['round'], row['pair'], row['observer'])][row['probe']] = row
    summaries = []
    for (host, scenario, mode, observer), values in sorted(groups.items()):
        stages = defaultdict(list)
        by_round = defaultdict(list)
        for row in values:
            by_round[row['round']].append(row['nanoseconds'])
            for span in row['stages']:
                if 'nanoseconds' in span:
                    stages[span['stage']].append(span['nanoseconds'])
        summaries.append(dict(
            host=host, scenario=scenario, mode=mode, observer=observer,
            **stats([r['nanoseconds'] for r in values]),
            worst_round_p95_ms=max(stats(v)['p95_ms'] for v in by_round.values()),
            counts={key: sum(r[key] for r in values) for key in (
                'accepted', 'playerStarts', 'receipts', 'archives', 'notices', 'activity',
                'probeCalls', 'signatureCalls')},
            signature_call=stats([r['signatureNanoseconds'] for r in values]),
            inclusive_stages={stage: stats(v) for stage, v in stages.items()}))
    deltas = defaultdict(list)
    for (host, scenario, _, _, observer), pair in pairs.items():
        if set(pair) != set(MODES):
            raise AssertionError('incomplete native comparison')
        for mode in MODES[1:]:
            deltas[(host, scenario, mode, observer)].append(
                pair[mode]['nanoseconds'] - pair['native-bypass']['nanoseconds'])
    observers = defaultdict(dict)
    for row in rows:
        observers[(row['host'], row['scenario'], row['probe'], row['round'], row['pair'])][row['observer']] = row['nanoseconds']
    observer_deltas = defaultdict(list)
    for (host, scenario, mode, _, _), pair in observers.items():
        if set(pair) != {True, False}:
            raise AssertionError('incomplete observer comparison')
        observer_deltas[(host, scenario, mode)].append(pair[True] - pair[False])
    return dict(groups=summaries,
                paired_delta_from_bypass=[dict(host=h, scenario=s, mode=m, observer=o, **stats(v))
                                          for (h, s, m, o), v in sorted(deltas.items())],
                observer_paired_deltas=[dict(host=h, scenario=s, mode=m, **stats(v))
                                       for (h, s, m), v in sorted(observer_deltas.items())])


def validate(rows, args):
    hosts = ['claude-code', 'codex'] if args.host == 'all' else [args.host]
    scenarios = ['full-empty', 'full-steady'] if args.scenario == 'all' else [args.scenario]
    expected = len(hosts) * len(scenarios) * len(MODES) * 2 * args.samples * args.rounds
    if len(rows) != expected:
        raise AssertionError('sample count mismatch')
    keys = set()
    for row in rows:
        key = (row['host'], row['scenario'], row['probe'], row['round'], row['pair'], row['observer'])
        if key in keys or row['host'] not in hosts or row['scenario'] not in scenarios or row['probe'] not in MODES:
            raise AssertionError('unexpected or duplicate sample')
        if not 0 <= row['round'] < args.rounds or not 0 <= row['pair'] < args.samples:
            raise AssertionError('sample coordinate mismatch')
        keys.add(key)
        denied = row['scenario'] in ['authorization-off', 'gui-exited']
        rejected = denied or row['scenario'] == 'stale-installation' or row['probe'] == 'native-failed'
        accepted = int(not rejected)
        played = accepted and row['scenario'] in ['full-empty', 'full-steady']
        expected_counts = dict(accepted=accepted, playerStarts=int(played), receipts=accepted,
                               archives=accepted, notices=accepted, activity=accepted,
                               probeCalls=int(not denied and row['probe'] != 'native-hit'),
                               signatureCalls=0)
        if row['evidence'] != 'core-isolated-native-version' or any(row[k] != v for k, v in expected_counts.items()):
            raise AssertionError('branch/result count mismatch')
        if not 0 <= row['signatureNanoseconds'] <= row['nanoseconds'] or bool(row['signatureNanoseconds']) != bool(row['signatureCalls']):
            raise AssertionError('signature timing mismatch')


def validate_refresh(rows, args):
    hosts = ['claude-code', 'codex'] if args.host == 'all' else [args.host]
    expected = {(host, kind, rnd, pair) for host in hosts for kind in ['empty', 'replace']
                for rnd in range(args.rounds) for pair in range(args.samples)}
    seen = set()
    for row in rows:
        key = (row['host'], row['refreshKind'], row['round'], row['pair'])
        if key not in expected or key in seen:
            raise AssertionError('unexpected or duplicate refresh sample')
        seen.add(key)
        if (row['evidence'] != 'native-explicit-refresh-and-isolated-hook'
                or row['status'] != 'published' or row['probeCalls'] != 1
                or row['signatureCalls'] != 1
                or not 0 < row['signatureNanoseconds'] <= row['nanoseconds']):
            raise AssertionError('strict refresh was not completed within measured span')
        hits = row['followingHooks']
        if len(hits) != 2 or {h['scenario'] for h in hits} != {'full-empty', 'full-steady'}:
            raise AssertionError('following hooks must cover both history conditions once')
        for hit in hits:
            if any(hit[k] != row[k] for k in ['host', 'round', 'pair']):
                raise AssertionError('following hook coordinate mismatch')
            if (hit['evidence'] != 'core-isolated-native-version' or hit['probe'] != 'native-hit'
                    or hit['observer'] is not False or hit['nanoseconds'] <= 0
                    or any(hit[k] != 1 for k in ['accepted', 'playerStarts', 'receipts', 'archives', 'activity', 'notices'])
                    or hit['probeCalls'] != 0 or hit['signatureCalls'] != 0 or hit['signatureNanoseconds'] != 0):
                raise AssertionError('refresh did not yield a correct isolated hook hit')
    if seen != expected:
        raise AssertionError('incomplete refresh coordinates')


def summarize_refresh(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[(row['host'], row['refreshKind'])].append(row)
    result = []
    for (host, kind), values in sorted(groups.items()):
        hooks = []
        for scenario in ['full-empty', 'full-steady']:
            hits = [next(h for h in r['followingHooks'] if h['scenario'] == scenario) for r in values]
            core_reference = 15.50 if scenario == 'full-empty' else 27.29
            rounds = defaultdict(list)
            for hit in hits:
                rounds[hit['round']].append(hit['nanoseconds'])
            worst = max(stats(v)['p95_ms'] for v in rounds.values())
            hooks.append(dict(scenario=scenario, **stats([h['nanoseconds'] for h in hits]),
                              worst_round_p95_ms=worst, core_reference_p95_ms=core_reference,
                              within_core_reference=worst <= core_reference,
                              counts={k: sum(h[k] for h in hits) for k in
                                      ['accepted', 'playerStarts', 'receipts', 'archives', 'activity', 'notices']}))
        result.append(dict(host=host, refreshKind=kind,
                           explicit_refresh=stats([r['nanoseconds'] for r in values]),
                           signature=stats([r['signatureNanoseconds'] for r in values]),
                           following_hooks=hooks,
                           counts={k: sum(r[k] for r in values) for k in ['probeCalls', 'signatureCalls']}))
    return dict(groups=result, production_refresh_budget_frozen=False,
                production_hook_budget_frozen=False)
