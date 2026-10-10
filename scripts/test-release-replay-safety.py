#!/usr/bin/env python3
"""Exercise the replay CLI without invoking a real host or reading live Claudio state."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name('measure-release-hooks.py')


class ReleaseReplaySafetyTests(unittest.TestCase):
    def test_default_rejects_before_any_external_process_or_output(self):
        with tempfile.TemporaryDirectory(prefix='claudio-replay-safety-') as directory:
            fixture = Path(directory)
            marker = fixture / 'external-process-called'
            # An old driver stops at this host-version probe, before it can read ~/.claudio.
            # The same tripwire stands in for the helper; no real hook can be invoked.
            tripwire = '#!/bin/sh\n: > "$CLAUDIO_REPLAY_TEST_MARKER"\nexit 97\n'
            for name in ['claude', 'helper']:
                path = fixture / name
                path.write_text(tripwire)
                path.chmod(0o755)
            environment = dict(os.environ, PATH=str(fixture),
                               CLAUDIO_REPLAY_TEST_MARKER=str(marker))
            destination = fixture / 'output'
            result = subprocess.run(
                [sys.executable, str(SCRIPT), '--helper', str(fixture / 'helper'),
                 '--host', 'claude-code', '--output', str(destination)],
                env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('live-state replay is disabled by default', result.stderr)
            self.assertIn('banner notices', result.stderr)
            self.assertIn('receipts', result.stderr)
            self.assertIn('activity counts', result.stderr)
            self.assertIn('benchmark-hooks.py', result.stderr)
            self.assertFalse(marker.exists(), 'default invocation must not spawn host/helper')
            self.assertFalse(destination.exists(), 'rejection must not create output artifacts')
            self.assertEqual(result.stdout, '')

    def test_all_hosts_reject_before_helper_access_even_with_python_optimization(self):
        with tempfile.TemporaryDirectory(prefix='claudio-replay-safety-') as directory:
            fixture = Path(directory)
            for host in ['claude-code', 'codex', 'workbuddy']:
                for options in [[], ['-O']]:
                    with self.subTest(host=host, options=options):
                        destination = fixture / 'output'
                        result = subprocess.run(
                            [sys.executable, *options, str(SCRIPT), '--helper',
                             str(fixture / 'missing-helper'), '--host', host,
                             '--output', str(destination), '--samples', '2',
                             '--warmup', '1', '--rounds', '2'],
                            capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn('live-state replay is disabled by default', result.stderr)
                        self.assertIn('6 accepted events, including warmup', result.stderr)
                        self.assertNotIn('Traceback', result.stderr)
                        self.assertFalse(destination.exists())

    def test_opt_in_must_be_explicit_and_complete(self):
        with tempfile.TemporaryDirectory(prefix='claudio-replay-safety-') as directory:
            fixture = Path(directory)
            command = [sys.executable, str(SCRIPT), '--helper', str(fixture / 'missing-helper'),
                       '--host', 'claude-code', '--output', str(fixture / 'output')]
            abbreviated = subprocess.run(command + ['--allow-live'],
                                         capture_output=True, text=True, timeout=10)
            self.assertEqual(abbreviated.returncode, 2, abbreviated.stderr)
            self.assertIn('unrecognized arguments: --allow-live', abbreviated.stderr)
            # The full opt-in reaches preflight, then the missing fake helper stops the run
            # before host discovery or user-state access. No real replay is authorized here.
            explicit = subprocess.run(command + ['--allow-live-state-replay'],
                                      capture_output=True, text=True, timeout=10)
            self.assertEqual(explicit.returncode, 1, explicit.stderr)
            self.assertIn('FileNotFoundError', explicit.stderr)
            self.assertIn('missing-helper', explicit.stderr)
            self.assertNotIn('live-state replay is disabled by default', explicit.stderr)
            self.assertFalse((fixture / 'output').exists())


if __name__ == '__main__':
    unittest.main()
