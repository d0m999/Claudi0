#!/usr/bin/env python3
"""Compiled synthetic Claude cache contracts; no build, sampling, host lookup or audio."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

if not __debug__:
    raise SystemExit('contract runner refuses Python -O/-OO')

BINARY = None
SCENARIOS = {
    'full-empty', 'full-steady', 'muted', 'debounced', 'not-ready',
    'authorization-off', 'gui-exited', 'stale-installation', 'lock-busy',
    'workspace-plain', 'workspace-git', 'git-damaged',
}
RESOLVER_CASES = {
    'repeated-empty-miss', 'force-does-not-renew', 'expired', 'identity-change',
    'corrupt', 'unknown-wrapper', 'signature-rejected', 'refresh-operation-busy',
    'cancel-before-refresh', 'identity-change-during-signature',
    'late-failed-probe-keeps-new-refresh',
}


class ClaudeCacheExperimentContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='claudio-cache-contract-runner-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home'
        self.tmp = self.root / 'tmp'
        self.home.mkdir()
        self.tmp.mkdir()
        self.environment = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.tmp),
                                PATH='/usr/bin:/bin', CLAUDE_CONFIG_DIR=str(self.home / '.claude'))

    def invoke(self, *arguments):
        result = subprocess.run([str(BINARY), *arguments], env=self.environment,
                                cwd=self.root, text=True, capture_output=True, timeout=30)
        self.assertEqual(list(self.home.iterdir()), [], 'contract touched home/host state')
        self.assertEqual(list(self.tmp.iterdir()), [], 'contract did not clean temporary fixture')
        return result

    def test_cache_hook_branches_and_resolver_contracts(self):
        result = self.invoke('--claude-cache-contract')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        report = json.loads(result.stdout)
        self.assertEqual(report['evidence'], 'claude-native-cache-synthetic-contract')
        self.assertEqual(report['host'], 'claude-code')
        for field in ['performanceMeasured', 'realHostProbed', 'realSignatureChecked',
                      'audioPlayed', 'lifecycleWiring']:
            self.assertIs(report[field], False)
        self.assertEqual(len(report['resolverCases']), len(RESOLVER_CASES))
        self.assertEqual(set(report['resolverCases']), RESOLVER_CASES)
        expected_coordinates = {(s, c, o) for s in SCENARIOS
                                for c in ['off', 'empty', 'hit'] for o in [False, True]}
        actual_coordinates = set()
        for row in report['hooks']:
            key = (row['scenario'], row['cacheCase'], row['observer'])
            self.assertNotIn(key, actual_coordinates)
            actual_coordinates.add(key)
            self.assertIsInstance(row['observer'], bool)
            denied = row['scenario'] in ['authorization-off', 'gui-exited']
            rejected = denied or row['scenario'] == 'stale-installation'
            accepted = int(not rejected)
            playback = {'muted': 'muted', 'debounced': 'debounced', 'lock-busy': 'debounced',
                        'not-ready': 'not_ready', 'git-damaged': 'not_ready'}.get(row['scenario'], 'played')
            self.assertEqual(row['accepted'], accepted)
            self.assertEqual(row['playback'], 'rejected' if rejected else playback)
            self.assertEqual(row['playerStarts'], int(not rejected and playback == 'played'))
            for field in ['receipts', 'archives', 'notices', 'activity']:
                self.assertEqual(row[field], accepted)
            self.assertEqual(row['probeCalls'], int(not denied and row['cacheCase'] != 'hit'))
            self.assertEqual(row['signatureCalls'], 0)
        self.assertEqual(actual_coordinates, expected_coordinates)
        self.assertEqual(len(report['hooks']), 72)
        self.assertNotIn('nanoseconds', result.stdout)
        self.assertNotIn('signatureNanoseconds', result.stdout)
        self.assertNotIn(str(self.root), result.stdout)

    def test_removed_or_measurement_options_refuse_before_fixtures(self):
        for arguments in [
            ['--claude-cache-contract', '--host', 'codex'],
            ['--claude-cache-contract', '--host', 'all'],
            ['--claude-cache-contract', '--samples', '1'],
            ['--claude-cache-contract', '--measure'],
            ['--claude-cache-contr'], ['--native-hook-cache'],
            ['--native-version-refresh'], ['--cache-comparison'],
            ['--git-timeout-diagnostic'],
        ]:
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('benchmark failed:', result.stderr)

    def test_existing_core_contract_still_works(self):
        result = self.invoke('--contract')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        report = json.loads(result.stdout)
        self.assertEqual(report['evidence'], 'synthetic-branch-contract')
        self.assertEqual(report['cases'], 24)
        self.assertEqual(set(report['branches']), SCENARIOS)
        self.assertIs(report['performanceMeasured'], False)

    def test_optimized_python_refuses_before_binary_access(self):
        for flag, optimized in [('-O', None), ('-OO', None), (None, '1'), (None, '2')]:
            with self.subTest(flag=flag, optimized=optimized):
                env = dict(self.environment)
                if optimized is not None:
                    env['PYTHONOPTIMIZE'] = optimized
                command = [sys.executable]
                if flag:
                    command.append(flag)
                command += ['-B', str(Path(__file__).resolve()), '--binary', '/missing/claudio-hook-benchmark']
                result = subprocess.run(command, env=env, cwd=self.root,
                                        text=True, capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('refuses Python -O/-OO', result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--binary', type=Path, required=True,
                        help='exact compiled claudio-hook-benchmark from the isolated candidate')
    args = parser.parse_args()
    if args.binary.name != 'claudio-hook-benchmark' or args.binary.is_symlink() or not args.binary.is_file():
        parser.error('requires a regular claudio-hook-benchmark executable')
    global BINARY
    BINARY = args.binary.resolve()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ClaudeCacheExperimentContract)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
