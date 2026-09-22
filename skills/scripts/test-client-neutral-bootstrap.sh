#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/bootstrap-reverse.sh"
REFRESH="$SCRIPT_DIR/refresh-tool-index.sh"
SCRATCH="$(mktemp -d /tmp/reverse-client-neutral-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

HOME_DIR="$SCRATCH/home"
BIN_DIR="$SCRATCH/bin"
TOOLS_DIR="$SCRATCH/tools"
CLAUDE_CFG="$SCRATCH/client/claude.json"
CODEX_CFG="$SCRATCH/client/codex.toml"
mkdir -p "$HOME_DIR" "$BIN_DIR" "$TOOLS_DIR" "$(dirname "$CLAUDE_CFG")"

for name in bash date dirname head mktemp python3 rm sed tr uname; do
  ln -s "$(command -v "$name")" "$BIN_DIR/$name"
done

for name in node npm npx; do
  cat > "$BIN_DIR/$name" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo 1.0.0; fi
exit 0
STUB
  chmod +x "$BIN_DIR/$name"
done

cat > "$BIN_DIR/ghidra" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN_DIR/ghidra"

cat > "$BIN_DIR/pwn" <<'STUB'
#!/bin/bash
if [[ $# -ne 1 || "$1" != "version" ]]; then
  printf 'pwn test stub: expected exactly one argument: version; got:' >&2
  printf ' <%s>' "$@" >&2
  printf '\n' >&2
  exit 64
fi
if [[ "${PWNLIB_NOTERM:-}" != "1" ]]; then
  printf '%s\n' 'Warning: _curses.error: setupterm: could not find terminfo database' >&2
fi
printf '%s\n' '[*] Pwntools v4.15.0' >&2
STUB
chmod +x "$BIN_DIR/pwn"

export PATH="$BIN_DIR:$PATH"
export HOME="$HOME_DIR"
export REVERSE_SKILL_TOOLS_DIR="$TOOLS_DIR"
export CLAUDE_MCP_CONFIG="$CLAUDE_CFG"
export CODEX_CONFIG_PATH="$CODEX_CFG"

MD="$SCRATCH/tool-index.md"
JSON="$SCRATCH/tool-index.json"
(
  unset TERM PWNLIB_NOTERM
  PATH="$BIN_DIR" "$BIN_DIR/bash" "$REFRESH" "$MD" "$JSON" >/dev/null
)

python3 - "$JSON" "$BIN_DIR/ghidra" "$BIN_DIR/pwn" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
tools = data['tools']
assert sum(t['name'] == 'binwalk' for t in tools) == 1, 'binwalk must appear exactly once'
by_tool = {t['name']: t for t in tools}
assert by_tool['npx']['available'] is True
assert by_tool['jshookmcp']['available'] is False, 'npx must not masquerade as jshookmcp'
assert by_tool['reqable-mcp']['available'] is False, 'npx must not masquerade as reqable-mcp'
assert by_tool['ghidra']['available'] is True, 'the distro-provided ghidra launcher must be discovered'
assert os.path.realpath(by_tool['ghidra']['path']) == os.path.realpath(sys.argv[2])
pwntools_matches = [tool for tool in tools if tool.get('name') == 'pwntools']
if len(pwntools_matches) != 1:
    raise SystemExit(
        f"expected exactly one pwntools tool record, got {len(pwntools_matches)}"
    )
pwntools = pwntools_matches[0]
expected_pwntools = {
    'available': True,
    'version': '[*] Pwntools v4.15.0',
    'source': 'command',
    'skill': 'reverse-engineering',
    'purpose': 'CTF pwn exploit development framework',
}
for field, expected in expected_pwntools.items():
    if pwntools.get(field) != expected:
        raise SystemExit(
            f"pwntools {field} must be {expected!r}, got {pwntools.get(field)!r}"
        )
if os.path.realpath(pwntools.get('path') or '') != os.path.realpath(sys.argv[3]):
    raise SystemExit(
        "pwntools path must resolve to the strict pwn stub: "
        f"got {pwntools.get('path')!r}"
    )
by_cap = {c['name']: c for c in data['capabilities']}
assert by_cap['jshookmcp']['ready'] is False
assert by_cap['reqable-mcp']['ready'] is False
PY

cat > "$CODEX_CFG" <<'EOF'
[mcp_servers.jshook]
command = "npx"
args = ["-y", "@jshookmcp/jshook@0.3.4"]
EOF
bash "$REFRESH" "$MD" "$JSON" >/dev/null
python3 - "$JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
cap = {c['name']: c for c in data['capabilities']}['jshookmcp']
assert cap['mcp_registered'] is True, 'Codex-only MCP registration must be discovered'
assert cap['runtime_available'] is True
assert cap['ready'] is True, 'registered npm MCP + npx runtime should be ready'
PY

rm -f "$CLAUDE_CFG" "$CODEX_CFG"
default_out="$(bash "$BOOTSTRAP" jshookmcp --skip-refresh)"
[[ "$default_out" == *'"status":"registration-required"'* || "$default_out" == *'"status": "registration-required"'* ]]
[[ ! -e "$CLAUDE_CFG" ]]
[[ ! -e "$CODEX_CFG" ]]

codex_out="$(bash "$BOOTSTRAP" jshookmcp --skip-refresh --mcp-host=codex)"
[[ "$codex_out" == *'"status":"ready"'* || "$codex_out" == *'"status": "ready"'* ]]
[[ ! -e "$CLAUDE_CFG" ]]
grep -Eq '^\[mcp_servers\.jshook\]$' "$CODEX_CFG"

rm -f "$CLAUDE_CFG" "$CODEX_CFG"
claude_out="$(bash "$BOOTSTRAP" jshookmcp --skip-refresh --mcp-host=claude)"
[[ "$claude_out" == *'"status":"ready"'* || "$claude_out" == *'"status": "ready"'* ]]
[[ -f "$CLAUDE_CFG" ]]
[[ ! -e "$CODEX_CFG" ]]
python3 - "$CLAUDE_CFG" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
assert 'jshook' in data.get('mcpServers', {})
PY

echo 'client-neutral Bash bootstrap/discovery regression passed'
