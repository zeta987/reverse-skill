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
| anything-analyzer | `Test-VsBuildToolsInstalled` asks `vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64` first, so VS 2026 Community counts |
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