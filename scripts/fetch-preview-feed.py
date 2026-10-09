#!/usr/bin/env python3
"""Fetch the fixed feed with system TLS trust; only first-version HTTP 404 may bootstrap."""
from pathlib import Path
import subprocess
import sys
import tempfile

path, version = sys.argv[1:]
url = 'https://d0m999.github.io/Claudi0/preview/appcast.xml'
with tempfile.TemporaryDirectory(prefix='claudio-previous-feed-') as temporary:
    downloaded = Path(temporary) / 'feed.xml'
    status = subprocess.check_output([
        'curl', '--silent', '--show-error', '--proto', '=https', '--tlsv1.2',
        '--max-time', '30', '--max-filesize', '2000000', '--write-out', '%{http_code}',
        '-o', str(downloaded), url], text=True).strip()
    if status == '404' and version == '0.0.1':
        assert not Path(path).exists(), 'unexpected prior staging file'
    else:
        assert status == '200', f'feed HTTP status {status}; preserve previous deployment'
        data = downloaded.read_bytes()
        assert len(data) <= 2000000
        Path(path).write_bytes(data)
