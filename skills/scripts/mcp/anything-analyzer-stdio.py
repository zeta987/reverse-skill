"""Start or reuse Anything Analyzer, then bridge MCP stdio to its Streamable HTTP endpoint.

Standard library only, so any Python 3.9+ can run it (the tested bridge venv has
mcp==1.6.0, which has no Streamable HTTP client; nothing here imports mcp).

Flow: stdout is parked on stderr first (the MCP channel must stay clean), the bearer
token is taken from ANYTHING_ANALYZER_MCP_TOKEN (process env, else the User
environment in HKCU\\Environment; never from an argument), the listener on
127.0.0.1:<port> is probed with an authenticated `initialize`, and when it is down
the app config is validated read-only, `pnpm dev` is spawned fully detached under a
named mutex shared with start-local-backend.ps1, and readiness is awaited. Only then
does the proxy leg (pinned `mcp-remote`, or the built-in relay) take over the real
stdout. All diagnostics go to stderr.
"""

import argparse
import datetime
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SERVER_NAME = 'anything-analyzer'
DEFAULT_PORT = 23816
TOKEN_ENV = 'ANYTHING_ANALYZER_MCP_TOKEN'
MCP_REMOTE_VERSION = '0.14.3'
BACKEND_LABEL = 'AnythingAnalyzer'
INITIALIZE = {
    'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
    'params': {'protocolVersion': '2025-03-26', 'capabilities': {},
               'clientInfo': {'name': 'reverse-skill-anything-analyzer-stdio', 'version': '1.0'}},
}
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def log(message):
    print(f'[anything-analyzer-stdio] {message}', file=sys.stderr, flush=True)


class LauncherError(Exception):
    """A precise, user-facing reason the launcher stopped."""


# --- stdout protection -------------------------------------------------------------

def park_stdout():
    """Return the real MCP stdout fd; from now on fd 1 writes land on stderr."""
    mcp_fd = os.dup(1)
    try:
        os.dup2(2, 1)
    except OSError as error:  # stderr unusable: keep stdout but never print to it
        log(f'could not redirect fd 1 to stderr: {error}')
    sys.stdout = sys.stderr
    return mcp_fd


# --- token -------------------------------------------------------------------------

def user_environment_token():
    try:
        import winreg
    except ImportError:
        return ''
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
            value, _ = winreg.QueryValueEx(key, TOKEN_ENV)
            return str(value)
    except OSError:
        return ''


def registry_string(root_name, subkey, name):
    """Read one REG_SZ/REG_EXPAND_SZ value; '' when absent or not on Windows."""
    try:
        import winreg
    except ImportError:
        return ''
    root = getattr(winreg, root_name)
    try:
        with winreg.OpenKey(root, subkey) as key:
            value, _ = winreg.QueryValueEx(key, name)
            return str(value)
    except OSError:
        return ''


