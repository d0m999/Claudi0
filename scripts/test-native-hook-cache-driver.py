#!/usr/bin/env python3
"""Validate synthetic hook evidence without importing a benchmark or helper."""
import copy
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from types import SimpleNamespace
import unittest

SPEC = spec_from_file_location('hook_cache_evidence', Path(__file__).with_name('hook-cache-evidence.py'))
DRIVER = module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)


def samples(scenario='full-steady'):
    rows = []
    denied = scenario == 'authorization-off'
    for mode in DRIVER.MODES:
        for observer in [True, False]:
            accepted = int(not denied and mode != 'native-failed')
            rows.append(dict(
                evidence='core-isolated-native-version', host='claude-code', scenario=scenario,
                probe=mode, round=0, pair=0, observer=observer, nanoseconds=100,
                accepted=accepted, playerStarts=accepted, receipts=accepted, archives=accepted,
                activity=accepted, notices=accepted,
                probeCalls=int(not denied and mode != 'native-hit'),
                signatureCalls=0,
                signatureNanoseconds=0,
                stages=[]))
    return rows


class EvidenceContract(unittest.TestCase):
    def args(self, scenario='full-steady'):
        return SimpleNamespace(host='claude-code', scenario=scenario, samples=1, rounds=1)

    def test_complete_valid_samples(self):
        rows = samples()
        DRIVER.validate(rows, self.args())
        summary = DRIVER.summarize(rows)
        self.assertEqual(len(summary['groups']), 16)
        self.assertEqual(len(summary['observer_paired_deltas']), 8)

    def test_nearest_rank_statistics_preserve_negative_deltas(self):
        self.assertEqual(DRIVER.stats([-2_000_000, 0, 4_000_000, 10_000_000]),
                         dict(n=4, p50_ms=0, p90_ms=10, p95_ms=10, max_ms=10))

    def test_worst_round_reference_is_not_the_pooled_percentile(self):
        rows = []
        for rnd in range(2):
            for pair in range(20):
                batch = samples()
                for row in batch:
                    row.update(round=rnd, pair=pair,
                               nanoseconds=100_000_000 if rnd == 0 and pair >= 18 else 1_000_000)
                rows.extend(batch)
        summary = DRIVER.summarize(rows)
        for group in summary['groups']:
            self.assertEqual(group['p95_ms'], 1)
            self.assertEqual(group['worst_round_p95_ms'], 100)

    def test_rejection_is_never_accepted_delivery(self):
        rows = samples('authorization-off')
        DRIVER.validate(rows, self.args('authorization-off'))
        for field in ['accepted', 'playerStarts', 'receipts', 'archives', 'activity', 'notices', 'probeCalls', 'signatureCalls']:
            bad = copy.deepcopy(rows)
            bad[0][field] = 1
            with self.subTest(field=field), self.assertRaises(AssertionError):
                DRIVER.validate(bad, self.args('authorization-off'))

    def test_missing_duplicate_or_unexpected_coordinates(self):
        rows = samples()
        for bad in [rows[:-1], rows[:-1] + [rows[0]], rows + [rows[0]]]:
            with self.assertRaises(AssertionError):
                DRIVER.validate(bad, self.args())
        for field, value in [('host', 'workbuddy'), ('probe', 'imagined'), ('pair', 1), ('round', -1), ('evidence', 'production-helper')]:
            bad = copy.deepcopy(rows)
            bad[0][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                DRIVER.validate(bad, self.args())

    def test_hit_cannot_spawn_probe_or_signature(self):
        for field in ['probeCalls', 'signatureCalls']:
            rows = samples()
            next(r for r in rows if r['probe'] == 'native-hit')[field] = 1
            with self.assertRaises(AssertionError):
                DRIVER.validate(rows, self.args())

    def test_miss_and_force_cannot_hide_signature_validation(self):
        for mode in ['native-cold', 'native-expired', 'native-force']:
            rows = samples()
            row = next(r for r in rows if r['probe'] == mode)
            row.update(signatureCalls=1, signatureNanoseconds=50)
            with self.subTest(mode=mode), self.assertRaises(AssertionError):
                DRIVER.validate(rows, self.args())

    def test_incomplete_comparison_cannot_be_summarized(self):
        with self.assertRaises(AssertionError):
            DRIVER.summarize(samples()[:-1])

    def test_signature_time_cannot_escape_hook_span(self):
        for mode, duration in [('native-hit', 1), ('native-cold', 1), ('native-cold', 101), ('native-cold', -1)]:
            rows = samples()
            next(r for r in rows if r['probe'] == mode)['signatureNanoseconds'] = duration
            with self.subTest(mode=mode, duration=duration), self.assertRaises(AssertionError):
                DRIVER.validate(rows, self.args())


class ExplicitRefreshEvidence(unittest.TestCase):
    def rows(self):
        result = []
        for kind in ['empty', 'replace']:
            hits = [next(r for r in samples(scene) if r['probe'] == 'native-hit' and not r['observer'])
                    for scene in ['full-empty', 'full-steady']]
            result.append(dict(evidence='native-explicit-refresh-and-isolated-hook', host='claude-code',
                               refreshKind=kind, round=0, pair=0, nanoseconds=1000,
                               probeCalls=1, signatureCalls=1, signatureNanoseconds=500,
                               status='published', followingHooks=hits))
        return result

    def test_complete_refresh_and_following_hit(self):
        rows = self.rows()
        DRIVER.validate_refresh(rows, SimpleNamespace(host='claude-code', samples=1, rounds=1))
        self.assertEqual(len(DRIVER.summarize_refresh(rows)['groups']), 2)

    def test_native_refresh_hits_use_core_reference_without_budget_approval(self):
        rows = self.rows()
        for row in rows:
            for hit in row['followingHooks']:
                hit['nanoseconds'] = 16_000_000 if hit['scenario'] == 'full-empty' else 20_000_000
        summary = DRIVER.summarize_refresh(rows)
        self.assertIs(summary['production_refresh_budget_frozen'], False)
        self.assertIs(summary['production_hook_budget_frozen'], False)
        for group in summary['groups']:
            for hit in group['following_hooks']:
                with self.subTest(kind=group['refreshKind'], scenario=hit['scenario']):
                    self.assertNotIn('approved_p95_ms', hit)
                    self.assertNotIn('passed', hit)
                    expected = 15.50 if hit['scenario'] == 'full-empty' else 27.29
                    self.assertEqual(hit['core_reference_p95_ms'], expected)
                    self.assertEqual(hit['within_core_reference'], hit['scenario'] == 'full-steady')

    def test_skips_failures_or_missing_hit_cannot_claim_refresh_success(self):
        args = SimpleNamespace(host='claude-code', samples=1, rounds=1)
        for key, value in [('status', 'busy'), ('probeCalls', 0), ('signatureCalls', 0),
                           ('signatureNanoseconds', 0), ('signatureNanoseconds', 1001)]:
            rows = self.rows(); rows[0][key] = value
            with self.subTest(key=key), self.assertRaises(AssertionError):
                DRIVER.validate_refresh(rows, args)
        for key in ['accepted', 'playerStarts', 'receipts', 'archives', 'activity', 'notices']:
            rows = self.rows(); rows[0]['followingHooks'][0][key] = 0
            with self.subTest(key=key), self.assertRaises(AssertionError):
                DRIVER.validate_refresh(rows, args)
        for rows in [self.rows()[:-1], self.rows() + self.rows()[:1]]:
            with self.assertRaises(AssertionError):
                DRIVER.validate_refresh(rows, args)

if __name__ == '__main__':
    unittest.main()
