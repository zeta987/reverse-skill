"""Synthetic stdlib coverage for lazy-stdio.py; never opens apps or targets."""

import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import unittest
import uuid

REPO = Path(__file__).resolve().parents[2]
LAUNCHER = REPO / 'skills/scripts/mcp/lazy-stdio.py'
ROOT = REPO / 'work' / ('lazy-stdio-test-' + uuid.uuid4().hex[:12])
ROOT.mkdir(parents=True)
SECRET = 'synthetic-secret-' + uuid.uuid4().hex
FIXTURE = ROOT / 'child.py'
FIXTURE.write_text(r'''
import json, os, subprocess, sys, time
from pathlib import Path
mode = sys.argv[1]; record = Path(sys.argv[2]); trace = Path(sys.argv[3])
grandchild = subprocess.Popen([sys.executable, '-I', '-c', 'import time; time.sleep(600)'],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
record.write_text(json.dumps({'pid': os.getpid(), 'grandchild': grandchild.pid}))
print(os.environ['FIXTURE_SECRET'], file=sys.stderr, flush=True)
print('startup diagnostic ' + os.environ['FIXTURE_SECRET'], flush=True)
if mode == 'early': raise SystemExit(7)
def emit(frame): print(json.dumps(frame), flush=True)
for line in sys.stdin:
    frame = json.loads(line)
    with trace.open('a') as handle: handle.write(json.dumps(frame) + '\n')
    if 'method' not in frame: continue
    method = frame['method']; rid = frame.get('id')
    if method == 'initialize':
        if mode == 'startup-hang':
            while True:
                emit({'jsonrpc': '2.0', 'method': 'notifications/progress', 'params': {}}); time.sleep(.05)
        emit({'jsonrpc': '2.0', 'id': rid, 'result': {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'fixture-backend', 'version': 'fixture-1'}}})
        if mode == 'blocked-stdin':
            while True: time.sleep(.1)
    elif method == 'tools/list':
        if frame.get('params', {}).get('cursor'):
            result = {'tools': [{'name': 'action', 'description': 'act', 'inputSchema': {'type': 'object', 'required': ['value'], 'properties': {'value': {'type': 'integer'}}}, 'annotations': {'destructiveHint': True}}]}
            if mode == 'repeat-cursor': result['nextCursor'] = 'second'
        else: result = {'tools': [{'name': 'catalog', 'description': 'catalogue', 'inputSchema': {'type': 'object', 'properties': {}}, 'annotations': {'readOnlyHint': True}}], 'nextCursor': 'second'}
        emit({'jsonrpc': '2.0', 'id': rid, 'result': result})
    elif method == 'tools/call':
        name = frame['params']['name']
        if name == 'hang':
            while True:
                emit({'jsonrpc': '2.0', 'method': 'notifications/progress', 'params': {}}); time.sleep(.05)
        if name == 'callback':
            emit({'jsonrpc': '2.0', 'id': 'child-ping', 'method': 'ping'})
            emit({'jsonrpc': '2.0', 'id': 'child-unknown', 'method': 'sampling/createMessage', 'params': {}})
        if name == 'rpc-error': emit({'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32602, 'message': os.environ['FIXTURE_SECRET']}})
        elif name == 'wrong-id': emit({'jsonrpc': '2.0', 'id': 'wrong', 'result': {}})
        elif name == 'large-result': emit({'jsonrpc': '2.0', 'id': rid, 'result': {'content': [{'type': 'text', 'text': 'x' * 3145728}]}})
        else: emit({'jsonrpc': '2.0', 'id': rid, 'result': {'content': [{'type': 'image', 'mimeType': 'image/png', 'data': 'AA=='}, {'type': 'text', 'text': 'fixture'}], 'structuredContent': frame['params'], 'isError': True}})
''', encoding='utf-8')