def repair_environment():
    """Fill in the environment a restricted MCP client leaves out.

    Codex starts MCP servers with a filtered environment (no APPDATA/LOCALAPPDATA,
    no PATHEXT, a minimal PATH), so the defaults below resolved to the wrong folder
    and pnpm/node were "not found". Values the client did pass are never overridden;
    the persisted Machine/User PATH is only appended when pnpm or node is missing.
    Returns the names that were filled, for the stderr log."""
    if os.name != 'nt':
        return []
    repaired = []
    profile = os.environ.get('USERPROFILE', '')
    if not profile:
        drive, path = os.environ.get('HOMEDRIVE', ''), os.environ.get('HOMEPATH', '')
        profile = (drive + path) if drive and path else str(Path.home())
        os.environ['USERPROFILE'] = profile
        repaired.append('USERPROFILE')
    shell_folders = r'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    for env_key, reg_name, relative in (('APPDATA', 'AppData', r'AppData\Roaming'),
                                        ('LOCALAPPDATA', 'Local AppData', r'AppData\Local')):
        if os.environ.get(env_key):
            continue
        os.environ[env_key] = registry_string('HKEY_CURRENT_USER', shell_folders, reg_name) or str(Path(profile) / relative)
        repaired.append(env_key)
    for env_key, default in (('SystemRoot', r'C:\Windows'), ('ProgramFiles', r'C:\Program Files')):
        if not os.environ.get(env_key):
            os.environ[env_key] = default
            repaired.append(env_key)
    if not os.environ.get('PATHEXT'):
        os.environ['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
        repaired.append('PATHEXT')
    if not (shutil.which('pnpm') and shutil.which('node')):
        persisted = ';'.join(filter(None, (
            registry_string('HKEY_LOCAL_MACHINE', r'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'Path'),
            registry_string('HKEY_CURRENT_USER', 'Environment', 'Path'))))
        current = os.environ.get('PATH', '')
        seen = {entry.lower().rstrip('\\') for entry in current.split(';') if entry}
        additions = []
        for entry in persisted.split(';'):
            entry = os.path.expandvars(entry.strip())
            if entry and entry.lower().rstrip('\\') not in seen:
                seen.add(entry.lower().rstrip('\\'))
                additions.append(entry)
        if additions:
            os.environ['PATH'] = ';'.join(([current] if current else []) + additions)
            repaired.append('PATH')
    return repaired


def token_candidates():
    """Process env first, then the persisted User value (clients may filter or carry a stale env)."""
    candidates = []
    for source, value in (('process environment', os.environ.get(TOKEN_ENV, '')),
                          ('User environment (HKCU\\Environment)', user_environment_token())):
        value = (value or '').strip()
        if value and all(value != known for _, known in candidates):
            candidates.append((source, value))
    return candidates


# --- HTTP probe --------------------------------------------------------------------

def parse_mcp_body(content_type, text):
    if content_type.startswith('text/event-stream'):
        for line in text.splitlines():
            if line.startswith('data:'):
                return json.loads(line[5:].strip())
        return None
    return json.loads(text) if text.strip() else None


def port_open(port, timeout=0.4):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=timeout):
            return True
    except OSError:
        return False


def mcp_post(port, token, payload, session_id=None, timeout=4.0, method='POST'):
    headers = {'Accept': 'application/json, text/event-stream', 'Authorization': f'Bearer {token}'}
    if session_id:
        headers['mcp-session-id'] = session_id
    data = None
    if payload is not None:
        data = json.dumps(payload).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(f'http://127.0.0.1:{port}/mcp', data=data, headers=headers, method=method)
    with _OPENER.open(request, timeout=timeout) as response:
        text = response.read().decode('utf-8', 'replace')
        return response.status, response.headers.get('mcp-session-id', ''), parse_mcp_body(response.headers.get('Content-Type', ''), text)


def close_session(port, token, session_id):
    """Explicit DELETE is the one code path that fires the pinned app's transport.onclose ->
    srv.close() -> transport.close() recursion (RangeError spam, one reported crash), so
    sessions are left to the app by default; ANYTHING_ANALYZER_CLOSE_SESSIONS=1 opts in."""
    if os.environ.get('ANYTHING_ANALYZER_CLOSE_SESSIONS') != '1':
        return
    try:
        mcp_post(port, token, None, session_id=session_id, timeout=1.5, method='DELETE')
    except (urllib.error.URLError, OSError, ValueError):
        pass


def probe(port, token):
    """Classify the listener: ('ok', info) | ('down', why) | ('unauthorized', why) | ('wrong', why)."""
    try:
        status, session_id, message = mcp_post(port, token, INITIALIZE)
    except urllib.error.HTTPError as error:
        if error.code == 401:
            return 'unauthorized', f'HTTP 401 Unauthorized: the listener rejected the bearer token from {TOKEN_ENV}.'
        return 'wrong', f'initialize returned HTTP {error.code}; the listener on port {port} is not a healthy {SERVER_NAME}.'
    except (urllib.error.URLError, OSError, ValueError) as error:
        return 'down', f'no MCP reply: {error}'
    if session_id:
        close_session(port, token, session_id)
    result = (message or {}).get('result') if isinstance(message, dict) else None
    info = (result or {}).get('serverInfo') if isinstance(result, dict) else None
    if isinstance(info, dict) and info.get('name') == SERVER_NAME:
        return 'ok', {'server_name': info.get('name'), 'server_version': info.get('version'),
                      'protocol_version': result.get('protocolVersion')}
    if isinstance(info, dict):
        return 'wrong', f"initialize answered with serverInfo.name '{info.get('name')}' instead of '{SERVER_NAME}'."
    return 'wrong', f'initialize returned HTTP {status} without an MCP result.'


def probe_with_candidates(port, candidates):
    """Try each token; return (state, detail, token_used)."""
    last = ('down', f'{TOKEN_ENV} is not set in the process or User environment.', '')
    for source, token in candidates:
        state, detail = probe(port, token)
        if state == 'ok':
            return state, detail, token
        last = (state, detail, token)
        if state != 'unauthorized':
            break
        log(f'token from {source} was rejected (401); trying the next source')
    return last


# --- app config ----------------------------------------------------------------------

def validate_config(path, port, candidates):
    """Read-only checks mirroring start-local-backend.ps1; returns the token the app expects."""
    if not path.is_file():
        raise LauncherError(f'Anything Analyzer config not found: {path}. Run bootstrap-reverse.ps1 -Capability anything-analyzer first.')
    raw = path.read_bytes()
    if raw[:3] == b'\xef\xbb\xbf':
        raise LauncherError(f'Anything Analyzer config has a UTF-8 BOM, which the app cannot parse: {path}. Rewrite it without a BOM (bootstrap-reverse.ps1 does); the token was left untouched.')
    try:
        config = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, ValueError) as error:
        raise LauncherError(f'Anything Analyzer config is not valid JSON: {path} ({error})') from None
    if not isinstance(config, dict) or config.get('enabled') is not True:
        raise LauncherError(f'Anything Analyzer config has enabled != true: {path}. The app would not start its MCP server.')
    host = config.get('host', '<missing>')
    if host != '127.0.0.1':
        raise LauncherError(f"Anything Analyzer config host is '{host}', expected 127.0.0.1 (the app default binds 0.0.0.0): {path}")
    if config.get('port') != port:
        raise LauncherError(f"Anything Analyzer config port is '{config.get('port', '<missing>')}', expected {port}: {path}")
    token = config.get('authToken')
    if config.get('authEnabled') is not True or not isinstance(token, str) or not token.strip():
        raise LauncherError(f'Anything Analyzer config must have authEnabled=true and a non-empty authToken: {path}. An empty token makes the app generate a new one that no client knows.')
    if not candidates:
        raise LauncherError(f'{TOKEN_ENV} is not set in the process or User environment; clients could not authenticate to the backend.')
    for source, candidate in candidates:
        if candidate == token:
            if source != 'process environment':
                log(f'process {TOKEN_ENV} is stale or missing; using the matching value from the {source}')
            return token
    raise LauncherError(f'The authToken in {path} differs from {TOKEN_ENV} in both the process and User environment; clients would get HTTP 401. Re-run the bootstrap to realign them (no value is printed here).')


