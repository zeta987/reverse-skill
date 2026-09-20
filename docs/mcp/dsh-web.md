# Local Windows dsh web adapter

This adapter keeps analysis MCP configuration in the repository and uses DSH's
native Agent preset selection. The local Windows DSH Node backend starts the
stdio bridges. Read the [shared guide](README.md) for backend startup and ports.

## Repository preset and scope

Verified with DSH 0.1.6-alpha.2. Store the local preset as:

```text
<repo>/.dsh/agent-presets/reverse-skill/
  agent.cordis.yml
  preset.yml
```

Create `agent.cordis.yml` from the **installed version's complete Standard
preset**, retaining its tools, prompts, services, and configuration, then append
one `@deepseek-ai/dsh-mcp-client` entry per server. A preset is a raw plugin list;
the profile overlay's `insert` wrapper does not belong in this file.

```yaml
# Append after the complete installed Standard composition.
- id: mcp-example
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: reverse-example
    transport: stdio
    command: '<resolved-python-executable>'
    args: ['<verified-bridge-script>']
    cwd: '<bridge-working-directory>'
    toolCallTimeoutMs: 300000
```

Use the command, argument, and environment mapping in the [Codex adapter](codex.md)
for IDA, Ghidra, x64dbg, and math. Local entry IDs are `mcp-ida-pro`,
`mcp-ghidra`, `mcp-x64dbg`, and `mcp-math`; namespaces are `ida-pro`, `ghidra`,
`x64dbg`, and `math`. Tools are named `mcp__<serverName>__<toolName>`.

`preset.yml` supplies the Web display metadata:

```yaml
name: Reverse Skill
description: Standard coding tools plus repo-defined IDA, Ghidra, x64dbg and math MCPs. Select explicitly per session.
```

Machine-specific presets are gitignored. The agent resolves installed paths and
creates these files; the user does not need to execute example commands.

## Register the preset root once

The Web profile needs a discovery pointer to the repository. Merge the following
configuration into its existing `agent-presets` entry in
`<DSH_HOME>/profiles/web/cordis.patch.yml`, preserving the current default,
configured roots, and inclusion flags:

```yaml
- id: agent-presets
  config:
    default: standard
    roots:
      - path: '<existing-user-preset-root>'
        trust: user
      - path: '<absolute-repo-path>/.dsh/agent-presets'
        trust: user
    includeShippedRoot: true
    includeUserRoot: true
```

This illustrates the verified installation's settings, not values to overwrite
on every machine. Keep the existing user root before the new repo root: the
first writable user root is also used for Web preset creation. If a higher
priority home or launch overlay changes this entry, resolve that conflict before
writing. Configuration replacement is not a nested deep merge.

Remove only the four previously added global MCP entries after validating their
preset replacement. Save an exact backup and check entry ID/server namespace
collisions. Preserve unrelated plugins, providers, credentials, models, and
permission settings. No DSH source modification or second Web process is needed.

In Web, select **Reverse Skill** when starting the analysis session. Select the
analysis workspace separately. The existing default remains **Standard**.
Only empty sessions can switch presets in this version.

**This is preset scope, not automatic workspace scope.** DSH does not discover a
repo `.dsh/cordis.patch.yml` when its session cwd changes. Selecting Reverse Skill
from another workspace still enables its MCPs. A bridge's `cwd` cannot limit
tool visibility. Sessions using the same preset share its standing scope and
MCP connections, so coordinate shared debugger/database state.

## Verification and reload

Validate using the installed DSH package, not an older fallback npx installation:

1. Parse the effective profile with pure composition APIs and discover the full
   preset with native `discoverPresets()`. Check all modules resolve and that the
   four MCP entries are absent from the global composition.
2. Mount the four actual MCP rows through native `AgentPresets.mount()` in a
   minimal context. Enumerate selected, sibling, and root tool views; call math
   `add(19,23)` in the selected scope and verify sibling access is rejected.
   Dispose the context and child bridges. This needs no provider or model call.
3. Refresh the live Web inventory. Confirm Reverse Skill appears, its session
   plugin list includes four MCPs, and Standard/global lists exclude those four.
   An inventory row marked enabled does not prove a backend call succeeded.
4. For analysis readiness, start/reuse the authorized backend and verify IDA's
   database identity, Ghidra's program, and x64dbg's raw HTTP status plus MCP
   status. Bridge tools can be discoverable while those backends are stopped.

The local migration passed steps 1–3: full preset discovery resolved 23 top-level
entries; the four-row runtime fixture exposed **138 tools** (42/40/34/22), with
zero in sibling/root views; math returned 42 and sibling execution was rejected.
Web displayed 33 preset plugin rows versus Standard's 29, and 186 global rows
after removal. The runtime fixture did not mount the Standard rows, create a
live Web session, or send a model request. These counts describe this tested
installation, not future package versions.

With HMR enabled, DSH watches profile/home patches and reloads affected entries;
CLI `--patch` file content is read at startup. Web inventory can retain a snapshot
until its panel is reopened or the page refreshed. Changing the preset root can
rebuild its standing scopes: do it when no affected operation is running, and
do not promise existing live sessions are unaffected. Editing a mounted preset
file also requires verification of the actual mounted composition; discovery
alone does not prove its existing connections were reloaded.

`disabled: true` belongs on a plugin entry. Unknown MCP config fields such as
`enabled`, `perms`, or `allowTools` do not implement permission controls in this
version. `reconnect.enabled` only controls reconnection. With default
`failOnStartupError: false`, an active plugin may still lack a working connection.

Avoid `dsh --dump-config` for read-only inspection: it prepares the profile and
can rewrite generated configuration or print secrets. Use narrow YAML and pure
composition/schema reads. Do not put browser authentication URLs in repo files.

Sources, checked against the local checkout and installed 0.1.6-alpha.2:
[Agent presets](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/preset/agent-presets),
[profile composition](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/boot/app-boot),
[MCP client](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/mcp/mcp-client),
[scope](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/core/scope),
[plugin inventory](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/host/plugin-inventory).
