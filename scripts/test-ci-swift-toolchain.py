#!/usr/bin/env python3
"""Exercise toolchain trust failures without downloading or installing real tools."""
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ci_swift', ROOT / 'scripts/setup-ci-swift.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class ToolchainTrustSuite(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='claudio-toolchain-trust-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / 'toolchains'
        self.download = self.root / 'download'
        self.payload = b'controlled signed package fixture'
        self.sha = hashlib.sha256(self.payload).hexdigest()
        self.signature = ('Status: signed by a developer certificate issued by Apple for distribution\n'
                          'Notarization: trusted by the Apple notary service\n'
                          '1. Developer ID Installer: Swift Open Source (V9AUD2URP3)\n')
        self.version = 'Swift version 6.4.1 (swift-6.4.1-RELEASE)\nTarget: arm64-apple-macosx26.0\n'
        self.calls = []
        self.identity = {'original-swift': {'sha256': 'unchanged', 'mode': '0o755'}}
        self.identities = [self.identity, self.identity]

    def execute(self, args):
        self.calls.append([str(x) for x in args])
        if args[0] == '/usr/bin/curl':
            Path(args[args.index('--output') + 1]).write_bytes(self.payload)
            return ''
        if args[0] == '/usr/sbin/pkgutil':
            return self.signature
        if args[0] == '/usr/sbin/installer':
            target = self.tools / setup.TOOLCHAIN_NAME
            (target / 'usr/bin').mkdir(parents=True)
            (target / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.swift.fixture641'}))
            return 'Fixture installed\n'
        if str(args[0]).endswith('/usr/bin/swift'):
            return self.version
        if args[0] == '/usr/bin/codesign':
            return ''
        raise AssertionError(f'Unexpected real command: {args}')

    def install(self):
        with patch.object(setup, 'PACKAGE_SHA256', self.sha), \
             patch.object(setup, 'execute', side_effect=self.execute), \
             patch.object(setup, 'installed_tool_identity', side_effect=self.identities):
            return setup.install(self.tools, self.download)

    def installed(self):
        return any(x[0] == '/usr/sbin/installer' for x in self.calls)

    def test_verified_package_selects_exact_version_and_preserves_existing_tools(self):
        result = self.install()
        self.assertTrue(self.installed())
        self.assertEqual(result['TOOLCHAINS'], 'org.swift.fixture641')
        self.assertEqual(result['package_sha256'], self.sha)
        self.assertTrue(result['existing_tool_hashes_and_modes_unchanged'])
        self.assertEqual(result['bin_path'], str(self.tools / setup.TOOLCHAIN_NAME / 'usr/bin'))

    def test_wrong_package_digest_never_reaches_installer(self):
        self.payload = b'tampered package'
        with self.assertRaisesRegex(RuntimeError, 'SHA-256'):
            self.install()
        self.assertFalse(self.installed())

    def test_other_developer_signature_never_reaches_installer(self):
        self.signature = self.signature.replace('Swift Open Source (V9AUD2URP3)', 'Another Developer (XXXXXXXXXX)')
        with self.assertRaisesRegex(RuntimeError, 'signature'):
            self.install()
        self.assertFalse(self.installed())

    def test_untrusted_chain_never_reaches_installer(self):
        self.signature = self.signature.replace('trusted by the Apple notary service', 'untrusted')
        with self.assertRaisesRegex(RuntimeError, 'signature'):
            self.install()
        self.assertFalse(self.installed())

    def test_untrusted_status_text_cannot_match_trusted_line(self):
        self.signature = self.signature.replace('Notarization: trusted', 'Notarization: not trusted')
        with self.assertRaisesRegex(RuntimeError, 'signature'):
            self.install()
        self.assertFalse(self.installed())

    def test_preexisting_toolchain_is_not_overwritten(self):
        (self.tools / setup.TOOLCHAIN_NAME).mkdir(parents=True)
        marker = self.tools / setup.TOOLCHAIN_NAME / 'keep'
        marker.write_bytes(b'existing work')
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            self.install()
        self.assertEqual(marker.read_bytes(), b'existing work')
        self.assertEqual(self.calls, [])

    def test_symlink_destination_is_not_followed(self):
        self.tools.mkdir()
        destination = self.root / 'unrelated'
        destination.mkdir()
        (self.tools / setup.TOOLCHAIN_NAME).symlink_to(destination, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            self.install()
        self.assertEqual(list(destination.iterdir()), [])
        self.assertEqual(self.calls, [])

    def test_symlink_toolchain_root_is_not_followed(self):
        destination = self.root / 'unrelated'
        destination.mkdir()
        self.tools.symlink_to(destination, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'symbolic link'):
            self.install()
        self.assertEqual(list(destination.iterdir()), [])
        self.assertEqual(self.calls, [])

    def test_self_hosted_runner_does_not_install(self):
        with patch.dict(os.environ, GITHUB_ACTIONS='true', RUNNER_OS='macOS',
                        RUNNER_ENVIRONMENT='self-hosted'), patch.object(setup, 'install') as install:
            with self.assertRaisesRegex(RuntimeError, 'disposable macOS'):
                setup.main()
            install.assert_not_called()

    def test_version_mismatch_rejects_toolchain_selection(self):
        self.version = 'Swift version 6.4.2 (unexpected)\n'
        with self.assertRaisesRegex(RuntimeError, 'version'):
            self.install()

    def test_installed_tool_mode_change_fails_isolation(self):
        self.identities[1] = {'original-swift': {'sha256': 'unchanged', 'mode': '0o700'}}
        with self.assertRaisesRegex(RuntimeError, 'Existing tool'):
            self.install()


if __name__ == '__main__':
    unittest.main()
