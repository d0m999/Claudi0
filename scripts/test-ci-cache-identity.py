#!/usr/bin/env python3
"""Execute CI's real cache fingerprint expressions with controlled toolchain outputs."""

import os
from pathlib import Path
import subprocess
import tempfile


workflow = Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"
assignments = [
    line.strip()
    for line in workflow.read_text().splitlines()
    if line.strip().startswith('FINGERPRINT="')
]
if len(assignments) != 2:
    raise SystemExit("Expected one cache fingerprint for each Swift CI lane")

with tempfile.TemporaryDirectory(prefix="claudio-ci-cache-identity-") as directory:
    root = Path(directory)
    for command, variable in [
        ("swift", "MOCK_SWIFT_VERSION"),
        ("xcodebuild", "MOCK_XCODE_VERSION"),
    ]:
        executable = root / command
        executable.write_text('#!/bin/bash\nprintf "%s\\n" "$' + variable + '"\n')
        executable.chmod(0o755)

    def fingerprint(assignment, workspace, swift="Swift 6.1.2", xcode="Xcode 16.4"):
        environment = os.environ.copy()
        environment.update(
            PATH=str(root) + os.pathsep + environment["PATH"],
            GITHUB_WORKSPACE=str(workspace),
            MOCK_SWIFT_VERSION=swift,
            MOCK_XCODE_VERSION=xcode,
        )
        return subprocess.check_output(
            ["bash", "-euo", "pipefail", "-c", assignment + '\nprintf "%s" "$FINGERPRINT"'],
            env=environment,
            text=True,
        )

    for lane, assignment in zip(["helper", "gui"], assignments):
        old_workspace = root / "Claudio" / "Claudio"
        renamed_workspace = root / "Claudi0" / "Claudi0"
        original = fingerprint(assignment, old_workspace)
        checks = {
            "stable inputs retain the cache identity":
                original == fingerprint(assignment, old_workspace),
            "repository rename invalidates absolute-path build artifacts":
                original != fingerprint(assignment, renamed_workspace),
            "Swift version invalidates compiled artifacts":
                original != fingerprint(assignment, old_workspace, swift="Swift 6.4"),
            "Xcode version invalidates SDK artifacts":
                original != fingerprint(assignment, old_workspace, xcode="Xcode 26.5"),
        }
        for description, passed in checks.items():
            if not passed:
                raise SystemExit(f"FAIL {lane}: {description}")

print("PASS: both Swift CI lanes preserve stable cache identities and invalidate path/toolchain changes")
