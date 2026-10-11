#!/usr/bin/env python3
"""Synthetic compatibility verifier contracts; no real harness or host is executed."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('test-hook-cache-compatibility.py')
CHILD = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
root, host = Path(sys.argv[2]), sys.argv[3]
marker = Path(os.environ['CLAUDIO_COMPATIBILITY_CONTRACT_MARKER'])
with marker.open('a') as log:
    log.write(host + '\\n')
cache = root / 'cache' / (host + '.json')
cold = not cache.exists()
if cold:
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_bytes(b'synthetic-observation')
action = sys.argv[4] if len(sys.argv) > 4 else None
actual = dict(resolved=True, probes=int(cold), signatures=int(cold))
if action:
    actual['refreshStatus'] = 'published' if action == 'refresh' else 'not-requested'
bad = os.environ.get('CLAUDIO_COMPATIBILITY_CONTRACT_BAD', '')
if bad == 'stderr':
    sys.stderr.write('unexpected synthetic stderr\\n')
elif bad == 'unresolved':
    actual['resolved'] = False
elif bad == 'probes':
    actual['probes'] += 1
elif bad == 'signatures':
    actual['signatures'] += 1
elif bad == 'refresh-status' and action:
    actual['refreshStatus'] = 'incorrect'
elif bad == 'rewrite-bytes' and not cold:
    cache.write_bytes(b'changed-observation')
elif bad == 'rewrite-mtime' and not cold:
    stat = cache.stat()
    os.utime(cache, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1000000000))
print(json.dumps(actual))
'''


class CompatibilityVerification(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='claudio-compatibility-contract-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.script = self.root / SCRIPT.name
        self.script.write_bytes(SCRIPT.read_bytes())
        self.before = self.root / 'before'
        self.after = self.root / 'after'
        # Use the current Python interpreter, so synthetic fixtures do not depend
        # on the caller's PATH or a second Python installation.
        child = CHILD.replace('#!/usr/bin/env python3', '#!' + sys.executable, 1)
        for binary in (self.before, self.after):
            binary.write_text(child)
            binary.chmod(0o700)
        scratch = self.root / 'scratch'
        scratch.mkdir()
        self.marker = self.root / 'children.txt'
        self.env = dict(os.environ, TMPDIR=str(scratch),
                        CLAUDIO_COMPATIBILITY_CONTRACT_MARKER=str(self.marker),
                        CLAUDIO_COMPATIBILITY_CONTRACT_BAD='')

    def run_script(self, optimization=None, bad='', importing=False):
        command = [sys.executable, '-B']
        if optimization:
            command.append(optimization)
        if importing:
            command += ['-c', 'import runpy,sys; runpy.run_path(sys.argv[1], run_name="contract_import")',
                        str(self.script)]
        else:
            command += [str(self.script), str(self.before), str(self.after)]
        return subprocess.run(command, env=dict(self.env, CLAUDIO_COMPATIBILITY_CONTRACT_BAD=bad),
                              cwd=self.root, capture_output=True, text=True)

    def snapshot(self):
        return {str(path.relative_to(self.root)): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in self.root.rglob('*') if path.is_file()}

    def test_good_results_preserve_both_orders(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        rows = json.loads(result.stdout)
        self.assertEqual(len(rows), 4)
        self.assertEqual([(row['host'], row['first'], row['second']) for row in rows],
                         [('claude-code', 'before', 'after'), ('claude-code', 'after', 'before'),
                          ('codex', 'before', 'after'), ('codex', 'after', 'before')])
        self.assertTrue(all(row['cold_probes'] == 1 and row['subsequent_probes'] == 0 for row in rows))
        self.assertEqual(len(self.marker.read_text().splitlines()), 8)

    def test_bad_results_are_rejected(self):
        for bad in ('stderr', 'unresolved', 'probes', 'signatures', 'refresh-status',
                    'rewrite-bytes', 'rewrite-mtime'):
            with self.subTest(bad=bad):
                result = self.run_script(bad=bad)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('AssertionError', result.stderr)

    def test_optimized_execution_rejected_before_side_effects(self):
        for optimization in ('-O', '-OO'):
            with self.subTest(optimization=optimization):
                before = self.snapshot()
                result = self.run_script(optimization, bad='unresolved')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('do not use python -O or -OO', result.stderr)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(self.marker.exists())

    def test_optimized_import_rejected(self):
        for optimization in ('-O', '-OO'):
            with self.subTest(optimization=optimization):
                before = self.snapshot()
                result = self.run_script(optimization, importing=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('do not use python -O or -OO', result.stderr)
                self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main()
