#!/usr/bin/env python3
"""Execute CI's shared cache fingerprint with controlled toolchain outputs."""

import os
from pathlib import Path
import re
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
workflow = root / ".github/workflows/ci.yml"
action = root / ".github/actions/swift-toolchain-fingerprint/action.yml"
workflow_text = workflow.read_text()
action_text = action.read_text()
uses = workflow_text.count("./.github/actions/swift-toolchain-fingerprint")
if uses != 4:
    raise SystemExit(f"Expected four Swift lanes to share the fingerprint action, found {uses}")
if any(line.strip().startswith('FINGERPRINT="') for line in workflow_text.splitlines()):
    raise SystemExit("ci.yml must not inline another cache fingerprint expression")
assignments = [
    line.strip()
    for line in action_text.splitlines()
    if line.strip().startswith('FINGERPRINT="')
]
if len(assignments) != 1:
    raise SystemExit("Expected one shared cache fingerprint expression")
patterns = re.findall(r"version-pattern: '([^']*)'", workflow_text)
if patterns != [
    r"Apple\ Swift\ version\ 6\.",
    r"Swift\ version\ 6\.4\.1([[:space:]]|$)",
    r"Swift\ version\ 6\.4\.1([[:space:]]|$)",
    r"Swift\ version\ 6\.4\.1([[:space:]]|$)",
]:
    raise SystemExit(f"Swift version gates drifted from the four-lane contract: {patterns}")

def version_matches(pattern, version):
    completed = subprocess.run(
        [
            "bash", "-c",
            '[[ "$2" =~ $1 ]]',
            "bash", pattern, version,
        ],
        check=False,
    )
    return completed.returncode == 0

helper_pattern, gui_pattern = patterns[0], patterns[1]
version_checks = {
    "helper accepts Apple Swift 6":
        version_matches(helper_pattern, "Apple Swift version 6.2 (swiftlang-6.2.0)"),
    "helper rejects the GUI Swift.org version string":
        not version_matches(helper_pattern, "Swift version 6.4.1 (swift-6.4.1-RELEASE)"),
    "GUI accepts the pinned 6.4.1 release":
        version_matches(gui_pattern, "Swift version 6.4.1 (swift-6.4.1-RELEASE)"),
    "GUI rejects a longer 6.4.10 version":
        not version_matches(gui_pattern, "Swift version 6.4.10 (swift-6.4.10-RELEASE)"),
}
for description, passed in version_checks.items():
    if not passed:
        raise SystemExit(f"FAIL version gate: {description}")

with tempfile.TemporaryDirectory(prefix="claudio-ci-cache-identity-") as directory:
    temp = Path(directory)
    for command, variable in [
        ("swift", "MOCK_SWIFT_VERSION"),
        ("xcodebuild", "MOCK_XCODE_VERSION"),
    ]:
        executable = temp / command
        executable.write_text('#!/bin/bash\nprintf "%s\\n" "$' + variable + '"\n')
        executable.chmod(0o755)

    def fingerprint(assignment, workspace, swift="Swift 6.1.2", xcode="Xcode 16.4"):
        environment = os.environ.copy()
        environment.update(
            PATH=str(temp) + os.pathsep + environment["PATH"],
            GITHUB_WORKSPACE=str(workspace),
            MOCK_SWIFT_VERSION=swift,
            MOCK_XCODE_VERSION=xcode,
        )
        return subprocess.check_output(
            ["bash", "-euo", "pipefail", "-c", assignment + '\nprintf "%s" "$FINGERPRINT"'],
            env=environment,
            text=True,
        )

    assignment = assignments[0]
    old_workspace = temp / "Claudio" / "Claudio"
    renamed_workspace = temp / "Claudi0" / "Claudi0"
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
            raise SystemExit(f"FAIL shared fingerprint: {description}")

print("PASS: four Swift CI lanes share one cache fingerprint and keep their version gates")
