#!/usr/bin/env python3
"""Isolated hook-contract fixtures; never bypass the helper's production gates."""
import ctypes
import json
import os
from pathlib import Path
import sys
import uuid


def authorize(root, host, lifetime_pid):
    config_file = root / "config.json"
    config = json.loads(config_file.read_text())
    config.setdefault("host_integrations", {"policy_version": 1, "surfaces": {}})["surfaces"][host] = {
        "enabled": True, "revision": str(uuid.uuid4()),
    }
    config_file.write_text(json.dumps(config))

    # The caller shell remains alive throughout the contract. A one-shot fixture process
    # cannot own this identity: production correctly rejects it as soon as it exits.
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
    if not (library.proc_pidinfo(lifetime_pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info)
            and info.pid == lifetime_pid and info.uid == os.getuid() and info.ruid == os.getuid()
            and info.status != 5):
        raise RuntimeError("fixture lifetime must have a verifiable live kernel identity")
    (root / "gui-run.json").write_text(json.dumps({
        "runID": str(uuid.uuid4()), "userID": os.getuid(),
        "process": {"pid": lifetime_pid, "startSeconds": info.start_seconds,
                    "startMicroseconds": info.start_microseconds},
    }))


def snapshot(root):
    # Include directories as well as bytes so even a rejected callback's empty state
    # directory is observable. The caller stores this snapshot outside the fixture root.
    print(json.dumps({str(path.relative_to(root)): (
        {"directory": True} if path.is_dir() else {"bytes": path.read_bytes().hex()}
    ) for path in sorted(root.rglob("*"))}, sort_keys=True))


def receipt_result(path):
    if not path.is_file():
        raise RuntimeError(f"receipt file missing: {path}")
    try:
        receipt = json.loads(path.read_text())
    except (ValueError, OSError) as error:
        raise RuntimeError(f"receipt unreadable or invalid JSON: {path}: {error}") from error
    if not isinstance(receipt, dict):
        raise RuntimeError(f"receipt JSON must be an object: {path}")
    result = receipt.get("playback_result")
    if not isinstance(result, str):
        raise RuntimeError(f"receipt has no string playback_result: {path}")
    print(result)


def main():
    command, path, *arguments = sys.argv[1:]
    if command == "authorize":
        authorize(Path(path), arguments[0], int(arguments[1]))
    elif command == "snapshot":
        snapshot(Path(path))
    elif command == "receipt-result":
        receipt_result(Path(path))
    else:
        raise ValueError(f"unknown fixture command: {command}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
