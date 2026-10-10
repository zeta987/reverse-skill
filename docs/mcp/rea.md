# rea runbook (reverse-engineer-anything, npm package `rea-agents`)

This file is the runbook for the `rea` MCP backend in this private fork: what is pinned,
what works on this Windows host, why the native providers stay unconfigured, how the
catalog identity is computed, and how a version bump is noticed, tested, applied and rolled
back. Install deviations stay in the deviation register
[host-deviations.md](host-deviations.md); this file holds the operating procedure.

[morluto/rea](https://github.com/morluto/rea) is one stdio MCP server + CLI that returns
Evidence-bearing results (`observed` / `derived` / `inferred`, `limitations[]`, residual
unknowns) for JavaScript/Electron trees and ASARs, managed PE/CLI assemblies, archive and
package inventories (ZIP/APK/IPA/MSIX/AppX/DMG), passive CDP page inspection and controlled
browser scenarios, HAR/mitmproxy captures, EVM bytecode and, through providers, native
binaries. It deliberately has **no scope/permission gate** (upstream `docs/roadmap.md`,
PR #555); the authorization gate stays in this repository (`case-init` → `scope.md`).
Upstream releases almost daily (6.1.0 on 2026-10-09, 6.2.0 the same day, 6.3.0 on
2026-10-10), so the pin is adopted deliberately with the tooling below, never by floating
`latest`.

## Supported version

Current pin: **rea-agents@6.3.0** (Node engines `^22.19.0 || ^24.11.0 || >=26.0.0`; host runs
Node 24.20.0 / npm 12.2.0). The pin is consumed as the npm package through the npx package
runner, not as source; the sibling source clone `D:\Data\Coding_Github\Reverse\rea` is for
reading only and is never built or linked.

Result shape since 6.2.0 (verified on 6.3.0 against the fixture and the advertised
`outputSchema`): analysis tools return the canonical Evidence record itself as
`structuredContent` (`evidence_id`, `subject`, `provider`, `analysis_profile`,
`predicate_type`, `operation`, `parameters`, `raw_result`, `normalized_result`,
`confidence`, `authority`, `environment`, `limitations`, `locations`, `evidence_links`);
the 6.1.0 `result` wrapper is gone, so read `normalized_result.*`. Session tools such as
`export_evidence_bundle` keep `result: {...}`. JavaScript semantic graphs carry
`evidence_contexts[]` and reference them from nodes/relations through
`evidence.context_id` + `evidence.location` (source-range); `statistics.truncated_scopes`
was removed. 6.3.0 adds `inspect_analysis_view` (139 tools); the ~138 schema changes in the
6.1.0 → 6.3.0 diff are mostly the portable NUL escape in path patterns.

The single version authority is `pinnedVersion` of the `rea` capability in
`skills/scripts/bootstrap-manifest.json`. Every other occurrence is derived from it and is
rewritten by `update-rea.ps1 -Mode Tracked`:

| Where | What carries the version |
|---|---|
| `skills/scripts/bootstrap-manifest.json`, `kali/scripts/bootstrap-manifest.json` | `npmPackage`, the `mcpArgs` element, `pinnedVersion`, the `note` (version, tool count, tools/list size, `npx -y rea-agents@<v> mcp`) |
| `skills/scripts/lib/ToolDiscovery.ps1` | catalog row `FixedVersion = 'rea-agents@<v>'` |
| `RULES.md`, `RULES_zh.md` | the `rea` row of the MCP service table (version, tool count, runner command) |
| `skills/js-reverse/SKILL.md` | the "rea 可用" paragraph names the version; `dotnet-reverse`, `macos-reverse`, `apk-reverse`, `browser-extension-reverse` carry the paragraph without a version |
| `skills/ops/evidence-finding-path.md` | §5.1 row and the §5.2 `-ReproCommand` example |
| `skills/references/community-security-skills.md` | the rea row (version, tool and prompt counts) |
| `docs/mcp/rea.md` | the "Current pin" line above, the `rea-agents@<v>` argument in the four registration-shape code blocks, and the Bump log below; the dated rows of the facts table are history and stay as they are |
| gitignored mirrors `.mcp.json`, `.codex/config.toml`, `.agents/mcp_config.json`, `.dsh/agent-presets/reverse-skill/agent.cordis.yml` | the `rea-agents@<v>` argument of the rea entry (`update-rea.ps1 -Mode Apply`) |

`rea setup` and `rea update` are **not** used: both write user-global client files
(`%USERPROFILE%\.claude.json` with `cmd.exe /d /c npx -y rea-agents@<v> mcp`, a skill under
`~\.agents\skills`) and know nothing about this project-scope layout. `rea doctor` therefore
reports every client registration as `missing`/`config_drift` forever; `claude mcp list` and
`codex mcp get rea` are the connection evidence instead.

## What works on this Windows host

Verified on 2026-10-09 (Node 24.20.0, npm 12.2.0), read-only and without `rea setup`;
re-verified on 2026-10-10 by `test-rea-contract.ps1 -Version 6.1.0`:

| Fact | Evidence |
|---|---|
| `npx -y rea-agents@6.1.0 --version` | `6.1.0` (package cached under `%APPDATA%\npm-cache\_npx`) |
| `rea setup --client claude_code --dry-run --json` | `status: planned`; would update **user-global** `%USERPROFILE%\.claude.json` with command `"cmd.exe" "/d" "/c" "npx" "-y" "rea-agents@6.1.0" "mcp"` (backup `.claude.json.rea.backup`) and install the skill to `%USERPROFILE%\.agents\skills\reverse-engineer-anything`. **Not applied** |
| `rea doctor --json` | exit 1 by design: `hopper` missing (Windows unsupported), `ghidra` `GHIDRA_INSTALL_DIR` unset (12.1.x required), `ida-registration` `REA_IDA_MCP_CONFIG` unset, `skill:identity` missing, every client registration `missing`/`config_drift`. Catalog identity: 94 CLI commands, **138 MCP tools**, 6 prompts |
| stdio handshake `node.exe npx-cli.js -y rea-agents@6.1.0 mcp` | `initialize` answered in 1–5 s (`serverInfo rea 6.1.0`, protocol `2025-06-18`), `tools/list` 138 tools in **one frame of 2,008,941 bytes**, `prompts/list` 6 prompts, `server/discover` → `-32601`, `ping` → `{}`, `resources/list` → `-32601`; stderr carries only JSON log lines for tool calls |
| `binary_session {}` on this host | 62 tools available target-free; 76 unavailable: 57 `target_required` (native tools, unlocked by `open_binary`), **Android** `inspect_android_package` / `inspect_android_class` / `inspect_android_method` / `search_android_classes` / `trace_android_references` = `unsupported_host` ("JADX subprocess ownership is unsupported on win32"), **macOS native** `inspect_macho` / `inspect_plist` / `inspect_signature` / `list_architectures` / `inspect_asset_catalog` / `demangle_swift` / `observe_native_*` / `capture_native_ui_scenario` = `unsupported_host`, `capture_process_scenario` = `unsupported_host` (Linux/macOS only), `extract_firmware` / `inspect_firmware_regions` (Binwalk/Unblob, Linux), `inspect_binary_layout` / `inspect_recorded_crash` (pwntools, Linux x64), `inspect_evm_interface` (Linux x64), `recover_javascript_sources` (Wakaru, Linux x64), `get_navigation_context` = `provider_missing` |
| offline fixture `analyze_javascript_application` on `work/rea-flow-test/sample` | returns `evidence_id` + `statistics` (relevant_files, parsed_javascript_files, modules, findings, …) in about 1 s |

Target-free on Windows and pointed at from the skills: `analyze_javascript_application`,
`trace_application_feature`, `compare_application_versions`, `inspect_managed_artifact`,
`inspect_managed_members`, `project_managed_application_graph`, `open_binary` → `inspect_artifact`
→ `project_android_application_graph` / `project_apple_application_graph`, `list_browser_targets`,
`inspect_web_page`, `analyze_web_bundle`, `observe_web_session`, `capture_browser_scenario`,
`inspect_web_network_capture`, `export_web_scripts`, `export_evidence_bundle` /
`import_evidence_bundle` / `get_evidence_bundle`. The 23 names referenced from `skills/` and
`docs/` are checked against every candidate catalog by `test-rea-contract.ps1`.

## Provider decisions

All three native providers stay unconfigured and `doctor` keeps reporting them red:

- **Hopper**: macOS/Linux only; setup says "Hopper installation remains unavailable on Windows".
- **Ghidra**: rea accepts Ghidra **12.1.x** only and wants `GHIDRA_INSTALL_DIR`/`JAVA_HOME` in
  the server environment. This host runs 12.0.2 with the loopback-patched GhydraMCP JAR
  (see host-deviations) and must not upgrade, so the env is not set and `Ghidra-mcp`
  remains the Ghidra path.
- **IDA**: rea's provider reuses an mrexodia/ida-pro-mcp registration (`REA_IDA_MCP_CONFIG`);
  the modern headless profile needs the `idalib_supervisor` API that the installed
  ida-pro-mcp 2.0.0 does not have, and the legacy profile would attach to the same
  `127.0.0.1:13337` backend that `ida-pro-mcp` already proxies. Double registration of one
  backend is what `docs/mcp/codex.md` warns against, so it is skipped.

Revisit only when a bump's CHANGELOG changes one of these facts (Ghidra version range, IDA
provider API, Windows support for Hopper/JADX).

## Registration shapes (the four mirrors)

Repo = `D:\Data\Coding_Github\Reverse\reverse-skill`; no env, no token, no provider variables.
The `node.exe` + `npx-cli.js` form is used instead of rea's own `cmd.exe /d /c npx` because a
quoted `C:\Program Files\nodejs\npx.cmd` under `cmd.exe` is the quote-stripping case documented
for the anything-analyzer proxy leg; the manifest keeps the portable `npx` vector and
bootstrap would render `cmd /c npx` (not used here). All four files are gitignored.

```json
// .mcp.json (Claude Code) — "rea" is also listed in .claude/settings.local.json enabledMcpjsonServers
"rea": {
  "type": "stdio",
  "command": "C:\\Program Files\\nodejs\\node.exe",
  "args": ["C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npx-cli.js", "-y", "rea-agents@6.3.0", "mcp"]
}
```

```json
// .agents/mcp_config.json (Antigravity) — no type, no cwd
"rea": {
  "command": "C:\\Program Files\\nodejs\\node.exe",
  "args": ["C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npx-cli.js", "-y", "rea-agents@6.3.0", "mcp"]
}
```

```yaml
# .dsh/agent-presets/reverse-skill/agent.cordis.yml (dsh web) — server/discover is -32601 natively
- id: mcp-rea
  name: "@deepseek-ai/dsh-mcp-client"
  config:
    serverName: rea
    transport: stdio
    command: C:\Program Files\nodejs\node.exe
    args:
      - C:\Program Files\nodejs\node_modules\npm\bin\npx-cli.js
      - -y
      - rea-agents@6.3.0
      - mcp
    cwd: D:\Data\Coding_Github\Reverse\reverse-skill
```

```toml
# .codex/config.toml (Codex) — added 2026-10-10; verified with `codex mcp get rea` and a headless
# `codex exec` run that called analyze_javascript_application + trace_application_feature.
# The 138-tool catalog loads into every Codex turn (measured: ~787k input tokens, 679k cached).
[mcp_servers."rea"]
command = 'C:\Program Files\nodejs\node.exe'
args = ['C:\Program Files\nodejs\node_modules\npm\bin\npx-cli.js', '-y', 'rea-agents@6.3.0', 'mcp']
startup_timeout_sec = 90
tool_timeout_sec = 300
enabled = true
```

Operational notes: the first spawn after an npx-cache purge downloads the package inside the
client's startup timeout (Claude Code about 30 s; keep the cache warm by running the contract
test first). `close_binary` clears the session's Evidence ledger, so `export_evidence_bundle`
into `work/<case>/evidence/rea/` first (`skills/ops/evidence-finding-path.md` §5.2).
`capture_browser_scenario` and the CDP tools only talk to a loopback CDP endpoint or an
executable the caller names, and `scope.md` must be granted before any of them touch a target.

