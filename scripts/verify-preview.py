#!/usr/bin/env python3
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def check_app(app, version):
    p = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert p['CFBundleIdentifier'] == 'com.claudio.app' and p['ClaudioPublicPreview'] is True
    assert p['CFBundleVersion'] == p['CFBundleShortVersionString'] == version
    assert p['LSMinimumSystemVersion'] == '12.0'
    assert p['SUPublicEDKey'] == (ROOT / 'config/sparkle-public-key.txt').read_text().strip()
    assert p['SUFeedURL'] == 'https://d0m999.github.io/Claudi0/preview/appcast.xml'
    assert p['SUVerifyUpdateBeforeExtraction'] is True and p['SURequireSignedFeed'] is True
    assert p['SUSignedFeedFailureExpirationInterval'] == 0 and p['SUAllowsAutomaticUpdates'] is False
    assert p['SUAutomaticallyUpdate'] is False and 'SUEnableAutomaticChecks' not in p
    login = app / 'Contents/Library/LoginItems/claudi0 LoginItem.app'
    lp = plistlib.loads((login / 'Contents/Info.plist').read_bytes())
    assert lp['CFBundleVersion'] == lp['CFBundleShortVersionString'] == version
    paths = [app / 'Contents/MacOS/claudi0-app', app / 'Contents/Resources/bin/claudi0', login / 'Contents/MacOS/claudi0-login-item']
    assert (app / 'Contents/Resources/bin/claudio').is_symlink()
    assert os.readlink(app / 'Contents/Resources/bin/claudio') == 'claudi0'
    for path in [app, login, *paths]:
        output = subprocess.check_output(['codesign', '-dv', '--verbose=4', str(path)], stderr=subprocess.STDOUT, text=True)
        assert 'Signature=adhoc' in output, 'preview must be ad-hoc'
    for path in paths:
        assert set(subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()) == {'arm64', 'x86_64'}
    assert subprocess.check_output([str(paths[1]), '--version'], text=True).strip() == version
    subprocess.run(['bash', 'scripts/verify-dev-bundle-signature.sh', str(app)], cwd=ROOT, check=True)
    subprocess.run(['python3', 'scripts/sparkle-bundle.py', 'verify', str(app)], cwd=ROOT, check=True)
    subprocess.run(['bash', 'scripts/check-release-size.sh', str(app)], cwd=ROOT, check=True)

if __name__ == '__main__':
    mode, path, version = sys.argv[1:]
    if mode == 'app': check_app(Path(path), version)
    elif mode == 'dmg':
        subprocess.run(['hdiutil', 'verify', path], check=True)
        with tempfile.TemporaryDirectory(prefix='claudio-preview-mount-') as mount:
            subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, path], check=True)
            try: check_app(Path(mount) / 'claudi0.app', version)
            finally: subprocess.run(['hdiutil', 'detach', mount], check=True)
    else: raise ValueError('unknown mode')
