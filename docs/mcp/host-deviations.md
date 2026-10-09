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
| pentestswarm | go-install `@v0.1.0` + MCP, "needs Claude/Ollama API key" | **Upgraded to v0.2.31** (`go install …@v0.2.31` on 2026-10-08, module version confirmed with `go version -m`; the binary still prints `version dev`); registered as the stdio launcher `pentestswarm-stdio.py` (see the runbook below); provider `openai` = the owner's OpenAI-compatible relay, key only in the User environment | v0.1.0 had no `openai` provider (claude/ollama/lmstudio only); v0.2.31 adds it. Manifest pin bumped to v0.2.31 in both manifests and the Kali bootstrap. `mcp serve` runs the swarm engine in-process and never opens Postgres or Redis; `doctor` only dials the ports |
| idapro (HTTP) | register `http://127.0.0.1:13337/mcp` | Not registered; the stdio proxy `ida-pro-mcp` already targets the same backend | Double registration of one backend is what `docs/mcp/codex.md` warns against |
| agent-browser (2026-10-09) | npm-global `agent-browser@0.31.1`, postInstall `npx playwright install chromium`, installDir `%LOCALAPPDATA%\ms-playwright` | `npm install -g` done by bootstrap; browsers installed with `agent-browser install` → Chrome for Testing 155.0.8059.39 in `%USERPROFILE%\.agent-browser\browsers` | npm 12 blocks the package's postinstall (`allowScripts`), which is harmless because the win32-x64 binary ships inside the package. `npx playwright install chromium` prompted for the `playwright` package and hung the non-interactive bootstrap; agent-browser 0.31 does not use `ms-playwright` at all |

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
| pentestswarm | manifest `mcpBridgeLauncher: %SKILL_ROOT%\scripts\mcp\pentestswarm-stdio.py`, `servicePort: 8080`, note rewritten for the free local stack (provider `ollama`, no API key); `start-local-backend.ps1 -Backend PentestSwarm`; runbook and client shapes below. Bootstrap does not write the entry (the parent registers by hand) |
| agent-browser | manifest `postInstall: agent-browser install`, `installDir: %USERPROFILE%\.agent-browser\browsers`, `docsUrl` → vercel-labs; `browser-automation/scripts/setup.ps1` runs `agent-browser install` instead of `npx playwright install chromium`; the `playwright` tool-index row also accepts `~\.agent-browser\browsers` as evidence. The Kali manifest and the POSIX bootstrap keep the old command (not verified here) |

Registration scope: `bootstrap-reverse.ps1 -McpHostTarget Claude|Codex|Antigravity|Both|All`
now writes the project-scope files listed below (`-McpScope Project`, default). Claude Code
never read `%USERPROFILE%\.claude\mcp.json`; `-McpScope User` goes through
`claude mcp add-json --scope user` instead.

## Client registration mirror

All four files carry the same server set and are gitignored because they embed
this machine's absolute paths.

