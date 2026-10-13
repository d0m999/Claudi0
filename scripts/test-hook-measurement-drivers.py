#!/usr/bin/env python3
"""Driver regressions with isolated state and substituted host/build processes."""

from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parent


def load_driver(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), SCRIPTS / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RealHookEvidenceTests(unittest.TestCase):
    def run_fixture(self, fixture, cases, hold_playback_lock=True):
        module = load_driver('measure-real-hook.py')
        root = fixture / '.claudio'
        (root / 'integrations/installations').mkdir(parents=True)
        (root / 'config.json').write_text(json.dumps({
            'host_integrations': {'surfaces': {'claude-code': {'enabled': True}}}}))
        installation = '10000000-0000-4000-8000-000000000001'
        (root / 'integrations/installations/claude-code.json').write_text(json.dumps({
            'installation_id': installation}))
        helper = fixture / 'helper'
        helper.write_bytes(b'isolated helper identity')
        destination = fixture / 'result.json'
        processes = []
        helper_calls = []
        callback_results = []

        class HostProcess:
            def __init__(self, command, *, cwd, **kwargs):
                self.directory = Path(cwd)
                self.case = cases[len(processes)]
                self.pid = 123
                self.returncode = 0
                self.communications = 0
                processes.append(self)

            def communicate(self, timeout):
                self.communications += 1
                if self.communications == 1:
                    def run_helper(command, **kwargs):
                        helper_calls.append(command)
                        if self.case == 'helper-timeout':
                            raise subprocess.TimeoutExpired(command, kwargs['timeout'])
                        if self.case in {'callback-cancelled', 'host-timeout'}:
                            # Cancellation after callback() publishes its invocation record.
                            raise SystemExit(143)
                        history = root / 'integrations/receipt-history/claude-code'
                        history.mkdir(parents=True, exist_ok=True)
                        (history / ('archive-' + str(len(helper_calls)) + '.json')).write_text(
                            json.dumps({'native_event': 'UserPromptSubmit',
                                        'installation_id': installation,
                                        'playback_result': 'debounced'}))
                        return subprocess.CompletedProcess(
                            command, 0, b'0123456789' if self.case == 'stdout' else b'',
                            b'0123456789' if self.case == 'stderr' else b'')

                    with patch.object(module.subprocess, 'run', side_effect=run_helper), \
                         patch.object(module.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'{}'))):
                        try:
                            callback_results.append(module.callback(self.directory / 'context.json'))
                        except SystemExit:
                            self.returncode = 143
                    if self.case == 'host-timeout':
                        raise subprocess.TimeoutExpired('fixture-host', timeout)
                return json.dumps({'is_error': self.returncode != 0}).encode(), b''

        command = [str(SCRIPTS / 'measure-real-hook.py'), '--helper', str(helper),
                   '--output', str(destination),
                   '--samples', str(len(cases)), '--allow-live-state-batch']
        if hold_playback_lock:
            command.append('--hold-playback-lock')
        with patch.object(module.sys, 'argv', command), \
             patch.object(module.Path, 'home', return_value=fixture), \
             patch.object(module, 'live_gui_metadata', return_value={'fixture_gui': True}), \
             patch.object(module.subprocess, 'check_output', return_value='fixture host version'), \
             patch.object(module.subprocess, 'Popen', HostProcess), \
             patch.object(module.os, 'killpg'), redirect_stdout(io.StringIO()):
            try:
                result = module.main()
            except AssertionError as error:
                result = error
        self.callback_results = callback_results
        return destination, result, processes, helper_calls

    def test_helper_output_prevents_success_and_preserves_failed_sample(self):
        for stream in ['stdout', 'stderr']:
            for hold_lock in [False, True]:
                with self.subTest(stream=stream, hold_lock=hold_lock), tempfile.TemporaryDirectory() as directory:
                    destination, result, processes, calls = self.run_fixture(
                        Path(directory), [stream], hold_playback_lock=hold_lock)
                    self.assertEqual(self.callback_results, [1])
                    self.assertEqual(result, 1, 'driver must propagate the zero-output contract failure')
                    evidence = json.loads(destination.read_text())
                    self.assertFalse(evidence['complete'])
                    self.assertEqual(evidence['initiated_callback'], 1)
                    self.assertEqual(evidence['driver_events_initiated'], 1)
                    self.assertEqual(evidence['helper_exit'], 0)
                    self.assertEqual(evidence[stream + '_bytes'], 10)
                    self.assertEqual(evidence['stderr_bytes' if stream == 'stdout' else 'stdout_bytes'], 0)
                    self.assertEqual(evidence['new_archive_results'], ['debounced'])
                    self.assertEqual(len(calls), 1)
                    self.assertFalse(processes[0].directory.exists())

    def test_lock_busy_failures_preserve_started_callbacks_after_temporary_cleanup(self):
        for case in ['helper-timeout', 'callback-cancelled', 'host-timeout']:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                destination, result, processes, calls = self.run_fixture(Path(directory), [case])
                self.assertIsInstance(result, AssertionError)
                self.assertIn('lock-busy path', str(result))
                self.assertTrue(destination.exists(), 'failed callback must survive temporary cleanup')
                evidence = json.loads(destination.read_text())
                self.assertFalse(evidence['complete'])
                self.assertEqual(len(evidence['sessions']), 1)
                session = evidence['sessions'][0]
                self.assertEqual(session['initiated_callback'], 1)
                self.assertEqual(session['driver_events_initiated'], 1)
                if case == 'helper-timeout':
                    self.assertTrue(session['helper_timed_out'])
                    self.assertTrue(session['callback_completed'])
                    self.assertIsNone(session['helper_exit'])
                else:
                    self.assertFalse(session['callback_completed'])
                self.assertEqual(session['session_timed_out'], case == 'host-timeout')
                self.assertEqual(len(calls), 1)
                self.assertFalse(processes[0].directory.exists())

    def test_later_failure_keeps_both_prior_success_and_failed_invocation(self):
        with tempfile.TemporaryDirectory() as directory:
            destination, result, processes, calls = self.run_fixture(
                Path(directory), ['valid', 'helper-timeout'])
            self.assertIsInstance(result, AssertionError)
            self.assertTrue(destination.exists())
            evidence = json.loads(destination.read_text())
            self.assertFalse(evidence['complete'])
            self.assertEqual(len(evidence['sessions']), 2)
            self.assertEqual(sum(row['initiated_callback'] for row in evidence['sessions']), 2)
            self.assertEqual(evidence['sessions'][0]['new_archive_results'], ['debounced'])
            self.assertTrue(evidence['sessions'][1]['helper_timed_out'])
            self.assertEqual(len(calls), 2)
            self.assertTrue(all(not process.directory.exists() for process in processes))

    def test_valid_lock_busy_callback_completes_measurement(self):
        for hold_lock in [False, True]:
            with self.subTest(hold_lock=hold_lock), tempfile.TemporaryDirectory() as directory:
                destination, result, _, calls = self.run_fixture(
                    Path(directory), ['valid'], hold_playback_lock=hold_lock)
                self.assertEqual(result, 0)
                evidence = json.loads(destination.read_text())
                self.assertTrue(evidence['complete'])
                self.assertEqual(evidence['initiated_callback'], 1)
                self.assertEqual(evidence['new_archive_results'], ['debounced'])
                self.assertEqual(len(calls), 1)

    def test_one_noisy_callback_fails_the_batch_without_dropping_other_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            destination, result, _, calls = self.run_fixture(Path(directory), ['valid', 'stdout'])
            self.assertEqual(result, 1)
            evidence = json.loads(destination.read_text())
            self.assertFalse(evidence['complete'])
            self.assertEqual(evidence['driver_events_initiated'], 2)
            self.assertEqual(evidence['initiated_callback'], 2)
            self.assertEqual(len(evidence['sessions']), 2)
            self.assertEqual([row['stdout_bytes'] for row in evidence['sessions']], [0, 10])
            self.assertEqual(self.callback_results, [0, 1])
            self.assertEqual(len(calls), 2)