# --- startup -----------------------------------------------------------------------

class NamedMutex:
    """Windows named mutex shared with start-local-backend.ps1; a no-op elsewhere."""

    def __init__(self, name):
        self.name = name
        self.handle = None
        self.kernel32 = None

    def acquire(self, timeout_seconds):
        if os.name != 'nt':
            log('no named mutex on this platform; concurrent launches are not serialized')
            return True
        import ctypes
        import ctypes.wintypes as wintypes
        kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        kernel32.CreateMutexW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR)
        kernel32.WaitForSingleObject.restype = wintypes.DWORD
        kernel32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        handle = kernel32.CreateMutexW(None, False, self.name)
        if not handle:
            raise LauncherError(f'CreateMutexW failed with error {ctypes.get_last_error()}')
        self.kernel32 = kernel32
        self.handle = handle
        result = kernel32.WaitForSingleObject(handle, int(timeout_seconds * 1000))
        return result in (0x0, 0x80)  # WAIT_OBJECT_0 or WAIT_ABANDONED

    def release(self):
        if self.handle and self.kernel32:
            self.kernel32.ReleaseMutex(self.handle)
            self.kernel32.CloseHandle(self.handle)
            self.handle = None


def resolve_pnpm(explicit):
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise LauncherError(f'pnpm launcher not found: {path}')
        return str(path)
    found = shutil.which('pnpm')  # honours PATHEXT, so .cmd/.exe in PATH order and never the .ps1 shim
    if not found:
        raise LauncherError('pnpm was not found on PATH; pass --pnpm or install pnpm.')
    return found


