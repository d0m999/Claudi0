#!/usr/bin/env python3
"""Verify native exports against HTML and demonstrate rejection of a changed source."""
import argparse
import importlib.util
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "designs/pixel-motion"
sys.path.insert(0, str(SOURCE))
spec = importlib.util.spec_from_file_location("event_animation_export", SOURCE / "export_runtime.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--browser-executable", default="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
args = parser.parse_args()
exporter.export_runtime(args.browser_executable, check_only=True)
with tempfile.TemporaryDirectory(prefix="claudio-animation-stale-source-") as temporary:
    source = Path(temporary) / "Pixel Motion Prototype.html"
    source.write_bytes(exporter.HTML.read_bytes() + b"\n<!-- source update verification -->\n")
    exporter.HTML = source
    try:
        exporter.export_runtime(args.browser_executable, check_only=True)
    except AssertionError as error:
        assert "Stale runtime asset:" in str(error), str(error)
        print("PASS: changed HTML rejects the old exported provenance")
    else:
        raise AssertionError("Changed HTML incorrectly accepted stale native assets")
