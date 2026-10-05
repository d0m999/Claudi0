#!/usr/bin/env python3
"""Run CI's actual whitespace gate against isolated full, shallow and rewritten histories."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap


workflow = Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"
step = workflow.read_text().split("      - name: Check patch whitespace\n", 1)[1]
step = step.split("\n      - name:", 1)[0]
command = textwrap.dedent(step.split("        run: |\n", 1)[1])


def git(directory, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(directory), *arguments], text=True, stderr=subprocess.DEVNULL
    ).strip()


with tempfile.TemporaryDirectory(prefix="claudio-ci-whitespace-") as directory:
    root = Path(directory)
    source = root / "source"
    git(root, "init", "-q", "-b", "main", str(source))
    git(source, "config", "user.name", "CI Fixture")
    git(source, "config", "user.email", "ci-fixture@example.invalid")
    document = source / "fixture.txt"
    commits = []
    for contents in ["base\n", "base\nhead\n", "base\nhead\ntrailing  \n"]:
        document.write_text(contents)
        git(source, "add", "fixture.txt")
        git(source, "commit", "-q", "-m", "fixture")
        commits.append(git(source, "rev-parse", "HEAD"))
    base, head, dirty = commits
    rewritten = git(
        source, "commit-tree", git(source, "rev-parse", head + "^{tree}"),
        "-m", "rewritten root with the same files",
    )
    git(source, "branch", "rewrite", rewritten)
    origin = root / "origin.git"
    git(root, "clone", "-q", "--bare", str(source), str(origin))
    git(origin, "update-ref", "-d", "refs/heads/rewrite")
    # GitHub permits fetching an exact pre-rewrite SHA; model that server contract locally.
    git(origin, "config", "uploadpack.allowAnySHA1InWant", "true")

    cases = [
        ("ordinary push", base, head, False, True, "push"),
        ("shallow missing parent", base, head, True, True, "push"),
        ("rewritten missing baseline", head, rewritten, True, True, "push"),
        ("whitespace after fetched baseline", head, dirty, True, False, "push"),
        ("unavailable baseline fails closed", "f" * 40, rewritten, True, False, "push"),
        ("initial push", "0" * 40, base, True, True, "push"),
        ("initial push whitespace", "0" * 40, dirty, True, False, "push"),
        ("missing range fails closed", "", head, True, False, "push"),
        ("pull request range", base, head, True, True, "pull_request"),
    ]
    for index, (name, before, after, shallow, passed, event) in enumerate(cases):
        git(origin, "update-ref", "refs/heads/main", after)
        checkout = root / f"checkout-{index}"
        options = ["--depth=1"] if shallow else []
        git(root, "clone", "-q", *options, origin.as_uri(), str(checkout))
        environment = os.environ.copy()
        environment.update(
            CLAUDIO_CI_EVENT_NAME=event,
            CLAUDIO_CI_PUSH_BEFORE=before,
            CLAUDIO_CI_PUSH_HEAD=after,
            CLAUDIO_CI_PR_BASE=before if event == "pull_request" else "",
            CLAUDIO_CI_PR_HEAD=after if event == "pull_request" else "",
        )
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", command], cwd=checkout,
            env=environment, text=True, capture_output=True,
        )
        if (result.returncode == 0) != passed:
            raise SystemExit(f"FAIL {name}:\n{result.stdout}{result.stderr}")
        if passed and shallow and before and before != "0" * 40:
            if git(checkout, "rev-parse", before + "^{commit}") != before:
                raise SystemExit(f"FAIL {name}: exact baseline was not fetched")
        print(f"PASS: {name}")