def spawn_detached(pnpm, repo_dir, stdout_path, stderr_path):
    """`pnpm dev` must outlive this launcher: no inherited stdio, own process group, own job."""
    command = [pnpm, 'dev']
    kwargs = {'cwd': str(repo_dir), 'stdin': subprocess.DEVNULL, 'close_fds': True}
    if os.name == 'nt':
        base = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
        flag_sets = [base | subprocess.CREATE_BREAKAWAY_FROM_JOB, base]
    else:
        flag_sets = [None]
        kwargs['start_new_session'] = True
    last_error = None
    for flags in flag_sets:
        with open(stdout_path, 'ab') as out, open(stderr_path, 'ab') as err:
            try:
                if flags is not None:
                    return subprocess.Popen(command, stdout=out, stderr=err, creationflags=flags, **kwargs)
                return subprocess.Popen(command, stdout=out, stderr=err, **kwargs)
            except OSError as error:
                last_error = error
                log(f'spawn with flags {flags:#x} failed ({error}); retrying without CREATE_BREAKAWAY_FROM_JOB' if flags is not None else f'spawn failed: {error}')
    raise LauncherError(f'could not start pnpm dev: {last_error}')


def ensure_backend(args, candidates):
    """Return (token, health, process_record_or_None) with a verified listener."""
    if port_open(args.port):
        state, detail, token = probe_with_candidates(args.port, candidates)
        if state == 'ok':
            log(f'reusing healthy listener on 127.0.0.1:{args.port} ({detail})')
            return token, detail, None
        raise LauncherError(f'Port {args.port} is occupied but the expected {SERVER_NAME} API is unavailable ({detail}); existing processes were preserved.')

    repo_dir = Path(args.repo or (Path(os.environ.get('USERPROFILE', str(Path.home()))) / 'Tools' / 'anything-analyzer'))
    if not (repo_dir / 'package.json').is_file():
        raise LauncherError(f'Anything Analyzer checkout not found (no package.json): {repo_dir}')
    config_path = Path(args.config or (Path(os.environ.get('APPDATA', str(Path.home()))) / 'anything-analyzer' / 'mcp-server-config.json'))
    token = validate_config(config_path, args.port, candidates)
    pnpm = resolve_pnpm(args.pnpm)

    mutex = NamedMutex(f'Local\\reverse-skill-{BACKEND_LABEL}-{args.port}')
    if not mutex.acquire(min(args.wait, 30)):
        raise LauncherError(f'Another {BACKEND_LABEL} startup still owns port {args.port}; retry after it finishes.')
    try:
        if port_open(args.port):  # a sibling client started it while we waited for the mutex
            state, detail, used = probe_with_candidates(args.port, [('app config', token)])
            if state == 'ok':
                log(f'listener came up while waiting for the startup mutex ({detail})')
                return used, detail, None
            raise LauncherError(f'Port {args.port} opened during the mutex wait but is not a healthy {SERVER_NAME} ({detail}); existing processes were preserved.')

        log_dir = Path(args.log_dir or (Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'reverse-skill' / 'anything-analyzer'))
        log_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')[:-3]
        stdout_path = log_dir / f'{BACKEND_LABEL}-{stamp}.stdout.log'
        stderr_path = log_dir / f'{BACKEND_LABEL}-{stamp}.stderr.log'
        process = spawn_detached(pnpm, repo_dir, stdout_path, stderr_path)
        record = {'backend': BACKEND_LABEL, 'pid': process.pid, 'port': args.port, 'executable': pnpm,
                  'repo_dir': str(repo_dir), 'config_path': str(config_path),
                  'started_at': datetime.datetime.now().astimezone().isoformat(), 'sample_opened': False,
                  'launcher': 'anything-analyzer-stdio.py', 'detached': True}
        (log_dir / f'{BACKEND_LABEL}-{stamp}.process.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
        log(f'started pnpm dev (pid {process.pid}) in {repo_dir}; logs under {log_dir}')

        deadline = time.monotonic() + args.wait
        while True:
            if process.poll() is not None:
                raise LauncherError(f'{BACKEND_LABEL} launcher exited with code {process.returncode} before readiness; inspect {log_dir}.')
            if port_open(args.port):
                state, detail = probe(args.port, token)
                if state == 'ok':
                    log(f'listener ready on 127.0.0.1:{args.port} after {args.wait - (deadline - time.monotonic()):.1f} s ({detail})')
                    return token, detail, record
                if state != 'down':
                    # Port open but initialize fails: report it, never loop (upstream disconnect bug can wedge the app).
                    raise LauncherError(f'Port {args.port} is open but initialize failed ({detail}); pnpm dev pid {process.pid} was preserved. Inspect {log_dir}.')
            if time.monotonic() >= deadline:
                raise LauncherError(f'{BACKEND_LABEL} did not become ready on loopback port {args.port} within {args.wait} s. PID {process.pid} was preserved; inspect {log_dir}.')
            time.sleep(0.4)
    finally:
        mutex.release()


# --- proxy legs ----------------------------------------------------------------------

class ProxyJob:
    """Own the proxy subtree: a Windows Job Object with KILL_ON_JOB_CLOSE whose only handle lives
    in this launcher, so node -> cmd -> mcp-remote die together with it even on TerminateProcess
    (a client's timeout kill).

    The launcher assigns *itself* to the job right before it spawns the proxy, after the
    detached `pnpm dev` app already exists: every later descendant is a job member from its
    first instruction, so nothing can escape in the gap between CreateProcess and
    AssignProcessToJobObject (a venv python.exe redirector or npx.cmd spawns its real child in
    microseconds, which an assign-after-spawn would miss). The app, spawned earlier, is never a
    member. When nested-job assignment of the launcher is refused (pre-Windows 8 parent job
    without breakaway), the proxy child is assigned after spawn as a best effort."""

    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
    JobObjectExtendedLimitInformation = 9

    def __init__(self):
        self.handle = None
        self.kernel32 = None
        self.self_member = False

    def adopt(self, process=None):
        """process=None assigns the launcher itself; otherwise the given Popen child."""
        if os.name != 'nt':
            return False
        import ctypes
        import ctypes.wintypes as wintypes

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in
                        ('ReadOperationCount', 'WriteOperationCount', 'OtherOperationCount',
                         'ReadTransferCount', 'WriteTransferCount', 'OtherTransferCount')]

        class BasicLimit(ctypes.Structure):
            _fields_ = [('PerProcessUserTimeLimit', ctypes.c_longlong), ('PerJobUserTimeLimit', ctypes.c_longlong),
                        ('LimitFlags', wintypes.DWORD), ('MinimumWorkingSetSize', ctypes.c_size_t),
                        ('MaximumWorkingSetSize', ctypes.c_size_t), ('ActiveProcessLimit', wintypes.DWORD),
                        ('Affinity', ctypes.c_size_t), ('PriorityClass', wintypes.DWORD), ('SchedulingClass', wintypes.DWORD)]

        class ExtendedLimit(ctypes.Structure):
            _fields_ = [('BasicLimitInformation', BasicLimit), ('IoInfo', IoCounters),
                        ('ProcessMemoryLimit', ctypes.c_size_t), ('JobMemoryLimit', ctypes.c_size_t),
                        ('PeakProcessMemoryUsed', ctypes.c_size_t), ('PeakJobMemoryUsed', ctypes.c_size_t)]

        kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel32.CreateJobObjectW.restype = wintypes.HANDLE
        kernel32.CreateJobObjectW.argtypes = (wintypes.LPVOID, wintypes.LPCWSTR)
        kernel32.SetInformationJobObject.restype = wintypes.BOOL
        kernel32.SetInformationJobObject.argtypes = (wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD)
        kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
        kernel32.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
        kernel32.TerminateJobObject.restype = wintypes.BOOL
        kernel32.TerminateJobObject.argtypes = (wintypes.HANDLE, wintypes.UINT)
        kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        job = kernel32.CreateJobObjectW(None, None)
        if not job:
            log(f'CreateJobObjectW failed ({ctypes.get_last_error()}); proxy subtree is not owned')
            return False
        info = ExtendedLimit()
        info.BasicLimitInformation.LimitFlags = self.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel32.SetInformationJobObject(job, self.JobObjectExtendedLimitInformation, ctypes.byref(info), ctypes.sizeof(info)):
            log(f'SetInformationJobObject failed ({ctypes.get_last_error()}); proxy subtree is not owned')
            kernel32.CloseHandle(job)
            return False
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        target = kernel32.GetCurrentProcess() if process is None else wintypes.HANDLE(int(process._handle))
        if not kernel32.AssignProcessToJobObject(job, target):
            # Typically a parent job without BREAKAWAY/nesting (pre-Windows 8); the chain then
            # follows that parent job's rules instead.
            log(f'AssignProcessToJobObject({"self" if process is None else process.pid}) failed ({ctypes.get_last_error()}); proxy subtree is not owned')
            kernel32.CloseHandle(job)
            return False
        self.kernel32 = kernel32
        self.handle = job
        self.self_member = process is None
        return True

    def terminate_children(self):
        """Kill every member except the launcher. With self-membership TerminateJobObject would
        kill this process too, so the kill-on-close at process exit does that part instead."""
        if self.handle and self.kernel32 and not self.self_member:
            self.kernel32.TerminateJobObject(self.handle, 1)

    def close(self):
        if self.handle and self.kernel32 and not self.self_member:
            self.kernel32.CloseHandle(self.handle)  # KILL_ON_JOB_CLOSE finishes whatever is left
            self.handle = None


