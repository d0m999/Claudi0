#!/usr/bin/env python3
"""Kernel-backed lifetime fixture contracts confined to temporary roots."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

from hook_cli_fixture import register_fixture_lifetime


class FixtureLifetimeContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='claudio-cli-fixture-contract-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_current_process_is_registered_without_other_files(self):
        register_fixture_lifetime(self.root)
        value = json.loads((self.root / 'gui-run.json').read_text())
        self.assertIsInstance(uuid.UUID(value['runID']), uuid.UUID)
        self.assertEqual(value['userID'], os.getuid())
        self.assertEqual(value['process']['pid'], os.getpid())
        self.assertGreater(value['process']['startSeconds'], 0)
        self.assertGreaterEqual(value['process']['startMicroseconds'], 0)
        self.assertLess(value['process']['startMicroseconds'], 1_000_000)
        self.assertEqual([p.name for p in self.root.iterdir()], ['gui-run.json'])

    def test_selected_live_process_is_registered(self):
        child = subprocess.Popen(['/bin/cat'], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        try:
            register_fixture_lifetime(self.root, child.pid)
            value = json.loads((self.root / 'gui-run.json').read_text())
            self.assertEqual(value['process']['pid'], child.pid)
        finally:
            child.communicate(timeout=5)

    def test_dead_process_cannot_replace_existing_fixture(self):
        register_fixture_lifetime(self.root)
        before = (self.root / 'gui-run.json').read_bytes()
        child = subprocess.Popen(['/usr/bin/true'])
        child.wait(timeout=5)
        with self.assertRaisesRegex(AssertionError, 'verifiable live kernel identity'):
            register_fixture_lifetime(self.root, child.pid)
        self.assertEqual((self.root / 'gui-run.json').read_bytes(), before)

    def test_invalid_identity_is_rejected_under_all_python_modes(self):
        code = ('import sys; from pathlib import Path; '
                'from hook_cli_fixture import register_fixture_lifetime; '
                'register_fixture_lifetime(Path(sys.argv[1]), -1)')
        for flags in ([], ['-O'], ['-OO']):
            with self.subTest(flags=flags):
                result = subprocess.run([sys.executable, '-B', *flags, '-c', code, str(self.root)],
                                        cwd=Path(__file__).parent, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('verifiable live kernel identity', result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(list(self.root.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
