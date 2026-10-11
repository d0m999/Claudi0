#!/usr/bin/env python3
"""Check cache byte compatibility across two executable harness builds in temporary roots."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

if not __debug__:
    raise SystemExit('cache compatibility verification requires assertions; do not use python -O or -OO')


def check(before, after):
    results = []
    for host in ('claude-code', 'codex'):
        for order in ((before, after), (after, before)):
            with tempfile.TemporaryDirectory(prefix='claudio-cache-compatibility-') as temporary:
                root = Path(temporary)
                command = 'claude' if host == 'claude-code' else 'codex'
                target = root / ('.local/share/claude/versions/2.1.282' if host == 'claude-code'
                                 else 'package/bin/codex')
                target.parent.mkdir(parents=True)
                target.write_text('#!/bin/sh\nexit 0\n')
                target.chmod(0o700)
                (root / 'bin').mkdir()
                (root / 'bin' / command).symlink_to(target)
                if host == 'codex':
                    package = root / 'package'
                    for name in ('codex-resources', 'codex-path'):
                        (package / name).mkdir()
                    (package / 'codex-package.json').write_text(json.dumps(dict(
                        layoutVersion=1, version='2.1.282', target='aarch64-apple-darwin',
                        variant='codex', entrypoint='bin/codex',
                        resourcesDir='codex-resources', pathDir='codex-path')))
                for index, binary in enumerate(order):
                    cache = root / 'cache' / (host + '.json')
                    previous = (cache.read_bytes(), cache.stat().st_mtime_ns) if index else None
                    command_args = [str(binary), '--host-version-cache-child', str(root), host]
                    if binary == after:
                        command_args.append('refresh' if index == 0 else 'resolve')
                    result = subprocess.run(command_args,
                                            capture_output=True, text=True, check=True)
                    assert not result.stderr, 'cache harness emitted stderr'
                    expected = int(index == 0)
                    actual = json.loads(result.stdout)
                    assert all(actual[key] == value for key, value in dict(resolved=True, probes=expected, signatures=expected).items())
                    if binary == after:
                        assert actual['refreshStatus'] == ('published' if index == 0 else 'not-requested')
                    if previous is not None:
                        assert (cache.read_bytes(), cache.stat().st_mtime_ns) == previous, 'cache hit rewrote the observation'
                results.append(dict(host=host, first=order[0].name, second=order[1].name,
                                    cold_probes=1, subsequent_probes=0))
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    args = parser.parse_args()
    print(json.dumps(check(args.before.resolve(), args.after.resolve()), indent=2))
