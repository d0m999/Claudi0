#!/usr/bin/env python3
"""One native-host timeout diagnostic with a disposable hook and loopback API.

Never runs Claudio, plays sound, or uses real API credentials. This measures a
UserPromptSubmit protocol boundary, not a normal model session or helper latency.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


def hook(trace):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    temporary = trace.with_suffix('.tmp')
    temporary.write_text(json.dumps({'pid': os.getpid(), 'started_ns': time.perf_counter_ns()}))
    os.chmod(temporary, 0o600)
    temporary.replace(trace)
    time.sleep(20)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--hook', type=Path)
    parser.add_argument('--host', choices=['claude-code', 'workbuddy'], default='claude-code')
    parser.add_argument('--timeout', type=float, default=6)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.hook:
        hook(args.hook)
        return
    if args.output is None or not 0 < args.timeout <= 6:
        parser.error('--output required; timeout must be in (0, 6] seconds')
    if args.output.exists():
        raise FileExistsError('refusing to replace evidence')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.host == 'claude-code':
        prefix = ['claude']
        host_version = subprocess.check_output(prefix + ['--version'], text=True).strip()
        host_binary = Path(shutil.which('claude')).resolve()
    else:
        bundle = Path('/Applications/WorkBuddy.app')
        host_binary = bundle / 'Contents/Resources/app.asar.unpacked/cli/bin/codebuddy'
        prefix = ['node', str(host_binary)]
        host_version = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    with tempfile.TemporaryDirectory(prefix='claudio-host-timeout-') as temporary:
        directory = Path(temporary)
        trace, settings = directory / 'hook.json', directory / 'settings.json'
        script = Path(__file__).resolve()
        driver_hash = hashlib.sha256(script.read_bytes()).hexdigest()
        host_hash = hashlib.sha256(host_binary.read_bytes()).hexdigest()
        command = 'exec ' + shlex.join([sys.executable, str(script), '--hook', str(trace)])
        settings.write_text(json.dumps({'hooks': {'UserPromptSubmit': [{'hooks': [
            {'type': 'command', 'command': command, 'timeout': args.timeout}]}]}}))
        requests = []
        lock = threading.Lock()

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                # Discard request bytes; never store prompt/model content or headers.
                size = int(self.headers.get('Content-Length', '0'))
                if size < 0 or size > 2**20:
                    self.send_error(413)
                    return
                self.rfile.read(size)
                value = {'messages_endpoint': self.path.split('?')[0] == '/v1/messages',
                         'ns': time.perf_counter_ns(), 'hook_started': trace.exists()}
                if trace.exists():
                    value['child_alive'] = alive(json.loads(trace.read_text())['pid'])
                with lock:
                    requests.append(value)
                data = b'{"type":"error","error":{"type":"authentication_error","message":"fixture only"}}'
                self.send_response(401)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        environment = {k: v for k, v in os.environ.items() if not k.startswith('ANTHROPIC_')}
        environment.update(ANTHROPIC_API_KEY='fixture-only',
                           ANTHROPIC_BASE_URL=f'http://127.0.0.1:{server.server_port}',
                           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
                           CLAUDE_CONFIG_DIR=str(directory / 'host-state'))
        if args.host == 'workbuddy':
            environment['CODEBUDDY_FORCE_LITE_WB_BUNDLE'] = '1'
        invocation = prefix + ['-p', '--output-format', 'json', '--no-session-persistence',
                               '--setting-sources', '', '--settings', str(settings),
                               '--strict-mcp-config', '--tools', '', '--', 'Reply only OK. Do not use tools.']
        start = time.perf_counter_ns()
        process = subprocess.Popen(invocation, cwd=directory, env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        expired = False
        stopped_after_observation = False
        child_absent_ns = None
        child_at_stop = None
        hook_age_at_stop_ns = None
        record = None
        try:
            deadline = time.monotonic() + 15
            while process.poll() is None:
                if record is None and trace.exists():
                    record = json.loads(trace.read_text())
                if record and child_absent_ns is None and not alive(record['pid']):
                    child_absent_ns = time.perf_counter_ns()
                with lock:
                    reached_api = any(r['messages_endpoint'] and r['hook_started'] for r in requests)
                if reached_api and child_absent_ns is not None:
                    stopped_after_observation = True
                    child_at_stop = alive(record['pid'])
                    hook_age_at_stop_ns = time.perf_counter_ns() - record['started_ns']
                    os.killpg(process.pid, signal.SIGTERM)
                    break
                if time.monotonic() >= deadline:
                    expired = True
                    child_at_stop = alive(record['pid']) if record else None
                    hook_age_at_stop_ns = time.perf_counter_ns() - record['started_ns'] if record else None
                    os.killpg(process.pid, signal.SIGTERM)
                    break
                time.sleep(.005)
            stdout, stderr = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            expired = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                stdout, stderr = process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate(timeout=2)
        finally:
            end = time.perf_counter_ns()
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)
        record = json.loads(trace.read_text()) if trace.exists() else None
        child_at_exit = alive(record['pid']) if record else None
        cleanup_by_driver = False
        if child_at_exit:
            identity = subprocess.check_output(['ps', '-p', str(record['pid']), '-o', 'command='], text=True)
            if str(trace) not in identity or str(script) not in identity:
                raise RuntimeError('fixture child identity changed; refusing cleanup')
            os.kill(record['pid'], signal.SIGKILL)
            cleanup_by_driver = True
        for _ in range(70):
            if not record or not alive(record['pid']):
                break
            time.sleep(.01)
        messages = [r for r in requests if r['messages_endpoint'] and r['hook_started']]
        first = messages[0] if messages else None
        unchanged = driver_hash == hashlib.sha256(script.read_bytes()).hexdigest() and host_hash == hashlib.sha256(host_binary.read_bytes()).hexdigest()
        value = dict(evidence='native-host-disposable-hook-timeout', host=args.host,
                     utc=datetime.now(timezone.utc).isoformat(), system=platform.system(),
                     macos=platform.mac_ver()[0], architecture=platform.machine(),
                     source_sha=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=script.parent.parent, text=True).strip(),
                     source_dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=script.parent.parent)),
                     host_version=host_version, host_binary_sha256=host_hash,
                     driver_sha256=driver_hash, inputs_unchanged=unchanged,
                     native_event='UserPromptSubmit', mode='short-noninteractive', configured_timeout_s=args.timeout,
                     hook_ignores_term=True, initiated_hooks=int(record is not None),
                     host_exit=process.returncode, driver_timed_out=expired, session_ns=end-start,
                     driver_stopped_after_observation=stopped_after_observation,
                     stdout_bytes=len(stdout), stderr_bytes=len(stderr), requests=len(requests),
                     first_messages_after_hook_ns=first['ns']-record['started_ns'] if first and record else None,
                     boundary='hook entry to first model API request; includes post-hook preparation',
                     child_alive_at_first_messages=first.get('child_alive') if first else None,
                     child_alive_at_host_exit=child_at_exit, fixture_child_killed_by_driver=cleanup_by_driver,
                     hook_entry_after_host_start_ns=record['started_ns']-start if record else None,
                     child_alive_at_driver_stop=child_at_stop, hook_age_at_driver_stop_ns=hook_age_at_stop_ns,
                     child_absent_after_hook_ns=child_absent_ns-record['started_ns'] if child_absent_ns and record else None,
                     child_poll_interval_ms=5,
                     child_reaped_at_end=not alive(record['pid']) if record else None,
                     model_response='synthetic authentication error; not normal session evidence' if requests else 'no loopback response observed',
                     valid_timeout_observation=record is not None and first is not None and not expired and unchanged,
                     claudio_invoked=False, installed_hook_settings_written=False,
                     desktop_delivery_verified=False)
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as destination:
            destination.write(json.dumps(value, indent=2) + '\n')
        print(json.dumps(value))
        return 0 if value['valid_timeout_observation'] else 1


if __name__ == '__main__':
    sys.exit(main())
