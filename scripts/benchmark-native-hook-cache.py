#!/usr/bin/env python3
"""Isolated complete Core hooks with real native probes/signatures; never production replay."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess

from importlib.util import module_from_spec, spec_from_file_location

REPO = Path(__file__).resolve().parents[1]
SPEC = spec_from_file_location('hook_benchmark', REPO / 'scripts/benchmark-hooks.py')
BENCH = module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)
EVIDENCE_PATH = Path(__file__).with_name('hook-cache-evidence.py')
EVIDENCE_SPEC = spec_from_file_location('hook_cache_evidence', EVIDENCE_PATH)
EVIDENCE = module_from_spec(EVIDENCE_SPEC)
EVIDENCE_SPEC.loader.exec_module(EVIDENCE)
MODES = EVIDENCE.MODES
validate, summarize = EVIDENCE.validate, EVIDENCE.summarize
validate_refresh, summarize_refresh = EVIDENCE.validate_refresh, EVIDENCE.summarize_refresh


def identity(binary, selected_host='all'):
    return json.loads(subprocess.check_output(
        [str(binary), '--native-host-identities', '--host', selected_host], cwd=REPO, text=True))


def source_identity():
    source = BENCH.source_identity()
    source[str(Path(__file__).relative_to(REPO))] = BENCH.digest(Path(__file__))
    source[str(EVIDENCE_PATH.relative_to(REPO))] = BENCH.digest(EVIDENCE_PATH)
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--warmup', type=int, default=10)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--host', choices=['all', 'claude-code', 'codex'], default='all')
    parser.add_argument('--scenario', choices=['all', 'full-empty', 'full-steady', 'muted',
                                             'authorization-off', 'gui-exited', 'stale-installation'], default='all')
    parser.add_argument('--explicit-refresh', action='store_true')
    parser.add_argument('--sdk', type=Path, help='Explicit compatible local SDK for reproducible builds')
    args = parser.parse_args()
    if not __debug__:
        parser.error('measurement requires assertions; do not use python -O')
    if args.explicit_refresh and args.scenario != 'all':
        parser.error('explicit refresh always measures full-empty and full-steady')
    if args.samples < 1 or args.warmup < 0 or args.rounds < 1:
        parser.error('invalid sample configuration')
    out = args.output.resolve()
    if not out.is_relative_to(REPO / 'dist') or out.exists():
        parser.error('output must be a new directory inside repository dist/')
    out.mkdir(parents=True)
    source = source_identity()
    scratch = REPO / 'helper/.build/hook-cache-review'
    base = ['swift', 'build', '-c', 'release', '--package-path', 'helper', '--scratch-path',
            str(scratch), '--experimental-lto-mode', 'full', '-Xswiftc', '-Osize']
    if args.sdk:
        base += ['--build-system', 'native', '--sdk', str(args.sdk.resolve())]
    with (out / 'build.log').open('w') as log:
        for product in ['claudio-hook-benchmark', 'claudio']:
            subprocess.run(base + ['--product', product], cwd=REPO, stdout=log, stderr=log, check=True)
    if source_identity() != source:
        raise RuntimeError('source changed during build; discard binary evidence')
    products = Path(BENCH.output(base + ['--show-bin-path']))
    binary = out / 'claudio-hook-benchmark'
    shutil.copy2(products / binary.name, binary)
    helper = out / 'claudio'
    shutil.copy2(products / helper.name, helper)
    metadata = dict(
        evidence='core-isolated-native-version', cache_policy='E1-explicit-refresh', complete=False,
        started=datetime.now(timezone.utc).isoformat(), source_sha=BENCH.output(['git', 'rev-parse', 'HEAD']),
        dirty=bool(BENCH.output(['git', 'status', '--porcelain'])), source_files=source,
        binary_sha256=BENCH.digest(binary), helper_sha256=BENCH.digest(helper),
        build_parameters=base[1:], system=BENCH.output(['sw_vers', '-productVersion']),
        architecture=BENCH.output(['uname', '-m']), swift=BENCH.output(['swift', '--version']),
        hosts_before=identity(binary, args.host), samples=args.samples, warmup=args.warmup, rounds=args.rounds,
        order_seed='0xC1A0D10', order='alternating forward/reverse modes and observer on/off',
        cache_conditions=dict(cold='remove entire temporary version cache directory before each event; miss must not create or sign',
                              expired='advance both observation clocks by 601 seconds before each event',
                              hit='explicit strict refresh and verify before timing', failed='controlled runner launch failure',
                              system_file_and_security_caches='uncontrolled; preflight and warmup performed'),
        temporary_object_lifetime='per-fixture setup and per-event autorelease pool; hook inner pool drains inside timed span; validation/output pool drains outside',
        effects='temporary config/installations/receipts/activity; mock player and notice sender')
    meta = out / 'metadata.json'
    meta.write_text(json.dumps(metadata, indent=2) + '\n')
    command = [str(binary), '--native-hook-cache', '--samples', str(args.samples), '--warmup', str(args.warmup),
               '--rounds', str(args.rounds), '--host', args.host, '--scenario', args.scenario]
    if args.explicit_refresh:
        command[1] = '--native-version-refresh'
        metadata.update(evidence='native-explicit-refresh-and-isolated-hook',
                        refresh_boundary='revocation, real probe, strict signature, publication and autorelease cleanup; following hook timed separately')
    metadata['command_options'] = command[1:]
    meta.write_text(json.dumps(metadata, indent=2) + '\n')
    with (out / 'samples.jsonl').open('w') as raw, (out / 'stderr.txt').open('w') as errors:
        subprocess.run(command, cwd=REPO, stdout=raw, stderr=errors, check=True)
    if (out / 'stderr.txt').stat().st_size:
        raise AssertionError('benchmark emitted unexpected stderr')
    rows = [json.loads(line) for line in (out / 'samples.jsonl').read_text().splitlines()]
    (validate_refresh if args.explicit_refresh else validate)(rows, args)
    metadata['hosts_after'] = identity(binary, args.host)
    after_source = source_identity()
    if after_source != source or metadata['hosts_before'] != metadata['hosts_after']:
        raise RuntimeError('source or native host changed during measurement')
    BENCH.verify_binary_identity(binary, helper, metadata)
    (out / 'summary.json').write_text(json.dumps((summarize_refresh if args.explicit_refresh else summarize)(rows), indent=2) + '\n')
    metadata.update(complete=True, sample_count=len(rows), completed=datetime.now(timezone.utc).isoformat())
    meta.write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(dict(complete=True, samples=len(rows), evidence=metadata['evidence'])))


if __name__ == '__main__':
    main()
