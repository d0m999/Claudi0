#!/usr/bin/env python3
"""Consume a successful main-branch preview build, including GitHub's archive digest."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
REPO = 'd0m999/Claudi0'

def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/{path}'], text=True))

if __name__ == '__main__':
    run_id, commit, version, destination = sys.argv[1:]
    assert re.fullmatch(r'[0-9]+', run_id) and re.fullmatch(r'[0-9a-f]{40}', commit)
    assert re.fullmatch(r'0\.0\.[1-9][0-9]*', version)
    assert os.environ['GITHUB_REPOSITORY'] == REPO
    run = api(f'actions/runs/{run_id}')
    workflow = api('actions/workflows/preview.yml')
    assert run['workflow_id'] == workflow['id'] and run['path'] == '.github/workflows/preview.yml'
    assert run['head_sha'] == commit and run['head_branch'] == 'main'
    assert run['event'] == 'workflow_dispatch' and run['conclusion'] == 'success'
    assert run['head_repository']['full_name'] == REPO
    artifacts = api(f'actions/runs/{run_id}/artifacts')['artifacts']
    matches = [a for a in artifacts if a['name'] == f'preview-{version}-{commit}' and not a['expired']]
    assert len(matches) == 1
    artifact = matches[0]
    assert 0 < artifact['size_in_bytes'] <= 50000000
    assert re.fullmatch(r'sha256:[0-9a-f]{64}', artifact['digest'])
    archive = subprocess.check_output(['gh', 'api', f'repos/{REPO}/actions/artifacts/{artifact["id"]}/zip'])
    assert len(archive) <= 50000000
    assert 'sha256:' + hashlib.sha256(archive).hexdigest() == artifact['digest']
    output = Path(destination)
    output.mkdir(exist_ok=False)
    expected = {f'claudi0-{version}.dmg', 'PREVIEW_MANIFEST.json', 'SHA256SUMS.txt'}
    with zipfile.ZipFile(io.BytesIO(archive)) as z:
        assert set(z.namelist()) == expected and len(z.infolist()) == 3
        assert sum(i.file_size for i in z.infolist()) <= 41000000
        for entry in z.infolist():
            assert not entry.is_dir() and ((entry.external_attr >> 16) & 0o170000) != 0o120000
            (output / entry.filename).write_bytes(z.read(entry))
    spec = importlib.util.spec_from_file_location('preview_artifact', ROOT / 'scripts/preview-artifact.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    module.accepted(output, ROOT / 'docs/preview-acceptance.json', commit, version, run_id, artifact['id'], artifact['digest'])
