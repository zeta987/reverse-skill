# Codex MCP adapter

Read [the shared backend guide](README.md) first. For this repository, place
these four MCP entries in **`<repo>/.codex/config.toml`**, so they load only
inside this trusted project. Preserve the user's global configuration and
commented-out entries. User-level `$CODEX_HOME/config.toml` is a separate scope
and should not receive this repository's servers unless explicitly requested.
The local file is gitignored because its executable paths are machine-specific;
the routing core does not require a Codex adapter. Preserve existing server names.

Each stdio server uses `[mcp_servers.<name>]`, `command`, `args`, and optional
`env`/`cwd`. `enabled = false` disables it. `startup_timeout_sec` controls
initialization; `tool_timeout_sec` controls a tool call. These timeouts do not
start an analysis backend or supply a license.

| Server | Command and arguments | Important environment |
|---|---|---|
| `ida-pro-mcp` | Existing Python + installed `ida_pro_mcp/server.py --ida-rpc http://127.0.0.1:13337` | `PYTHONUTF8=1`; backend separately receives `IDADIR` |
| `Ghidra-mcp` | Tested bridge Python + the verified GhydraMCP stdio launcher | `GHIDRA_HYDRA_HOST=127.0.0.1`; no positional 13337 URL |
| `x64dbg-mcp` | Tested bridge Python + repo `skills/scripts/mcp/x64dbg-stdio.py --bridge <installed-x64dbg.py>` | `X64DBG_URL=http://127.0.0.1:8888/` |
| `math-mcp` | Existing Node + `math-mcp/build/index.js` | None required |

Resolve each path from the current installation. The same backend should have
one chosen alias per client; avoid registering both `idapro` and `ida-pro-mcp`
against the same backend unless duplicate tools are intentional.

Keep the Ghydra and x64dbg launchers beside `bridge_compat.py`. An older config
that runs `x64dbg.py serve` directly bypasses the settings and register-parameter
compatibility fixes; update only that server's args to use the repo launcher.

After merging, parse TOML, compare all unrelated sections with the backup,
then inspect `codex mcp list` from this repository and from outside it. The four
servers should appear only inside the repository. That command verifies configuration inventory,
not a successful analysis call. A model-free app-server check can initialize
the selected servers and call `mcpServerStatus/list`; require a non-empty tool
catalog and no `toolsError`. For scope verification, let Codex load the project
file normally; injecting the four entries with `-c` would not prove project
loading. Backend operations must be verified separately.

For a running client, use its supported MCP reload mechanism and check the
result. The app-server protocol exposes `config/mcpServer/reload`, but a
successful check in a separate app-server process does not prove an already
open conversation has refreshed its tool catalog. If the client cannot reload,
state that a new client session is needed rather than claim tools are present.

Source: [official Codex MCP documentation](https://developers.openai.com/codex/mcp).
