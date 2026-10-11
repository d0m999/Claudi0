#!/usr/bin/env python3
"""Exercise the read-only closeout CLI only in synthetic temporary directories."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

VERIFIER = Path(__file__).with_name('verify-hook-cache-closeout.py')
REJECTION = 'closeout verification requires assertions; do not use python -O or -OO'


def snapshot(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


class CloseoutVerifierContract(unittest.TestCase):
    def fixture(self, root):
        package = root / 'dist/closeout'
        package.mkdir(parents=True)
        script = root / 'scripts/verify-hook-cache-closeout.py'
        script.parent.mkdir()
        script.write_bytes(VERIFIER.read_bytes())
        original = root / 'dist/original/samples.jsonl'
        original.parent.mkdir(parents=True)
        original.write_text('synthetic evidence\n')
        (package / 'evidence-index.json').write_text(json.dumps({
            str(original.relative_to(root)): hashlib.sha256(original.read_bytes()).hexdigest()}))
        (package / 'verification.json').write_text('{"sentinel": "retain original"}\n')
        self.manifest(package)
        return package, script, original

    def manifest(self, package):
        (package / 'package-sha256.json').write_text(json.dumps({
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in package.iterdir() if p.is_file() and p.name != 'package-sha256.json'}))

    def run_verifier(self, root, script, package, *options):
        return subprocess.run([sys.executable, '-B', *options, str(script),
                               '--package', str(package), '--evidence-root', str(root)],
                              cwd=root, capture_output=True, text=True, timeout=10)

    def test_optimized_modes_reject_before_any_package_write(self):
        for optimization in ['-O', '-OO']:
            with self.subTest(optimization=optimization), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                package, script, _ = self.fixture(root)
                before = snapshot(root)
                result = self.run_verifier(root, script, package, optimization)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(REJECTION, result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(snapshot(root), before)

    def test_optimized_import_rejects_too(self):
        for optimization in ['-O', '-OO']:
            with self.subTest(optimization=optimization), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                _, script, _ = self.fixture(root)
                before = snapshot(root)
                code = 'import runpy,sys; runpy.run_path(sys.argv[1], run_name="contract_import")'
                result = subprocess.run([sys.executable, '-B', optimization, '-c', code, str(script)],
                                        cwd=root, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(REJECTION, result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(snapshot(root), before)

    def test_obsolete_writer_commands_cannot_overwrite_baseline(self):
        for phase in ['initialize', 'finalize']:
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                package, script, _ = self.fixture(root)
                before = snapshot(root)
                result = subprocess.run([sys.executable, '-B', str(script), phase,
                                         '--package', str(package), '--evidence-root', str(root)],
                                        cwd=root, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('unrecognized arguments', result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(snapshot(root), before)

    def test_changed_evidence_rejects_without_rewriting_verdict(self):
        for changed in ['package', 'external']:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                package, script, original = self.fixture(root)
                target = package / 'verification.json' if changed == 'package' else original
                target.write_text('changed\n')
                before = snapshot(root)
                result = self.run_verifier(root, script, package)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('digest mismatch', result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(snapshot(root), before)

    def test_valid_package_reports_only_digest_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package, script, _ = self.fixture(root)
            before = snapshot(root)
            result = self.run_verifier(root, script, package)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            self.assertEqual(json.loads(result.stdout), dict(
                schema_version=1, verification='listed-sha256-digests',
                package_files_verified=2, external_files_verified=1))
            self.assertEqual(snapshot(root), before)
            self.assertNotIn(str(root), result.stdout)

    def test_external_index_cannot_be_silently_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package, script, _ = self.fixture(root)
            before = snapshot(root)
            result = subprocess.run([sys.executable, '-B', str(script), '--package', str(package)],
                                    cwd=root, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('--evidence-root is required', result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertEqual(snapshot(root), before)

    def test_unsafe_manifest_paths_and_symlinks_are_rejected(self):
        for name in ['../outside', '/outside', 'nested/../outside', 'linked.json', 'linked-dir/samples.jsonl']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                package, script, original = self.fixture(root)
                if name == 'linked.json':
                    (package / name).symlink_to(original)
                if name.startswith('linked-dir/'):
                    (package / 'linked-dir').symlink_to(original.parent, target_is_directory=True)
                (package / 'package-sha256.json').write_text(json.dumps({name: '0' * 64}))
                before = snapshot(root)
                result = self.run_verifier(root, script, package)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('unsafe manifest path', result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(snapshot(root), before)

    def test_empty_malformed_and_duplicate_manifests_are_rejected(self):
        for content in ['{}', '[]', 'invalid JSON', '{"a":"wrong-digest"}',
                        '{"a":"' + '0' * 64 + '","a":"' + '1' * 64 + '"}']:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                package, script, _ = self.fixture(root)
                (package / 'package-sha256.json').write_text(content)
                before = snapshot(root)
                result = self.run_verifier(root, script, package)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertEqual(snapshot(root), before)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verifier', type=Path, default=VERIFIER)
    args, remaining = parser.parse_known_args()
    VERIFIER = args.verifier.resolve(strict=True)
    unittest.main(argv=[sys.argv[0], *remaining])
