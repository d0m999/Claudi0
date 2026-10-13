#!/usr/bin/env python3
"""Synthetic identity selection contracts; no helper build, real host or hook replay."""
from importlib.util import module_from_spec, spec_from_file_location
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
SOURCES = REPO / 'helper/Sources/claudio-hook-benchmark'


class NativeIdentitySelection(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='claudio-identity-contract-')
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        stub = root / 'ClaudioCore.swift'
        stub.write_text('''import Foundation
public enum HostID: String { case claudeCode = "claude-code", codex = "codex" }
public enum HostVersionResolutionMode { case forceProbe }
public struct HostExecutableLocator {
    public static func standard() -> Self { Self() }
    public func executablePath(command: String) -> String? {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDIO_IDENTITY_CONTRACT_ROOT"]!)
        let log = root.appendingPathComponent("consulted.txt")
        let previous = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try! (previous + command + "\\n").write(to: log, atomically: true, encoding: .utf8)
        let path = root.appendingPathComponent("bin/" + command).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
public struct HostVersionResolver {
    public init(executableLocator: HostExecutableLocator) {}
    public func resolve(_ host: HostID, mode: HostVersionResolutionMode) -> String? {
        "2.1.282"
    }
}
''')
        # Compile the real collector and its real CLI dispatch with only the Core
        # lookup/probe boundary replaced. Neither benchmark main nor Core is run.
        collector = SOURCES / 'NativeHostIdentity.swift'
        body = (collector.read_text() if collector.exists() else
                (SOURCES / 'NativeHookCacheBenchmark.swift').read_text().split(
                    '/// Complete handleHostHook calls', 1)[0])
        isolated = root / 'NativeHostIdentity.swift'
        isolated.write_text(body)
        original = (SOURCES / 'main.swift').read_text()
        start = original.index('    if arguments.contains("--native-host-identities") {')
        end = original.index('\n    if arguments.contains("--native-hook-cache")', start)
        branch = original[start:end]
        wrapper = root / 'main.swift'
        wrapper.write_text('''import Foundation
struct Failure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}
func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String, _ fallback: String) -> String {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return fallback }
        return arguments[i + 1]
    }
''' + branch + '''
}
do { try main() } catch {
    FileHandle.standardError.write(Data("identity contract rejected\\n".utf8)); exit(1)
}
''')
        sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
        compiler = ['swiftc', '-swift-version', '6']
        if sdk.is_dir():
            compiler += ['-sdk', str(sdk)]
        cls.binary = root / 'identity-contract'
        commands = [compiler + ['-emit-module', '-emit-object', '-parse-as-library',
                               '-module-name', 'ClaudioCore', str(stub), '-o', str(root / 'ClaudioCore.o')],
                    compiler + ['-I', str(root), str(isolated), str(wrapper),
                                str(root / 'ClaudioCore.o'), '-o', str(cls.binary)]]
        for command in commands:
            result = subprocess.run(command, cwd=root, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stderr)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='claudio-identity-fixture-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.env = dict(os.environ, CLAUDIO_IDENTITY_CONTRACT_ROOT=str(self.root))

    def fixture(self, host):
        target = self.root / ('versions/2.1.282' if host == 'claude-code' else 'package/bin/codex')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b'synthetic-host-binary')
        (self.root / 'bin').mkdir(exist_ok=True)
        (self.root / 'bin' / ('claude' if host == 'claude-code' else 'codex')).symlink_to(target)
        if host == 'codex':
            (self.root / 'package/codex-package.json').write_text('{"layoutVersion":1}')

    def invoke(self, host=None):
        args = [str(self.binary), '--native-host-identities']
        if host is not None:
            args += ['--host', host]
        return subprocess.run(args, env=self.env, capture_output=True, text=True)

    def verify(self, result, hosts, commands):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        rows = json.loads(result.stdout)
        self.assertEqual([row['host'] for row in rows], hosts)
        self.assertEqual((self.root / 'consulted.txt').read_text().splitlines(), commands)
        for row in rows:
            for key in ('binarySHA256', 'invocationPathSHA256', 'targetPathSHA256'):
                self.assertEqual(len(row[key]), 64)
            self.assertEqual('metadataSHA256' in row, row['host'] == 'codex')

    def test_claude_only(self):
        self.fixture('claude-code')
        self.verify(self.invoke('claude-code'), ['claude-code'], ['claude'])

    def test_codex_only(self):
        self.fixture('codex')
        self.verify(self.invoke('codex'), ['codex'], ['codex'])

    def test_default_all(self):
        for host in ('claude-code', 'codex'):
            self.fixture(host)
        self.verify(self.invoke(), ['claude-code', 'codex'], ['claude', 'codex'])

    def test_explicit_all(self):
        for host in ('claude-code', 'codex'):
            self.fixture(host)
        self.verify(self.invoke('all'), ['claude-code', 'codex'], ['claude', 'codex'])

    def test_invalid_selection_rejects_before_lookup(self):
        result = self.invoke('unknown')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertFalse((self.root / 'consulted.txt').exists())

    def test_python_driver_forwards_selected_host(self):
        spec = spec_from_file_location('native_driver', REPO / 'scripts/benchmark-native-hook-cache.py')
        driver = module_from_spec(spec)
        spec.loader.exec_module(driver)
        self.fixture('codex')
        # Only the identity function is used; driver.main would build and measure.
        with patch.dict(os.environ, self.env):
            rows = driver.identity(self.binary, 'codex')
        self.assertEqual([row['host'] for row in rows], ['codex'])
        self.assertEqual((self.root / 'consulted.txt').read_text().splitlines(), ['codex'])

    def test_driver_preflight_and_postflight_use_selected_host(self):
        spec = spec_from_file_location('native_driver', REPO / 'scripts/benchmark-native-hook-cache.py')
        driver = module_from_spec(spec)
        spec.loader.exec_module(driver)
        for host in ('claude-code', 'codex', 'all'):
            with self.subTest(host=host):
                output = self.root / 'dist' / host
                calls = []

                def identity(binary, selected_host='all'):
                    calls.append(selected_host)
                    return [{'host': selected_host}]

                def run(command, **kwargs):
                    if '--native-hook-cache' in command:
                        self.assertEqual(command[command.index('--host') + 1], host)
                        # Empty output is a synthetic boundary fixture, not samples.
                        kwargs['stdout'].write('')

                def copy(source, destination):
                    Path(destination).write_bytes(b'synthetic-binary')

                with patch.object(driver, 'REPO', self.root), \
                     patch.object(driver, 'source_identity', return_value={'fixture': 'unchanged'}), \
                     patch.object(driver.BENCH, 'output', return_value=str(self.root)), \
                     patch.object(driver.BENCH, 'digest', return_value='synthetic-digest'), \
                     patch.object(driver.BENCH, 'verify_binary_identity'), \
                     patch.object(driver.shutil, 'copy2', side_effect=copy), \
                     patch.object(driver.subprocess, 'run', side_effect=run), \
                     patch.object(driver, 'identity', side_effect=identity), \
                     patch.object(driver, 'validate'), \
                     patch.object(driver, 'summarize', return_value={}), \
                     patch('sys.argv', ['driver', '--output', str(output), '--host', host]), \
                     patch('builtins.print'):
                    driver.main()
                self.assertEqual(calls, [host, host])
                metadata = json.loads((output / 'metadata.json').read_text())
                self.assertEqual(metadata['hosts_before'], metadata['hosts_after'])


if __name__ == '__main__':
    unittest.main()