def alive(pid):
    if os.name == 'nt':
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        try:
            code = wintypes.DWORD()
            return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class Client:
    def __init__(self, mode='normal', timeout=2, read_output=True):
        stem = ROOT / uuid.uuid4().hex
        self.record = stem.with_suffix('.process.json')
        self.trace = stem.with_suffix('.trace.jsonl')
        self.stderr = stem.with_suffix('.stderr')
        self.frames = queue.Queue()
        self.err_handle = self.stderr.open('wb')
        self.process = subprocess.Popen([sys.executable, '-I', str(LAUNCHER), '--server-name', 'fixture',
            '--startup-timeout', str(timeout), '--tool-timeout', str(timeout), '--',
            sys.executable, '-I', str(FIXTURE), mode, str(self.record), str(self.trace)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err_handle,
            env={**os.environ, 'FIXTURE_SECRET': SECRET})
        def read():
            for line in self.process.stdout:
                self.frames.put(json.loads(line))
            self.frames.put(None)
        if read_output:
            threading.Thread(target=read, daemon=True).start()

    def send(self, frame):
        self.process.stdin.write((json.dumps(frame) + '\n').encode())
        self.process.stdin.flush()

    def request(self, method, params=None, rid=1):
        self.send({'jsonrpc': '2.0', 'id': rid, 'method': method, **({'params': params} if params is not None else {})})
        frame = self.frames.get(timeout=8)
        assert frame is not None, f'wrapper exited: {self.stderr.read_text(errors="replace")}'
        assert frame['id'] == rid, frame
        return frame

    def call(self, name, arguments=None, rid=2, meta=None):
        return self.request('tools/call', {'name': name, 'arguments': arguments or {}, **({'_meta': meta} if meta is not None else {})}, rid)

    def traces(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def close(self, hard=False):
        if self.process.poll() is None:
            if hard:
                self.process.kill()
            else:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
                raise
        self.err_handle.close()
        if self.record.exists():
            pids = json.loads(self.record.read_text())
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and any(alive(pid) for pid in pids.values()):
                time.sleep(.05)
            assert not any(alive(pid) for pid in pids.values()), f'orphan subtree: {pids}'
        assert SECRET not in self.stderr.read_text(errors='replace'), 'child stderr leaked'
        wrapper_pids = re.findall(r'wrapper_pid=(\d+)', self.stderr.read_text(errors='replace'))
        assert all(int(pid) == self.process.pid for pid in wrapper_pids), 'test used a wrapper process redirector'


INIT = {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}}


class LazyTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(LAUNCHER.exists(), 'lazy stdio gateway has not been implemented')
        self.clients = []

    def client(self, *args, **kwargs):
        client = Client(*args, **kwargs)
        self.clients.append(client)
        return client

    def tearDown(self):
        for client in self.clients:
            client.close()

    def test_local_no_start(self):
        c = self.client()
        self.assertEqual(c.request('initialize', INIT)['result']['serverInfo']['name'], 'fixture')
        tools = c.request('tools/list', {'_meta': {'progressToken': 'catalog'}})['result']['tools']
        self.assertEqual([t['name'] for t in tools], ['discover_tools', 'call_tool'])
        self.assertEqual(c.request('ping', {'_meta': {}})['result'], {})
        self.assertEqual(c.request('server/discover')['error']['code'], -32601)
        for method, params in [('tools/call', {'name': 'unknown'}), ('tools/call', {'name': 'call_tool', 'arguments': {'name': 'x', 'arguments': []}}),
                               ('tools/call', {'name': 'discover_tools', 'arguments': {'extra': 1}}), ('tools/list', {'_meta': []})]:
            self.assertEqual(c.request(method, params)['error']['code'], -32602)
        c.send({'jsonrpc': '2.0', 'method': 'tools/call', 'params': {'name': 'discover_tools'}})
        c.send({'jsonrpc': '2.0', 'method': 'notifications/initialized', 'params': {'_meta': {}}})
        c.process.stdin.write(b'{bad\n'); c.process.stdin.flush()
        self.assertEqual(c.frames.get(timeout=5)['error']['code'], -32700)
        c.send([])
        self.assertEqual(c.frames.get(timeout=5)['error']['code'], -32600)
        self.assertFalse(c.record.exists(), 'local requests started the original command')

    def test_discovery_call_and_callbacks(self):
        c = self.client()
        c.request('initialize', INIT)
        discovered = json.loads(c.call('discover_tools', meta={'progressToken': 'catalog'})['result']['content'][0]['text'])
        self.assertEqual(discovered['serverInfo'], {'name': 'fixture-backend', 'version': 'fixture-1'})
        self.assertEqual([t['name'] for t in discovered['tools']], ['catalog', 'action'])
        self.assertEqual(discovered['tools'][1]['inputSchema']['required'], ['value'])
        self.assertEqual(discovered['tools'][0]['annotations'], {'readOnlyHint': True})
        params = {'name': 'callback', 'arguments': {'value': 42}}
        result = c.call('call_tool', params, meta={'progressToken': 'action'})['result']
        self.assertEqual(result, {'content': [{'type': 'image', 'mimeType': 'image/png', 'data': 'AA=='}, {'type': 'text', 'text': 'fixture'}], 'structuredContent': {**params, '_meta': {'progressToken': 'action'}}, 'isError': True})
        # Flush callback responses with a subsequent healthy tool request.
        self.assertTrue(c.call('call_tool', {'name': 'rpc-error', 'arguments': {}})['result']['isError'])
        self.assertNotIn(SECRET, json.dumps(c.call('call_tool', {'name': 'action', 'arguments': {}})))
        trace = c.traces()
        init = [f for f in trace if f.get('method') == 'initialize']
        self.assertEqual(len(init), 1)
        self.assertEqual(init[0]['params']['capabilities'], {})
        self.assertEqual(init[0]['params']['protocolVersion'], '2024-11-05')
        requests = [f for f in trace if 'method' in f and 'id' in f]
        self.assertEqual([f['id'] for f in requests], sorted({f['id'] for f in requests}))
        self.assertTrue(all(f['params']['_meta'] == {'progressToken': 'catalog'} for f in trace if f.get('method') == 'tools/list'))
        self.assertIn({'jsonrpc': '2.0', 'id': 'child-ping', 'result': {}}, trace)
        self.assertIn({'jsonrpc': '2.0', 'id': 'child-unknown', 'error': {'code': -32601, 'message': 'Method not found'}}, trace)

    def test_fatal_failures_and_no_replay(self):
        for mode, tool in [('early', None), ('startup-hang', None), ('repeat-cursor', None), ('normal', 'hang'), ('normal', 'wrong-id')]:
            with self.subTest(mode=mode, tool=tool):
                c = self.client(mode, timeout=.5)
                start = time.monotonic()
                reply = c.call('call_tool', {'name': tool, 'arguments': {}}) if tool else c.call('discover_tools')
                self.assertTrue(reply['result']['isError'])
                self.assertNotIn(SECRET, json.dumps(reply))
                c.process.wait(timeout=5)
                self.assertNotEqual(c.process.returncode, 0)
                self.assertLess(time.monotonic() - start, 4, 'notifications reset deadline')
                if tool:
                    self.assertEqual(sum(f.get('method') == 'tools/call' for f in c.traces()), 1)
                c.close()

    def test_eof_during_demand_and_hard_kill(self):
        for hard in (False, True):
            c = self.client('startup-hang', timeout=30)
            c.send({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': 'discover_tools'}})
            deadline = time.monotonic() + 5
            while not c.record.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(c.record.exists())
            start = time.monotonic()
            c.close(hard=hard)
            self.assertLess(time.monotonic() - start, 5)

    def test_blocked_input_timeout_and_eof(self):
        for close_input in (False, True):
            c = self.client('blocked-stdin', timeout=30 if close_input else .5)
            params = {'name': 'call_tool', 'arguments': {'name': 'action', 'arguments': {'large': 'x' * 1048576}}}
            start = time.monotonic()
            c.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': params})
            if close_input:
                deadline = time.monotonic() + 5
                while not c.record.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(c.record.exists())
                time.sleep(.1)
                c.close()
            else:
                reply = c.frames.get(timeout=5)
                self.assertTrue(reply['result']['isError'])
                c.process.wait(timeout=5)
                self.assertNotEqual(c.process.returncode, 0)
                c.close()
            self.assertLess(time.monotonic() - start, 5)

    def test_unread_output_timeout_and_eof(self):
        for close_input in (False, True):
            c = self.client(timeout=30 if close_input else .5, read_output=False)
            start = time.monotonic()
            c.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'call_tool', 'arguments': {'name': 'large-result', 'arguments': {}}}})
            if close_input:
                deadline = time.monotonic() + 5
                while not any(f.get('method') == 'tools/call' for f in c.traces()) and time.monotonic() < deadline:
                    time.sleep(.02)
                time.sleep(.1)
                c.close()
            else:
                c.process.wait(timeout=5)
                self.assertNotEqual(c.process.returncode, 0)
                c.close()
            self.assertTrue(c.record.exists())
            self.assertLess(time.monotonic() - start, 5)


if __name__ == '__main__':
    tests = sys.argv[1:]
    suite = (unittest.defaultTestLoader.loadTestsFromNames(['LazyTests.' + name for name in tests], module=sys.modules[__name__])
             if tests else unittest.defaultTestLoader.loadTestsFromTestCase(LazyTests))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {'status': 'PASS' if result.wasSuccessful() else 'FAIL', 'tests': result.testsRun,
              'failures': len(result.failures), 'errors': len(result.errors), 'python': sys.version, 'artifacts': str(ROOT), 'fixture_only': True}
    (ROOT / 'result.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if result.wasSuccessful() else 1)
