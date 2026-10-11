"""Temporary-root GUI lifetime fixture shared by CLI contract tests."""
import ctypes
import json
import os
import uuid

def check(condition, message):
    if not condition:
        raise AssertionError(message)

def register_fixture_lifetime(root, pid=None):
    pid = os.getpid() if pid is None else pid
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
    check(library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info)
          and info.pid == pid and info.uid == os.getuid() and info.status != 5,
          "fixture process has a verifiable live kernel identity")
    (root / "gui-run.json").write_text(json.dumps({
        "runID": str(uuid.uuid4()), "userID": os.getuid(),
        "process": {"pid": pid, "startSeconds": info.start_seconds,
                    "startMicroseconds": info.start_microseconds},
    }))
