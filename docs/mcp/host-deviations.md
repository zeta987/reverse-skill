# Windows host deviations and backend runbook (private fork)

This repository is a personal fork. **Never open pull requests or issues against
the upstream project from this fork.** Record every divergence from
`skills/scripts/bootstrap-manifest.json` or `bootstrap-reverse.ps1` here and fix
the manifest/bootstrap in the fork instead of working around it silently.

Last verified: 2026-10-08 on Windows 11 (Python 3.14 system, uv 0.12, Node 24,
Go 1.27, Gradle 9.3, JDK 21, VS Community 2026).

## Deviations from the manifest (install batch 2026-10-08)

| Capability | Manifest says | What was actually done | Why |
|---|---|---|---|
| binwalk | winget `ReFirmLabs.binwalk` | `cargo install binwalk` → 3.1.0 in `~/.cargo/bin` | The winget ID does not exist |
| pwntools | `pip install pwntools==4.15.0` into system Python | `uv tool install --python 3.13 pwntools==4.15.0` → `pwn` in `~/.local/bin` | `unicorn` has no wheel for Python 3.14; the local cmake build fails |
| bkcrack | github-release-zip, `preferApiDigest` | Downloaded with `gh release download`, SHA-256 checked against the API digest, extracted by hand into `%USERPROFILE%\Tools\bkcrack` | Bootstrap threw `The property 'Count' cannot be found` after the digest check and extracted nothing |
| seclists | git-clone at pinned commit | `git fetch --depth 1 <pinned>` with `-c core.autocrlf=false`; 11 payload files (EICAR, zip bombs, web shells) were removed by Defender and must not be restored | System-level `core.autocrlf=true` made the fresh checkout look dirty, so bootstrap refused it |
| proxycat | git-clone + manual pip | Dependencies in `%USERPROFILE%\Tools\ProxyCat\.venv` (uv, Python 3.13); launcher `%USERPROFILE%\Tools\bin\proxycat.bat` | `postInstallSteps` are never executed by any script |
| anything-analyzer | local-http-mcp, auto | **Not installed.** | `Test-VsBuildToolsInstalled` only checks the VS 2022 BuildTools folders and would winget-install them although VS 2026 with VC tools is present |
| pentestswarm | go-install + MCP | Installed, **not registered** in any client | `pentestswarm doctor` requires its API server (8080), Redis, Docker and Ollama first |
| idapro (HTTP) | register `http://127.0.0.1:13337/mcp` | Not registered; the stdio proxy `ida-pro-mcp` already targets the same backend | Double registration of one backend is what `docs/mcp/codex.md` warns against |

Status after the 2026-10-08 fork fixes (branch `dev/windows-mcp-clients`):

| Deviation | Fork change |
|---|---|
| binwalk | manifest `bootstrapKind: cargo-install`, `cargoCrate: binwalk`, `pinnedVersion: 3.1.0`; bootstrap runs `cargo install --locked binwalk --version 3.1.0`, tool index probes `~\.cargo\bin\binwalk.exe` |
| pwntools | `verifyCommand: pwn`, `uvPython: "3.13"`; bootstrap prefers `uv tool install --python 3.13 pwntools==4.15.0`, index probes `~\.local\bin\pwn.exe` |
| bkcrack | `Expand-ArchiveIntoDirectory` wraps `Get-ChildItem` in `@()`; the single-top-directory zip now extracts under `Set-StrictMode` |
| seclists | `Ensure-GitCloneInstall` runs `git -c core.autocrlf=false` for init/fetch/checkout/status and persists `core.autocrlf=false` in the checkout. The existing host checkout stays dirty (16 status entries with and without the flag) because Defender removed payload files; do not restore them. The existing ProxyCat checkout reports clean both ways, so older checkouts are not regressed by the flag |
| proxycat | `postInstallSteps` are now emitted as `[post-install]` warnings and in the results JSON (`post_install_steps`); the dependency install itself is still manual |
| anything-analyzer | `Test-VsBuildToolsInstalled` asks `vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64` first, so VS 2026 Community counts. Three more defects surfaced on the first real run and were fixed: (a) `mcp-server-config.json` was written with a UTF-8 BOM (`Set-Content -Encoding utf8` on Windows PowerShell 5.1); the app's `JSON.parse(readFileSync(path,'utf-8'))` threw, it fell back to `enabled=false` and generated a fresh token, so the server never started and `ANYTHING_ANALYZER_MCP_TOKEN` no longer matched. Now written with `WriteAllText` + `UTF8Encoding($false)`. (b) The file omitted `host`; the app default `DEFAULT_MCP_LISTEN_HOST` is `0.0.0.0`. Now `"host": "127.0.0.1"` is explicit. (c) `pnpm rebuild electron esbuild better-sqlite3` rebuilt better-sqlite3 for the Node ABI via pnpm's node-gyp 9.4.1, which fails on VS 2026 (`find VS unknown version 'undefined'`) and first wipes `build/Release`, destroying the Electron-ABI prebuilt. Now `pnpm rebuild electron esbuild` then `pnpm exec electron-builder install-app-deps`, and the install fails closed unless `node_modules/.pnpm/better-sqlite3@*/node_modules/better-sqlite3/build/Release/better_sqlite3.node` exists |
| idapro (HTTP) | unchanged: still a second alias of the stdio-proxied backend |
| burpsuite-mcp | manifest now registers the stdio bridge `node <repo>\burp-mcp-full\mcp-bridge.js` instead of `http://localhost:9876/mcp` |
| ghidra-mcp | manifest describes the GhydraMCP path (user extension, loopback patch, `ghydra-stdio.py`, REST from 8192) instead of LaurieWired 8765 |