def install_termination_signals():
    """Turn the catchable termination signals into KeyboardInterrupt so the proxy child is
    terminated explicitly. TerminateProcess is not catchable; the job object covers that."""
    import signal

    def raise_interrupt(signum, frame):
        raise KeyboardInterrupt

    for name in ('SIGTERM', 'SIGBREAK', 'SIGINT'):
        number = getattr(signal, name, None)
        if number is not None:
            try:
                signal.signal(number, raise_interrupt)
            except (ValueError, OSError):
                pass


def npx_command():
    """node.exe + npx-cli.js directly: a quoted npx.cmd path plus a quoted --header value
    would trip cmd.exe's first/last-quote stripping rule."""
    override = os.environ.get('ANYTHING_ANALYZER_MCP_REMOTE_COMMAND', '')
    if override:
        # Test hook / local override: JSON argv prefix that stands in for `node npx-cli.js`.
        try:
            command = json.loads(override)
        except ValueError:
            raise LauncherError('ANYTHING_ANALYZER_MCP_REMOTE_COMMAND must be a JSON array of strings') from None
        if not isinstance(command, list) or not command or not all(isinstance(item, str) for item in command):
            raise LauncherError('ANYTHING_ANALYZER_MCP_REMOTE_COMMAND must be a JSON array of strings')
        return command
    node = shutil.which('node')
    if not node:
        raise LauncherError('node was not found on PATH; mcp-remote needs Node.js (or use --proxy relay).')
    cli = Path(node).resolve().parent / 'node_modules' / 'npm' / 'bin' / 'npx-cli.js'
    if cli.is_file():
        return [node, str(cli)]
    npx = shutil.which('npx')
    if npx and Path(npx).suffix.lower() == '.exe':
        return [npx]
    if npx:
        # Batch shim: let cmd.exe keep every quote by wrapping the whole line once more.
        return ['cmd.exe', '/d', '/s', '/c', npx]
    raise LauncherError('npx was not found next to node or on PATH; use --proxy relay.')


