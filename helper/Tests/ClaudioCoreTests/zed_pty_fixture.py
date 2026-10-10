"""Synthetic PTYs only. No real terminal, UI automation, host config or user CLI data."""
import errno
import fcntl
import hashlib
import json
import os
import pty
import select
import signal
import socket
import struct
import subprocess
import sys
import termios
import tempfile
import time
import uuid

RUNNER = sys.argv[1]
CLI = len(sys.argv) > 2 and sys.argv[2] == "--cli"
PAYLOAD = "中文".encode() + b"\x00\x1b[200~literal\x1b[I\x1b[201~end"
EXIT_BACKPRESSURE_CHILD = """import os, tty
tty.setraw(0)
os.write(1, b'EXITREADY')
os.read(0, 1)
os.write(1, b'x' * 1024)
"""


def attributes_equal(left, right):
    # Darwin sets PENDIN when restoring ICANON, including without this launcher.
    # It is a transient kernel rescan flag, not a changed user terminal setting.
    left, right = list(left), list(right)
    left[3] &= ~termios.PENDIN
    right[3] &= ~termios.PENDIN
    return left == right


def flags_equal(left, right):
    # Compare the mutable F_SETFL flags. Darwin adds a read-only flag on exec,
    # reproduced by the ordinary CLI --help without entering the PTY launcher.
    mask = os.O_NONBLOCK | os.O_APPEND | os.O_ASYNC
    return left & mask == right & mask


