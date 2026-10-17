#!/usr/bin/env python3
"""Bound one native harness process group and sample it before timeout cleanup."""

import argparse
import os
import signal
import subprocess
import sys
import time


def run(command, timeout, sample_tool):
    started = time.monotonic()
    process = subprocess.Popen(command, start_new_session=True)

    def stop_group():
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # The harness may exit before an uncooperative compiler/probe child does.
        # Finish the owned session's process group even after its leader is reaped.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

    def interrupted(signum, _frame):
        stop_group()
        raise SystemExit(128 + signum)

    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(f"::error::GUI harness exceeded {timeout:g}s; sampling pid {process.pid}", flush=True)
            if process.poll() is None:
                try:
                    subprocess.run([sample_tool, str(process.pid), "5", "10"],
                                   timeout=15, check=False)
                except (OSError, subprocess.TimeoutExpired) as error:
                    print(f"Native sample unavailable: {error}", flush=True)
            stop_group()
            return 124
        return status if status >= 0 else 128 - status
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        print(f"GUI harness elapsed: {time.monotonic() - started:.3f}s", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--sample-tool", default="/usr/bin/sample")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not 0 < args.timeout <= 3600:
        parser.error("provide a command and a timeout between 0 and 3600 seconds")
    return run(command, args.timeout, args.sample_tool)


if __name__ == "__main__":
    sys.exit(main())