## Catalog identity (two hashes, two methods)

| Hash | Value for 6.1.0 | How it is computed | Where it comes from |
|---|---|---|---|
| `tools_sha256` (rea's own) | `35487b43394b2482fb84d37ab7fb20c0315671f40a49c4c39b8d048a2c3db5a6` | Inside the server, `src/catalogIdentity.ts`: the tool **contracts** sorted by name, projected to `{name, title, surface, description, effects, annotations, input_schema, output_schema}` with `z.toJSONSchema`, serialized with `canonicalize` (RFC 8785) and SHA-256'd. Schema-sensitive, independent of the wire encoding | `binary_session {}` → `server_identity.catalog.tools_sha256`; also `rea doctor --json`. `test-rea-contract.ps1` reports it as `rea_tools_sha256` |
| `tools_list_sha256` (ours) | `6994ff1aa24272a5a09913f087907a25f279fd477108391db7ba3e0b35dafb9e` | SHA-256 of the **raw bytes of the `tools/list` response frame** as it arrived on stdout (request `id` fixed at 2; if the server ever paginates, frames are joined with `\n`). Depends on the server's JSON serializer, key order and the request id, which is exactly why it detects wire-level changes that the contract hash would not, and vice versa | `test-rea-contract.ps1` (`tools_list_sha256` in the catalog file and report) |

Both are recorded per version in the Bump log. They are not comparable with each other; compare
each only with its own kind across versions. For "what actually changed", use the semantic
diff (`-PreviousCatalog`): added / removed tools and tools whose `description`,
`inputSchema`, `outputSchema` or `annotations` differ after recursive key sorting.

## Tooling

All scripts live in `skills/scripts/` and share `skills/scripts/lib/ReaTooling.ps1`.
`check-rea-upstream.ps1` and `update-rea.ps1` run on Windows PowerShell 5.1 or pwsh 7;
`test-rea-contract.ps1` needs **pwsh 7** (it kills the npx process tree with `Kill($true)`).

| Script | Purpose | Writes | Exit codes |
|---|---|---|---|
| `check-rea-upstream.ps1` | pin vs `npm view rea-agents dist-tags.latest`; engines + `dist.integrity` of latest; versions between pin and latest (`behind_by`); CHANGELOG sections and `⚠ BREAKING CHANGES` bullets from the sibling clone **as checked out** (no `git fetch`); clone HEAD reported | nothing (JSON on stdout) | 0 up to date, 3 update available, 2 latest unknown; secondary failures in `lookup_failures[]` |
| `test-rea-contract.ps1 -Version <v> [-FixtureDir <dir>] [-PreviousCatalog <json>] [-OutputPath] [-ReportPath]` | real handshake against `rea-agents@<v>`, full `tools/list`, catalog file, `tools_list_sha256`, `rea_tools_sha256`, semantic diff, referenced-tool check over `skills/` + `docs/` (rg if present, else Select-String over git-visible files), optional `analyze_javascript_application` on the fixture (`evidence_id` + `statistics` required) | catalog + report JSON (default `%TEMP%\rea-contract\<v>-catalog.json` / `<v>-report.json`), scratch cwd | 0 pass, 1 fail |
| `update-rea.ps1 -Version <v> -Mode Tracked\|Apply\|Both [-ContractReport <report>] [-Note]` | Tracked: anchored string edits in every tracked carrier above (counts from the report), bump-log row, residual `git grep`; Apply: rea entry of each existing mirror, byte-preserving, then prints `claude mcp list` / `codex mcp get rea` | the listed files only | 0 ok, 1 anchor/edit failure (nothing written), 4 stale references remain, 5 Apply refused |
| `test-rea-tooling.ps1` | fixture-based regression for the Tracked/Apply edits, mirror entry location, catalog diff, changelog parsing, version compare, reference scanner | temp fixture tree only | 0 pass, 1 fail |

## Bump procedure

One bump = one tracked commit + one separate local apply step, because the mirrors are
gitignored. Use a short-lived branch (`dev/rea-<new-version>`), never commit from `main`.

1. **Notice**: `pwsh -NoProfile -File skills/scripts/check-rea-upstream.ps1`. Exit 3 means a
   newer release exists; read `breaking_changes[]` and `changelog_excerpt`. If
   `lookup_failures[]` says the clone has no section for the new version, refresh the
   read-only clone by hand (`git -C D:\Data\Coding_Github\Reverse\rea fetch --tags && git -C ... pull`)
   and re-run; the script itself never fetches.
2. **Contract test the candidate** (downloads into the npx cache, no install):
   `pwsh -NoProfile -File skills/scripts/test-rea-contract.ps1 -Version <new> -FixtureDir work/rea-flow-test/sample -PreviousCatalog $env:TEMP\rea-contract\<old>-catalog.json`.
   Run the old version once first if its catalog file is missing. Read the diff: a removed or
   renamed tool that the skills reference fails the run; a changed `inputSchema` on a
   referenced tool means the SKILL paragraph needs a re-read even though the run passes.
   Check `node_engines` against the host Node.
3. **Tracked update on the branch**:
   `pwsh -NoProfile -File skills/scripts/update-rea.ps1 -Version <new> -Mode Tracked -ContractReport $env:TEMP\rea-contract\<new>-report.json -Note "<why>"`.
   Review `git diff` (manifests, ToolDiscovery, RULES rows, SKILL paragraph, ops/references
   docs, this file). Adjust the SKILL paragraphs and the provider decisions above by hand if
   the CHANGELOG changed behaviour the paragraphs describe. Commit (`chore(mcp): bump rea to <new>`).
4. **Apply to the mirrors** (local, not committed):
   `pwsh -NoProfile -File skills/scripts/update-rea.ps1 -Version <new> -Mode Apply -ContractReport $env:TEMP\rea-contract\<new>-report.json`.
   It refuses without a passing report for exactly that version.
5. **Reconnect the clients**: restart or `/mcp` reconnect in Claude Code, then `claude mcp list`
   (rea ✓ Connected) and `codex mcp get rea`; restart Antigravity / dsh web so they re-read
   the project files. Expect the first start to be slower if the npx cache was cold.
6. **Repository checks**: `skills/scripts/test-rea-tooling.ps1`, `verify-routing-coherence.ps1`,
   `smoke.ps1`, `test-routing.ps1`; `refresh-tool-index.ps1` must still show the rea row as
   Registered ✓ Ready ✓.
7. **Strict case review on an offline fixture**: re-run the js flow on `work/rea-flow-test`
   (analyze → trace → `export_evidence_bundle` → `append-evidence.ps1`) and
   `python skills/case-review/scripts/review_case.py --strict work/rea-flow-test`; the .NET
   fixture `work/rea-dotnet-test` when the diff touched `inspect_managed_*`.
8. Record anything the bump broke or changed on this host in
   [host-deviations.md](host-deviations.md) (register) and in the Bump log here (the row is
   appended automatically; edit its Note if needed).

## Rollback

- **Tracked**: `git revert <bump commit>` on the branch (or `update-rea.ps1 -Version <old> -Mode Tracked`
  with the old report, which appends a downgrade row to the Bump log instead of rewriting
  history). Either way `pinnedVersion` must read `<old>` afterwards (`Get-ReaManifestPin`).
- **Mirrors**: `update-rea.ps1 -Version <old> -Mode Apply -ContractReport $env:TEMP\rea-contract\<old>-report.json`
  (the old report still exists if step 2 was followed; otherwise re-run the contract test for
  `<old>`, it is read-only against the npx cache). Then reconnect the clients as in step 5.
  The old package stays in `%APPDATA%\npm-cache\_npx`, so the rollback start is fast.
- Never edit the pinned package inside the npx cache, and never point a mirror at a version
  the manifest does not pin except during steps 4–7 of a bump in progress.

## Bump log

| Date | From → To | Tool count | tools_list_sha256 | Note |
|---|---|---|---|---|
| 2026-10-09 | — → 6.1.0 | 138 | `6994ff1aa24272a5a09913f087907a25f279fd477108391db7ba3e0b35dafb9e` | initial adoption (hand-registered, project scope); rea `tools_sha256` `35487b43394b2482fb84d37ab7fb20c0315671f40a49c4c39b8d048a2c3db5a6`; hash measured 2026-10-10 by test-rea-contract.ps1 |
| 2026-10-10 | 6.1.0 → 6.3.0 | 139 | `3cb70bd86fa468fa2c502fddd68b7b9bb4c6cd817df25290fdfe70f0281d2d94` | 6.2.0/6.3.0 breaking: results are canonical Evidence records (read normalized_result); semantic graphs carry evidence_contexts; truncated_scopes removed; contract test PASS, 23 referenced tools present, +inspect_analysis_view |