def run_mcp_remote(args, token, mcp_fd):
    command = npx_command()
    wrapped = command[0].lower() == 'cmd.exe'
    tail = ['-y', f'mcp-remote@{args.mcp_remote_version}', f'http://127.0.0.1:{args.port}/mcp',
            '--transport', 'http-only', '--header', 'Authorization:Bearer ${' + TOKEN_ENV + '}']
    if wrapped:
        line = subprocess.list2cmdline(command[4:] + tail)
        command = command[:4] + [f'"{line}"']
    else:
        command = command + tail
    env = dict(os.environ)
    env[TOKEN_ENV] = token  # mcp-remote expands ${VAR} itself; the value never reaches the command line
    log(f'proxy: mcp-remote@{args.mcp_remote_version} -> http://127.0.0.1:{args.port}/mcp')
    job = ProxyJob()
    owned = job.adopt()  # the launcher joins first; pnpm dev (if any) was spawned before this point
    child = subprocess.Popen(command, stdin=sys.stdin.fileno(), stdout=mcp_fd, stderr=sys.stderr.fileno(), env=env)
    if not owned:
        owned = job.adopt(child)
    if owned:
        log(f'proxy subtree (pid {child.pid}) owned by a kill-on-close job object ({"launcher is a member" if job.self_member else "child assigned after spawn"})')
    try:
        while True:
            # A timed wait returns to the interpreter periodically; an infinite
            # WaitForSingleObject would never let the SIGBREAK/SIGINT handler run on Windows.
            try:
                return child.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                continue
    except (KeyboardInterrupt, SystemExit):
        log('terminating the proxy subtree')
        child.terminate()
        job.terminate_children()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        return 130  # process exit closes the job handle; KILL_ON_JOB_CLOSE ends the grandchildren
    finally:
        job.close()