Registration scope: `bootstrap-reverse.ps1 -McpHostTarget Claude|Codex|Antigravity|Both|All`
now writes the project-scope files listed below (`-McpScope Project`, default). Claude Code
never read `%USERPROFILE%\.claude\mcp.json`; `-McpScope User` goes through
`claude mcp add-json --scope user` instead.

## Client registration mirror

All four files carry the same server set and are gitignored because they embed
this machine's absolute paths.

| Client | File | Servers |
|---|---|---|
| Codex CLI | `.codex/config.toml` (project scope, repo is trusted) | ida-pro-mcp, Ghidra-mcp, x64dbg-mcp, math-mcp, r2mcp, jshook, xquik, anything-analyzer (stdio launcher, see below) |
| Claude Code | `.mcp.json` + `.claude/settings.local.json` (`enabledMcpjsonServers`) | same eight; every stdio entry carries `"type": "stdio"` |
| Antigravity | `.agents/mcp_config.json` (`mcpServers`, no `cwd` field) | same eight; `xquik` as `serverUrl` |
| dsh web | `.dsh/agent-presets/reverse-skill/agent.cordis.yml` | ida-pro, ghidra, x64dbg, math, r2, jshook, anything-analyzer (xquik not added: http transport unverified) |

`r2mcp` and `jshook` answer `server/discover` with `-32601` natively, so they do not
need the `legacy-mcp-stdio.py` wrapper that the Python `mcp==1.6.0` bridges need.
`xquik` needs an OAuth login once per client (`/mcp` in Claude Code,
`codex mcp login xquik`); no credential lives in these files.

## Backend runbook (the configs start bridges, not backends)

### IDA (ida-pro-mcp 2.0.0, idalib headless)

The installed `ida_pro_mcp` 2.0.0 has `idalib_server` but **no `idalib_supervisor`**.
`skills/ida-reverse/scripts/start.ps1` now detects the module per interpreter and falls
back to `idalib_server --host 127.0.0.1 --port 13337 --unsafe`, and
`Get-ManagedSupervisorProcessIds` enumerates `Win32_Process` once (about 1.3 s here
instead of one WMI query per process); `watchdog.ps1` / `install-autostart.ps1` inherit
both fixes because they only call `start.ps1`. The supported path for this host remains:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\scripts\mcp\start-local-backend.ps1 `
  -Backend Ida -Executable C:\Python314\python.exe `
  -IdaDir "C:\Program Files\IDA Professional 9.0" `
  -LogDir "$env:LOCALAPPDATA\reverse-skill\ida-mcp" -WaitSeconds 60
```

Requires User env `IDADIR=C:\Program Files\IDA Professional 9.0`. Verified
2026-10-08: 42 tools on `127.0.0.1:13337`; the Claude Code proxy reported connected.
Codex uses the identical proxy command line but was not exercised live.
The backend is a plain process; it does not survive logoff.

