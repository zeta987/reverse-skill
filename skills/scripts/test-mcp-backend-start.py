"""Exercise concurrent startup and early exit with an inert local HTTP fixture."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request
import uuid

if os.name != 'nt':
    raise SystemExit('This test covers the Windows backend launcher.')
repo = Path(__file__).resolve().parents[2]
root = repo / 'work' / ('mcp-launcher-test-' + uuid.uuid4().hex[:12])
root.mkdir(parents=True)
package = root / 'modules' / 'ida_pro_mcp'
package.mkdir(parents=True)
(package / '__init__.py').write_text('', encoding='utf-8')
(root / 'idalib.dll').write_bytes(b'inert test marker; not a library')
fixture = r'''
import argparse,json,os,threading
from http.server import BaseHTTPRequestHandler,HTTPServer
if os.environ.get('REVERSE_TEST_EARLY_EXIT')=='1': raise SystemExit(7)
p=argparse.ArgumentParser();p.add_argument('--host');p.add_argument('--port',type=int);a=p.parse_args()
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        length=int(self.headers.get('Content-Length','0'));self.rfile.read(length)
        result={'jsonrpc':'2.0','id':1,'result':{'tools':[{'name':'decompile'},{'name':'list_funcs'}]}}
        self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(json.dumps(result).encode())
    def do_GET(self):
        self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
        self.wfile.write(json.dumps({'fixture':os.environ['REVERSE_TEST_NONCE'],'pid':os.getpid()}).encode())
        if self.path=='/shutdown': threading.Thread(target=self.server.shutdown,daemon=True).start()
server=HTTPServer((a.host,a.port),Handler);server.serve_forever();server.server_close()
'''
(package / 'idalib_server.py').write_text(fixture, encoding='utf-8')
nonce = uuid.uuid4().hex
environment = {**os.environ, 'PYTHONPATH': str(root / 'modules'), 'REVERSE_TEST_NONCE': nonce}
environment.pop('REVERSE_TEST_EARLY_EXIT', None)


def free_port():
    with socket.socket() as server:
        server.bind(('127.0.0.1', 0))
        return server.getsockname()[1]


def run(port, backend='Ida', early_exit=False):
    command = ['pwsh', '-NoProfile', '-File', str(repo / 'skills/scripts/mcp/start-local-backend.ps1'),
               '-Backend', backend, '-Executable', sys.executable, '-IdaDir', str(root),
               '-Port', str(port), '-LogDir', str(root / ('early' if early_exit else 'parallel')),
               '-WaitSeconds', '8']
    env = {**environment, **({'REVERSE_TEST_EARLY_EXIT': '1'} if early_exit else {})}
    # Files avoid inheritable pipe handles held by the deliberately persistent backend.
    token = uuid.uuid4().hex
    stdout_path, stderr_path = root / (token+'.stdout'), root / (token+'.stderr')
    with stdout_path.open('w',encoding='utf-8') as output, stderr_path.open('w',encoding='utf-8') as errors:
        process = subprocess.Popen(command,env=env,stdout=output,stderr=errors)
        try:
            exit_code = process.wait(timeout=25)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            raise
    return {'exit_code':exit_code,'stdout':stdout_path.read_text(encoding='utf-8'),'stderr':stderr_path.read_text(encoding='utf-8')}


port = free_port()
try:
    with ThreadPoolExecutor(2) as pool:
        attempts = list(pool.map(lambda spelling: run(port, spelling), ['Ida', 'ida']))
    assert all(item['exit_code'] == 0 for item in attempts), attempts
    values = [json.loads(item['stdout']) for item in attempts]
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/owner', timeout=3) as response:
        owner = json.load(response)
    assert owner['fixture'] == nonce
    assert {item['pid'] for item in values} == {owner['pid']}, values
    assert sorted(item['reused'] for item in values) == [False, True], values
    assert len(list((root / 'parallel').glob('*.process.json'))) == 1
finally:
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/owner', timeout=2) as response:
            owner = json.load(response)
        if owner.get('fixture') == nonce:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/shutdown', timeout=2):
                pass
    except OSError:
        pass
early = run(free_port(), early_exit=True)
assert early['exit_code'] != 0 and 'exited with code 7' in early['stderr'], early
report = {'status': 'PASS', 'concurrent_start': values, 'early_exit_rejected': True,
          'fixture_only': True, 'artifacts': str(root)}
(root / 'result.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