class BenchmarkDriverTests(unittest.TestCase):
    def run_fixture(self, fixture, options, fault=None):
        module = load_driver('benchmark-hooks.py')
        binaries = fixture / 'bin'
        binaries.mkdir()
        for name in ['claudio', 'claudio-hook-benchmark']:
            (binaries / name).write_bytes(b'fixture binary')
        destination = fixture / 'measurement'
        commands = []

        identities = []

        def source_identity():
            identities.append(True)
            changed = ((fault == 'build-source' and len(identities) >= 2)
                       or (fault == 'measurement-source' and len(identities) >= 3))
            return {'fixture-source': 'changed' if changed else 'unchanged'}

        def output(command):
            commands.append(command)
            if command == ['claude', '--version']:
                raise FileNotFoundError('claude is absent in this fixture')
            if '--show-bin-path' in command:
                return str(binaries)
            if command == ['git', 'status', '--porcelain']:
                return ''
            return 'fixture metadata'

        def run(command, **kwargs):
            commands.append(command)
            if command[0] == 'swift':
                return subprocess.CompletedProcess(command, 0)
            if '--git-timeout-only' in options:
                self.assertIn('--git-timeout-diagnostic', command)
            if '--git-timeout-diagnostic' in command:
                rows = [{'observer': observer, 'pair': pair, 'nanoseconds': 100,
                         'childrenReaped': True, 'workspaceFailedClosed': True}
                        for observer in [False, True] for pair in range(10)]
            else:
                probe = command[command.index('--probe') + 1]
                scenario = command[command.index('--scenario') + 1]
                samples_count = int(command[command.index('--samples') + 1])
                rounds_count = int(command[command.index('--rounds') + 1])
                scenarios = ['full-empty', 'full-steady', 'muted', 'debounced', 'not-ready',
                             'authorization-off', 'gui-exited', 'stale-installation', 'lock-busy',
                             'workspace-plain', 'workspace-git', 'git-damaged'] if scenario == 'all' else [scenario]
                probes = ['cache-bypass', 'cache-hit'] if probe == 'cache-compare' else [probe]
                rows = [dict(scenario=scenario_name, probe=mode, observer=observer, round=round_index, pair=pair,
                             nanoseconds=100, playback='debounced', probeResult='success', stages=[],
                             accepted=1, playerStarts=0, receipts=1, archives=1, notices=1, activity=1, probeCalls=1)
                        for scenario_name in scenarios for mode in probes for observer in [False, True]
                        for round_index in range(rounds_count) for pair in range(samples_count)]
            for row in rows[:-1] if fault == 'missing-sample' else rows:
                kwargs['stdout'].write(json.dumps(row) + '\n')
            if fault == 'stderr':
                kwargs['stderr'].write('fixture unexpected stderr\n')
            if fault in {'claudio', 'claudio-hook-benchmark'}:
                (binaries / fault).write_bytes(b'replacement from a concurrent build')
            return subprocess.CompletedProcess(command, 0)

        command = [str(SCRIPTS / 'benchmark-hooks.py'), '--output', str(destination), *options]
        with patch.object(sys, 'argv', command), \
             patch.object(module, 'REPO', fixture), \
             patch.object(module, 'source_identity', side_effect=source_identity), \
             patch.object(module, 'output', side_effect=output), \
             patch.object(module.subprocess, 'run', side_effect=run), redirect_stdout(io.StringIO()):
            try:
                module.main()
                result = None
            except (FileNotFoundError, AssertionError, RuntimeError) as error:
                result = error
        return destination, commands, result

    def test_git_only_completes_without_a_real_host_version_query(self):
        for extra in [[], ['--skip-probe-comparison']]:
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as directory:
                destination, commands, result = self.run_fixture(
                    Path(directory), ['--git-timeout-only', *extra])
                self.assertIsNone(result)
                self.assertNotIn(['claude', '--version'], commands)
                metadata = json.loads((destination / 'metadata.json').read_text())
                self.assertTrue(metadata['complete'])
                self.assertFalse(metadata['probe_comparison'])
                self.assertIsNone(metadata['host_version'])
                self.assertEqual(metadata['evidence'], 'core-component-failure-diagnostic')
                rows = (destination / 'git-timeout.jsonl').read_text().splitlines()
                self.assertEqual(len(rows), 20)

    def test_real_version_comparison_still_requires_the_host(self):
        with tempfile.TemporaryDirectory() as directory:
            destination, commands, result = self.run_fixture(Path(directory), [])
            self.assertIsInstance(result, FileNotFoundError)
            self.assertEqual(commands.count(['claude', '--version']), 1)
            self.assertFalse((destination / 'git-timeout.jsonl').exists())

    def test_normal_and_cache_measurements_complete_with_stable_binaries(self):
        for mode in [[], ['--cache-comparison']]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                destination, _, result = self.run_fixture(Path(directory), [
                    '--samples', '1', '--rounds', '1', '--warmup', '0',
                    '--skip-probe-comparison', '--skip-timeout-diagnostic', *mode])
                self.assertIsNone(result)
                metadata = json.loads((destination / 'metadata.json').read_text())
                self.assertTrue(metadata['complete'])

    def test_binary_replacement_prevents_completion_in_every_measurement_mode(self):
        for mode in [[], ['--git-timeout-only'], ['--cache-comparison']]:
            for binary in ['claudio-hook-benchmark', 'claudio']:
                with self.subTest(mode=mode, binary=binary), tempfile.TemporaryDirectory() as directory:
                    destination, _, result = self.run_fixture(Path(directory), [
                        '--samples', '1', '--rounds', '1', '--warmup', '0',
                        '--skip-probe-comparison', '--skip-timeout-diagnostic', *mode], fault=binary)
                    self.assertIsInstance(result, RuntimeError)
                    self.assertIn(binary + ' changed during measurement', str(result))
                    metadata = json.loads((destination / 'metadata.json').read_text())
                    self.assertFalse(metadata.get('complete', False))
                    self.assertTrue(list(destination.glob('*.jsonl')), 'keep failed measurement evidence')

    def test_source_sample_and_stderr_checks_still_reject_invalid_runs(self):
        for mode in [[], ['--git-timeout-only']]:
            for fault in ['build-source', 'measurement-source', 'missing-sample', 'stderr']:
                with self.subTest(mode=mode, fault=fault), tempfile.TemporaryDirectory() as directory:
                    destination, _, result = self.run_fixture(Path(directory), [
                        '--samples', '1', '--rounds', '1', '--warmup', '0',
                        '--skip-probe-comparison', '--skip-timeout-diagnostic', *mode], fault=fault)
                    self.assertIsInstance(result, AssertionError)
                    metadata_file = destination / 'metadata.json'
                    if metadata_file.exists():
                        self.assertFalse(json.loads(metadata_file.read_text()).get('complete', False))

    def test_optimization_is_rejected_before_build_or_evidence_creation(self):
        runner = '''
import importlib.util, sys
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('benchmark_driver', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.argv = sys.argv[1:]
with patch.object(module, 'source_identity', side_effect=RuntimeError('optimization passed entry guard')):
    module.main()
'''
        for python_flags, optimize in [(['-O'], None), ([], '1'), (['-OO'], None), ([], '2')]:
            for mode in [[], ['--git-timeout-only'], ['--cache-comparison']]:
                with self.subTest(flags=python_flags, optimize=optimize, mode=mode), tempfile.TemporaryDirectory() as directory:
                    destination = Path(directory) / 'measurement'
                    environment = os.environ.copy()
                    environment.pop('PYTHONOPTIMIZE', None)
                    if optimize is not None:
                        environment['PYTHONOPTIMIZE'] = optimize
                    result = subprocess.run([sys.executable, *python_flags, '-c', runner,
                                             str(SCRIPTS / 'benchmark-hooks.py'),
                                             '--output', str(destination), *mode],
                                            env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn('do not use python -O', result.stderr)
                    self.assertFalse(destination.exists(), 'entry rejection must precede evidence/build work')


if __name__ == '__main__':
    unittest.main()