The earlier observation that the script "ran past 120 s although the backend was
healthy within seconds" was **not reproduced** after the fork fixes: the reuse path
returns in about 1 s under both Windows PowerShell 5.1 and pwsh 7, and the fixture
test `skills/scripts/test-mcp-backend-start.py` shows the new-start path returning in
about 1.3 s. The health probe now uses a direct `HttpWebRequest` with `Proxy = $null`
(Windows PowerShell's `Invoke-RestMethod` can stall on proxy auto-detection), and the
JSON output carries `elapsed_ms` so a future stall can be attributed.

### Ghidra (GhydraMCP v2.2.0-rc.2, loopback-patched)

Installed user extension: `%APPDATA%\ghidra\ghidra_12.0.2_PUBLIC\Extensions\GhydraMCP`
with the loopback-patched JAR (SHA-256
`EBFC739EE6B9A4B3C1638E2622007CBDD0F4EA901BD00D968D0D5DEC905F10DA`, see
`docs/mcp/patches/ghydra-v2.2.0-rc2-loopback.patch`). Its `extension.properties`
still says `ghidraVersion=11.4.2`; Ghidra 12.0.2 loads it anyway (confirmed in
`application.log` on 2026-09-20; on 2026-10-08 via `/info` on 8192 and bridge calls). Upstream v3.0.0-rc.1 ships
12.1.2 builds only, so do not "upgrade" without rebuilding against 12.0.2.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\scripts\mcp\start-ghidra-project.ps1 `
  -GhidraRun D:\Programs\ReverseToolbox\ghidra_12.0.2_PUBLIC\ghidraRun.bat `
  -ProjectPath <absolute .gpr> [-ProgramPath /<program>] -Port 8192
```

Verified 2026-10-08 with the case project
`work/mcp-integration-research/ghidra/project/iwck-mcp-test.gpr`: listener
`127.0.0.1:8192` only, bridge `instances_list` and `functions_list` succeed.
Create a case-specific project per analysis; do not make `iwck.exe` a default.

### Anything Analyzer (local-http-mcp, 23816)

Verified working `%APPDATA%\anything-analyzer\mcp-server-config.json` (no BOM):

```json
{"enabled":true,"host":"127.0.0.1","port":23816,"authEnabled":true,"authToken":"<token>"}
```

The Electron window **is** the service and dies at logoff. After a restart the listener is
`127.0.0.1:23816` only: `initialize` with `Authorization: Bearer <token>` returns 200 and
`serverInfo` `anything-analyzer`, without the header it returns 401. The bearer token lives
in the User environment variable `ANYTHING_ANALYZER_MCP_TOKEN`, which the bootstrap sets from
the same file.

Agent-controlled start (same contract as the IDA and x64dbg entrypoints: reuse a healthy
listener, never kill anything, record the PID, loopback check):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\scripts\mcp\start-local-backend.ps1 `
  -Backend AnythingAnalyzer -LogDir "$env:LOCALAPPDATA\reverse-skill\anything-analyzer" -WaitSeconds 90
```

Defaults: `-RepoDir %USERPROFILE%\Tools\anything-analyzer`, `-Port 23816`, `-ConfigPath
%APPDATA%\anything-analyzer\mcp-server-config.json`, pnpm = the first `.exe`/`.cmd`/`.bat`
on PATH in PATH order (on this host `%LOCALAPPDATA%\pnpm\bin\pnpm.cmd`, 12.4.2; the WinGet
`pnpm.exe` 12.8.1 sits later on PATH and is not preferred); the `.ps1` shim is used only when
nothing else exists, wrapped in the current host. `-PnpmPath` pins the choice. Before
`pnpm dev` is started the
script validates the app config read-only and fails with a precise message when the file is
missing, carries a UTF-8 BOM, is not JSON, has `enabled != true`, `host != 127.0.0.1`, a
different `port`, `authEnabled != true`, an empty `authToken`, or an `authToken` that differs
from `ANYTHING_ANALYZER_MCP_TOKEN` (clients would get 401). It never rewrites the token. The
health probe is a Streamable HTTP `initialize` (`Accept: application/json, text/event-stream`,
SSE reply parsed) that must answer `serverInfo.name` `anything-analyzer`; an occupied port
whose listener answers 401 or another server name is refused with that reason and left
running. `pnpm dev` runs hidden with stdout/stderr under `-LogDir` next to the
`AnythingAnalyzer-<stamp>.process.json` record (`pid` is the `pnpm` launcher, `executable`
the resolved pnpm path, `repo_dir`, `config_path`). In `anything-analyzer-dev.log` the main and preload vite
builds report well under 1 s each and the listener line
`[MCP Server] Listening on http://127.0.0.1:23816/mcp` appears after them (the log has no
timestamps, so the wall-clock startup was not measured); `-WaitSeconds` accepts up to 180
for cold caches.
Fixture test: `skills/scripts/test-mcp-anything-analyzer-start.ps1` (stub `pnpm.cmd` +
Python HTTP fixture; passes under Windows PowerShell 5.1 and pwsh 7; never touches the real
app, config or token).

