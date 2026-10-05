#!/usr/bin/env python3
"""Real helper subprocesses, isolated configuration, stub host versions and silent audio."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--debug-bin", type=Path)
parser.add_argument("--release-bin", type=Path)
args = parser.parse_args()
checks = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        raise AssertionError(message)


def build(configuration):
    command = ["swift", "build", "--package-path", "helper", "-c", configuration, "--product", "claudio"]
    subprocess.run(command, cwd=REPO, check=True, stdout=subprocess.DEVNULL)
    directory = subprocess.check_output(command + ["--show-bin-path"], cwd=REPO, text=True).strip()
    return Path(directory) / "claudio"


debug = args.debug_bin or build("debug")
release = args.release_bin or build("release")


def invoke(binary, arguments, env, data=b""):
    return subprocess.run([str(binary), *arguments], input=data, capture_output=True, env=env, timeout=12)


def hook(binary, host, native, installation, payload, env):
    data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
    result = invoke(binary, ["hook", host, native, "--installation-id", installation], env, data)
    check(result.returncode == 0 and result.stdout == b"" and result.stderr == b"",
          f"{host}/{native}: exit 0 and zero stdout/stderr")


def payload(host, native, request="r"):
    value = {"hook_event_name": native, "session_id": "fixture-session", "cwd": "/fixture/project"}
    if host == "opencode":
        value.update(bridge_schema=1, session_kind="main")
        if native == "UserTurnStarted":
            value.update(turn_id=request, message_id="m", origin_kind="user", executing=True)
        elif native in ("ResponseCompleted", "ResponseFailed", "SubagentCompleted"):
            value.update(turn_id=request, message_id="m", terminal="failure" if native == "ResponseFailed" else "success")
            if native == "ResponseFailed":
                value["error_kind"] = "APIError"
            if native == "SubagentCompleted":
                value.update(session_kind="child", parent_session_id="fixture-parent")
        else:
            value["request_id"] = request
    else:
        value["client_type"] = "kimi_code_cli"
        if native == "TurnStarted":
            value.update(turn_id=1, origin_kind="user", prompt="PRIVATE_BODY")
        elif native == "SubagentStop":
            value.update(agent_name="fixture child", response="PRIVATE_BODY")
        else:
            value.update(tool_call_id=request, tool_name="AskUserQuestion" if native == "PreToolUse" else "Shell",
                         tool_input={"command": "PRIVATE_BODY"})
    return value


def bytes_on_disk(root):
    return {str(file.relative_to(root)): file.read_bytes() for file in root.rglob("*") if file.is_file()}


def register_fixture_lifetime(root):
    # This test process stands in for the GUI lifetime only inside its temporary root.
    # Capture the kernel identity rather than bypassing the production event gate.
    class ProcBSDInfo(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint32) for name in (
            "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved"
        )] + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
              ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32), ("jobc", ctypes.c_uint32),
              ("tty_device", ctypes.c_uint32), ("tty_pgid", ctypes.c_uint32),
              ("nice", ctypes.c_int32), ("start_seconds", ctypes.c_uint64),
              ("start_microseconds", ctypes.c_uint64)]

    info = ProcBSDInfo()
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    check(library.proc_pidinfo(os.getpid(), 3, 0, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info)
          and info.pid == os.getpid() and info.uid == os.getuid() and info.status != 5,
          "fixture process has a verifiable live kernel identity")
    (root / "gui-run.json").write_text(json.dumps({
        "runID": str(uuid.uuid4()), "userID": os.getuid(),
        "process": {"pid": os.getpid(), "startSeconds": info.start_seconds,
                    "startMicroseconds": info.start_microseconds},
    }))


with tempfile.TemporaryDirectory(prefix="claudio-additional-cli-") as temporary:
    base = Path(temporary)
    tools = base / "tools"
    tools.mkdir()
    for command, version in (("opencode", "1.18.34"), ("kimi", "2.1.1")):
        file = tools / command
        file.write_text(f"#!/bin/sh\nprintf '{version}\\n'\n")
        file.chmod(0o700)
    for host, events in (
        ("opencode", ["UserTurnStarted", "ResponseCompleted", "ResponseFailed", "PermissionRequested", "QuestionAsked", "SubagentCompleted"]),
        ("kimi-code", ["TurnStarted", "PermissionRequest", "PreToolUse", "SubagentStop"]),
    ):
        home = base / host / "home"
        root = home / ".claudio"
        root.mkdir(parents=True)
        shutil.copytree(REPO / "packs/minimal-chime", root / "packs/minimal-chime")
        (root / "config.json").write_text('{"selected_pack":"minimal-chime","master_volume":0,"events":{}}')
        config_root = base / host / "configuration"
        config_root.mkdir()
        plugin = config_root / "plugins/claudio.js"
        file = plugin if host == "opencode" else config_root / "config.toml"
        protected = config_root / ("opencode.jsonc" if host == "opencode" else "config.toml")
        original = b'// Vibe Island and unknown config\n{"plugin":["vibe-island"],"future":{"keep":true},}\n' if host == "opencode" else (
            b'# Vibe Island and unknown config\r\n[[hooks]]\r\nevent = "Stop"\r\ncommand = "vibe-island hook stop"\r\n[future]\r\nkeep = true')
        protected.write_bytes(original)
        legacy = home / ".kimi/config.toml"
        legacy.parent.mkdir()
        legacy.write_bytes(b"# old Kimi bytes\n")
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
                   CLAUDIO_TEST_HOME=str(home), CLAUDIO_TEST_ROOT=str(root),
                   OPENCODE_CONFIG_DIR=str(config_root), KIMI_CODE_HOME=str(config_root))
        marker = root / "integrations/installations" / (host + ".json")

        def connect():
            result = invoke(debug, ["integrations", "connect", host], env)
            check(result.returncode == 0, f"{host}: isolated connect: {result.stdout.decode()}")
            return json.loads(marker.read_text())["installation_id"]

        installation = connect()
        installed = file.read_bytes()
        check(connect() == installation and file.read_bytes() == installed, f"{host}: idempotent bytes and generation")
        prepared_status = invoke(debug, ["integrations", "status"], env)
        check(prepared_status.returncode == 0 and "接入已准备好" in prepared_status.stdout.decode()
              and "/hooks" not in prepared_status.stdout.decode(),
              "prepared without receipts never infers an authorization requirement")
        if host == "opencode":
            check(installed.endswith((REPO / "integrations/opencode/claudio.js").read_bytes()), "compiled template equals shipped JS verbatim")
            check(protected.read_bytes() == original, "JSONC bytes preserved")
        else:
            check(b"timeout = 2" in installed and b'event = "StopFailure"' not in installed,
                  "only supported hooks with timeout 2")
            check(file.with_suffix(".toml.claudio.bak").read_bytes() == original, "one-shot backup exact bytes")
        inactive = bytes_on_disk(root)
        hook(debug, host, events[0], installation, payload(host, events[0]), env)
        check(bytes_on_disk(root) == inactive, "GUI lifetime absent: callbacks have zero state writes")
        register_fixture_lifetime(root)
        for native in events:
            hook(debug, host, native, installation, payload(host, native), env)
            receipt = root / "integrations/receipts" / host / (native + ".json")
            check(receipt.is_file(), f"{host}/{native}: current receipt")
        observed_status = invoke(debug, ["integrations", "status"], env)
        check(observed_status.returncode == 0 and "已收到事件；支持" in observed_status.stdout.decode()
              and "/5 已就绪" not in observed_status.stdout.decode(),
              "received evidence and declared supported reminders stay separate")
        question = "QuestionAsked" if host == "opencode" else "PreToolUse"
        hook(debug, host, question, installation, payload(host, question), env)
        receipt = root / "integrations/receipts" / host / (question + ".json")
        check(json.loads(receipt.read_text())["playback_result"] == "debounced", "duplicate request is consumed once")
        before = bytes_on_disk(root)
        for data in (b"", b"[]", b"{", b" " * 65537,
                     json.dumps(dict(payload(host, events[0]), session_id=False)).encode()):
            hook(debug, host, events[0], installation, data, env)
        hook(debug, host, events[0], str(uuid.uuid4()), payload(host, events[0]), env)
        if host == "kimi-code":
            for native in ("Stop", "StopFailure"):
                hook(debug, host, native, installation, payload(host, native), env)
        alternative = dict(env)
        alternative["OPENCODE_CONFIG_DIR" if host == "opencode" else "KIMI_CODE_HOME"] = str(base / "other-root")
        hook(debug, host, events[0], installation, payload(host, events[0]), alternative)
        check(bytes_on_disk(root) == before, "invalid, stale and wrong-root callbacks have zero state writes")
        for path, data in before.items():
            check(b"PRIVATE_BODY" not in data and b"fixture-session" not in data,
                  "ordinary Claudio state never stores native body or session identity: " + path)

        # Remove one exact owned binding, retaining its canonical template/block grammar.
        if host == "opencode":
            lines = installed.split(b"\n", 2)
            config = json.loads(lines[1][len(b"const installation = "):-1])
            config["enabled_events"].pop()
            lines[1] = b"const installation = " + json.dumps(config, sort_keys=True, separators=(",", ":")).encode() + b";"
            file.write_bytes(b"\n".join(lines))
        else:
            start = installed.rfind(b"[[hooks]]")
            end = installed.index(b"# <<< Claudio Kimi Code hooks v1", start)
            file.write_bytes(installed[:start] + installed[end:])
        replacement = connect()
        check(replacement != installation, "repair missing binding rotates installation")
        repaired = bytes_on_disk(root)
        hook(debug, host, question, installation, payload(host, question, "late"), env)
        check(bytes_on_disk(root) == repaired, "late old callback cannot activate repaired installation")
        check(invoke(debug, ["integrations", "disconnect", host], env).returncode == 0, "disconnect succeeds")
        check(not marker.exists(), "disconnect revokes current installation")
        check(not plugin.exists() if host == "opencode" else file.read_bytes() == original,
              "disconnect removes only owned bytes")
        check(protected.read_bytes() == original and legacy.read_bytes() == b"# old Kimi bytes\n",
              "third-party and old Kimi bytes preserved")
        hook(release, host, events[0], replacement, payload(host, events[0]), env)
        check(invoke(release, ["integrations", "connect", host], env).returncode != 0,
              "ordinary Release rejects unverified new-host connect")
    status = invoke(release, ["integrations", "status", "--json"], env)
    check(status.returncode == 0 and [item["host"] for item in json.loads(status.stdout)] ==
          ["claude-code", "codex", "workbuddy"], "ordinary Release has no unverified visible hosts")
print(f"Additional host CLI: {checks} checks passed; fixtures only, real-host acceptance not performed")
