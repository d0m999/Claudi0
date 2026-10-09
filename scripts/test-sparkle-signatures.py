#!/usr/bin/env python3
"""Use ephemeral keys only. Tampered archives/feeds and missing signatures must fail."""
import base64
import hashlib
import plistlib
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
stage = Path(sys.argv[1])
# Generate a test-only seed and public key with CryptoKit. Never use the release identity.
setup = stage / 'key.swift'
setup.write_text('import CryptoKit\nimport Foundation\nlet key = Curve25519.Signing.PrivateKey()\ntry key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))\ntry key.publicKey.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[2]))\n')
subprocess.run(['swift', str(setup), str(stage / 'seed'), str(stage / 'public')], check=True)
seed = (stage / 'seed').read_text()
sign = ROOT / 'gui/.build/artifacts/sparkle/Sparkle/bin/sign_update'
verify = ROOT / 'scripts/verify-sparkle-signature.swift'
result = subprocess.run(['swift', str(verify), 'key-match', str(stage / 'public'), 'stdin'], input=seed, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
assert result.returncode == 0
result = subprocess.run(['swift', str(verify), 'key-match', str(stage / 'public'), 'stdin'], input=base64.b64encode(bytes(32)).decode(), text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
assert result.returncode != 0
archive = stage / 'archive.dmg'; archive.write_bytes(b'fixture immutable archive')
signature = subprocess.check_output([str(sign), '--ed-key-file', '-', '-p', str(archive)], input=seed, text=True).strip()
def check(mode, path, expected, sig=None):
    result = subprocess.run(['swift', str(verify), mode, str(stage / 'public'), str(path), *([sig] if sig else [])], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert (result.returncode == 0) == expected
check('archive', archive, True, signature)
archive.write_bytes(b'tampered archive'); check('archive', archive, False, signature)
check('archive', archive, False, base64.b64encode(bytes(64)).decode())
feed = stage / 'appcast.xml'; feed.write_text('<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture</title></channel></rss>\n')
subprocess.run([str(sign), '--ed-key-file', '-', str(feed)], input=seed, text=True, check=True, stdout=subprocess.DEVNULL)
check('feed', feed, True)
original = feed.read_bytes(); feed.write_bytes(original.replace(b'Fixture', b'Tampered')); check('feed', feed, False)
feed.write_bytes(b'<rss/>'); check('feed', feed, False)
print('Sparkle EdDSA archive/feed verification and tampering regressions passed')

# Exercise the official generator with real ad-hoc DMGs, including preservation of the first item.
updates = stage / 'updates'; updates.mkdir()
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
for version in ['0.0.1', '0.0.2']:
    payload = stage / ('payload-' + version); app = payload / 'Fixture.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    shutil.copyfile('/usr/bin/true', app / 'Contents/MacOS/fixture')
    (app / 'Contents/MacOS/fixture').chmod(0o755)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='com.claudio.sparkle.fixture', CFBundleName='Fixture',
        CFBundlePackageType='APPL', CFBundleExecutable='fixture', CFBundleVersion=version,
        CFBundleShortVersionString=version, LSMinimumSystemVersion='12.0',
        SUPublicEDKey=(stage / 'public').read_text(), SURequireSignedFeed=True,
        SUVerifyUpdateBeforeExtraction=True)))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dmg = updates / ('fixture-' + version + '.dmg')
    subprocess.run(['hdiutil', 'create', '-srcfolder', str(payload), '-format', 'UDZO', str(dmg)], check=True, stdout=subprocess.DEVNULL)
    before = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (updates / ('fixture-' + version + '.html')).write_text('<p>Fixture notes</p>')
    subprocess.run([str(sign.parent / 'generate_appcast'), '--ed-key-file', '-', '--maximum-deltas', '0',
        '--embed-release-notes', '--download-url-prefix', 'https://example.com/preview/', str(updates)],
        input=seed, text=True, check=True, stdout=subprocess.DEVNULL)
    assert hashlib.sha256(dmg.read_bytes()).hexdigest() == before
    check('feed', updates / 'appcast.xml', True)
    feed_tree = ET.parse(updates / 'appcast.xml')
    versions = [item.findtext(ns + 'version') for item in feed_tree.findall('./channel/item')]
    assert version in versions
    if version == '0.0.2': assert set(versions) == {'0.0.1', '0.0.2'}
    for item in feed_tree.findall('./channel/item'):
        enclosure = item.find('enclosure')
        archive_name = enclosure.attrib['url'].rsplit('/', 1)[1]
        check('archive', updates / archive_name, True, enclosure.attrib[ns + 'edSignature'])
    assert not feed_tree.findall('.//' + ns + 'deltas')
print('Official generate_appcast: two ad-hoc DMGs, embedded notes, signed feed, preserved items and immutable bytes passed')
