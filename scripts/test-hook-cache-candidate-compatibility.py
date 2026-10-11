#!/usr/bin/env python3
"""Check historical E1 and narrowed candidate cache contracts in temporary roots.

Both inputs must be reviewed executable harnesses supporting the explicit five-argument
--host-version-cache-child ROOT HOST ACTION interface. This is not the legacy four-argument
auto-fill verifier, a production helper runner, a host CLI runner or a performance benchmark.
The unchanged test-hook-cache-compatibility.py remains the historical dual-host verifier.
"""
if not __debug__:
    raise SystemExit('cache candidate compatibility requires normal Python mode; do not use python -O or -OO')

import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile


class CompatibilityError(ValueError):
    """An observed child result or cache effect violated the declared contract."""


def require(condition, message):
    if not condition:
        raise CompatibilityError(message)


def prepare_fixture(root, host):
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


def cache_snapshot(root):
    directory = root / 'cache'
    if not directory.exists() and not directory.is_symlink():
        return None
    info = directory.lstat()
    require(stat.S_ISDIR(info.st_mode), 'cache root is not a plain directory')
    files = {}
    for path in directory.iterdir():
        entry = path.lstat()
        require(stat.S_ISREG(entry.st_mode), 'cache contains a non-regular entry')
        require(entry.st_size <= 16_384, 'cache entry exceeds the contract bound')
        files[path.name] = (path.read_bytes(), entry.st_mtime_ns, stat.S_IMODE(entry.st_mode))
    return stat.S_IMODE(info.st_mode), info.st_mtime_ns, files


def step(binary, role, root, host, action, probes, signatures, status, cache_effect):
    before = cache_snapshot(root)
    try:
        result = subprocess.run(
            [str(binary), '--host-version-cache-child', str(root), host, action],
            cwd=root, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        raise CompatibilityError('test child could not complete') from None
    require(result.returncode == 0, 'test child returned a nonzero status')
    require(not result.stderr, 'test child emitted stderr')
    try:
        actual = json.loads(result.stdout)
    except (ValueError, TypeError):
        raise CompatibilityError('test child did not return one JSON object') from None
    require(isinstance(actual, dict), 'test child result is not an object')
    require(actual.get('resolved') is True, 'version was not resolved')
    for key, expected in (('probes', probes), ('signatures', signatures)):
        require(type(actual.get(key)) is int and actual[key] == expected,
                'unexpected ' + key + ' count')
    require(actual.get('refreshStatus') == status, 'unexpected refresh status')
    after = cache_snapshot(root)
    if cache_effect == 'published':
        require(after is not None and host + '.json' in after[2],
                'published observation is missing')
    elif cache_effect == 'absent':
        require(before is None and after is None, 'ineligible candidate created cache state')
    else:
        require(before is not None and after == before,
                'reuse or fallback changed cache bytes, mtime, mode or entries')
    return dict(role=role, action=action, resolved=True, probes=probes, signatures=signatures,
                refreshStatus=status, cache_effect=cache_effect)


def check(historical, candidate):
    historical, candidate = Path(historical).resolve(), Path(candidate).resolve()
    require(all(path.is_file() and os.access(path, os.X_OK) for path in (historical, candidate)),
            'both inputs must be executable test harnesses')
    require(not historical.samefile(candidate), 'historical and candidate roles must be distinct')
    results = []
    for first, second in ((('historical', historical), ('candidate', candidate)),
                          (('candidate', candidate), ('historical', historical))):
        with tempfile.TemporaryDirectory(prefix='claudio-candidate-compatibility-') as temporary:
            root = Path(temporary)
            prepare_fixture(root, 'claude-code')
            steps = [step(first[1], first[0], root, 'claude-code', 'refresh',
                          1, 1, 'published', 'published'),
                     step(second[1], second[0], root, 'claude-code', 'resolve',
                          0, 0, 'not-requested', 'preserved')]
            results.append(dict(host='claude-code', scenario=first[0] + '-first', steps=steps))
    with tempfile.TemporaryDirectory(prefix='claudio-candidate-compatibility-') as temporary:
        root = Path(temporary)
        prepare_fixture(root, 'codex')
        steps = [step(historical, 'historical', root, 'codex', 'refresh',
                      1, 1, 'published', 'published'),
                 step(candidate, 'candidate', root, 'codex', 'resolve',
                      1, 0, 'not-requested', 'preserved'),
                 step(candidate, 'candidate', root, 'codex', 'refresh',
                      1, 0, 'ineligible', 'preserved')]
        for dependency in ('codex-resources', 'codex-path', 'codex-package.json'):
            path = root / 'package' / dependency
            if dependency == 'codex-package.json':
                path.write_text('{}')
            else:
                (path / 'changed-member').write_text('changed dependency')
            steps.append(step(candidate, 'candidate', root, 'codex', 'resolve',
                              1, 0, 'not-requested', 'preserved'))
        results.append(dict(host='codex', scenario='historical-first', steps=steps))
    with tempfile.TemporaryDirectory(prefix='claudio-candidate-compatibility-') as temporary:
        root = Path(temporary)
        prepare_fixture(root, 'codex')
        steps = [step(candidate, 'candidate', root, 'codex', 'refresh',
                      1, 0, 'ineligible', 'absent'),
                 step(candidate, 'candidate', root, 'codex', 'resolve',
                      1, 0, 'not-requested', 'absent'),
                 step(historical, 'historical', root, 'codex', 'refresh',
                      1, 1, 'published', 'published'),
                 step(candidate, 'candidate', root, 'codex', 'resolve',
                      1, 0, 'not-requested', 'preserved')]
        results.append(dict(host='codex', scenario='candidate-first', steps=steps))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('historical', type=Path)
    parser.add_argument('candidate', type=Path)
    args = parser.parse_args()
    try:
        rows = check(args.historical, args.candidate)
    except (CompatibilityError, OSError):
        parser.exit(1, 'cache candidate compatibility failed: child result or cache effect violated the contract\n')
    print(json.dumps(rows, indent=2))


if __name__ == '__main__':
    main()
