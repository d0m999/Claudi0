#!/usr/bin/env python3
"""Freeze and verify the code-owned identity of a non-distribution Bailian bundle."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def capture(root):
    paths = set()
    for directory in ["gui/Sources", "helper/Sources", "gui/AppResources"]:
        paths.update(path for path in (root / directory).rglob("*") if path.is_file())
    for name in ["gui/Package.swift", "helper/Package.swift", "gui/Package.resolved",
                 "helper/Package.resolved", "scripts/dev-bundle.sh",
                 "scripts/bailian-acceptance-source.py"]:
        path = root / name
        if path.exists():
            paths.add(path)
    contents = {}
    revisions = {}
    for path in sorted(paths):
        name = str(path.relative_to(root))
        before = path.stat()
        contents[name] = path.read_bytes()
        after = path.stat()
        revision = [after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns]
        if revision != [before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns]:
            raise OSError("source changed during capture")
        revisions[name] = revision
    files = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
    asset_source = contents["gui/Sources/ClaudioGUICore/BailianAssetContract.swift"].decode()
    host = re.search(r'static let hostname = "([a-z0-9.-]+)"', asset_source).group(1)
    mime = re.search(r'acceptedMediaTypes: \["([a-z/.-]+)"\]', asset_source).group(1)
    payload = {
        "schema": 1,
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "source_files": files,
        "source_digest": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(),
        "bailian_asset_policy": {
            "origin": "https://" + host + ":443",
            "accepted_media_types": [mime],
            "url_normalization": "exact-host-http-default-or-80-to-https-443-preserve-path-query",
            "anonymous_get": True,
            "redirects": 0,
            "final_url_matches_normalized_request": True,
        },
        "distribution_eligible": False,
    }
    return payload, revisions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["freeze", "verify"])
    parser.add_argument("root", type=Path)
    parser.add_argument("identity", type=Path)
    args = parser.parse_args()
    revision_path = args.identity.with_name(args.identity.name + ".state")
    try:
        current, revisions = capture(args.root.resolve())
        if args.action == "freeze":
            args.identity.write_text(json.dumps(current, sort_keys=True, indent=2) + "\n")
            # Private build watch state catches edits restored to the original bytes. It is
            # discarded after the build; only content hashes enter the app's identity file.
            revision_path.write_text(json.dumps(revisions, sort_keys=True) + "\n")
        else:
            frozen = json.loads(args.identity.read_text())
            frozen_revisions = json.loads(revision_path.read_text())
            if current != frozen or revisions != frozen_revisions:
                changed = sorted(name for name in current["source_files"].keys() | frozen["source_files"].keys()
                                 if current["source_files"].get(name) != frozen["source_files"].get(name)
                                 or revisions.get(name) != frozen_revisions.get(name))
                print("Bailian acceptance source changed during build: " + ", ".join(changed or ["HEAD"]),
                      file=sys.stderr)
                return 1
    except (OSError, KeyError, AttributeError, ValueError, subprocess.CalledProcessError):
        print("Bailian acceptance source changed or could not be captured", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
