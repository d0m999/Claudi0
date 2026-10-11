#!/usr/bin/env python3
"""Core driver contracts with substituted build/host processes; no performance sampling."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('benchmark-hooks.py')


def load_driver():
    spec = importlib.util.spec_from_file_location('core_benchmark_driver', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BenchmarkDriverTests(unittest.TestCase):
    def run_fixture(self, fixture, options=(), fault=None):
        module = load_driver()
        binaries = fixture / 'bin'
        binaries.mkdir()
        for name in ['claudio', 'claudio-hook-benchmark']:
            (binaries / name).write_bytes(b'fixture binary')
        destination = fixture / 'evidence'
        commands, identities = [], []

        def source_identity():
            identities.append(True)
            changed = ((fault == 'build-source' and len(identities) >= 2)
                       or (fault == 'measurement-source' and len(identities) >= 3))
            return {'fixture-source': 'changed' if changed else 'unchanged'}

        def output(command):
            commands.append(command)
            if command == ['claude', '--version']:
                raise FileNotFoundError('fixture host absent')
            if '--show-bin-path' in command:
                return str(binaries)
            if command == ['git', 'status', '--porcelain']:
                return ''
            return 'fixture metadata'

        def run(command, **kwargs):
            commands.append(command)
            if command[0] == 'swift':
                return subprocess.CompletedProcess(command, 0)
            probe = command[command.index('--probe') + 1]
            selected = command[command.index('--scenario') + 1]
            count = int(command[command.index('--samples') + 1])
            rounds = int(command[command.index('--rounds') + 1])
            scenarios = module.SCENARIOS if selected == 'all' else [selected]
            rows = []
            for scenario in scenarios:
                denied = scenario in ['authorization-off', 'gui-exited']
                rejected = denied or scenario == 'stale-installation' or probe == 'timeout'
                playback = {'muted': 'muted', 'debounced': 'debounced', 'lock-busy': 'debounced',
                            'not-ready': 'not_ready', 'git-damaged': 'not_ready'}.get(scenario, 'played')
                for rnd in range(rounds):
                    for pair in range(count):
                        for observer in [False, True]:
                            rows.append(dict(evidence='core-isolated', host='claude-code',
                                             scenario=scenario, probe=probe, round=rnd, pair=pair,
                                             observer=observer, nanoseconds=100, stages=[],
                                             playback='rejected' if rejected else playback,
                                             probeResult='not-invoked' if denied else
                                             'timed-out' if probe == 'timeout' else 'completed',
                                             accepted=int(not rejected),
                                             playerStarts=int(not rejected and playback == 'played'),
                                             receipts=int(not rejected), archives=int(not rejected),
                                             activity=int(not rejected), notices=int(not rejected),
                                             probeCalls=int(not denied)))
            if fault == 'duplicate-coordinate':
                rows[-1] = rows[0]
            if fault == 'wrong-branch':
                rows[0]['accepted'] = 0
            for row in rows[:-1] if fault == 'missing-sample' else rows:
                kwargs['stdout'].write(json.dumps(row) + '\n')
            if fault == 'stderr':
                kwargs['stderr'].write('fixture unexpected stderr\n')
            if fault in ['claudio', 'claudio-hook-benchmark']:
                (binaries / fault).write_bytes(b'changed binary')
            return subprocess.CompletedProcess(command, 0)

        command = ['driver', '--output', str(destination), '--samples', '1', '--rounds', '1',
                   '--warmup', '0', '--skip-probe-comparison', '--skip-timeout-diagnostic', *options]
        with patch.object(sys, 'argv', command), patch.object(module, 'REPO', fixture), \
             patch.object(module, 'source_identity', side_effect=source_identity), \
             patch.object(module, 'output', side_effect=output), \
             patch.object(module.subprocess, 'run', side_effect=run), redirect_stdout(io.StringIO()):
            try:
                module.main()
                error = None
            except (AssertionError, RuntimeError, SystemExit, FileNotFoundError) as caught:
                error = caught
        return destination, commands, error

    def test_stable_inputs_and_explicit_arm64_build_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            destination, commands, error = self.run_fixture(Path(directory))
            self.assertIsNone(error)
            metadata = json.loads((destination / 'metadata.json').read_text())
            self.assertTrue(metadata['complete'])
            builds = [command for command in commands if command[:2] == ['swift', 'build']]
            self.assertEqual(len(builds), 3)
            for command in builds:
                self.assertEqual(command[:len(metadata['build'])], metadata['build'])
                self.assertEqual(command[command.index('--arch') + 1], 'arm64')
                self.assertEqual(command[command.index('--experimental-lto-mode') + 1], 'full')
                self.assertIn('-Osize', command)
            self.assertEqual(len((destination / 'scenarios.jsonl').read_text().splitlines()), 24)
            self.assertNotIn(['claude', '--version'], commands)

    def test_rejected_evidence_keeps_raw_rows_without_completion(self):
        faults = ['claudio', 'claudio-hook-benchmark', 'measurement-source', 'missing-sample',
                  'duplicate-coordinate', 'wrong-branch', 'stderr']
        for fault in faults:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                destination, _, error = self.run_fixture(Path(directory), fault=fault)
                self.assertIsNotNone(error)
                self.assertFalse(json.loads((destination / 'metadata.json').read_text())['complete'])
                self.assertTrue((destination / 'scenarios.jsonl').exists())

    def test_build_source_drift_rejects_before_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            destination, _, error = self.run_fixture(Path(directory), fault='build-source')
            self.assertIsInstance(error, AssertionError)
            self.assertFalse((destination / 'scenarios.jsonl').exists())

    def test_removed_experimental_options_reject_before_build(self):
        for option in ['--cache-comparison', '--git-timeout-only', '--native-hook-cache']:
            with self.subTest(option=option), tempfile.TemporaryDirectory() as directory:
                destination, commands, error = self.run_fixture(Path(directory), [option])
                self.assertIsInstance(error, SystemExit)
                self.assertEqual(error.code, 2)
                self.assertEqual(commands, [])
                self.assertFalse(destination.exists())

    def test_optimized_python_rejects_before_evidence_creation(self):
        runner = '''import importlib.util, sys
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('driver', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.argv = sys.argv[1:]
with patch.object(module, 'source_identity', side_effect=RuntimeError('entry guard bypassed')):
    module.main()
'''
        for flags, optimize in [(['-O'], None), (['-OO'], None), ([], '1'), ([], '2')]:
            with self.subTest(flags=flags, optimize=optimize), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'evidence'
                environment = dict(os.environ)
                environment.pop('PYTHONOPTIMIZE', None)
                if optimize:
                    environment['PYTHONOPTIMIZE'] = optimize
                result = subprocess.run([sys.executable, *flags, '-c', runner, str(SCRIPT),
                                         '--output', str(output)], env=environment,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('do not use python -O', result.stderr)
                self.assertFalse(output.exists())

    def test_existing_statistics_owner_handles_empty_and_signed_values(self):
        module = load_driver()
        self.assertIs(module.stats, module.STATISTICS.stats)
        with self.assertRaises(ValueError):
            module.stats([])
        self.assertEqual(module.stats([-100, 200])['p50_ms'], -0.0001)


@unittest.skipUnless(os.environ.get('CLAUDIO_BENCHMARK_CONTRACT_BINARY'),
                     'set the isolated compiled benchmark path to run branch contracts')
class CompiledBranchContracts(unittest.TestCase):
    def invoke(self, arguments):
        binary = Path(os.environ['CLAUDIO_BENCHMARK_CONTRACT_BINARY']).resolve()
        self.assertEqual(binary.name, 'claudio-hook-benchmark')
        with tempfile.TemporaryDirectory(prefix='claudio-core-contract-') as directory:
            environment = dict(os.environ, HOME=directory, TMPDIR=directory, PATH=directory)
            return subprocess.run([str(binary), *arguments], env=environment,
                                  capture_output=True, text=True, timeout=30)

    def test_all_twelve_branches_with_observer_on_and_off(self):
        result = self.invoke(['--contract'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        data = json.loads(result.stdout)
        self.assertEqual(data['cases'], 24)
        self.assertEqual(data['branches'], {
            'full-empty': 'played', 'full-steady': 'played', 'muted': 'muted',
            'debounced': 'debounced', 'not-ready': 'not_ready', 'authorization-off': 'rejected',
            'gui-exited': 'rejected', 'stale-installation': 'rejected', 'lock-busy': 'debounced',
            'workspace-plain': 'played', 'workspace-git': 'played', 'git-damaged': 'not_ready'})
        self.assertFalse(data['performanceMeasured'])
        self.assertFalse(data['realHostCallbacks'])
        self.assertFalse(data['audioPlayed'])
        self.assertNotIn('nanoseconds', result.stdout)

    def test_native_cache_and_diagnostic_entries_are_not_present(self):
        for arguments in [['--native-hook-cache'], ['--native-version-refresh'],
                          ['--native-signature-diagnostic'], ['--git-timeout-diagnostic'],
                          ['--probe', 'cache-hit'], ['--contract', '--probe', 'real']]:
            with self.subTest(arguments=arguments):
                result = self.invoke(arguments)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, '')
                self.assertIn('benchmark failed: invalid', result.stderr)


if __name__ == '__main__':
    unittest.main()