Known upstream limitation (pinned `0ed4791`, v3.6.60, **not patched** in the checkout):
`src/main/mcp/mcp-server.ts:167-173` sets `transport.onclose` to call `srv.close()`, and
`McpServer.close()` closes the same transport, which fires `onclose` again. Every client
disconnect (a `DELETE /mcp` session close, a dropped connection, a client restart) therefore
ends in `RangeError: Maximum call stack size exceeded`, logged as
`Exception in PromiseRejectCallback` from `@modelcontextprotocol/sdk` `webStandardStreamableHttp.js`
in `anything-analyzer-dev.err.log` (68 such entries on this host after the 2026-10-08 run).
The session maps are cleared before the recursion, so the server usually keeps serving, but
the owner saw it crash once on 2026-10-08. In the SDK code the only caller of
`transport.close()` during normal traffic is an explicit `DELETE /mcp` (session
termination); a dropped connection or a killed client never fires it. Both launchers and the
built-in relay therefore **never send `DELETE`** by default and leave their `initialize`
sessions to the app (two small in-memory map entries each); `ANYTHING_ANALYZER_CLOSE_SESSIONS=1`
opts back in. Wait for an upstream fix or carry a fork patch under `docs/mcp/patches/`; do not
edit the pinned checkout in place, and do not report it upstream from this fork. Because of
this bug both launchers also treat "port open but `initialize` fails" as unhealthy and stop
with the reason instead of retrying in a loop.

#### Auto-start from the MCP clients (stdio launcher)

The owner does not open the app by hand: every client (Claude Code, Codex, Antigravity, dsh)
registers [`anything-analyzer-stdio.py`](../../skills/scripts/mcp/anything-analyzer-stdio.py)
as a **stdio** server and the launcher brings the app up when the client spawns it. It is
standard-library Python (the bridge venv's `mcp==1.6.0` has no Streamable HTTP client and is
not imported), so the tested bridge interpreter `D:\WIN_MCP\reverse-mcp-python\Scripts\python.exe`
(3.13) runs it. Behaviour, in order:

1. `fd 1` is duplicated and parked on stderr before anything else runs; nothing but the proxy
   leg can ever write to the MCP channel (tests assert empty stdout on every failure path).
2. Token = `ANYTHING_ANALYZER_MCP_TOKEN` from the process environment, else the User value in
   `HKCU\Environment` (`winreg`). A stale process value that the app rejects with 401 falls
   through to the User value with a stderr note, so a client started before the bootstrap
   rewrote the token still connects. The token is never taken from an argument and never
   written to a client config; `mcp-remote` receives it only through the child environment.
3. Health = authenticated Streamable HTTP `initialize` on `127.0.0.1:<port>/mcp` (SSE parsed,
   `serverInfo.name` must be `anything-analyzer`; the probe session is left open, see the
   `DELETE` note above). Healthy → reuse. Open but 401 / other server / other name → stop
   with that reason, nothing killed.
4. Down → read-only validation of `%APPDATA%\anything-analyzer\mcp-server-config.json`
   (same nine checks as the PowerShell entrypoint, including token == env), then the named
   mutex `Local\reverse-skill-AnythingAnalyzer-<port>` shared with `start-local-backend.ps1`
   (four clients starting together produce exactly one `pnpm dev`; the mutex is held until
   health passes, and the port is re-probed after acquiring it), then `pnpm dev` with
   `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP` (+ `CREATE_BREAKAWAY_FROM_JOB` when allowed),
   stdin `NUL`, stdout/stderr to `%LOCALAPPDATA%\reverse-skill\anything-analyzer\
   AnythingAnalyzer-<stamp>.{stdout,stderr}.log`, record `AnythingAnalyzer-<stamp>.process.json`.
   The app survives when the client kills the launcher (verified with the fixture: `/owner`
   still answers after the launcher exited). pnpm = `shutil.which('pnpm')` (PATHEXT order, so
   `pnpm.cmd` from PATH, never the `.ps1` shim); `--pnpm` pins it.
