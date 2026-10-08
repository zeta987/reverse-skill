"""Exercise anything-analyzer-stdio.py against a stub pnpm and a fake Streamable HTTP server.

The fake mirrors @modelcontextprotocol/sdk 1.29 StreamableHTTPServerTransport semantics read
from the pinned app checkout: 406 unless Accept lists application/json and text/event-stream,
mcp-session-id issued on initialize, 400 for a non-initialize POST without a session, 404 for
an unknown session, SSE "event: message"/"data:" replies for requests, 202 for notifications,
405 for GET, 200 for DELETE, -32601 for server/discover. Every port is random; the real app,
its config and the real token are never touched.

Set REVERSE_TEST_MCP_REMOTE=1 to also run the pinned mcp-remote proxy leg (needs Node and,
on first use, network access for npx); otherwise only the built-in relay leg is exercised.
"""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

if os.name != 'nt':
    raise SystemExit('This test covers the Windows stdio launcher.')
repo = Path(__file__).resolve().parents[2]
launcher = repo / 'skills' / 'scripts' / 'mcp' / 'anything-analyzer-stdio.py'
root = repo / 'work' / ('mcp-aa-stdio-test-' + uuid.uuid4().hex[:12])
root.mkdir(parents=True)
fake_repo = root / 'anything-analyzer'
fake_repo.mkdir()
(fake_repo / 'package.json').write_text('{"name":"anything-analyzer","scripts":{"dev":"electron-vite dev"}}', encoding='utf-8')
nonce = uuid.uuid4().hex
test_token = 'test-token-' + uuid.uuid4().hex
marker = root / 'pnpm-invocations.txt'

FIXTURE = r'''
import json, os, threading, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
if os.environ.get('REVERSE_TEST_EARLY_EXIT') == '1':
    raise SystemExit(7)
port = int(os.environ['REVERSE_TEST_PORT']); token = os.environ['REVERSE_TEST_TOKEN']
name = os.environ.get('REVERSE_TEST_SERVER_NAME', 'anything-analyzer'); nonce = os.environ['REVERSE_TEST_NONCE']
sessions = set(); lock = threading.Lock()
TOOLS = [{'name': 'list_requests', 'description': 'fixture', 'inputSchema': {'type': 'object', 'properties': {}}}]
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def _send(self, code, body=b'', ctype='application/json', extra=None):
        self.send_response(code)
        if body or code != 202:
            self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for key, value in (extra or {}).items(): self.send_header(key, value)
        self.end_headers()
        if body: self.wfile.write(body)
    def _json(self, code, obj, extra=None): self._send(code, json.dumps(obj).encode(), extra=extra)
    def _authorized(self):
        if self.headers.get('Authorization') != 'Bearer ' + token:
            self._json(401, {'error': 'Unauthorized: invalid or missing token'}); return False
        return True
    def do_GET(self):
        if self.path == '/owner': self._json(200, {'fixture': nonce, 'pid': os.getpid(), 'name': name, 'sessions': len(sessions)}); return
        if self.path == '/shutdown':
            self._json(200, {'ok': True}); threading.Thread(target=self.server.shutdown, daemon=True).start(); return
        if not self._authorized(): return
        self._json(405, {'jsonrpc': '2.0', 'error': {'code': -32000, 'message': 'Method not allowed'}, 'id': None})
    def do_DELETE(self):
        if not self._authorized(): return
        sid = self.headers.get('mcp-session-id', '')
        with lock:
            if sid in sessions: sessions.discard(sid); self._send(200); return
        self._json(sid and 404 or 400, {'error': 'Session not found'})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if not self._authorized(): return
        if self.path != '/mcp': self._send(404, b'Not Found', 'text/plain'); return
        accept = self.headers.get('Accept', '')
        if 'application/json' not in accept or 'text/event-stream' not in accept:
            self._json(406, {'jsonrpc': '2.0', 'error': {'code': -32000, 'message': 'Not Acceptable: Client must accept both application/json and text/event-stream'}, 'id': None}); return
        try: message = json.loads(raw)
        except ValueError: self._json(400, {'jsonrpc': '2.0', 'error': {'code': -32700, 'message': 'Parse error'}, 'id': None}); return
        frames = message if isinstance(message, list) else [message]
        sid = self.headers.get('mcp-session-id', '')
        is_init = any(f.get('method') == 'initialize' for f in frames)
        if sid:
            with lock:
                if sid not in sessions: self._json(404, {'jsonrpc': '2.0', 'error': {'code': -32001, 'message': 'Session not found'}, 'id': None}); return
        elif not is_init:
            self._json(400, {'error': 'Bad request: missing session ID or not an initialize request'}); return
        if is_init:
            sid = str(uuid.uuid4())
            with lock: sessions.add(sid)
        responses = []
        for frame in frames:
            if 'method' not in frame or 'id' not in frame: continue
            method = frame['method']; rid = frame['id']
            if method == 'initialize':
                responses.append({'jsonrpc': '2.0', 'id': rid, 'result': {'protocolVersion': frame.get('params', {}).get('protocolVersion', '2025-03-26'), 'capabilities': {'tools': {'listChanged': False}}, 'serverInfo': {'name': name, 'version': '1.0.0'}}})
            elif method == 'tools/list':
                responses.append({'jsonrpc': '2.0', 'id': rid, 'result': {'tools': TOOLS}})
            elif method == 'ping':
                responses.append({'jsonrpc': '2.0', 'id': rid, 'result': {}})
            else:
                responses.append({'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32601, 'message': 'Method not found'}})
        if not responses:
            self._send(202, extra={'mcp-session-id': sid}); return
        body = ''.join('event: message\ndata: ' + json.dumps(r) + '\n\n' for r in responses).encode()
        self._send(200, body, 'text/event-stream', {'mcp-session-id': sid})
ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
'''
fixture = root / 'fixture.py'
fixture.write_text(FIXTURE, encoding='utf-8')
stub_dir = root / 'stub'
stub_dir.mkdir()
stub_pnpm = stub_dir / 'pnpm.cmd'
stub_pnpm.write_text('@echo off\r\necho invoked %* >> "%REVERSE_TEST_MARKER%"\r\nif not "%1"=="dev" exit /b 9\r\n'
                     f'"{sys.executable}" -I "{fixture}"\r\n', encoding='ascii')

