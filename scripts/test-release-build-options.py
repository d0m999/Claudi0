#!/usr/bin/env python3
"""Validate real bundle/workflow command arguments using isolated fake compilers."""

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "bundle_identity_fixture", ROOT / "scripts/test-bailian-bundle-identity.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class ReleaseBuildOptionsSuite(unittest.TestCase):
    def assert_options(self, args):
        self.assertEqual(args[args.index("--arch") + 1], "arm64")
        self.assertEqual(args[args.index("-c") + 1], "release")
        product = args[args.index("--product") + 1]
        if product in ("claudio", "ClaudioGUI"):
            self.assertEqual(args[args.index("--experimental-lto-mode") + 1], "full")
            self.assertIn(["-Xswiftc", "-Osize"],
                          [args[i:i + 2] for i in range(len(args))])
        else:
            self.assertEqual(product, "ClaudioLoginItem")
            self.assertNotIn("--experimental-lto-mode", args)
            self.assertNotIn("-Osize", args)

    def test_local_build_and_path_query_arguments(self):
        calls = fixture.run_case("")
        self.assertEqual(len(calls), 6)
        for product in ("claudio", "ClaudioGUI", "ClaudioLoginItem"):
            product_calls = [a for a in calls if a[a.index("--product") + 1] == product]
            self.assertEqual(len(product_calls), 2)
            self.assertEqual(sum("--show-bin-path" in a for a in product_calls), 1)
        for args in calls:
            self.assert_options(args)

    def reject_mutation(self, original, replacement, expected):
        source = (ROOT / "scripts/dev-bundle.sh").read_text()
        self.assertEqual(source.count(original), 1, "mutation must target one command")
        with self.assertRaisesRegex(AssertionError, re.escape(expected)):
            fixture.run_case("", bundle_source=source.replace(original, replacement, 1))

    def test_helper_build_requires_full_lto(self):
        original = ('        --experimental-lto-mode full -Xswiftc -Osize \\\n'
                    '        "${HOST_BUILD_OPTIONS')
        self.reject_mutation(original, original.replace("--experimental-lto-mode full ", ""),
                             "full LTO is required")

    def test_helper_path_query_requires_full_lto(self):
        self.reject_mutation("--product claudio --experimental-lto-mode full -Xswiftc -Osize",
                             "--product claudio -Xswiftc -Osize", "full LTO is required")

    def test_helper_requires_size_optimization(self):
        original = ('        --experimental-lto-mode full -Xswiftc -Osize \\\n'
                    '        "${HOST_BUILD_OPTIONS')
        self.reject_mutation(original, original.replace("-Xswiftc -Osize", ""),
                             "-Osize is required")

    def test_helper_cannot_build_intel(self):
        self.reject_mutation('--arch arm64 --package-path "$repo_root/helper" --product claudio',
                             '--arch x86_64 --package-path "$repo_root/helper" --product claudio',
                             "arm64 is required")

    def test_login_item_keeps_existing_options(self):
        self.reject_mutation('--product ClaudioLoginItem \\\n',
                             '--product ClaudioLoginItem --experimental-lto-mode full \\\n',
                             "LoginItem options must remain unchanged")

    def test_release_workflow_compiler_arguments(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        commands = re.findall(r"^        run: (swift build -c release .*--product .*?)$",
                              workflow, re.MULTILINE)
        self.assertEqual(len(commands), 3)
        with tempfile.TemporaryDirectory(prefix="claudio-release-argv-") as directory:
            root = Path(directory)
            compiler = root / "swift"
            compiler.write_text(f"#!{sys.executable}\n" +
                                "import json,os,sys\n" +
                                "with open(os.environ['ARGV_LOG'], 'a') as log:\n" +
                                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n")
            compiler.chmod(0o755)
            log = root / "calls.jsonl"
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       ARGV_LOG=str(log))
            for command in commands:
                subprocess.run(["bash", "-euo", "pipefail", "-c", command],
                               cwd=root, env=env, check=True, capture_output=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual({a[a.index("--product") + 1] for a in calls},
                             {"claudio", "ClaudioGUI", "ClaudioLoginItem"})
            for args in calls:
                self.assert_options(args)
                self.assertEqual(args[args.index("--build-system") + 1], "native",
                                 "release staging paths require SwiftPM's native build system")


if __name__ == "__main__":
    unittest.main()
