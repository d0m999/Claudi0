#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('artifact', ROOT / 'scripts/preview-artifact.py')
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
with tempfile.TemporaryDirectory() as temp:
    d = Path(temp); dmg = d / 'claudi0-0.0.1.dmg'; dmg.write_bytes(b'candidate fixture')
    sha = hashlib.sha256(dmg.read_bytes()).hexdigest(); commit = 'a' * 40
    m = dict(schema=1, channel='public-preview', source_commit=commit, version='0.0.1',
        dmg=dmg.name, sha256=sha, size=dmg.stat().st_size, sparkle_version='2.10.0',
        public_key=a.KEY.read_text().strip(), run_id='7', repository='d0m999/Claudi0',
        signing='ad-hoc', notarized=False, architectures=['arm64'])
    (d / 'PREVIEW_MANIFEST.json').write_text(json.dumps(m))
    (d / 'SHA256SUMS.txt').write_text(f'{sha}  {dmg.name}\n')
    a.validate(d, commit, '0.0.1', '7')
    record = dict(version='0.0.1', source_commit=commit, sha256=sha, run_id='7',
        artifact_id='8', artifact_digest='sha256:' + 'b' * 64, gates={g:'passed' for g in a.GATES})
    ledger = d / 'ledger.json'; ledger.write_text(json.dumps({'schema':1, 'public_launch':'passed', 'candidates':[record]}))
    a.accepted(d, ledger, commit, '0.0.1', '7', '8', record['artifact_digest'])
    def rejected(call):
        try: call()
        except (AssertionError, KeyError): return
        raise AssertionError('invalid artifact or acceptance was allowed')
    rejected(lambda: a.validate(d, 'c' * 40, '0.0.1', '7'))
    rejected(lambda: a.validate(d, commit, '0.0.2', '7'))
    rejected(lambda: a.validate(d, commit, '0.0.1', '9'))
    for architectures in ([], ['x86_64'], ['arm64', 'x86_64'], ['arm64', 'arm64']):
        m['architectures'] = architectures
        (d / 'PREVIEW_MANIFEST.json').write_text(json.dumps(m))
        rejected(lambda: a.validate(d, commit, '0.0.1', '7'))
    m['architectures'] = ['arm64']
    (d / 'PREVIEW_MANIFEST.json').write_text(json.dumps(m))
    feed = ET.Element('rss'); channel = ET.SubElement(feed, 'channel')
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, a.NS + 'version').text = '0.0.1'
    rejected(lambda: a.arm64_item(feed, '0.0.1'))
    hardware = ET.SubElement(item, a.NS + 'hardwareRequirements')
    for value in ('', 'x86_64', 'arm64,x86_64'):
        hardware.text = value
        rejected(lambda: a.arm64_item(feed, '0.0.1'))
    hardware.text = 'arm64'
    assert a.arm64_item(feed, '0.0.1') is item
    rejected(lambda: a.arm64_item(feed, '0.0.2'))
    duplicate = ET.SubElement(item, a.NS + 'hardwareRequirements'); duplicate.text = 'arm64'
    rejected(lambda: a.arm64_item(feed, '0.0.1'))
    item.remove(duplicate)
    for gate in a.GATES:
        record['gates'][gate] = 'not_evaluated'; ledger.write_text(json.dumps({'schema':1, 'public_launch':'passed', 'candidates':[record]}))
        rejected(lambda: a.accepted(d, ledger, commit, '0.0.1', '7', '8', record['artifact_digest']))
        record['gates'][gate] = 'passed'
    m['channel'] = 'local-inspection'
    (d / 'PREVIEW_MANIFEST.json').write_text(json.dumps(m))
    rejected(lambda: a.validate(d, commit, '0.0.1'))
    m['channel'] = 'public-preview'
    (d / 'PREVIEW_MANIFEST.json').write_text(json.dumps(m))
    ledger.write_text(json.dumps({'schema':1, 'public_launch':'not_evaluated', 'candidates':[record]}))
    rejected(lambda: a.accepted(d, ledger, commit, '0.0.1', '7', '8', record['artifact_digest']))
    dmg.write_bytes(b'changed raw bytes')
    rejected(lambda: a.validate(d, commit, '0.0.1'))
print('Preview artifact validator regressions passed (fixture only)')