# mcp-remote stand-in for the ownership tests: spawns a grandchild the way npx-cli.js -> cmd ->
# node does, records both pids, then holds stdin open like a proxy would.
STANDIN = r'''
import json, os, signal, subprocess, sys, time
signal.signal(signal.SIGBREAK, signal.SIG_IGN)  # survive the console event aimed at the launcher's group
record = os.environ['REVERSE_TEST_STANDIN_RECORD']
grandchild = subprocess.Popen([sys.executable, '-I', '-c', 'import time; time.sleep(600)'],
                              creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,  # own group: only the job can end it
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
with open(record, 'w', encoding='utf-8') as handle:
    json.dump({'pid': os.getpid(), 'grandchild': grandchild.pid, 'argv': sys.argv[1:]}, handle)
sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': 0, 'result': {'standin': True}}) + '\n'); sys.stdout.flush()
for _ in sys.stdin:
    pass
time.sleep(600)  # a proxy that ignores EOF: only explicit termination or the job object ends it
'''
standin = root / 'standin.py'
standin.write_text(STANDIN, encoding='utf-8')


def pid_alive(pid):
    import ctypes
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    handle = kernel32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return False
    try:
        code = ctypes.c_ulong()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return False
        return code.value == 259  # STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def wait_dead(pids, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not any(pid_alive(pid) for pid in pids):
            return True
        time.sleep(0.2)
    return False


