#!/usr/bin/env python3
"""Run the public adapter migration suite against genuine Release/acceptance policies.

The ordinary helper harness contains Debug-only seams. A disposable package links only
ClaudioCore and this suite, with every configuration and receipt confined to temp roots.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--acceptance", action="store_true")
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="claudio-migration-package-") as temporary:
    package = Path(temporary)
    sources = package / "helper/Tests/ClaudioCoreTests"
    sources.mkdir(parents=True)
    original = repo / "helper/Tests/ClaudioCoreTests"
    for name in ("AdditionalHostMigrationSuite.swift", "Fixtures"):
        (sources / name).symlink_to(original / name)
    (package / "integrations").symlink_to(repo / "integrations")
    (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ClaudioMigrationChecks", platforms: [.macOS(.v12)],
    dependencies: [.package(path: HELPER_PATH)],
    targets: [.executableTarget(name: "migration-tests",
        dependencies: [.product(name: "ClaudioCore", package: "helper")],
        path: "helper/Tests/ClaudioCoreTests", exclude: ["Fixtures"])])
'''.replace("HELPER_PATH", json.dumps(str(repo / "helper"))))
    (sources / "main.swift").write_text('''import Foundation
var checks = 0
var failures = 0
@MainActor func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: " + message()) }
}
@MainActor func asyncSuite(_ name: String, _ body: @MainActor () async -> Void) async {
    print("• " + name)
    await body()
}
await runAdditionalHostMigrationSuites()
print("Migration: \\(checks) checks, \\(failures) failures")
exit(failures == 0 ? 0 : 1)
''')
    command = ["swift", "run", "--package-path", str(package),
               "--scratch-path", str(repo / "helper/.build/additional-host-migration"), "-c", "release"]
    if args.acceptance:
        command += ["-Xswiftc", "-DCLAUDIO_ADDITIONAL_HOST_ACCEPTANCE"]
    subprocess.run(command + ["migration-tests"], cwd=repo, check=True)
