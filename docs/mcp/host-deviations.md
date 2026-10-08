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
| Codex CLI | `.codex/config.toml` (project scope, repo is trusted) | ida-pro-mcp, Ghidra-mcp, x64dbg-mcp, math-mcp, r2mcp, jshook, xquik |
| Claude Code | `.mcp.json` + `.claude/settings.local.json` (`enabledMcpjsonServers`) | same seven; every stdio entry carries `"type": "stdio"` |
| Antigravity | `.agents/mcp_config.json` (`mcpServers`, no `cwd` field) | same seven; `xquik` as `serverUrl` |
| dsh web | `.dsh/agent-presets/reverse-skill/agent.cordis.yml` | ida-pro, ghidra, x64dbg, math, r2, jshook (xquik not added: http transport unverified) |

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
The session maps are cleared before the recursion, so the server keeps serving; the entries
are noise, not a crash. The launcher's health probe closes its own `initialize` session with
a `DELETE`, so expect one more entry per launcher run. Wait for an upstream fix or carry a
fork patch under `docs/mcp/patches/`; do not edit the pinned checkout in place, and do not
report it upstream from this fork.

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