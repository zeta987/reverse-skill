#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REFRESH="$SCRIPT_DIR/refresh-tool-index.sh"
DISCOVERY="$SCRIPT_DIR/lib/tool-discovery.sh"
BOOTSTRAP="$SCRIPT_DIR/bootstrap-reverse.sh"
REAL_BASH="$(command -v bash)"
REAL_PYTHON="$(command -v python3)"
SCRATCH="$(mktemp -d /tmp/reverse-pwntools-discovery-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

BIN_DIR="$SCRATCH/bin"
HOME_DIR="$SCRATCH/home"
FIXTURE_SCRIPTS="$SCRATCH/fixture/kali/scripts"
OUTPUT_MD="$SCRATCH/tool-index.md"
OUTPUT_JSON="$SCRATCH/tool-index.json"
mkdir -p "$BIN_DIR" "$HOME_DIR" "$FIXTURE_SCRIPTS/lib"

# Exercise a byte-for-byte copy of the production refresh path and discovery
# catalog, changing only the port probe in the temporary copy. This prevents
# localhost connections while preserving the real discovery implementation.
cp "$REFRESH" "$FIXTURE_SCRIPTS/refresh-tool-index.sh"
cp "$DISCOVERY" "$FIXTURE_SCRIPTS/lib/tool-discovery.sh"
"$REAL_PYTHON" - "$FIXTURE_SCRIPTS/lib/tool-discovery.sh" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
starts = [index for index, line in enumerate(lines) if line.rstrip("\r\n") == "test_tcp_port() {"]
if len(starts) != 1:
    raise SystemExit(f"expected exactly one test_tcp_port function, found {len(starts)}")

start = starts[0]
ends = [index for index in range(start + 1, len(lines)) if lines[index].rstrip("\r\n") == "}"]
if not ends:
    raise SystemExit("could not find the end of test_tcp_port")
end = ends[0]
if end - start > 20:
    raise SystemExit("test_tcp_port is no longer the expected short function")

lines[start : end + 1] = ["test_tcp_port() {\n", "    return 1\n", "}\n"]
path.write_text("".join(lines), encoding="utf-8")
PY
REFRESH="$FIXTURE_SCRIPTS/refresh-tool-index.sh"

# Keep discovery hermetic: expose only the host utilities required by the real
# refresh script. In particular, no host security tools can leak into results.
for name in bash date dirname head mktemp python3 uname; do
    source_path="$(command -v "$name")" || {
        echo "required test dependency not found: $name" >&2
        exit 1
    }
    ln -s "$source_path" "$BIN_DIR/$name"
done

HAVE_JQ=false
if source_path="$(command -v jq 2>/dev/null)"; then
    ln -s "$source_path" "$BIN_DIR/jq"
    HAVE_JQ=true
else
    echo "SKIP: jq is unavailable; JSON-only pwntools assertions will not run" >&2
fi

cat > "$BIN_DIR/pwn" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "--version" ]]; then
    printf '%s\n' 'Pwntools 4.15.0'
fi
exit 0
STUB
chmod +x "$BIN_DIR/pwn"

# Always pass temporary output paths and a temporary HOME: this must not write
# generated indexes into the repository or inspect client-global config.
env PATH="$BIN_DIR" HOME="$HOME_DIR" \
    "$REAL_BASH" "$REFRESH" "$OUTPUT_MD" "$OUTPUT_JSON" >/dev/null

if [[ "$HAVE_JQ" == "true" ]]; then
    "$REAL_PYTHON" - "$OUTPUT_JSON" "$BIN_DIR/pwn" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)

matches = [tool for tool in data["tools"] if tool.get("name") == "pwntools"]
assert len(matches) == 1, f"expected exactly one pwntools entry, got {len(matches)}"
pwntools = matches[0]
assert pwntools.get("available") is True, "pwntools must be available through the pwn command"
assert os.path.realpath(pwntools.get("resolved_path", "")) == os.path.realpath(sys.argv[2]), (
    f"pwntools resolved_path must point to the pwn stub: {pwntools.get('resolved_path')!r}"
)
assert pwntools.get("version") == "Pwntools 4.15.0", (
    f"expected pwntools version 'Pwntools 4.15.0', got {pwntools.get('version')!r}"
)
PY
fi

"$REAL_PYTHON" - "$OUTPUT_MD" <<'PY'
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
in_capability_view = False
matches = []
for line in lines:
    if line.strip().startswith("## 能力状态视图"):
        in_capability_view = True
        continue
    if not in_capability_view or not line.lstrip().startswith("|"):
        continue
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if cells and cells[0] == "pwntools":
        matches.append(cells)

assert len(matches) == 1, f"expected exactly one pwntools capability row, got {len(matches)}"
row = matches[0]
assert len(row) >= 6, f"malformed pwntools capability row: {row!r}"
assert row[1] == "✓", f"pwntools capability must be available, got {row[1]!r}"
assert row[5] == "pip-package", f"pwntools install method must be pip-package, got {row[5]!r}"
PY

list_output="$(env PATH="$BIN_DIR" HOME="$HOME_DIR" "$REAL_BASH" "$BOOTSTRAP" --list)"
"$REAL_PYTHON" - "$list_output" <<'PY'
import sys

tokens = sys.argv[1].split()
assert "pwntools" in tokens, "bootstrap --list must include the complete token 'pwntools'"
PY

"$REAL_PYTHON" - \
    "$REPO_ROOT/skills/scripts/bootstrap-manifest.json" \
    "$REPO_ROOT/kali/scripts/bootstrap-manifest.json" <<'PY'
import json
import sys

for manifest_path in sys.argv[1:]:
    with open(manifest_path, encoding="utf-8") as stream:
        manifest = json.load(stream)
    matches = [cap for cap in manifest["capabilities"] if cap.get("name") == "pwntools"]
    assert len(matches) == 1, f"{manifest_path}: expected exactly one pwntools capability"
    assert matches[0].get("verifyCommand") == "pwn", (
        f"{manifest_path}: pwntools verifyCommand must be 'pwn', "
        f"got {matches[0].get('verifyCommand')!r}"
    )
PY

echo "Kali pwntools discovery regression passed"
