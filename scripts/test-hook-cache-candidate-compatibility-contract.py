#!/usr/bin/env python3
"""Synthetic candidate verifier contracts; only temporary fake child processes run."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('test-hook-cache-candidate-compatibility.py')
CHILD = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
if len(sys.argv) != 5 or sys.argv[1] != '--host-version-cache-child':
    sys.exit('only explicit five-argument test child accepted')
root, host, action = Path(sys.argv[2]), sys.argv[3], sys.argv[4]
candidate = Path(sys.argv[0]).name == 'candidate'
marker = Path(os.environ['CLAUDIO_CANDIDATE_CONTRACT_MARKER'])
with marker.open('a') as log:
    log.write(json.dumps(dict(candidate=candidate, host=host, action=action)) + '\n')
cache = root / 'cache' / (host + '.json')
exists = cache.exists()
ineligible = candidate and host == 'codex'
probe = ineligible or action == 'refresh' or not exists
sign = not ineligible and action == 'refresh'
if sign:
    cache.parent.mkdir(exist_ok=True)
    cache.write_bytes(b'synthetic-observation')
actual = dict(resolved=True, probes=int(probe), signatures=int(sign),
              refreshStatus=('ineligible' if ineligible else 'published')
              if action == 'refresh' else 'not-requested')
bad = os.environ.get('CLAUDIO_CANDIDATE_CONTRACT_BAD', '')
if bad == 'stderr':
    sys.stderr.write('unexpected stderr\n')
elif bad == 'unresolved':
    actual['resolved'] = False
elif bad == 'probes':
    actual['probes'] += 1
elif bad == 'signatures':
    actual['signatures'] += 1
elif bad == 'refresh-status':
    actual['refreshStatus'] = 'wrong'
elif bad == 'boolean-count':
    actual['probes'] = True
elif bad == 'nonzero':
    sys.exit(7)
elif bad == 'rewrite-bytes' and exists:
    cache.write_bytes(b'rewritten')
elif bad == 'rewrite-mtime' and exists:
    info = cache.stat()
    os.utime(cache, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000000))
elif bad in ('codex-create', 'codex-lock') and ineligible:
    cache.parent.mkdir(exist_ok=True)
    path = cache if bad == 'codex-create' else cache.parent / 'codex.lock'
    path.write_bytes(b'unwanted')
elif bad == 'bad-json':
    print('invalid JSON')
    sys.exit(0)
print(json.dumps(actual))
'''


class CandidateCompatibilityVerification(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='claudio-candidate-contract-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.script = self.root / SCRIPT.name
        self.script.write_bytes(SCRIPT.read_bytes())
        self.historical = self.root / 'historical'
        self.candidate = self.root / 'candidate'
        child = CHILD.replace('#!/usr/bin/env python3', '#!' + sys.executable, 1)
        for binary in (self.historical, self.candidate):
            binary.write_text(child)
            binary.chmod(0o700)
        scratch = self.root / 'scratch'
        scratch.mkdir()
        self.marker = self.root / 'children.jsonl'
        self.env = dict(os.environ, TMPDIR=str(scratch),
                        CLAUDIO_CANDIDATE_CONTRACT_MARKER=str(self.marker),
                        CLAUDIO_CANDIDATE_CONTRACT_BAD='')

    def run_script(self, optimization=None, bad='', importing=False, same_binary=False):
        command = [sys.executable, '-B']
        if optimization:
            command.append(optimization)
        if importing:
            command += ['-c', 'import runpy,sys; runpy.run_path(sys.argv[1], run_name="contract_import")',
                        str(self.script)]
        else:
            command += [str(self.script), str(self.historical),
                        str(self.historical if same_binary else self.candidate)]
        return subprocess.run(command, cwd=self.root, capture_output=True, text=True,
                              env=dict(self.env, CLAUDIO_CANDIDATE_CONTRACT_BAD=bad))

    def snapshot(self):
        return {str(path.relative_to(self.root)): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in self.root.rglob('*') if path.is_file()}

    def test_good_results_separate_cache_reuse_from_codex_fallback(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        rows = json.loads(result.stdout)
        self.assertEqual([(row['host'], row['scenario']) for row in rows],
                         [('claude-code', 'historical-first'), ('claude-code', 'candidate-first'),
                          ('codex', 'historical-first'), ('codex', 'candidate-first')])
        for row in rows[:2]:
            self.assertEqual([step['probes'] for step in row['steps']], [1, 0])
            self.assertEqual([step['signatures'] for step in row['steps']], [1, 0])
            self.assertEqual(row['steps'][1]['cache_effect'], 'preserved')
        codex_steps = [step for row in rows[2:] for step in row['steps'] if step['role'] == 'candidate']
        self.assertTrue(codex_steps)
        self.assertTrue(all(step['probes'] == 1 and step['signatures'] == 0 for step in codex_steps))
        self.assertEqual([step['cache_effect'] for step in rows[3]['steps'][:2]], ['absent', 'absent'])
        calls = [json.loads(line) for line in self.marker.read_text().splitlines()]
        self.assertEqual(len(calls), 14)

    def test_bad_outputs_and_cache_side_effects_are_rejected(self):
        for bad in ('stderr', 'unresolved', 'probes', 'signatures', 'refresh-status',
                    'boolean-count', 'nonzero', 'bad-json', 'rewrite-bytes', 'rewrite-mtime',
                    'codex-create', 'codex-lock'):
            with self.subTest(bad=bad):
                result = self.run_script(bad=bad)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('cache candidate compatibility failed', result.stderr)

    def test_same_binary_roles_rejected_before_child_execution(self):
        result = self.run_script(same_binary=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertFalse(self.marker.exists())

    def test_optimized_execution_and_import_rejected_before_side_effects(self):
        for optimization in ('-O', '-OO'):
            for importing in (False, True):
                with self.subTest(optimization=optimization, importing=importing):
                    before = self.snapshot()
                    result = self.run_script(optimization=optimization, importing=importing)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, '')
                    self.assertIn('do not use python -O or -OO', result.stderr)
                    self.assertEqual(self.snapshot(), before)
                    self.assertFalse(self.marker.exists())


if __name__ == '__main__':
    unittest.main()