def run_relay(args, token, mcp_fd):
    """Minimal JSON-RPC relay: one POST per stdin frame, SSE/JSON answers written as one line."""
    out = os.fdopen(mcp_fd, 'wb', buffering=0)
    session_id = None
    log(f'proxy: built-in relay -> http://127.0.0.1:{args.port}/mcp (no standalone GET stream)')

    def emit(message):
        out.write(json.dumps(message, separators=(',', ':')).encode('utf-8') + b'\n')

    for raw in sys.stdin.buffer:
        raw = raw.strip()
        if not raw:
            continue
        try:
            message = json.loads(raw.decode('utf-8'))
        except ValueError:
            emit({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error'}})
            continue
        frames = message if isinstance(message, list) else [message]
        expects_reply = any(isinstance(frame, dict) and 'method' in frame and 'id' in frame for frame in frames)
        request_id = next((frame.get('id') for frame in frames if isinstance(frame, dict) and 'id' in frame), None)
        try:
            status, new_session, reply = mcp_post(args.port, token, message, session_id=session_id, timeout=args.relay_timeout)
            if new_session:
                session_id = new_session
            if expects_reply and reply is not None:
                emit(reply)
            elif expects_reply:
                emit({'jsonrpc': '2.0', 'id': request_id, 'error': {'code': -32000, 'message': f'backend returned HTTP {status} without a body'}})
        except urllib.error.HTTPError as error:
            body = error.read().decode('utf-8', 'replace')
            if expects_reply:
                emit({'jsonrpc': '2.0', 'id': request_id, 'error': {'code': -32000, 'message': f'backend HTTP {error.code}: {body[:200]}'}})
            else:
                log(f'backend HTTP {error.code} for a notification: {body[:200]}')
        except (urllib.error.URLError, OSError, ValueError) as error:
            if expects_reply:
                emit({'jsonrpc': '2.0', 'id': request_id, 'error': {'code': -32000, 'message': f'backend unreachable: {error}'}})
            else:
                log(f'backend unreachable for a notification: {error}')
    if session_id:
        close_session(args.port, token, session_id)
    return 0


# --- main ----------------------------------------------------------------------------

def parse_args(argv):
    parser = argparse.ArgumentParser(description='Start/reuse Anything Analyzer and bridge MCP stdio to it.')
    parser.add_argument('--port', type=int, default=int(os.environ.get('ANYTHING_ANALYZER_MCP_PORT', DEFAULT_PORT)))
    parser.add_argument('--repo', default=os.environ.get('ANYTHING_ANALYZER_REPO', ''), help='checkout with package.json (default %%USERPROFILE%%\\Tools\\anything-analyzer)')
    parser.add_argument('--config', default=os.environ.get('ANYTHING_ANALYZER_MCP_CONFIG', ''), help='mcp-server-config.json (default %%APPDATA%%\\anything-analyzer\\...)')
    parser.add_argument('--pnpm', default=os.environ.get('ANYTHING_ANALYZER_PNPM', ''), help='pnpm launcher (default: first pnpm on PATH)')
    parser.add_argument('--log-dir', default=os.environ.get('ANYTHING_ANALYZER_LOG_DIR', ''), help='default %%LOCALAPPDATA%%\\reverse-skill\\anything-analyzer')
    parser.add_argument('--wait', type=float, default=float(os.environ.get('ANYTHING_ANALYZER_WAIT_SECONDS', 90)), help='seconds to wait for readiness (client startup timeouts still apply)')
    parser.add_argument('--proxy', choices=('mcp-remote', 'relay'), default=os.environ.get('ANYTHING_ANALYZER_PROXY', 'mcp-remote'))
    parser.add_argument('--mcp-remote-version', default=os.environ.get('ANYTHING_ANALYZER_MCP_REMOTE_VERSION', MCP_REMOTE_VERSION))
    parser.add_argument('--relay-timeout', type=float, default=120.0)
    parser.add_argument('--check-only', action='store_true', help='ensure the backend, print the health JSON to stderr, exit without a proxy')
    return parser.parse_args(argv)


def main(argv=None):
    mcp_fd = park_stdout()
    install_termination_signals()
    repaired = repair_environment()
    if repaired:
        log('restricted client environment: filled ' + ', '.join(repaired) + ' from the registry/defaults')
    args = parse_args(argv)
    try:
        candidates = token_candidates()
        token, health, record = ensure_backend(args, candidates)
        if args.check_only:
            log(json.dumps({'backend': BACKEND_LABEL, 'port': args.port, 'reused': record is None, 'health': health}))
            return 0
        if args.proxy == 'relay':
            return run_relay(args, token, mcp_fd)
        return run_mcp_remote(args, token, mcp_fd)
    except LauncherError as error:
        log(f'ERROR: {error}')
        return 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
