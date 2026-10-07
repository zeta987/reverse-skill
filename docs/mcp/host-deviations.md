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

Tool-index rows for these still read from `Get-Command`/fixed paths and show them as
available, but a fresh `bootstrap-reverse.ps1` run will hit the same failures until
the manifest is fixed.

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

The installed `ida_pro_mcp` 2.0.0 has `idalib_server` but **no `idalib_supervisor`**,
so `skills/ida-reverse/scripts/start.ps1`, `watchdog.ps1` and `install-autostart.ps1`
do not apply to this host (start.ps1 also stalls for minutes in
`Get-ManagedSupervisorProcessIds`, one WMI query per process). Use:

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

- `skills/tool-index.md` marks `ida` as missing because `refresh-tool-index.ps1`
  only probes `Get-Command ida`; IDA Pro 9.0 is installed at
  `C:\Program Files\IDA Professional 9.0`.
- `apksigner`/`zipalign` show missing for the same reason; they live in the Android
  SDK `build-tools\36.1.0` and `rebuild-sign-install.ps1` finds them itself.
- `jshookmcp`/`xquik-mcp` show "MCP 已注册 —" because the index reads only the
  global client configs, not the project-scope files above.