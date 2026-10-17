#!/usr/bin/env python3
"""Exercise native CI watchdog exit propagation, sampling and child cleanup."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


script = Path(__file__).resolve().with_name("run-ci-gui-harness.py")
real_python = Path(sys.executable).resolve()
real_ps = Path(shutil.which("ps")).resolve()


def identity(path):
    status = path.lstat()
    assert stat.S_ISREG(status.st_mode)
    return hashlib.sha256(path.read_bytes()).hexdigest(), stat.S_IMODE(status.st_mode)


before = {path: identity(path) for path in [real_python, real_ps]}
with tempfile.TemporaryDirectory(prefix="claudio-ci-watchdog-") as directory:
    root = Path(directory)
    sample = root / "sample"
    sample.write_text(
        "#!" + str(real_python) + "\n"
        "import json, os, pathlib, sys\n"
        "pathlib.Path(os.environ['FIXTURE_SAMPLE_LOG']).write_text(json.dumps(sys.argv[1:]))\n"
    )
    sample.chmod(0o700)
    environment = dict(os.environ, FIXTURE_SAMPLE_LOG=str(root / "sample.json"),
                       FIXTURE_CHILD_PID=str(root / "child.pid"))

    def execute(code, timeout=5):
        return subprocess.run(
            [sys.executable, str(script), "--timeout", str(timeout),
             "--sample-tool", str(sample), "--", sys.executable, "-c", code],
            capture_output=True, text=True, env=environment, timeout=15)

    success = execute("print('completed native fixture')")
    assert success.returncode == 0 and "completed native fixture" in success.stdout
    failure = execute("import sys; sys.exit(7)")
    assert failure.returncode == 7
    assert not (root / "sample.json").exists(), "Completed commands must not be sampled"
    child = (
        "import os,pathlib,signal,time; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "pathlib.Path(os.environ['FIXTURE_CHILD_PID']).write_text(str(os.getpid())); "
        "time.sleep(90)"
    )
    parent = (
        "import subprocess,sys,time; "
        f"subprocess.Popen([sys.executable, '-c', {child!r}], "
        "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
        "time.sleep(90)"
    )
    try:
        timeout = execute(parent, timeout=2)
        assert timeout.returncode == 124 and "::error::GUI harness exceeded" in timeout.stdout
        sampled = json.loads((root / "sample.json").read_text())
        assert len(sampled) == 3 and sampled[0].isdigit() and sampled[1:] == ["5", "10"]
        child_pid = int((root / "child.pid").read_text())
        state = subprocess.run([str(real_ps), "-p", str(child_pid), "-o", "state="],
                               capture_output=True, text=True).stdout.strip()
        assert not state or state.startswith("Z"), "Timeout must kill children that ignore SIGTERM"
    finally:
        if (root / "child.pid").exists():
            try:
                os.kill(int((root / "child.pid").read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
assert {path: identity(path) for path in before} == before, "Installed tool hash or mode changed"
print("PASS: native CI watchdog preserves exits, samples timeouts and terminates child groups")