def kill_tree_best_effort(pids):
    for pid in pids:
        subprocess.run(['taskkill', '/PID', str(pid), '/T', '/F'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


base_env = {**os.environ, 'REVERSE_TEST_TOKEN': test_token, 'REVERSE_TEST_NONCE': nonce,
            'REVERSE_TEST_MARKER': str(marker), 'REVERSE_TEST_SERVER_NAME': 'anything-analyzer',
            'REVERSE_TEST_EARLY_EXIT': '0', 'ANYTHING_ANALYZER_MCP_TOKEN': test_token}
base_env.pop('ANYTHING_ANALYZER_PROXY', None)
fixture_ports = []


def free_port():
    with socket.socket() as server:
        server.bind(('127.0.0.1', 0))
        return server.getsockname()[1]


def http_get(port, path, timeout=3):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f'http://127.0.0.1:{port}{path}', timeout=timeout) as response:
        return json.load(response)


def write_config(path, port, **overrides):
    payload = {'enabled': True, 'host': '127.0.0.1', 'port': port, 'authEnabled': True, 'authToken': test_token}
    for key, value in overrides.items():
        if value is None:
            payload.pop(key, None)
        else:
            payload[key] = value
    path.write_bytes(json.dumps(payload).encode('utf-8'))


def marker_count():
    return len(marker.read_text(encoding='utf-8').splitlines()) if marker.exists() else 0


def start_direct_fixture(port, token, name):
    env = {**base_env, 'REVERSE_TEST_PORT': str(port), 'REVERSE_TEST_TOKEN': token, 'REVERSE_TEST_SERVER_NAME': name}
    stderr_log = (root / f'direct-fixture-{port}.stderr').open('wb')
    process = subprocess.Popen([sys.executable, '-I', str(fixture)], env=env,
                               creationflags=subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=stderr_log)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            owner = http_get(port, '/owner')
            if owner['fixture'] == nonce:
                fixture_ports.append(port)
                # A venv python.exe is a redirector: the fixture's os.getpid() is its child's pid,
                # so identity is tracked by the /owner pid, not by the Popen handle.
                return process, owner['pid']
        except OSError:
            time.sleep(0.2)
    raise AssertionError(f'direct fixture did not come up on {port}')


def launcher_command(port, config, log_dir, proxy='relay', extra=()):
    return [sys.executable, '-I', str(launcher), '--port', str(port), '--repo', str(fake_repo), '--pnpm', str(stub_pnpm),
            '--config', str(config), '--log-dir', str(log_dir), '--wait', '15', '--proxy', proxy, *extra]


def run_launcher(port, config, log_dir, proxy='relay', extra=(), env_extra=None, stdin_frames=None, timeout=60, expect_frames=0):
    """Run the launcher as a client would: stdin = JSON-RPC frames, stdout = MCP channel, stderr = diagnostics.

    A real client keeps stdin open while it waits for answers; mcp-remote forwards
    asynchronously and shuts down on stdin EOF, so stdin is closed only after
    `expect_frames` lines reached stdout (or the launcher exited / timed out)."""
    env = {**base_env, 'REVERSE_TEST_PORT': str(port), **(env_extra or {})}
    token = uuid.uuid4().hex
    out_path, err_path = root / (token + '.stdout'), root / (token + '.stderr')
    with out_path.open('wb') as out, err_path.open('wb') as err:
        process = subprocess.Popen(launcher_command(port, config, log_dir, proxy, extra), env=env,
                                   stdin=subprocess.PIPE, stdout=out, stderr=err)
        def stdout_frames():
            return len([line for line in out_path.read_text(encoding='utf-8', errors='replace').splitlines() if line.strip()])

        def wait_for(count, deadline):
            while process.poll() is None and time.monotonic() < deadline and stdout_frames() < count:
                time.sleep(0.2)

        try:
            deadline = time.monotonic() + timeout
            frames_in = list(stdin_frames or [])
            if expect_frames and frames_in:
                # Like a real client: send initialize alone, wait for its reply (the proxy learns the
                # session id from it), then the rest. Blasting everything at once races the session.
                process.stdin.write((json.dumps(frames_in[0]) + '\n').encode('utf-8'))
                process.stdin.flush()
                wait_for(1, deadline)
                frames_in = frames_in[1:]
            process.stdin.write(''.join(json.dumps(frame) + '\n' for frame in frames_in).encode('utf-8'))
            process.stdin.flush()
            if expect_frames:
                wait_for(expect_frames, deadline)
            process.stdin.close()
            process.wait(timeout=max(1.0, deadline - time.monotonic()))
        except (subprocess.TimeoutExpired, OSError):
            process.kill()
            process.wait(timeout=5)
            raise
    stdout = out_path.read_text(encoding='utf-8')
    frames = [json.loads(line) for line in stdout.splitlines() if line.strip()]
    return {'exit_code': process.returncode, 'stdout': stdout, 'frames': frames,
            'stderr': err_path.read_text(encoding='utf-8', errors='replace')}


SMOKE = [
    {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'smoke', 'version': '0'}}},
    {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
    {'jsonrpc': '2.0', 'id': 2, 'method': 'server/discover', 'params': {}},
    {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list', 'params': {}},
]


def assert_smoke(frames, label):
    by_id = {frame.get('id'): frame for frame in frames}
    assert by_id.get(1, {}).get('result', {}).get('serverInfo', {}).get('name') == 'anything-analyzer', f'{label}: initialize reply missing: {frames}'
    assert by_id.get(2, {}).get('error', {}).get('code') == -32601, f'{label}: server/discover must answer -32601: {frames}'
    tools = by_id.get(3, {}).get('result', {}).get('tools', [])
    assert [tool['name'] for tool in tools] == ['list_requests'], f'{label}: tools/list reply missing: {frames}'
    assert len(frames) == 3, f'{label}: unexpected extra stdout frames: {frames}'


def assert_refused(result, needle, label):
    assert result['exit_code'] != 0, f'{label}: exit code was 0'
    assert needle in result['stderr'], f"{label}: expected '{needle}' in stderr, got: {result['stderr']}"
    assert result['stdout'] == '', f'{label}: stdout must stay empty before the proxy starts, got: {result["stdout"]!r}'


report = {'status': 'FAIL', 'artifacts': str(root)}
try:
    config = root / 'mcp-server-config.json'
    port = free_port()
    validation_log = root / 'logs-validation'

    # --- 1. config validation: precise refusal, empty stdout, pnpm never invoked ---
    cases = [
        ('missing config', lambda: config.unlink(missing_ok=True), 'config not found'),
        ('BOM', lambda: config.write_bytes(b'\xef\xbb\xbf' + json.dumps({'enabled': True, 'host': '127.0.0.1', 'port': port, 'authEnabled': True, 'authToken': test_token}).encode()), 'UTF-8 BOM'),
        ('invalid JSON', lambda: config.write_bytes(b'{"enabled":true,'), 'not valid JSON'),
        ('enabled=false', lambda: write_config(config, port, enabled=False), 'enabled != true'),
        ('host missing', lambda: write_config(config, port, host=None), "host is '<missing>'"),
        ('host 0.0.0.0', lambda: write_config(config, port, host='0.0.0.0'), 'expected 127.0.0.1'),
        ('port mismatch', lambda: write_config(config, port + 1), f'expected {port}'),
        ('authEnabled=false', lambda: write_config(config, port, authEnabled=False), 'authEnabled=true'),
        ('empty token', lambda: write_config(config, port, authToken=''), 'non-empty authToken'),
        ('token mismatch', lambda: write_config(config, port, authToken='another-token'), f'differs from ANYTHING_ANALYZER_MCP_TOKEN'),
    ]
    for label, setup, needle in cases:
        setup()
        result = run_launcher(port, config, validation_log, stdin_frames=SMOKE)
        assert_refused(result, needle, label)
        assert marker_count() == 0, f'{label}: pnpm was invoked although the config was rejected'
        assert not validation_log.exists(), f'{label}: LogDir was created before validation passed'
    assert json.loads(config.read_bytes())['authToken'] == 'another-token', 'validation rewrote the user config'
    write_config(config, port)
    result = run_launcher(port, config, validation_log, extra=('--repo', str(root / 'no-checkout')), stdin_frames=SMOKE)
    assert_refused(result, 'no package.json', 'missing checkout')
    assert marker_count() == 0
    report['validation_cases'] = len(cases) + 1

    # --- 2. down -> stub pnpm starts the fixture detached; relay answers the smoke ---
    start_log = root / 'logs-start'
    started = run_launcher(port, config, start_log, stdin_frames=SMOKE, expect_frames=3)
    assert started['exit_code'] == 0, f'fresh start failed: {started["stderr"]}'
    assert_smoke(started['frames'], 'fresh start')
    owner = http_get(port, '/owner')
    assert owner['fixture'] == nonce, 'listener is not our fixture'
    fixture_ports.append(port)
    assert marker_count() == 1 and marker.read_text(encoding='utf-8').startswith('invoked dev'), 'stub pnpm was not invoked with dev'
    records = list(start_log.glob('AnythingAnalyzer-*.process.json'))
    assert len(records) == 1, records
    record = json.loads(records[0].read_text(encoding='utf-8'))
    assert record['backend'] == 'AnythingAnalyzer' and record['port'] == port and record['repo_dir'] == str(fake_repo) and record['executable'] == str(stub_pnpm) and record['detached'] is True, record
    assert test_token not in records[0].read_text(encoding='utf-8') and test_token not in started['stderr'] and test_token not in started['stdout'], 'token leaked into a record or output'
    assert len(list(start_log.glob('AnythingAnalyzer-*.stdout.log'))) == 1 and len(list(start_log.glob('AnythingAnalyzer-*.stderr.log'))) == 1
    assert 'started pnpm dev' in started['stderr'] and 'listener ready' in started['stderr'], started['stderr']
    # The fixture must survive the launcher's exit (detached): /owner still answers after communicate() returned.
    assert http_get(port, '/owner')['pid'] == owner['pid'], 'detached fixture died with the launcher'
    # Sessions are deliberately NOT closed: an explicit DELETE is the path that trips the pinned
    # app's onclose recursion. The fixture therefore keeps the probe and relay sessions.
    assert http_get(port, '/owner')['sessions'] >= 1, 'expected the probe/relay sessions to be left open (no DELETE by default)'
    report['fresh_start'] = {'exit_code': started['exit_code'], 'frames': len(started['frames']), 'launcher_pid': record['pid']}

    # --- 3. reuse: healthy listener, config not re-read, no new process ---
    config.unlink()
    reused = run_launcher(port, config, start_log, stdin_frames=SMOKE, expect_frames=3)
    assert reused['exit_code'] == 0, reused['stderr']
    assert_smoke(reused['frames'], 'reuse')
    assert 'reusing healthy listener' in reused['stderr'], reused['stderr']
    assert marker_count() == 1 and len(list(start_log.glob('*.process.json'))) == 1, 'reuse started a second instance'
    write_config(config, port)

    # --- 3b. stale process env: launcher falls back to the User-scope token (simulated via winreg? no: via a wrong process value + matching config) ---
    stale = run_launcher(port, config, start_log, env_extra={'ANYTHING_ANALYZER_MCP_TOKEN': 'stale-process-value'}, stdin_frames=SMOKE)
    # With only the stale process value and no matching User value, the reuse path must refuse with the 401 reason.
    assert stale['exit_code'] != 0 and 'HTTP 401 Unauthorized' in stale['stderr'] and stale['stdout'] == '', stale
    assert http_get(port, '/owner')['pid'] == owner['pid'], 'stale-token refusal killed the listener'

    # --- 4. concurrent launches on one free port: exactly one pnpm invocation, every proxy answers ---
    multi_port = free_port()
    multi_config = root / 'multi-config.json'
    write_config(multi_config, multi_port)
    multi_log = root / 'logs-multi'
    with ThreadPoolExecutor(3) as pool:
        results = list(pool.map(lambda _: run_launcher(multi_port, multi_config, multi_log, stdin_frames=SMOKE, expect_frames=3), range(3)))
    fixture_ports.append(multi_port)
    for index, result in enumerate(results):
        assert result['exit_code'] == 0, f'concurrent #{index}: {result["stderr"]}'
        assert_smoke(result['frames'], f'concurrent #{index}')
    assert marker_count() == 2, f'concurrent launches started pnpm {marker_count() - 1} times'
    assert len(list(multi_log.glob('*.process.json'))) == 1
    report['concurrent'] = {'launchers': 3, 'starts': 1}

    # --- 5. wrong owner / wrong token on an occupied port: refused, preserved, empty stdout ---
    other_port = free_port()
    other, other_pid = start_direct_fixture(other_port, test_token, 'other-mcp-server')
    other_config = root / 'other-config.json'
    write_config(other_config, other_port)
    refused = run_launcher(other_port, other_config, root / 'logs-other', stdin_frames=SMOKE)
    assert_refused(refused, "serverInfo.name 'other-mcp-server'", 'wrong owner')
    assert 'existing processes were preserved' in refused['stderr']
    other_owner = http_get(other_port, '/owner')
    assert other.poll() is None and other_owner['pid'] == other_pid, f'foreign listener was killed or replaced: poll={other.poll()} owner={other_owner} expected pid={other_pid}'
    assert not (root / 'logs-other').exists() and marker_count() == 2
    auth_port = free_port()
    auth, auth_pid = start_direct_fixture(auth_port, 'a-token-the-launcher-does-not-have', 'anything-analyzer')
    auth_config = root / 'auth-config.json'
    write_config(auth_config, auth_port)
    rejected = run_launcher(auth_port, auth_config, root / 'logs-auth', stdin_frames=SMOKE)
    assert_refused(rejected, 'HTTP 401 Unauthorized', '401 owner')
    assert auth.poll() is None and http_get(auth_port, '/owner')['pid'] == auth_pid and marker_count() == 2

    # --- 6. launcher exits before readiness ---
    early_port = free_port()
    early_config = root / 'early-config.json'
    write_config(early_config, early_port)
    early = run_launcher(early_port, early_config, root / 'logs-early', env_extra={'REVERSE_TEST_EARLY_EXIT': '1'}, stdin_frames=SMOKE)
    assert_refused(early, 'exited with code', 'early exit')
    assert marker_count() == 3

    # --- 7. proxy subtree ownership: the launcher's death (hard kill or normal exit) takes the
    #        proxy and its grandchild with it; the detached app fixture survives both ---
    standin_env = {'ANYTHING_ANALYZER_MCP_REMOTE_COMMAND': json.dumps([sys.executable, '-I', str(standin)])}
    standin_pids = []
    ownership = {}
    for mode in ('hard-kill', 'ctrl-break'):
        record_path = root / f'standin-{mode}.json'
        env = {**base_env, 'REVERSE_TEST_PORT': str(port), **standin_env, 'REVERSE_TEST_STANDIN_RECORD': str(record_path)}
        out_path, err_path = root / f'standin-{mode}.stdout', root / f'standin-{mode}.stderr'
        with out_path.open('wb') as out, err_path.open('wb') as err:
            process = subprocess.Popen(launcher_command(port, config, start_log, 'mcp-remote'), env=env,
                                       stdin=subprocess.PIPE, stdout=out, stderr=err,
                                       creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not record_path.exists() and process.poll() is None:
                time.sleep(0.2)
            assert record_path.exists(), f'{mode}: stand-in never started: {err_path.read_text(errors="replace")}'
            time.sleep(0.3)
            pids = json.loads(record_path.read_text(encoding='utf-8'))
            standin_pids += [pids['pid'], pids['grandchild']]
            assert pid_alive(pids['pid']) and pid_alive(pids['grandchild']), f'{mode}: stand-in chain not alive before the test'
            assert 'owned by a kill-on-close job object' in err_path.read_text(errors='replace'), f'{mode}: job object was not applied: {err_path.read_text(errors="replace")}'
            assert pids['argv'][:2] == ['-y', 'mcp-remote@0.14.3'], f'{mode}: stand-in did not receive the mcp-remote argv: {pids["argv"]}'
            if mode == 'hard-kill':
                process.kill()  # TerminateProcess: what a client does on timeout; no handler can run
                process.wait(timeout=10)
                ownership[mode] = {'launcher_exit': process.returncode}
            else:
                # Catchable termination: CTRL_BREAK to the launcher's own group. The stand-in ignores the
                # event and the grandchild sits in another group, so only the launcher's explicit
                # terminate + job teardown can end them.
                import signal
                try:
                    process.send_signal(signal.CTRL_BREAK_EVENT)
                except OSError as error:
                    process.kill()
                    process.wait(timeout=10)
                    ownership[mode] = f'SKIPPED (no console for CTRL_BREAK_EVENT: {error})'
                    assert wait_dead([pids['pid'], pids['grandchild']], timeout=10), f'{mode}: subtree survived the fallback kill'
                    continue
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
                    raise AssertionError(f'{mode}: launcher ignored CTRL_BREAK_EVENT for 15 s: {err_path.read_text(errors="replace")}')
                stderr_text = err_path.read_text(errors='replace')
                assert process.returncode == 130 and 'terminating the proxy subtree' in stderr_text, f'{mode}: launcher did not take the signal path (exit {process.returncode}): {stderr_text}'
                ownership[mode] = {'launcher_exit': process.returncode}
        assert wait_dead([pids['pid'], pids['grandchild']], timeout=10), f'{mode}: proxy subtree survived the launcher: stand-in alive={pid_alive(pids["pid"])} grandchild alive={pid_alive(pids["grandchild"])}'
        assert http_get(port, '/owner')['pid'] == owner['pid'], f'{mode}: the detached app fixture was killed with the proxy subtree'
    report['proxy_ownership'] = {**ownership, 'orphans': 0}

    # --- 8. optional: pinned mcp-remote proxy leg against the fake server ---
    if os.environ.get('REVERSE_TEST_MCP_REMOTE') == '1':
        assert shutil.which('node'), 'node is required for the mcp-remote leg'
        remote = run_launcher(port, config, start_log, proxy='mcp-remote', stdin_frames=SMOKE, timeout=180, expect_frames=3)
        assert remote['exit_code'] == 0, f'mcp-remote leg failed: {remote["stderr"]}'
        assert_smoke(remote['frames'], 'mcp-remote')
        assert 'proxy: mcp-remote@' in remote['stderr'], remote['stderr']
        report['mcp_remote'] = {'exit_code': remote['exit_code'], 'frames': len(remote['frames'])}
    else:
        report['mcp_remote'] = 'SKIPPED (set REVERSE_TEST_MCP_REMOTE=1)'

    # --- 9. restricted client environment (Codex filters APPDATA/LOCALAPPDATA/PATHEXT and trims PATH) ---
    if os.name == 'nt':
        import winreg
        probe = (
            'import importlib.util, json, os, shutil, sys\n'
            f'spec = importlib.util.spec_from_file_location("launcher", {str(launcher)!r})\n'
            'module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)\n'
            'repaired = module.repair_environment()\n'
            'print(json.dumps({"repaired": repaired, "APPDATA": os.environ.get("APPDATA"), "LOCALAPPDATA": os.environ.get("LOCALAPPDATA"),\n'
            '                  "PATHEXT": os.environ.get("PATHEXT"), "PATH": os.environ.get("PATH")}))\n'
        )
        stripped = {key: value for key, value in os.environ.items()
                    if key.upper() not in ('APPDATA', 'LOCALAPPDATA', 'PATHEXT', 'PATH')}
        stripped['PATH'] = os.environ.get('SystemRoot', r'C:\Windows') + r'\System32'
        probe_run = subprocess.run([sys.executable, '-I', '-c', probe], env=stripped, capture_output=True, text=True, timeout=60)
        assert probe_run.returncode == 0, f'repair_environment probe failed: {probe_run.stderr}'
        repaired_env = json.loads(probe_run.stdout)
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders') as key:
            expected_appdata = winreg.QueryValueEx(key, 'AppData')[0]
        assert repaired_env['APPDATA'] == expected_appdata, f'APPDATA fallback: {repaired_env}'
        assert repaired_env['LOCALAPPDATA'] and repaired_env['PATHEXT'], f'LOCALAPPDATA/PATHEXT fallback: {repaired_env}'
        assert {'APPDATA', 'LOCALAPPDATA', 'PATHEXT'} <= set(repaired_env['repaired']), repaired_env['repaired']
        user_path = ''
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
                user_path = winreg.QueryValueEx(key, 'Path')[0]
        except OSError:
            pass
        if user_path.strip(';'):
            first_user_entry = os.path.expandvars(user_path.split(';')[0]).lower().rstrip('\\')
            assert first_user_entry in {entry.lower().rstrip('\\') for entry in repaired_env['PATH'].split(';')}, f'persisted PATH was not appended: {repaired_env["PATH"]}'
        # The launcher itself must still succeed end to end under that environment (explicit --pnpm/--config, relay leg).
        restricted_run_env = {key: value for key, value in base_env.items() if key.upper() not in ('APPDATA', 'LOCALAPPDATA', 'PATHEXT')}
        restricted_run_env['PATH'] = stripped['PATH']
        restricted = subprocess.run(launcher_command(port, config, start_log, 'relay', ('--check-only',)),
                                    env={**restricted_run_env, 'REVERSE_TEST_PORT': str(port)}, capture_output=True, text=True, timeout=60)
        assert restricted.returncode == 0, f'restricted-env --check-only failed: {restricted.stderr}'
        assert restricted.stdout == '', f'stdout must stay empty: {restricted.stdout!r}'
        assert 'restricted client environment: filled' in restricted.stderr, restricted.stderr
        report['restricted_environment'] = {'repaired': repaired_env['repaired'], 'check_only_exit': restricted.returncode}
    else:
        report['restricted_environment'] = 'SKIPPED (Windows only)'

    report['status'] = 'PASS'
    report['fixture_only'] = True
finally:
    kill_tree_best_effort([pid for pid in standin_pids if pid_alive(pid)]) if 'standin_pids' in globals() else None
    for fixture_port in fixture_ports:
        try:
            if http_get(fixture_port, '/owner', timeout=2).get('fixture') == nonce:
                try:
                    http_get(fixture_port, '/shutdown', timeout=2)
                except OSError:
                    pass
        except OSError:
            pass
    (root / 'result.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
