#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
candidate = Path(sys.argv[1])
m = json.loads((candidate / 'PREVIEW_MANIFEST.json').read_text())
with tempfile.TemporaryDirectory(prefix='claudio-public-readback-') as temp:
    temp = Path(temp)
    for name in [m['dmg'], 'SHA256SUMS.txt', 'PREVIEW_MANIFEST.json']:
        destination = temp / name
        subprocess.run(['curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
            '--tlsv1.2', '--max-time', '180', '--max-filesize', '40000000', '--retry', '3',
            f"https://github.com/d0m999/Claudi0/releases/download/preview-v{m['version']}/{name}",
            '-o', str(destination)], check=True)
        assert destination.read_bytes() == (candidate / name).read_bytes(), 'public bytes differ'
    subprocess.run(['swift', str(ROOT / 'scripts/verify-sparkle-signature.swift'), 'archive',
        str(ROOT / 'config/sparkle-public-key.txt'), str(temp / m['dmg']),
        (candidate / 'SPARKLE_SIGNATURE.txt').read_text().strip()], check=True)
    subprocess.run(['python3', str(ROOT / 'scripts/verify-preview.py'), 'dmg', str(temp / m['dmg']), m['version']], check=True)
