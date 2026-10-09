"""Demand-only MCP stdio gateway. Transport failures require client reconnection.

Standard library only. Local handshake/catalog requests never spawn the original
command. A Windows lifetime job owns the whole child tree from its first instruction;
Unix children use a separate process group. No action is automatically replayed.
"""

import argparse
import json
import math
import os
import queue
import signal
import subprocess
import sys
import threading
import time

_BACKEND = None  # Keep Popen/pipe objects alive until direct OS process teardown.


class TransportError(Exception):
    """Sanitized transport failure; the wrapper must exit to end its owned tree."""


class InputClosed(Exception):
    pass


def diagnostic(label, action, child=None):
    # The label is caller-supplied metadata, not backend output or command arguments.
    label = ''.join(c for c in label if c.isalnum() or c in '-_.')[:80]
    print(f'[lazy-stdio] server={label} wrapper_pid={os.getpid()} {action}'
          + (f' child_pid={child.pid}' if child else ''), file=sys.stderr, flush=True)


def own_windows_lifetime():
    """Join KILL_ON_JOB_CLOSE before spawning; refusal must never fall back to Popen.

    Keep this handle open until process exit. Explicitly closing it would also kill
    the wrapper itself, so OS process teardown performs the final tree cleanup.
    """
    import ctypes
    from ctypes import wintypes

    class IoCounters(ctypes.Structure):
        _fields_ = [(key, ctypes.c_ulonglong) for key in (
            'ReadOperationCount', 'WriteOperationCount', 'OtherOperationCount',
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

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateJobObjectW.argtypes = (wintypes.LPVOID, wintypes.LPCWSTR)
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = (wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD)
    kernel.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    handle = kernel.CreateJobObjectW(None, None)
    if not handle:
        raise TransportError('Could not create child ownership job.')
    limits = ExtendedLimit()
    limits.BasicLimitInformation.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if (not kernel.SetInformationJobObject(handle, 9, ctypes.byref(limits), ctypes.sizeof(limits))
            or not kernel.AssignProcessToJobObject(handle, kernel.GetCurrentProcess())):
        kernel.CloseHandle(handle)
        raise TransportError('Could not guarantee child tree ownership; command was not started.')
    return handle


def read_lines(fd, destination, eof=None, parse=False):
    """Raw fd reads avoid buffered-file locks held by daemon threads during shutdown."""
    pending = b''
    try:
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            pending += chunk
            while b'\n' in pending:
                raw, pending = pending.split(b'\n', 1)
                if parse:
                    try:
                        frame = json.loads(raw, parse_constant=int)
                    except (ValueError, UnicodeError):
                        continue  # Startup diagnostics are not MCP; never echo their text.
                    destination.put(frame)
                else:
                    destination.put(raw)
        if pending and not parse:
            destination.put(pending)
    except OSError:
        pass
    finally:
        if eof is not None:
            eof.set()
        destination.put(None)


def drain_stderr(fd):
    try:
        while os.read(fd, 65536):
            pass  # Backend diagnostics can contain secrets; do not echo or save them.
    except OSError:
        pass


def write_frame(fd, frame, deadline, eof):
    """One serialized write with an interruptible wait, including upstream output."""
    data = (json.dumps(frame, separators=(',', ':'), ensure_ascii=False) + '\n').encode('utf-8')
    complete = queue.Queue()
    def write():
        try:
            remaining = memoryview(data)
            while remaining:
                count = os.write(fd, remaining)
                if count <= 0:
                    raise OSError
                remaining = remaining[count:]
            complete.put(True)
        except OSError:
            complete.put(False)
    threading.Thread(target=write, daemon=True).start()
    while True:
        if eof.is_set():
            raise InputClosed
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TransportError('Pipe write timed out; reconnect before retrying.')
        try:
            success = complete.get(timeout=min(.05, remaining))
        except queue.Empty:
            continue
        if not success:
            raise TransportError('Pipe closed.')
        return


class Backend:
    def __init__(self, args, eof):
        self.args, self.eof = args, eof
        self.process = None
        self.frames = queue.Queue()
        self.next_id = 0
        self.server_info = None
        self.job_handle = None

    def send(self, frame, deadline):
        write_frame(self.process.stdin.fileno(), frame, deadline, self.eof)

    def request(self, method, params, deadline):
        self.next_id += 1
        request_id = self.next_id
        self.send({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params}, deadline)
        while True:
            if self.eof.is_set():
                raise InputClosed
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TransportError('Backend request timed out; reconnect before retrying.')
            try:
                frame = self.frames.get(timeout=min(.05, remaining))
            except queue.Empty:
                continue
            if frame is None:
                raise TransportError('Backend exited or closed its output.')
            if not isinstance(frame, dict) or frame.get('jsonrpc') != '2.0':
                raise TransportError('Backend returned an invalid protocol message.')
            if 'method' in frame:
                if not isinstance(frame['method'], str):
                    raise TransportError('Backend returned an invalid method.')
                if 'id' in frame:
                    if not isinstance(frame['id'], (str, int)) or isinstance(frame['id'], bool):
                        raise TransportError('Backend returned an invalid callback ID.')
                    response = {'jsonrpc': '2.0', 'id': frame['id']}
                    if frame['method'] == 'ping':
                        response['result'] = {}
                    else:
                        response['error'] = {'code': -32601, 'message': 'Method not found'}
                    self.send(response, deadline)
                continue  # Notifications do not extend the request's deadline.
            if (frame.get('id') != request_id or isinstance(frame.get('id'), bool)
                    or ('result' in frame) == ('error' in frame)):
                raise TransportError('Backend response could not be correlated.')
            if 'error' in frame:
                error = frame['error']
                if (not isinstance(error, dict) or not isinstance(error.get('code'), int)
                        or isinstance(error['code'], bool) or not isinstance(error.get('message'), str)):
                    raise TransportError('Backend returned an invalid error response.')
            elif not isinstance(frame['result'], dict):
                raise TransportError('Backend returned an invalid result.')
            return frame

    def start(self):
        if self.process is not None:
            return
        if self.eof.is_set():
            raise InputClosed
        if os.name == 'nt':
            self.job_handle = own_windows_lifetime()
        deadline = time.monotonic() + self.args.startup_timeout
        try:
            self.process = subprocess.Popen(self.args.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, close_fds=True, start_new_session=os.name != 'nt',
                                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        except (OSError, ValueError):
            raise TransportError('Original backend command could not be started.') from None
        diagnostic(self.args.server_name, 'started', self.process)
        threading.Thread(target=read_lines, args=(self.process.stdout.fileno(), self.frames, None, True), daemon=True).start()
        threading.Thread(target=drain_stderr, args=(self.process.stderr.fileno(),), daemon=True).start()
        reply = self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                              'clientInfo': {'name': 'reverse-skill-lazy-stdio', 'version': '1.0'}}, deadline)
        result = reply.get('result', {})
        info = result.get('serverInfo')
        if (not isinstance(info, dict) or not all(isinstance(info.get(k), str) for k in ('name', 'version'))
                or result.get('protocolVersion') not in ('2024-11-05', '2025-03-26', '2025-11-25')
                or not isinstance(result.get('capabilities'), dict)):
            raise TransportError('Backend initialization failed protocol negotiation.')
        self.server_info = info
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'}, deadline)

    def close(self):
        if self.process is None:
            return
        diagnostic(self.args.server_name, 'closing', self.process)
        if os.name != 'nt':
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=5)
        # Windows process exit closes the lifetime job, including grandchildren.


