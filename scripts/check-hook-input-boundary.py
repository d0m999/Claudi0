#!/usr/bin/env python3
"""Check real bundle binaries keep the Codex transcript reader in the hook helper."""

from pathlib import Path
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-hook-input-boundary.py <app>")
    app = Path(sys.argv[1])
    marker = b"CodexApprovalRoutingResolver"
    gui = app / "Contents/MacOS/claudi0-app"
    helper = app / "Contents/Resources/bin/claudi0"
    if marker in gui.read_bytes():
        raise SystemExit("FAIL: Codex transcript reader is linked into the GUI")
    if marker not in helper.read_bytes():
        raise SystemExit("FAIL: Codex transcript reader is missing from the hook helper")
    print("PASS: Codex transcript reader is present only in the hook helper")


if __name__ == "__main__":
    main()