class Terminal:
    def __init__(self, child, original_mode=2, respond=True, descriptor=None, stderr_tty=True, foreground=True):
        os.setsid()
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
        self.saved = termios.tcgetattr(self.slave)
        self.saved_flags = fcntl.fcntl(self.slave, fcntl.F_GETFL)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 23, 79, 0, 0))
        self.original_mode, self.respond = original_mode, respond
        self.data = b""
        self.query_seen = False

        def child_session():
            os.setpgid(0, 0)
            if foreground:
                os.tcsetpgrp(0, os.getpgrp())

        prefix = [RUNNER, "zed-session", "--"] if CLI else [RUNNER, "--zed-pty-launch"]
        environment = dict(os.environ)
        if descriptor:
            environment["CLAUDIO_TEST_PTY_DESCRIPTOR"] = descriptor
            environment["CLAUDIO_TEST_ROOT"] = os.path.dirname(descriptor)
        self.process = subprocess.Popen(
            prefix + ["/usr/bin/python3", "-c", child], env=environment,
            stdin=self.slave, stdout=self.slave, stderr=self.slave if stderr_tty else subprocess.DEVNULL,
            preexec_fn=child_session, close_fds=True)

    def pump(self, timeout=0.03):
        if select.select([self.master], [], [], timeout)[0]:
            try:
                self.data += os.read(self.master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
            if not self.query_seen and b"\x1b[?1004$p" in self.data:
                self.query_seen = True
                if self.respond:
                    os.write(self.master, ("\x1b[?1004;%d$y" % self.original_mode).encode())

    def until(self, token, seconds=3):
        end = time.monotonic() + seconds
        while token not in self.data and time.monotonic() < end:
            self.pump()
        assert token in self.data, "expected fixture marker missing"

    def finish(self, code=0):
        end = time.monotonic() + 4
        while self.process.poll() is None and time.monotonic() < end:
            self.pump()
        assert self.process.poll() == code, "wrong child exit status: expected %d, actual %s" % (code, self.process.poll())
        for _ in range(3):
            self.pump(0.01)
        assert attributes_equal(termios.tcgetattr(self.slave), self.saved), "outer terminal settings not restored"
        assert flags_equal(fcntl.fcntl(self.slave, fcntl.F_GETFL), self.saved_flags), "outer descriptor flags not restored"
        if self.respond and self.query_seen:
            restored = b"\x1b[?1004h" if self.original_mode in (1, 3) else b"\x1b[?1004l"
            assert self.data.endswith(restored), "original focus mode not restored"

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        os.close(self.master)
        os.close(self.slave)


def run_case(name, body):
    try:
        body()
        print(json.dumps({"case": name, "passed": True}), flush=True)
    except Exception as error:
        print(json.dumps({"case": name, "passed": False, "reason": str(error)}), flush=True)
        return False
    return True


def byte_case():
    child = """import os, tty
tty.setraw(0)
assert os.isatty(0) and os.isatty(1)
assert os.get_terminal_size(0).columns == 79
os.write(1, b'READY')
assert os.read(0, 1) == b'\\x1b'
os.write(1, b'ESCOK')
data=b''
while len(data)<%d: data+=os.read(0, %d-len(data))
assert data == bytes.fromhex('%s')
os.write(1, b'BYTESOK')
""" % (len(PAYLOAD), len(PAYLOAD), PAYLOAD.hex())
    terminal = Terminal(child)
    try:
        terminal.until(b"READY")
        os.write(terminal.master, b"\x1b")
        terminal.until(b"ESCOK")
        os.write(terminal.master, b"\x1b[I\x1b[O" + PAYLOAD)
        terminal.until(b"BYTESOK")
        terminal.finish()
    finally:
        terminal.close()


def focus_case():
    child = """import os, tty
tty.setraw(0)
os.write(1, b'\\x1b[?1004l\\x1b[?1004$p')
reply=b''
while not reply.endswith(b'$y'): reply+=os.read(0, 1)
assert reply == b'\\x1b[?1004;2$y'
os.write(1, b'\\x1b[?1004hFOCUSREADY')
assert os.read(0, 3) == b'\\x1b[I'
os.write(1, b'FOCUSOK')
"""
    terminal = Terminal(child, original_mode=1)
    try:
        terminal.until(b"FOCUSREADY")
        os.write(terminal.master, b"\x1b[I")
        terminal.until(b"FOCUSOK")
        terminal.finish()
    finally:
        terminal.close()


def size_case():
    child = """import os, signal, time
def resized(*_):
    if os.get_terminal_size(0).columns == 101: os.write(1,b'SIZEOK'); raise SystemExit(0)
signal.signal(signal.SIGWINCH, resized)
os.write(1,b'SIZEREADY')
while True: time.sleep(0.02)
"""
    terminal = Terminal(child)
    try:
        terminal.until(b"SIZEREADY")
        fcntl.ioctl(terminal.master, termios.TIOCSWINSZ, struct.pack("HHHH", 37, 101, 0, 0))
        terminal.until(b"SIZEOK")
        terminal.finish()
    finally:
        terminal.close()


def large_case():
    terminal = Terminal("import os\nos.write(1,b'LARGEREADY')\nfor _ in range(128): os.write(1,b'x'*8192)\nos.write(1,b'LARGEEND')")
    try:
        terminal.until(b"LARGEREADY")
        time.sleep(0.15)  # Exercise bounded backpressure without draining the outer PTY.
        terminal.until(b"LARGEEND", 5)
        terminal.finish()
        data = terminal.data.split(b"LARGEREADY", 1)[1].split(b"LARGEEND", 1)[0]
        assert len(data) == 1048576 and hashlib.sha256(data).digest() == hashlib.sha256(b"x" * 1048576).digest(), "output bytes changed"
    finally:
        terminal.close()


def exit_case():
    terminal = Terminal("raise SystemExit(37)")
    try:
        terminal.finish(37)
    finally:
        terminal.close()


def exit_backpressure_case(original_mode=2):
    terminal = Terminal(EXIT_BACKPRESSURE_CHILD, original_mode=original_mode)
    try:
        terminal.until(b"EXITREADY")
        os.write(terminal.master, b"q")
        # Leave the terminal unread until the child has exited and the launcher's
        # final write meets the still-full outer PTY output queue.
        time.sleep(0.15)
        terminal.finish()
        payload = terminal.data.split(b"EXITREADY", 1)[1]
        restored = b"\x1b[?1004h" if original_mode == 1 else b"\x1b[?1004l"
        assert payload == b"x" * 1024 + restored, "exit lost output or focus-mode restore bytes"
    finally:
        terminal.close()


def delayed_restore_case():
    terminal = Terminal(EXIT_BACKPRESSURE_CHILD)
    try:
        terminal.until(b"EXITREADY")
        os.write(terminal.master, b"q")
        # Even sustained backpressure or an interrupted wait cannot hand the shell
        # a terminal whose focus mode is still owned by the launcher.
        time.sleep(0.1)
        os.kill(terminal.process.pid, signal.SIGWINCH)
        time.sleep(1.1)
        assert terminal.process.poll() is None, "launcher handed back the terminal before restoration completed"
        terminal.finish()
        assert terminal.data.split(b"EXITREADY", 1)[1] == b"x" * 1024 + b"\x1b[?1004l", "delayed restore lost bytes"
    finally:
        terminal.close()


def signal_case():
    terminal = Terminal("import os,signal,time\nsignal.signal(signal.SIGINT,signal.SIG_DFL)\nos.write(1,b'SIGNALREADY')\ntime.sleep(10)")
    try:
        terminal.until(b"SIGNALREADY")
        os.write(terminal.master, b"\x03")
        terminal.finish(130)
    finally:
        terminal.close()


def stopped_case():
    terminal = Terminal("import os,signal\nos.write(1,b'STOPREADY')\nos.kill(os.getpid(),signal.SIGTSTP)\nos.write(1,b'RESUMED')")
    try:
        end = time.monotonic() + 3
        stopped = False
        while time.monotonic() < end:
            pid, status = os.waitpid(terminal.process.pid, os.WNOHANG | os.WUNTRACED)
            if pid and os.WIFSTOPPED(status):
                stopped = True
                break
            terminal.pump()
        assert stopped, "launcher did not suspend with its child"
        assert attributes_equal(termios.tcgetattr(terminal.slave), terminal.saved), "job suspension left the shell raw"
        assert flags_equal(fcntl.fcntl(terminal.slave, fcntl.F_GETFL), terminal.saved_flags), "job suspension left the shell nonblocking"
        # A background continuation must stop again without taking the shell's terminal.
        os.tcsetpgrp(terminal.slave, os.getpgrp())
        os.kill(terminal.process.pid, signal.SIGCONT)
        end = time.monotonic() + 3
        stopped_again = False
        while time.monotonic() < end:
            pid, status = os.waitpid(terminal.process.pid, os.WNOHANG | os.WUNTRACED)
            if pid and os.WIFSTOPPED(status):
                stopped_again = True
                break
            terminal.pump()
        assert stopped_again, "background continuation did not remain suspended"
        assert attributes_equal(termios.tcgetattr(terminal.slave), terminal.saved), "background continuation took the shell terminal mode"
        assert flags_equal(fcntl.fcntl(terminal.slave, fcntl.F_GETFL), terminal.saved_flags), "background continuation took the shell descriptor flags"
        os.tcsetpgrp(terminal.slave, terminal.process.pid)
        os.kill(terminal.process.pid, signal.SIGCONT)
        terminal.until(b"RESUMED")
        terminal.finish()
    finally:
        terminal.close()


def termination_case():
    terminal = Terminal("import os,time\nos.write(1,b'TERMREADY')\ntime.sleep(10)")
    try:
        terminal.until(b"TERMREADY")
        os.kill(terminal.process.pid, signal.SIGTERM)
        terminal.finish(143)
    finally:
        terminal.close()


def unsupported_case():
    terminal = Terminal("import os\nos.write(1,b'MUSTNOTRUN')", respond=False)
    try:
        terminal.finish(64 if CLI else 65)
        assert b"MUSTNOTRUN" not in terminal.data, "child started without supported focus protocol"
    finally:
        terminal.close()


def channel_case():
    with tempfile.TemporaryDirectory(prefix="cl-pty-", dir="/private/tmp") as directory:
        path = os.path.join(directory, "nav.sock")
        descriptor = os.path.join(directory, "zed-navigation.json")
        epoch = str(uuid.uuid4()).upper()
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        os.chmod(path, 0o600)
        listener.listen(1)
        listener.settimeout(2)
        with open(descriptor, "w") as output:
            json.dump({"schema": 1, "epoch": epoch, "socketPath": path, "socketInode": os.stat(path).st_ino}, output)
        os.chmod(descriptor, 0o600)
        terminal = Terminal("import os,tty\ntty.setraw(0)\nos.write(1,b'CHANNELREADY')\nassert os.read(0,1)==b'q'\nos.write(1,b'CHANNELDONE')", descriptor=descriptor)
        connection = None
        try:
            terminal.until(b"CHANNELREADY")
            connection, _ = listener.accept()
            connection.settimeout(2)
            reader = connection.makefile("rb")
            registration = json.loads(reader.readline())
            assert registration["type"] == "register" and registration["schema"] == 1
            assert registration["session"]["process"]["pid"] == terminal.process.pid
            assert registration["session"]["innerTTY"] != registration["session"]["outerTTY"]
            initial = json.loads(reader.readline())
            assert initial["type"] == "state" and initial["sequence"] == 0
            os.write(terminal.master, b"\x1b[I")
            focus = json.loads(reader.readline())
            assert focus["focused"] and focus["sequence"] == 1
            requests = [str(uuid.uuid4()).upper() for _ in range(2)]
            for request in requests:
                frame = {"schema": 1, "type": "snapshot", "epoch": epoch, "instance": registration["instance"], "request": request}
                connection.sendall(json.dumps(frame).encode() + b"\n")
            for request in requests:
                barrier = json.loads(reader.readline())
                assert barrier["request"] == request and barrier["sequence"] == 1 and barrier["focused"] and barrier["caughtUp"]
                assert set(barrier) <= {"schema", "type", "epoch", "instance", "request", "sequence", "focused", "observedUptime", "caughtUp"}, "PTY bytes leaked into side channel"
            reader.close()
            connection.close()
            connection = None
            listener.close()
            os.unlink(descriptor)
            os.write(terminal.master, b"q")
            terminal.until(b"CHANNELDONE")
            terminal.finish()
        finally:
            terminal.close()
            if connection:
                connection.close()
            listener.close()


def redirected_case():
    terminal = Terminal("import os\nos.write(1,b'MUSTNOTRUN')", stderr_tty=False)
    try:
        terminal.finish(64 if CLI else 65)
        assert not terminal.query_seen and b"MUSTNOTRUN" not in terminal.data, "mixed stdio was not rejected before terminal changes"
    finally:
        terminal.close()


def background_case():
    terminal = Terminal("import os\nos.write(1,b'MUSTNOTRUN')", foreground=False)
    try:
        terminal.finish(64 if CLI else 65)
        assert not terminal.query_seen and b"MUSTNOTRUN" not in terminal.data, "background launch changed the active terminal"
    finally:
        terminal.close()


checks = [
    ("UTF-8, paste, NUL and bare Escape", byte_case),
    ("child focus mode and original mode restore", focus_case),
    ("SIGWINCH and size propagation", size_case),
    ("1 MiB output with backpressure", large_case),
    ("child exit code", exit_case),
    ("exit restores focus mode under output backpressure", exit_backpressure_case),
    ("exit preserves originally enabled focus mode under backpressure", lambda: exit_backpressure_case(1)),
    ("delayed and interrupted output wait completes before terminal handoff", delayed_restore_case),
    ("Ctrl-C reaches child", signal_case),
    ("job suspension and resume", stopped_case),
    ("launcher SIGTERM reaches command", termination_case),
    ("missing protocol rejects before spawn", unsupported_case),
    ("metadata barriers and GUI disconnect", channel_case),
    ("mixed stdio rejects before changing terminal", redirected_case),
    ("background launch rejects before changing terminal", background_case),
]
passed = []
for name, body in checks:
    child = os.fork()
    if child == 0:
        os._exit(0 if run_case(name, body) else 1)
    _, status = os.waitpid(child, 0)
    passed.append(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0)
sys.exit(0 if all(passed) else 1)
