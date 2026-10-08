#!/usr/bin/env python3
"""Private, bounded Audio 3.1 resource discovery; never print a key or full asset URL."""
import argparse
import json
from pathlib import Path
import re
import time
import ssl
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OBSERVED_HOST = 'dashscope-result-bj.oss-cn-beijing.aliyuncs.com'


def download_url(literal):
    if len(literal.encode()) > 4096 or any(ord(c) < 33 or ord(c) > 126 or c == "\\" for c in literal):
        raise ValueError('Invalid asset URL')
    parts = urllib.parse.urlsplit(literal)
    if parts.hostname != OBSERVED_HOST or parts.username is not None or parts.password is not None or '#' in literal:
        raise ValueError('Invalid asset authority')
    if parts.scheme == 'http' and parts.port in (None, 80):
        prefixes = [f'http://{OBSERVED_HOST}/', f'http://{OBSERVED_HOST}:80/']
        prefix = next((v for v in prefixes if literal.startswith(v)), None)
        if prefix is None:
            raise ValueError('Invalid HTTP spelling')
        normalized = f'https://{OBSERVED_HOST}/' + literal[len(prefix):]
    elif parts.scheme == 'https' and parts.port in (None, 443):
        normalized = literal
    else:
        raise ValueError('Invalid asset scheme or port')
    if not parts.path or parts.path == '/' or '//' in parts.path:
        raise ValueError('Invalid asset path')
    if any(urllib.parse.unquote(v).lower() in ('.', '..') for v in parts.path.split('/')):
        raise ValueError('Invalid asset path segment')
    return normalized


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--discover', action='store_true', help='Use at most two Next generation requests')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    values = {}
    for line in (root / '.env').read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            name, value = line.split('=', 1)
            values[name.strip()] = value.strip()
    key, workspace = values.get('DASHSCOPE_API_KEY', ''), values.get('SFM_WORKSPACE_ID', '')
    if not key or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', workspace):
        raise SystemExit('Missing or invalid private configuration')
    endpoint = f'https://{workspace}.cn-beijing.maas.aliyuncs.com'
    context = ssl.create_default_context()
    try:
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=context))
    def call(path, body=None):
        request = urllib.request.Request(endpoint + path, data=body,
            headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json', 'Accept': 'application/json'})
        with opener.open(request, timeout=180 if body else 30) as response:
            if response.geturl() != request.full_url or response.headers.get_content_type() != 'application/json':
                raise ValueError('API response contract failed')
            raw = response.read(512 * 1024 + 1)
            if len(raw) > 512 * 1024:
                raise ValueError('API response too large')
            return json.loads(raw)
    for model in ['qwen-audio-3.1-tts-flash', 'qwen-audio-3.1-tts-next']:
        query = urllib.parse.urlencode({'model': model, 'authorization_scope': 'AUTHORIZED', 'action': 'INFERENCE', 'page_no': 1, 'page_size': 200})
        data = call('/api/v1/models/permissions?' + query)
        entries = data.get('output', {}).get('permissions', [])
        granted = data.get('success') is True and not data.get('code') and any(
            e.get('model') == model and e.get('permissions', {}).get('inference') is True for e in entries)
        print(json.dumps({'model': model, 'inference_permission': granted}))
        if not granted:
            raise SystemExit('Permission check failed; no generation sent')
    if not args.discover:
        return
    private = root / 'dist' / 'bailian-acceptance'
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    counter = private / 'request-budget.json'
    state = json.loads(counter.read_text()) if counter.exists() else {'discovery': 0, 'generation_requests': 0}
    for prompt in ['自然的小猫轻轻叫一声，主体清晰，无背景音乐，总时长不超过 3 秒。',
                   '车站提示短旋律，主体清晰，总时长不超过 3 秒，不要人声。']:
        if state['discovery'] >= 2 or state['generation_requests'] >= 20:
            break
        # Count before sending, including uncertain failures. Never retry POST.
        state['discovery'] += 1
        state['generation_requests'] += 1
        counter.write_text(json.dumps(state)); counter.chmod(0o600)
        started = time.monotonic()
        data = call('/api/v1/services/audio/tts/SpeechSynthesizer', json.dumps({
            'model': 'qwen-audio-3.1-tts-next', 'input': {'text_prompt': prompt, 'format': 'wav', 'sample_rate': 24000, 'channels': 1}}).encode())
        output = data.get('output', {})
        if output.get('finish_reason') != 'stop':
            raise ValueError('Next response did not stop')
        url = output.get('audio', {}).get('url', '')
        parts = urllib.parse.urlsplit(url)
        host = parts.hostname or ''
        observation = {'request_number': state['generation_requests'], 'scheme': parts.scheme,
                       'host': host, 'port': parts.port or (443 if parts.scheme == 'https' else 80),
                       'generation_seconds': round(time.monotonic() - started, 2)}
        # Upgrade only the exact observed bucket; preserve signed path/query byte for byte.
        try:
            target = download_url(url)
        except ValueError:
            observation['contract'] = 'rejected_url'
            print(json.dumps(observation)); raise SystemExit('Discovery failed URL contract; stop acceptance')
        observation['download_origin'] = f'https://{OBSERVED_HOST}:443'
        observation['https_upgrade'] = target != url
        request = urllib.request.Request(target, headers={'Accept': 'audio/wav'})
        with opener.open(request, timeout=max(1, 180 - (time.monotonic() - started))) as response:
            observation.update({'mime': response.headers.get_content_type(), 'status': response.status,
                                'anonymous_get': True, 'redirects': 0, 'final_url_unchanged': response.geturl() == target})
            audio = response.read(5 * 1024 * 1024 + 1)
            observation['bytes'] = len(audio)
            observation['wav_magic'] = audio[:4] == b'RIFF' and audio[8:12] == b'WAVE'
            if response.status != 200 or not observation['final_url_unchanged'] or len(audio) > 5 * 1024 * 1024 or not observation['wav_magic']:
                observation['contract'] = 'rejected_asset'
                print(json.dumps(observation)); raise SystemExit('Discovery failed asset contract; stop acceptance')
        observation['contract'] = 'observed'
        print(json.dumps(observation))


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as exc:
        raise SystemExit(f'HTTP {exc.code}; no response body or URL logged; stop without retry') from None
    except (ValueError, KeyError, OSError, urllib.error.URLError):
        raise SystemExit('Discovery/configuration failed; details redacted; stop without retry') from None