| Client | File | Servers |
|---|---|---|
| Codex CLI | `.codex/config.toml` (project scope, repo is trusted) | ida-pro-mcp, Ghidra-mcp, x64dbg-mcp, math-mcp, r2mcp, jshook, xquik, anything-analyzer (stdio launcher, see below), pentestswarm (stdio launcher, see below) |
| Claude Code | `.mcp.json` + `.claude/settings.local.json` (`enabledMcpjsonServers`) | same nine; every stdio entry carries `"type": "stdio"` |
| Antigravity | `.agents/mcp_config.json` (`mcpServers`, no `cwd` field) | same nine; `xquik` as `serverUrl` |
| dsh web | `.dsh/agent-presets/reverse-skill/agent.cordis.yml` | ida-pro, ghidra, x64dbg, math, r2, jshook, anything-analyzer, pentestswarm (xquik not added: http transport unverified) |

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
   Detached start through WMI (2026-10-09): Codex ends its MCP servers' whole descendant tree
   at exit and `CREATE_BREAKAWAY_FROM_JOB` does not change the parent PID, so `pnpm dev` died
   with every Codex session. `spawn_via_wmi()` now creates `cmd.exe /d /s /c "mkdir <logdir> &
   "<pnpm>" dev 1>>log 2>>&1"` through `Win32_Process.Create` (parent `WmiPrvSE.exe`, outside
   the client's job and PID tree), falling back to the direct detached spawn when WMI is
   unavailable. Two findings shaped it: `Win32_ProcessStartup.EnvironmentVariables` is not
   usable (from a restricted caller the child "started" but died before writing a byte; a full
   caller got return code 21), so the child gets the user's default environment block and only
   `REVERSE_TEST_*` / `ANYTHING_ANALYZER_*` variables (never the token) are forwarded as `set`
   statements; and **sandboxed shells see a virtualized filesystem**: the Claude Code tool shell
   and Codex's MCP processes both created `%LOCALAPPDATA%\reverse-skill\...` and
   `%APPDATA%\anything-analyzer\mcp-server-config.json` in their own view, while the WMI child
   runs on the real filesystem where the directory did not exist and the config still held the
   app's fallback (`enabled=false`, `host=0.0.0.0`). The child therefore creates the log directory
   itself, and the real config was rewritten through a WMI-created `copy` from `%TEMP%` (which is
   shared with the real filesystem). Check real-filesystem state through a WMI-created `dir`
   before trusting what a sandboxed shell shows. Known limitation: Codex does not wait for a slow
   server before its first turn, so the very first prompt issued within ~15 s of a cold start may
   report anything-analyzer as unavailable; the app now survives the session, so the next
   conversation reuses it (verified with `codex exec` twice).
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

### Pentest Swarm AI (pentestswarm v0.2.31 on the owner's relay)

Installed binary: v0.2.31 since 2026-10-08 (`go install github.com/Armur-Ai/Pentest-Swarm-AI/cmd/pentestswarm@v0.2.31`
over the v0.1.0 build in `%USERPROFILE%\go\bin`; `go version -m` shows `mod … v0.2.31`, while
`--version` still prints `version dev` because the `go install` build has no ldflags). The
statements below were read from the v0.1.0 module cache
(`%USERPROFILE%\go\pkg\mod\github.com\!armur-!ai\!pentest-!swarm-!a!i@v0.1.0`) and re-checked
against the v0.2.31 sources: `cli/mcp.go` is identical, `internal/mcp/server.go` differs only in
struct-tag whitespace, `internal/mcp/tools.go` has the same five tools (`explain_finding` is still
canned text), and `cli/doctor.go` has the same eight infra checks. Three upstream facts override
the manifest's old "needs Claude/Ollama API key" note and the `doctor` wording:

1. **`mcp serve` is self-contained.** `cli/mcp.go` → `mcp.RegisterDefaultTools(server, cfg)`
   → `engine.NewRunner(cfg)` with `memory.NewMemoryStore()`; the five tools run the swarm
   engine **in-process** over stdio. Nothing imports `internal/db` (the only
   `pgxpool.NewWithConfig` is inside that package, `Migrate` has no caller) and `go.mod` has
   no Redis client. `campaign_status` merely formats a `http://localhost:8080/...` URL. The
   API server on 8080, Postgres and Redis are therefore only what `pentestswarm doctor`
   (pure TCP dials) and the `campaign`/`scan --follow` CLI paths want. The stdio launcher's
   default chain is **Ollama only**; `--ensure-api-server` and `--redis-port 6379` are opt-in
   legs for `doctor`. No MCP sampling either: `internal/mcp/server.go` handles exactly
   `initialize`, `tools/list`, `tools/call`, `resources/list`, `resources/read` (lines 98-194,
   nothing else in the tree mentions `sampling/createMessage`), so the swarm cannot borrow the
   MCP client's model; the provider is built per tool call in `internal/engine/runner.go:161`
   (`llm.NewProvider`), before recon, so `scan_target` and `quick_recon` (`tools.go:49`, `:84`)
   both need it while `explain_finding` (`tools.go:110`, canned text), `campaign_status`
   (`:122`, formats a URL) and `list_tools` (`:140`, static list) never touch an LLM. Providers
   in v0.1.0 (`internal/llm/factory.go:48-80`, `config.go:286-288`): `claude`, `ollama`,
   `lmstudio` only; there is no `openai` provider (the docs site describes a newer release).
   `lmstudio` posts to `<endpoint>/v1/chat/completions` with no `Authorization` header and no
   `tools` field (`lmstudio.go:44-55`, `:105-109`), so an OpenAI-compatible relay works only
   keyless and only without tool calling; `ollama` is the one local provider that sends tools
   (`ollama.go:54`). `claude` uses `anthropic-sdk-go` v1.26.0 with `option.WithAPIKey` only
   (`claude.go:44`); that SDK reads `ANTHROPIC_BASE_URL` from the environment
   (`client.go:34`), which is the only route to an Anthropic-compatible relay, and the
   launcher deliberately scrubs the key variables, so it is not a free path either.
2. **`serve` ignores `server.host`.** `internal/api/server.go` `Start()` is
   `app.Listen(":<port>")`; the live process binds `0.0.0.0:8080` (netstat, 2026-10-08,
   IPv4 wildcard only). `config.yaml` records `host: "127.0.0.1"` as the intent. The gate is
   **fail-closed**: when the API server leg is requested (`-Backend PentestSwarm` in
   `start-local-backend.ps1`, `--ensure-api-server` in the stdio launcher) and the listener is
   wildcard-bound, both launchers refuse it with an error unless the caller opts in with
   `-AllowWildcardBind` / `--allow-wildcard-bind` (env `PENTESTSWARM_ALLOW_WILDCARD_BIND=1`),
   which is meant to be combined with a Windows Firewall inbound-block rule for the port. A
   wildcard listener that merely exists while `mcp serve` runs (which never needs it) is only
   reported as `bind_all_interfaces: true` with a stderr warning. Decision 2026-10-08: the owner
   does not run `serve` at all, so no fork patch (`Listen(host:port)` + `go build`, the
   `docs/mcp/patches/` pattern) and no firewall rule exist yet.
3. **Protocol quirks** (verified live on 2026-10-08 with the four-frame smoke):
   `protocolVersion` is hard-coded `2024-11-05`; `server/discover` and `ping` answer
   `-32601` natively (no `legacy-mcp-stdio.py` wrapper for the dsh row); the `default` case
   of `handleRequest` also answers **notifications**, so `notifications/initialized` produces
   one id-less `{"jsonrpc":"2.0","error":{"code":-32601,...}}` frame on stdout; `tools/list`
   iterates a Go map (compare sorted). Tool count: **5** (`campaign_status`,
   `explain_finding`, `list_tools`, `quick_recon`, `scan_target`).

Host components (all free; nothing paid, no provider key anywhere):

| Component | State on this host | How it was reached |
|---|---|---|
| PostgreSQL | native service `postgresql-x64-18` (18.6, EDB installer), `listen_addresses = '*'` and loopback `trust` in `pg_hba.conf` (pre-existing host config, not changed) | role + database `pentestswarm` created on 2026-10-08 with a 32-char generated password that exists only in the User environment variable `PENTESTSWARM_DATABASE_PASSWORD` (`psql -v pw=… -f -`, never on a command line). **pgvector is not available**: no `vector.control` under `C:\Program Files\PostgreSQL\18\share\extension`, no Windows binary for PG 18 without a source build, and v0.1.0 never runs `000002_pgvector.sql`. The Docker `pgvector/pgvector:pg16` fallback was not used because it would publish 5432, which the native service already owns |
| Redis | `winget install Memurai.MemuraiDeveloper` (4.1.2, free developer edition, Windows service `Memurai`) — see the status line below | `doctor` dials 6379 only; both launchers treat a closed 6379 as a **warning** (they try `Start-Service`/`sc start Memurai` first) because v0.1.0 never opens Redis |
| Ollama | `%LOCALAPPDATA%\Programs\Ollama\ollama.exe` 0.11.8 (not a service, no autostart) | launchers run `ollama serve` detached with `OLLAMA_HOST=127.0.0.1:11434`; model `llama3.1:8b` (the `pentestswarm config init` default; `internal/llm/ollama.go` names "Llama 3.1+" for tool calling; 4.92 GB from `registry.ollama.ai`) — see the status line below |
| Docker | Desktop 29.8.2 running (autostart) | not needed by this stack; only the bundled labs use it |
| config | `%USERPROFILE%\.pentestswarm\config.yaml` (viper's second search path after `./config.yaml`; both launchers pass `--config` explicitly because `HOME` is empty on Windows and Codex strips `USERPROFILE`) | Final shape (option A, v0.2.31): `server.host 127.0.0.1`, `server.port 8080`, `orchestrator.provider openai`, `model gpt-6.1-sol`, `endpoint https://<relay-host>/v1` (the owner's private OpenAI-compatible relay; hostname intentionally not recorded here), `api_key ""` (User env only), `context_window 128000`, `database.*` as above with `password ""`, `redis 127.0.0.1:6379`, `intelligence.enabled false`. The `claude` and `ollama` shapes stay supported by both launchers |

Status line (updated as the host steps land): Postgres role/db ✅, `config.yaml` ✅,
`pentestswarm serve` verified once on 2026-10-08 through `pentestswarm-stdio.py --check-only
--ensure-api-server` (`GET /api/v1/health` → `{"service":"pentestswarm","status":"ok"}`, bind
`0.0.0.0:8080`) and then **stopped** at the owner's request because `mcp serve` does not need
it; Memurai install failed (1603, see below); Ollama dropped in favour of the relay; `doctor`
with `serve` stopped = 5/8 (API ❌ by design, Redis ❌, Ollama ❌ no longer used; `doctor` has no
provider check in v0.1.0 or v0.2.31). Live `tools/list` through the launcher against the real
v0.1.0 binary with the relay config: 4 smoke frames + the stray notification error, **5 tools**,
no Ollama started, key taken from `HKCU\Environment`.

Memurai install note: `winget install --id Memurai.MemuraiDeveloper --exact --silent` ran on
2026-10-08 after the owner's approval (MSI hash verified, UAC accepted) and **failed with 1603**:
the MSI log shows `SFXCA: Failed to create temp directory. Error code 5` inside the elevated
custom actions (`ca_CheckIfFirewallServiceRunning`, then `ca_SilentCheckIfPortIsAvailable`
fatal), i.e. the installer's own temp extraction was denied under msiexec, not a port conflict
(6379 was free). Not retried. Owner options: run the verified MSI
(`%LOCALAPPDATA%\Temp\WinGet\Memurai.MemuraiDeveloper.4.1.2\Memurai-Developer-v4.1.2.msi`)
from an elevated prompt with `/l*v`, or `docker run -d --name redis -p 127.0.0.1:6379:6379
redis:7-alpine` (Docker Desktop is up). Redis only matters for `doctor`.

Provider decision (2026-10-08): the owner chose their own OpenAI-compatible relay
(`https://<relay-host>/v1`; the real hostname lives only in `config.yaml` on the host) over a local Ollama model. The relay key lives only in the
User environment variable `PENTESTSWARM_ORCHESTRATOR_API_KEY` (viper's env override for
`orchestrator.api_key`); it is never in `config.yaml`, the repo, a client config or a log. Both
launchers read it from the process environment, else `HKCU\Environment`, and hand it only to
the local pentestswarm children (`mcp serve`, and `serve` when that leg is requested), never to
`ollama serve`; provider overrides (`PENTESTSWARM_ORCHESTRATOR_PROVIDER/MODEL/ENDPOINT`, `ANTHROPIC_API_KEY`)
are still removed so `config.yaml` stays authoritative. Model probe (one minimal tool-calling
chat completion per candidate, `max_tokens 64`, HTTP status only): `gpt-6.1-sol` 200 + well-formed
tool call (also 200 + `tool_use` in the Anthropic messages format), `claude-sonnet-5-5` 200/200
pass, `qwen3.8-max` 200/200 pass, `glm-5.3-max` 200 pass in OpenAI format but 503 in Anthropic
format, `kimi-k3` 200 but **no** tool call in either format; `GET /v1/models` 200 (165 models).
`orchestrator.model` = `gpt-6.1-sol` (first to pass, per the owner's rule), `context_window
128000`. **Version conflict:** the installed v0.1.0 accepts only `claude`/`ollama`/`lmstudio`
(`factory.go:48-80`, `config.go:286-288`); the `openai` provider (Bearer header, `tools`,
health `GET <endpoint>/models`) exists from upstream v0.2.x (`internal/llm/openai.go` at
v0.2.31, factory case at line 81; `cli/mcp.go` and `internal/mcp/server.go` are the same shape:
five tools, same handler cases). With v0.1.0 the stdio smoke still passes (`mcp serve` only
`Load`s the config, it never `Validate`s), but `scan_target`/`quick_recon` would fail at call
time with `unknown provider "openai"`. Round 4 (superseded by round 5 below, kept for the facts): the owner briefly chose to stay on
v0.1.0 and route the relay through the **`claude` provider**: `orchestrator.provider "claude"`, `model "claude-sonnet-5-5"` (the parent session
verified `POST /v1/messages` on the relay with `x-api-key` + `anthropic-version 2023-06-01`
returns 200 for `claude-sonnet-5-5` and `claude-haiku-5-5`, and a tools request answered
`stop_reason tool_use` with a well-formed block; only a forced `tool_choice: {"type":"tool"}`
got HTTP 400, which `claude.go` never sends — it sets no `ToolChoice` at all), `api_key ""`,
`orchestrator.endpoint "https://<relay-host>"` (no `/v1`: anthropic-sdk-go joins the base
URL with the relative path `v1/messages`, `message.go:66`, and `option.WithBaseURL` adds the
trailing slash). Env override name confirmed from `config.go:227-229`: `SetEnvPrefix("PENTESTSWARM")`
+ `.`→`_` replacer + `AutomaticEnv` → `orchestrator.api_key` is `PENTESTSWARM_ORCHESTRATOR_API_KEY`,
and `cli/mcp.go` / `cli/serve.go` read that variable explicitly when the file value is empty, so
the key never has to be in the file. `ANTHROPIC_BASE_URL` is read by the SDK's
`DefaultClientOptions` (`client.go:34`) and is set by **both launchers in the child environment
only**, from `orchestrator.endpoint` (which pentestswarm ignores for `claude`); an inherited
`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` is removed from every child,
nothing is written at User or Machine scope (Claude Code itself reads `ANTHROPIC_BASE_URL`), and
the PowerShell entrypoint uses `Remove-Item Env:` because under pwsh 7
`SetEnvironmentVariable(name, $null)` leaves an empty-but-defined variable in `Start-Process`
children, which would break the SDK. `claude.go` sends `cache_control` (`ttl` default `5m`,
`claude.go:189`) on cached system prompts; whether the relay accepts that field is only known
once a real tool call runs (see the status line). **Host config write pending:** this session's
permission classifier refused to write the `claude`+relay shape into
`%USERPROFILE%\.pentestswarm\config.yaml` (classified as traffic redirection), so the file
still holds the earlier `openai` shape until the owner writes or approves the four-line change
(`provider: "claude"`, `model: "claude-sonnet-5-5"`, `endpoint: "https://<relay-host>"`,
`context_window: 200000`); the launchers, tests and docs already support it.

**Round 5 decision (final, 2026-10-08): option A.** The owner chose the upgrade: v0.2.31 installed
as above, manifest pin bumped (`goPackage …@v0.2.31`, `pinnedVersion v0.2.31`; the Docker fallback
tag stays `v0.1.0` because ghcr.io answered 403 to the anonymous token flow for every tag, so no
v0.2.31 image could be confirmed), provider **`openai`** with `endpoint
https://<relay-host>/v1`, `model gpt-6.1-sol`, key only via
`PENTESTSWARM_ORCHESTRATOR_API_KEY` — exactly the config.yaml already on disk. Redis: **skipped
entirely** at the owner's request (no Memurai retry, no Docker redis); the `doctor` Redis leg
stays red by design. The `claude` provider support in both launchers remains (tested) but is
unused. Verified on v0.2.31 (2026-10-08): `doctor` 5/8 (API ❌ `serve` kept stopped, Redis ❌
skipped, Ollama ❌ unused, Postgres/Docker/Go/disk/RAM ✅); live stdio smoke through
`pentestswarm-stdio.py` → 4 frames + the stray notification error, `server/discover` → `-32601`
(no `legacy-mcp-stdio.py` for dsh), `ping` → `-32601`, **5 tools with schemas byte-identical to
the v0.1.0 capture**, and the MCP child (pid from the launcher log) owned **no LISTENING socket**
while alive. Provider-path proof: v0.2.31 offers no tool, dry-run or CLI command that reaches the
LLM without a target (`explain_finding` is canned, `config validate` is a TODO stub that only
checks `./config.yaml` exists, `quickstart`/`doctor` never call the provider, `demo` is explicitly
"no network, no LLM"), so it was **not** run; the direct relay probe above (`gpt-6.1-sol`: HTTP 200
with a well-formed tool call on `/v1/chat/completions`, `GET /v1/models` 200) is the only
provider evidence.

#### Agent-controlled start (same contract as the other backends)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\scripts\mcp\start-local-backend.ps1 `
  -Backend PentestSwarm -LogDir "$env:LOCALAPPDATA\reverse-skill\pentestswarm" -WaitSeconds 90
```

Defaults: `-Executable` = `pentestswarm` on PATH, else `%USERPROFILE%\go\bin\pentestswarm.exe`;
`-ConfigPath %USERPROFILE%\.pentestswarm\config.yaml`; `-Port 8080`; `-OllamaPath` = `ollama`
on PATH, else `%LOCALAPPDATA%\Programs\Ollama\ollama.exe`; `-OllamaPort 11434`; `-RedisPort 6379`
(`0` skips either dependency). This PowerShell entrypoint is the **full** chain for `doctor` and the campaign CLI (the stdio
launcher below starts only Ollama by default). Order: read-only `config.yaml` validation (`server.host`
`127.0.0.1`, `server.port` == `-Port`, `provider` `ollama`, `openai` or `claude`, empty `api_key`,
non-empty `model`; `ollama` needs a loopback `endpoint` on `-OllamaPort`, `openai`/`claude` need an
`https://` (or loopback) relay base URL — for `claude` without a `/v1` suffix — and the key in the
process or User environment; each failure has its own message and nothing is started) → Redis (service start attempt, then warning) → Ollama (only for
provider `ollama`) (`GET /api/tags`; reuse, else
`ollama serve` detached + `Ollama-<stamp>.*` logs/record; a missing model is a warning naming
`ollama pull <model>`) → API server (`GET /api/v1/health` must answer `service pentestswarm`;
reuse, else `pentestswarm serve --config <path> --port <port>` hidden with
`PentestSwarm-<stamp>.{stdout,stderr}.log` + `.process.json`). The JSON on stdout carries
`dependencies.redis`, `dependencies.ollama` (`state`, `models`, `model_present`) and
`bind_all_interfaces`; every advisory line goes to **stderr** so stdout stays parseable. The
named mutex `Local\reverse-skill-PentestSwarm-8080` is shared with the stdio launcher. Provider
and API-key variables (`ANTHROPIC_API_KEY`, `PENTESTSWARM_ORCHESTRATOR_*`,
`PENTESTSWARM_AGENTS_*`) are removed from every child environment; `PENTESTSWARM_DATABASE_PASSWORD`
(process, else User scope) is handed to `serve` only. An occupied 8080 whose health answers
another service, or an occupied 11434 without `/api/tags`, is refused with that reason and
left running. Fixture test: `skills/scripts/test-mcp-pentestswarm-start.ps1` (stub
`pentestswarm.cmd`/`ollama.cmd` + Python HTTP fixtures, random ports; passes under Windows
PowerShell 5.1 and pwsh 7).

#### Auto-start from the MCP clients (stdio launcher)

Every client registers [`pentestswarm-stdio.py`](../../skills/scripts/mcp/pentestswarm-stdio.py)
(standard-library Python, run by the tested bridge interpreter) as a **stdio** server. It does
the same read-only validation, then only what `mcp serve` needs: for providers `openai`/`claude`
nothing local at all (the relay key is read from the process or User environment and handed to
the child; for `claude` the child also gets `ANTHROPIC_BASE_URL` from `orchestrator.endpoint`);
for provider `ollama`, Ollama (reuse, or `ollama serve` detached with
`OLLAMA_HOST=127.0.0.1:<port>`; a missing model is a warning). The API
server leg (`--ensure-api-server`) and the Redis probe (`--redis-port 6379`) are opt-in and
exist for `pentestswarm doctor`, not for the tools. Then it `exec`s
`pentestswarm mcp serve --config <path>` with stdin/stdout inherited (fd 1 is parked on stderr
until that moment, so no diagnostic can reach the MCP channel) and its cwd set to
`%LOCALAPPDATA%\reverse-skill\pentestswarm\work` (the swarm tools write `./reports` there, never
into a repo). The MCP child is owned the same way as the Anything Analyzer proxy: the launcher
assigns **itself** to a `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` job right before the spawn (after
`ollama serve`/`pentestswarm serve` were started detached outside it), so a client's
`TerminateProcess` on timeout ends the child and its grandchildren; `SIGBREAK`/`SIGINT`/`SIGTERM`
terminate it explicitly (exit 130).

It needs **nothing from the process environment**: Codex hands MCP servers a filtered
environment, so `USERPROFILE` comes from `HKCU\Volatile Environment`, `APPDATA`/`LOCALAPPDATA`
from `HKCU\...\Explorer\Shell Folders`, `SHGetKnownFolderPath` is the next fallback, and PATH is
the union of the process PATH, `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment\Path`
and `HKCU\Environment\Path` (`%VAR%` expanded). Like `repair_environment()` in
`anything-analyzer-stdio.py` (dev 448b597) it repairs its own process first — `USERPROFILE`,
`HOMEDRIVE`/`HOMEPATH`, `APPDATA`, `LOCALAPPDATA`, `SystemRoot`, `ProgramFiles`, `PATHEXT`, and the
persisted PATH when `pentestswarm` is not found — never overriding what the client did pass, and
the children inherit the repaired values because `os.UserHomeDir()` is used by the fp cache, NVD
cache and `init`. Overrides: `--exe`/`PENTESTSWARM_EXE`,
`--config`/`PENTESTSWARM_CONFIG`, `--port`, `--ollama-exe`, `--ollama-port` (0 = skip),
`--redis-port` (default 0 = skip), `--ensure-api-server` (or `PENTESTSWARM_ENSURE_API_SERVER=1`),
`--log-dir`, `--wait` (90 s), `--check-only` (summary JSON on stderr with `api_server`, `ollama`,
`redis`, `bind_all_interfaces`; no MCP child). Fixture test: `skills/scripts/test-mcp-pentestswarm-stdio.py` (stub launchers,
HTTP + stdio fixtures mirroring the quirks above; 10 validation refusals with empty stdout,
fresh start with `--ensure-api-server`, reuse, missing-model warning, the default
Ollama-only chain (no `serve` started), 3-way concurrency → one `ollama serve` + one
`pentestswarm serve`, wrong owner on either port, early exit, hard-kill + ctrl-break ownership
under a Codex-style environment with `USERPROFILE`/`APPDATA`/`LOCALAPPDATA`/`PATH` removed,
`--check-only`). Client startup timeouts apply as for Anything Analyzer: `ollama serve` cold
start plus `pentestswarm serve` are both fast on this host (the API server answered health
within a second of the spawn), but set the Codex timeout explicitly anyway.

Shapes to paste (repo = `D:\Data\Coding_Github\Reverse\reverse-skill`, all four files
gitignored; no url, no key, no password anywhere — the relay key stays in the User environment
and the launcher's `HKCU` fallback finds it even under Codex's filtered environment):

```json
// .mcp.json (Claude Code) — add "pentestswarm" to .claude/settings.local.json enabledMcpjsonServers
"pentestswarm": {
  "type": "stdio",
  "command": "D:\\WIN_MCP\\reverse-mcp-python\\Scripts\\python.exe",
  "args": ["D:\\Data\\Coding_Github\\Reverse\\reverse-skill\\skills\\scripts\\mcp\\pentestswarm-stdio.py"]
}
```

```toml
# .codex/config.toml (Codex). No env_vars needed: the launcher resolves every path from the
# registry and never needs a token; startup_timeout_sec covers a cold `ollama serve`.
[mcp_servers.pentestswarm]
command = "D:\\WIN_MCP\\reverse-mcp-python\\Scripts\\python.exe"
args = ["D:\\Data\\Coding_Github\\Reverse\\reverse-skill\\skills\\scripts\\mcp\\pentestswarm-stdio.py"]
startup_timeout_sec = 120
```

```json
// .agents/mcp_config.json (Antigravity) — no cwd, no type, no env
"pentestswarm": {
  "command": "D:\\WIN_MCP\\reverse-mcp-python\\Scripts\\python.exe",
  "args": ["D:\\Data\\Coding_Github\\Reverse\\reverse-skill\\skills\\scripts\\mcp\\pentestswarm-stdio.py"]
}
```

```yaml
# .dsh/agent-presets/reverse-skill/agent.cordis.yml (dsh web) — append after the Standard composition;
# server/discover is answered -32601 natively, so no legacy-mcp-stdio.py wrapper
- id: mcp-pentestswarm
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: pentestswarm
    transport: stdio
    command: 'D:\WIN_MCP\reverse-mcp-python\Scripts\python.exe'
    args: ['D:\Data\Coding_Github\Reverse\reverse-skill\skills\scripts\mcp\pentestswarm-stdio.py']
    cwd: 'D:\Data\Coding_Github\Reverse\reverse-skill\skills\scripts\mcp'
```

Manual `doctor`/`serve` from a shell: `pentestswarm doctor` and `pentestswarm serve` find the
config through `$HOME/.pentestswarm` only when viper can resolve a home directory; pass
`--config "$env:USERPROFILE\.pentestswarm\config.yaml"` when in doubt. Authorized targets only:
the `scan_target`/`quick_recon` tools run real recon tooling against whatever target the client
names.

### x64dbg

Plugin `MCPx64dbg.dp64/.dp32` is in the x64dbg plugins folders. Start x64dbg
(empty session is enough) so `http://127.0.0.1:8888/` answers; the bridge needs the
trailing slash in `X64DBG_URL`.

### ARTEX (escalation platform, not registered as MCP)

Local fork at `<repo parent>\ARTEX` (mirror of `mhtsec/ARTEX` v0.3.15; the original
`Autumn-27/ARTEX` repository and its Docker Hub image are gone). ARTEX is a standalone
autonomous pentest platform with its own planner/worker agents, a MITM recording proxy and
an intercept-approval gate; it exposes REST + JWT only, so there is nothing to put in the
four client mirrors and no bootstrap-manifest capability. It is wired in as an
**escalation path** for `pentest-tools` / `api-security` / `attack-chain`
(`skills/pentest-tools/references/artex-escalation.md`), not as a backend.

Start/probe/stop: `skills/scripts/artex/start-artex.ps1 -Action Start|Status|Stop`.
The script resolves the root from `-ArtexRoot`, `ARTEX_ROOT`, then `<repo parent>\ARTEX`;
requires `.env` and `jwt.key` to exist as files; refuses to start unless
`docker-compose.override.yml` pins 8787 and 8788 to `127.0.0.1` (the upstream compose file
publishes 8787 on all interfaces); requires the locally built `artex:local` image; polls
`GET /api/health` and reports `initialized` from `/api/auth/status`. It never logs in and
never prints `.env`, `jwt.key` or a token. `Stop` runs `docker compose stop` so `pgdata` and
`data/` survive. Do not run `update.sh`, `docker compose pull` or the in-app updater: they
point at the deleted upstream. Build and deploy steps live in `ARTEX/CLAUDE.md`.

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