def rpc_error(request_id, code, message):
    return {'jsonrpc': '2.0', 'id': request_id, 'error': {'code': code, 'message': message}}


def tool_error(message):
    return {'content': [{'type': 'text', 'text': message}], 'isError': True}


def gateway_tools(label):
    return [
        {'name': 'discover_tools', 'description': f'Discover {label} tools before calling call_tool. Starts the original backend command on demand and returns its server information, tool names, descriptions, schemas and annotations.',
         'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}},
        {'name': 'call_tool', 'description': f'Call a {label} tool using the name and arguments obtained from discover_tools. Review its description and schema first. Starts the backend on demand and may execute actions or modify state. Transport failure requires reconnecting; actions are never automatically replayed.',
         'inputSchema': {'type': 'object', 'properties': {'name': {'type': 'string', 'minLength': 1}, 'arguments': {'type': 'object'}},
                         'required': ['name', 'arguments'], 'additionalProperties': False}},
    ]


def run(args):
    global _BACKEND
    incoming, eof = queue.Queue(), threading.Event()
    threading.Thread(target=read_lines, args=(sys.stdin.fileno(), incoming, eof), daemon=True).start()
    backend = Backend(args, eof)
    _BACKEND = backend
    tools = gateway_tools(args.server_name)
    try:
        while True:
            raw = incoming.get()
            if raw is None:
                return 0
            fatal = False
            output_deadline = time.monotonic() + args.tool_timeout
            try:
                frame = json.loads(raw, parse_constant=int)
            except (ValueError, UnicodeError):
                reply = rpc_error(None, -32700, 'Parse error')
            else:
                if (not isinstance(frame, dict) or frame.get('jsonrpc') != '2.0'
                        or not isinstance(frame.get('method'), str)
                        or ('id' in frame and (not isinstance(frame['id'], (str, int, float, type(None))) or isinstance(frame['id'], bool)))):
                    reply = rpc_error(None, -32600, 'Invalid request')
                else:
                    rid, method, params = frame.get('id'), frame['method'], frame.get('params', {})
                    result = None
                    reply = rpc_error(rid, -32602, 'Invalid params')
                    valid_meta = isinstance(params, dict) and ('_meta' not in params or isinstance(params['_meta'], dict))
                    if valid_meta:
                        if method == 'initialize':
                            if (isinstance(params.get('protocolVersion'), str) and isinstance(params.get('capabilities'), dict)
                                    and isinstance(params.get('clientInfo'), dict)
                                    and all(isinstance(params['clientInfo'].get(k), str) for k in ('name', 'version'))):
                                protocol = params['protocolVersion']
                                if protocol not in ('2024-11-05', '2025-03-26', '2025-11-25'):
                                    protocol = '2024-11-05'
                                result = {'protocolVersion': protocol, 'capabilities': {'tools': {'listChanged': False}},
                                          'serverInfo': {'name': args.server_name, 'version': '1.0'},
                                          'instructions': f'Discover {args.server_name} tools before using call_tool. Backend startup happens only on valid tool demand. Reconnect after transport failure; review each discovered tool schema and annotations.'}
                        elif method in ('ping', 'tools/list', 'notifications/initialized'):
                            if not set(params) - {'_meta'}:
                                result = {'tools': tools} if method == 'tools/list' else {}
                        elif method == 'tools/call':
                            name, arguments = params.get('name'), params.get('arguments', {})
                            valid = isinstance(arguments, dict) and not set(params) - {'name', 'arguments', '_meta'}
                            if name == 'discover_tools':
                                valid = valid and not arguments
                            elif name == 'call_tool':
                                valid = (valid and set(arguments) == {'name', 'arguments'} and isinstance(arguments.get('name'), str)
                                         and bool(arguments['name'].strip()) and isinstance(arguments.get('arguments'), dict))
                            else:
                                valid = False
                            if valid and 'id' in frame:
                                try:
                                    backend.start()
                                    deadline = time.monotonic() + args.tool_timeout
                                    output_deadline = deadline
                                    meta = {'_meta': params['_meta']} if '_meta' in params else {}
                                    if name == 'discover_tools':
                                        discovered, cursors, page_params = [], set(), dict(meta)
                                        while True:
                                            response = backend.request('tools/list', page_params, deadline)
                                            if 'error' in response:
                                                result = tool_error('Backend discovery returned a JSON-RPC error.')
                                                break
                                            page = response['result']
                                            if not isinstance(page.get('tools'), list) or not all(isinstance(t, dict) for t in page['tools']):
                                                raise TransportError('Backend returned an invalid tool catalog.')
                                            discovered.extend(page['tools'])
                                            cursor = page.get('nextCursor')
                                            if cursor is None:
                                                result = {'content': [{'type': 'text', 'text': json.dumps({'serverInfo': backend.server_info, 'tools': discovered}, ensure_ascii=False)}]}
                                                break
                                            if not isinstance(cursor, str) or not cursor or cursor in cursors:
                                                raise TransportError('Backend returned invalid pagination.')
                                            cursors.add(cursor)
                                            page_params['cursor'] = cursor
                                    else:
                                        response = backend.request('tools/call', {**arguments, **meta}, deadline)
                                        result = response.get('result') if 'result' in response else tool_error('Backend tool returned a JSON-RPC error.')
                                except TransportError as error:
                                    result = tool_error(str(error) + ' The gateway is closing; reconnect before retrying. No action was replayed.')
                                    fatal = True
                                    output_deadline = time.monotonic() + min(args.tool_timeout, 1.0)
                        else:
                            reply = rpc_error(rid, -32601, 'Method not found')
                    if result is not None:
                        reply = {'jsonrpc': '2.0', 'id': rid, 'result': result}
                    if 'id' not in frame:
                        reply = None
            if reply is not None:
                try:
                    write_frame(sys.stdout.fileno(), reply, output_deadline, eof)
                except TransportError:
                    return 1  # Upstream output failed; no recursive attempt to emit an error.
            if fatal:
                return 1
    except InputClosed:
        return 0
    finally:
        backend.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server-name', required=True)
    parser.add_argument('--startup-timeout', type=float, default=30)
    parser.add_argument('--tool-timeout', type=float, default=60)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ['--']:
        args.command = args.command[1:]
    if (not args.command or not all(math.isfinite(t) and t > 0 for t in (args.startup_timeout, args.tool_timeout))):
        parser.error('a backend command and positive timeouts are required')
    def stop(signum, frame):
        raise KeyboardInterrupt
    for name in ('SIGINT', 'SIGTERM', 'SIGBREAK'):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), stop)
    try:
        return run(args)
    except (KeyboardInterrupt, BrokenPipeError):
        return 130


if __name__ == '__main__':
    status = main()
    # Daemon fd readers/writers may still be blocked in a child pipe. Do not let
    # interpreter finalization delay the OS teardown that closes our lifetime job.
    os._exit(status)
