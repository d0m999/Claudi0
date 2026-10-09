#!/usr/bin/env python3
"""Validate candidate provenance/acceptance and prepare a signed feed from immutable DMG bytes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / 'gui/.build/artifacts/sparkle/Sparkle/bin'
KEY = ROOT / 'config/sparkle-public-key.txt'
VERIFY = ROOT / 'scripts/verify-sparkle-signature.swift'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
GATES = ['automation', 'browser_download_quarantine', 'two_version_https_upgrade', 'native_ui_keyboard_voiceover',
         'real_host_receipts', 'arm64', 'x86_64', 'macos12_login', 'macos13plus_login', 'system_open_anyway',
         'failure_recovery', 'local_storage_provider_admission']

def load(path, limit=100000):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size <= limit
    return json.loads(path.read_text())

def validate(directory, commit, version, run_id=None):
    m = load(directory / 'PREVIEW_MANIFEST.json')
    assert m['schema'] == 1 and m['channel'] == 'public-preview'
    assert m['source_commit'] == commit and re.fullmatch(r'[0-9a-f]{40}', commit)
    assert m['version'] == version and re.fullmatch(r'0\.0\.[1-9][0-9]*', version)
    assert m['dmg'] == f'claudi0-{version}.dmg'
    assert m['public_key'] == KEY.read_text().strip() and m['sparkle_version'] == '2.10.0'
    assert m['signing'] == 'ad-hoc' and m['notarized'] is False
    assert m['architectures'] == ['arm64', 'x86_64']
    if run_id: assert str(m['run_id']) == str(run_id) and m['repository'] == 'd0m999/Claudi0'
    dmg = directory / m['dmg']
    assert dmg.is_file() and not dmg.is_symlink() and 0 < dmg.stat().st_size <= 40000000
    assert m['size'] == dmg.stat().st_size
    assert hashlib.sha256(dmg.read_bytes()).hexdigest() == m['sha256']
    assert (directory / 'SHA256SUMS.txt').read_text() == f"{m['sha256']}  {m['dmg']}\n"
    return m

def accepted(directory, ledger, commit, version, run_id, artifact_id, artifact_digest):
    m = validate(directory, commit, version, run_id)
    acceptance = load(ledger)
    assert acceptance['schema'] == 1 and acceptance['public_launch'] == 'passed', 'public launch not accepted'
    records = acceptance['candidates']
    matches = [r for r in records if r.get('version') == version and r.get('source_commit') == commit]
    assert len(matches) == 1, 'exactly one accepted candidate required'
    record = matches[0]
    assert record['sha256'] == m['sha256'] and str(record['run_id']) == str(run_id)
    assert str(record['artifact_id']) == str(artifact_id) and record['artifact_digest'] == artifact_digest
    assert all(record['gates'].get(g) == 'passed' for g in GATES), 'public launch remains blocked by acceptance'
    return m

def verify(mode, path, signature=None, secret=None):
    command = ['swift', str(VERIFY), mode, str(KEY), str(path)]
    if signature: command.append(signature)
    subprocess.run(command, input=secret, text=True, check=True)

def prepare(directory, output, previous):
    secret = os.environ.get('SPARKLE_PRIVATE_KEY')
    assert secret, 'SPARKLE_PRIVATE_KEY missing'
    verify('key-match', 'stdin', secret=secret)
    m = load(directory / 'PREVIEW_MANIFEST.json')
    validate(directory, m['source_commit'], m['version'])
    assert not output.exists(), 'refuse an existing feed staging directory'
    output.mkdir(parents=True)
    feed = output / 'preview/appcast.xml'
    feed.parent.mkdir()
    if previous:
        verify('feed', previous)
        shutil.copyfile(previous, feed)
        tree = ET.parse(feed)
        for item in tree.findall('./channel/item'):
            v = item.find(NS + 'version')
            assert v is not None
            assert tuple(map(int, v.text.split('.'))) < tuple(map(int, m['version'].split('.'))), 'preview must increase monotonically'
    else: assert m['version'] == '0.0.1', 'bootstrap without feed is first-version only'
    with tempfile.TemporaryDirectory(prefix='claudio-appcast-') as staging:
        staging = Path(staging)
        shutil.copyfile(directory / m['dmg'], staging / m['dmg'])
        (staging / f"claudi0-{m['version']}.html").write_text(
            f"<h2>claudi0 {m['version']} — 公开预览 / Public Preview</h2><p>Ad-hoc signed, not notarized. "
            'System approval may be required. <a href="https://d0m999.github.io/Claudi0/preview/">Installation and recovery</a>.</p>')
        if previous: shutil.copyfile(previous, staging / 'appcast.xml')
        subprocess.run([str(TOOLS / 'generate_appcast'), '--ed-key-file', '-', '--maximum-deltas', '0',
            '--maximum-versions', '0', '--embed-release-notes', '--download-url-prefix',
            f"https://github.com/d0m999/Claudi0/releases/download/preview-v{m['version']}/", '--link',
            'https://d0m999.github.io/Claudi0/preview/', '-o', str(staging / 'appcast.xml'), str(staging)],
            input=secret, text=True, check=True)
        shutil.copyfile(staging / 'appcast.xml', feed)
    verify('feed', feed)
    tree = ET.parse(feed)
    matches = [item for item in tree.findall('./channel/item') if item.findtext(NS + 'version') == m['version']]
    assert len(matches) == 1
    enclosure = matches[0].find('enclosure')
    assert enclosure is not None and enclosure.attrib['length'] == str(m['size'])
    assert enclosure.attrib['url'] == f"https://github.com/d0m999/Claudi0/releases/download/preview-v{m['version']}/{m['dmg']}"
    signature = enclosure.attrib[NS + 'edSignature']
    verify('archive', directory / m['dmg'], signature)
    assert not tree.findall('.//' + NS + 'deltas'), 'no delta updates'
    (output / 'preview/index.html').write_text((ROOT / 'docs/preview-download.html').read_text())
    (output / 'index.html').write_text('<a href="preview/">claudi0 Public Preview</a>\n')
    (directory / 'SPARKLE_SIGNATURE.txt').write_text(signature + '\n')
    (directory / 'RELEASE_NOTES.md').write_text((ROOT / 'docs/preview-install.txt').read_text())

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('mode', choices=['validate', 'accepted', 'prepare'])
    p.add_argument('directory', type=Path)
    p.add_argument('--commit'); p.add_argument('--version'); p.add_argument('--run-id')
    p.add_argument('--artifact-id'); p.add_argument('--artifact-digest'); p.add_argument('--ledger', type=Path)
    p.add_argument('--output', type=Path); p.add_argument('--previous', type=Path)
    a = p.parse_args()
    if a.mode == 'validate': validate(a.directory, a.commit, a.version, a.run_id)
    elif a.mode == 'accepted': accepted(a.directory, a.ledger, a.commit, a.version, a.run_id, a.artifact_id, a.artifact_digest)
    else: prepare(a.directory, a.output, a.previous)
