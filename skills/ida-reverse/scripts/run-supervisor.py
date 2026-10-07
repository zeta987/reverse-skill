"""Hidden idalib backend launcher with file logging.

Started via pythonw so no console window appears. stdout/stderr and the
logging module both go to %LOCALAPPDATA%\\reverse-skill\\ida-mcp\\supervisor.log.

Runs whichever headless backend the installed ida-pro-mcp provides:
``ida_pro_mcp.idalib_supervisor`` (older builds) or ``ida_pro_mcp.idalib_server``
(2.0.0, which has no supervisor module). Command-line arguments
(--host/--port/--unsafe) are passed through unchanged.
"""

from __future__ import annotations

import importlib
import importlib.util
import os
import sys
from datetime import datetime
from pathlib import Path

BACKEND_MODULES = ("ida_pro_mcp.idalib_supervisor", "ida_pro_mcp.idalib_server")


def _log_path() -> Path:
    root = Path(os.environ.get("LOCALAPPDATA") or ".") / "reverse-skill" / "ida-mcp"
    root.mkdir(parents=True, exist_ok=True)
    return root / "supervisor.log"


def _rotate(path: Path, max_bytes: int = 5 * 1024 * 1024) -> None:
    if path.exists() and path.stat().st_size > max_bytes:
        bak = path.with_name(path.name + ".1")
        if bak.exists():
            bak.unlink()
        path.replace(bak)


def detect_backend_module() -> str:
    """Return the first available backend module name, or '' when none is installed."""
    if importlib.util.find_spec("ida_pro_mcp") is None:
        return ""
    for name in BACKEND_MODULES:
        if importlib.util.find_spec(name) is not None:
            return name
    return ""


def main() -> None:
    log_path = _log_path()
    _rotate(log_path)
    log_fp = open(log_path, "a", encoding="utf-8", buffering=1, errors="replace")
    sys.stdout = log_fp
    sys.stderr = log_fp
    print(
        f"==== start {datetime.now():%Y-%m-%d %H:%M:%S} pid={os.getpid()} ====",
        flush=True,
    )

    module_name = detect_backend_module()
    if not module_name:
        print("ERR: ida_pro_mcp provides neither idalib_supervisor nor idalib_server", flush=True)
        sys.exit(2)
    print(f"backend module: {module_name}", flush=True)

    # Import the backend first: 2.0.0's idalib_server loads idapro and then
    # ida_pro_mcp.ida_mcp (which needs IDA symbols), so its zeromcp copy only becomes
    # importable afterwards. serve() resolves HTTPServer at call time, so patching
    # between import and main() is sufficient.
    backend = importlib.import_module(module_name)
    try:
        _patch_streamable_http(module_name)
    except Exception as exc:
        print(f"WARN: streamable-http patch skipped: {exc}", flush=True)

    backend.main()


def _load_zeromcp(module_name: str):
    """Locate the vendored zeromcp HTTP module for the installed layout.

    2.0.0 ships it as the package ida_pro_mcp.ida_mcp.zeromcp (mcp.py inside);
    older builds vendor it under site-packages/ida_pro_mcp/ida_mcp/zeromcp and
    import it as a top-level ``zeromcp`` through sys.path.
    """
    for candidate in ("ida_pro_mcp.ida_mcp.zeromcp.mcp", "ida_pro_mcp.ida_mcp.mcp"):
        if candidate in sys.modules:
            return sys.modules[candidate]
        try:
            return importlib.import_module(candidate)
        except Exception:
            continue
    backend_spec = importlib.util.find_spec(module_name)
    if backend_spec is None or not backend_spec.origin:
        raise RuntimeError(f"cannot locate {module_name}")
    zm_dir = Path(backend_spec.origin).resolve().parent / "ida_mcp"
    sys.path.insert(0, str(zm_dir))
    try:
        return importlib.import_module("zeromcp.mcp")
    finally:
        sys.path.remove(str(zm_dir))


def _patch_streamable_http(module_name: str) -> None:
    """HTTP MCP clients use Streamable HTTP on /mcp.

    Both backends serve with background=False -> HTTPServer (one request at a
    time). A GET /sse or GET /mcp that stays open then makes tools/list hang, and
    the client marks the server error. Swapping in ThreadingHTTPServer is safe for
    every known layout. The GET /mcp handler is only replaced for the legacy
    supervisor, whose handler returned 405; the 2.0.0 handler already streams.
    """
    import select
    import socket
    import time
    import uuid
    from urllib.parse import urlparse

    zm = _load_zeromcp(module_name)
    zm.HTTPServer = zm.ThreadingHTTPServer

    if module_name != "ida_pro_mcp.idalib_supervisor":
        return

    orig_get = zm.McpHttpRequestHandler.do_GET

    def do_get(self):
        if not self._check_api_request():
            return
        if urlparse(self.path).path != "/mcp":
            return orig_get(self)

        session_id = self.headers.get("Mcp-Session-Id") or str(uuid.uuid4())
        self.mcp_server.register_http_session(session_id)
        conn = zm._McpSseConnection(self.wfile)
        self.mcp_server._sse_connections[conn.session_id] = conn
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Mcp-Session-Id", session_id)
            self.send_cors_headers()
            self.end_headers()
            sock = self.connection
            if sock and hasattr(sock, "settimeout"):
                try:
                    sock.settimeout(1.0)
                except OSError:
                    pass
            last_ping = time.time()
            while conn.alive and self.mcp_server._running:
                now = time.time()
                if sock:
                    try:
                        readable, _, _ = select.select([sock], [], [], 1.0)
                        if readable and sock.recv(1, socket.MSG_PEEK) == b"":
                            break
                    except (OSError, socket.error, ConnectionResetError, BrokenPipeError):
                        break
                else:
                    time.sleep(1.0)
                if now - last_ping >= 30:
                    try:
                        conn.send_event("ping", "")
                    except (OSError, BrokenPipeError):
                        break
                    last_ping = now
        finally:
            conn.alive = False
            self.mcp_server._sse_connections.pop(conn.session_id, None)

    zm.McpHttpRequestHandler.do_GET = do_get


if __name__ == "__main__":
    main()