5. Readiness wait `--wait` (default 90 s), then the proxy leg takes over the real stdout:
   - default `--proxy mcp-remote`: pinned `mcp-remote@0.14.3 http://127.0.0.1:23816/mcp
     --transport http-only --header "Authorization:Bearer ${ANYTHING_ANALYZER_MCP_TOKEN}"`,
     run as `node.exe <nodejs>\node_modules\npm\bin\npx-cli.js -y …` instead of `cmd /c npx`:
     a quoted `C:\Program Files\nodejs\npx.cmd` plus a quoted header value is exactly the case
     where `cmd.exe` strips the first and last quote. mcp-remote expands `${VAR}` itself (log
     line `Replacing ${ANYTHING_ANALYZER_MCP_TOKEN} with environment value`). Side effects: first
     use downloads it into the npx cache (`%APPDATA%\npm-cache\_npx\`), and mcp-remote keeps
     OAuth state under `%USERPROFILE%\.mcp-auth\` (folders from `0.1.17` to `v1`, 2025-06 to
     2026-08-27, already exist from the Jina registration; the bearer-header smoke runs on
     2026-10-08 created no new folder there).
   - `--proxy relay` (or `ANYTHING_ANALYZER_PROXY=relay`): built-in JSON-RPC relay, one POST
     per stdin frame, SSE/JSON answer written as one line, `mcp-session-id` learned from
     `initialize`, notifications/responses expect 202 and emit nothing, no standalone GET
     stream. No Node or network needed; use it when npx is unavailable.
   Proxy subtree ownership: right before spawning the proxy (after any `pnpm dev` is already
   running outside it) the launcher assigns **itself** to a Job Object with
   `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so `node npx-cli.js → cmd → node proxy.js` are
   members from their first instruction and die with the launcher even on `TerminateProcess`
   (a client's timeout kill); assigning the child after `Popen` would miss the grandchildren a
   venv redirector or `npx.cmd` spawns in the first microseconds. Catchable stops
   (`SIGBREAK`/`SIGINT`/`SIGTERM`) terminate the proxy child explicitly and exit 130; process
   exit closes the job handle, which ends the rest. If nested-job assignment is refused, the
   child is assigned after spawn as a best effort and the log line says so.
   `ANYTHING_ANALYZER_MCP_REMOTE_COMMAND` (JSON argv array) replaces `node npx-cli.js` for
   tests and local overrides.
   Restricted client environment: Codex starts MCP servers without `APPDATA`,
   `LOCALAPPDATA`, `PATHEXT` and with a trimmed `PATH`, which made the config default
   resolve to `%USERPROFILE%\anything-analyzer\...` and pnpm/node "not found" (Codex reported
   `connection closed: initialize response`). `repair_environment()` now fills those from
   the `Shell Folders` registry key and appends the persisted Machine/User `PATH` only when
   pnpm or node cannot be resolved; values the client did pass are never overridden.
   Verified 2026-10-08 with three stripped-environment runs against the live app and a real
   `codex exec` handshake.
   Both legs passed the three-message smoke (`initialize`, `server/discover` → `-32601`,
   `tools/list`) against the fake Streamable HTTP server in
   `skills/scripts/test-mcp-anything-analyzer-stdio.py`, which mirrors the SDK 1.29 transport
   semantics read from the pinned checkout (406 Accept check, session ids, 400/404, SSE
   replies, 202 for notifications, 405 GET). **Not verified against the live app** from the
   session that wrote this (the owner's rule: never start/stop/probe the real app from there).
   `server/discover` reaches the app, whose SDK answers `-32601`, so the dsh row needs no
   `legacy-mcp-stdio.py` wrapper.

Client startup timeouts are the real constraint, not `--wait`: Codex gives a stdio server
`startup_timeout_sec` = 10 by default, Claude Code about 30 s (`MCP_TIMEOUT` in ms, reports
say the SDK caps it near 60 s). What the dev log supports: the two vite builds take well
under 1 s each; the Electron startup time until `[MCP Server] Listening` is **not measured**
(no timestamps, and the real app was not started from the session that wrote this). If a
start exceeds the client's limit, that client's first attempt fails and its next attempt (or
any other client) reuses the app the first attempt left running. Set the Codex timeout
explicitly (below) and `MCP_TIMEOUT=90000` for Claude Code when the cold start matters.

Shapes to paste (repo = `D:\Data\Coding_Github\Reverse\reverse-skill`, all four files
gitignored; no `url`, no header, no token anywhere):

```json
// .mcp.json (Claude Code) — keep "anything-analyzer" in .claude/settings.local.json enabledMcpjsonServers
"anything-analyzer": {
  "type": "stdio",
  "command": "D:\\WIN_MCP\\reverse-mcp-python\\Scripts\\python.exe",
  "args": ["D:\\Data\\Coding_Github\\Reverse\\reverse-skill\\skills\\scripts\\mcp\\anything-analyzer-stdio.py"]
}
```

```toml
# .codex/config.toml (Codex). env_vars forwards the *name* only (Codex filters the child
# environment; "Environment variables to allow and forward"); the launcher also falls back to HKCU.
[mcp_servers.anything-analyzer]
command = "D:\\WIN_MCP\\reverse-mcp-python\\Scripts\\python.exe"
args = ["D:\\Data\\Coding_Github\\Reverse\\reverse-skill\\skills\\scripts\\mcp\\anything-analyzer-stdio.py"]
env_vars = ["ANYTHING_ANALYZER_MCP_TOKEN"]
startup_timeout_sec = 120
```

```json
// .agents/mcp_config.json (Antigravity) — no cwd, no type, no token
"anything-analyzer": {
  "command": "D:\\WIN_MCP\\reverse-mcp-python\\Scripts\\python.exe",
  "args": ["D:\\Data\\Coding_Github\\Reverse\\reverse-skill\\skills\\scripts\\mcp\\anything-analyzer-stdio.py"]
}
```

```yaml
# .dsh/agent-presets/reverse-skill/agent.cordis.yml (dsh web) — append after the Standard composition
- id: mcp-anything-analyzer
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: anything-analyzer
    transport: stdio
    command: 'D:\WIN_MCP\reverse-mcp-python\Scripts\python.exe'
    args: ['D:\Data\Coding_Github\Reverse\reverse-skill\skills\scripts\mcp\anything-analyzer-stdio.py']
    cwd: 'D:\Data\Coding_Github\Reverse\reverse-skill\skills\scripts\mcp'
```

`bootstrap-reverse.ps1 -Capability anything-analyzer -McpHostTarget …` now writes the
`command`/`args` part of this stdio shape (manifest `mcpBridgeLauncher`; interpreter from
`REVERSE_MCP_BRIDGE_PYTHON`, else the first `python` on PATH, which is safe because the
launcher is stdlib-only) instead of the `url` + `Authorization` header form. Set
`REVERSE_MCP_BRIDGE_PYTHON=D:\WIN_MCP\reverse-mcp-python\Scripts\python.exe` before running it
on this host to get the paths above verbatim. The two Codex-only keys (`env_vars`,
`startup_timeout_sec`) are **not** written by bootstrap; add them by hand, otherwise Codex
stays on its 10 s startup default (the token itself is covered by the launcher's `HKCU`
fallback).

Manual alternative (kept for a client without stdio or for debugging): the plain HTTP
registration `{"type":"http","url":"http://127.0.0.1:23816/mcp","headers":{"Authorization":"Bearer ${ANYTHING_ANALYZER_MCP_TOKEN}"}}`
(Codex: `url` + `bearer_token_env_var = "ANYTHING_ANALYZER_MCP_TOKEN"`). It starts nothing,
and a client whose process environment predates the current token gets 401 until restarted;
that is exactly what happened on 2026-10-08 (process value ≠ User value while both config
copies matched the User value).

### x64dbg

Plugin `MCPx64dbg.dp64/.dp32` is in the x64dbg plugins folders. Start x64dbg
(empty session is enough) so `http://127.0.0.1:8888/` answers; the bridge needs the
trailing slash in `X64DBG_URL`.

## Index artefacts to know about

All three were fixed in the fork on 2026-10-08; they are kept here as the record of
why the probes exist:

- `ida` used to be reported missing because `refresh-tool-index.ps1` only probed
  `Get-Command ida`. The catalog now also probes `%IDADIR%\ida.exe|ida64.exe` and
  `C:\Program Files\IDA Professional 9.0\ida.exe|ida64.exe` (IDA 9.0 ships only
  `ida.exe`; `ida64.exe` is kept for older layouts).
- `apksigner`/`zipalign` are now resolved from the highest Android SDK
  `build-tools\<version>` under `ANDROID_HOME`, `ANDROID_SDK_ROOT` or
  `%LOCALAPPDATA%\Android\Sdk` (36.1.0 on this host).
- "MCP 已注册" now reads the project-scope `.mcp.json`, `.codex/config.toml` and
  `.agents/mcp_config.json` in addition to the Codex/Claude user configs, so
  `jshookmcp`/`xquik-mcp` are recognised. The capability table separator also has
  eight columns again.