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
trap 'rm -rf -- "$SCRATCH"' EXIT

BIN_DIR="$SCRATCH/bin"
HOME_DIR="$SCRATCH/home"
FIXTURE_SCRIPTS="$SCRATCH/fixture/kali/scripts"
OUTPUT_MD="$SCRATCH/tool-index.md"
OUTPUT_JSON="$SCRATCH/tool-index.json"
mkdir -p "$BIN_DIR" "$HOME_DIR" "$FIXTURE_SCRIPTS/lib"

# Exercise temporary copies of the production refresh path and discovery
# catalog. Disable the port probe and quarantine literal absolute fallback
# paths in the copied catalog so the fixture cannot contact localhost or run a
# host security tool outside its isolated PATH.
cp "$REFRESH" "$FIXTURE_SCRIPTS/refresh-tool-index.sh"
cp "$DISCOVERY" "$FIXTURE_SCRIPTS/lib/tool-discovery.sh"
"$REAL_PYTHON" - \
    "$DISCOVERY" \
    "$FIXTURE_SCRIPTS/lib/tool-discovery.sh" \
    "$SCRATCH/unavailable-host-paths" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
fixture_path = Path(sys.argv[2])
unavailable_root = Path(sys.argv[3])
source_bytes = source_path.read_bytes()
source_hash = hashlib.sha256(source_bytes).hexdigest()
source_text = source_bytes.decode("utf-8")
fixture_text = fixture_path.read_text(encoding="utf-8")


def catalog_bounds(catalog_lines, label):
    starts = [
        index
        for index, line in enumerate(catalog_lines)
        if line.rstrip("\r\n") == "declare -a TOOL_CATALOG=("
    ]
    if len(starts) != 1:
        raise SystemExit(
            f"{label} must contain exactly one TOOL_CATALOG declaration; "
            f"found {len(starts)}"
        )
    start = starts[0]
    ends = [
        index
        for index in range(start + 1, len(catalog_lines))
        if catalog_lines[index].rstrip("\r\n") == ")"
    ]
    if not ends:
        raise SystemExit(f"could not find the end of {label} TOOL_CATALOG")
    return start, ends[0]

port_probe = """test_tcp_port() {
    local port="$1"
    local host="${2:-127.0.0.1}"
    (echo >/dev/tcp/"$host"/"$port") 2>/dev/null && return 0
    # fallback to nc
    nc -z "$host" "$port" 2>/dev/null && return 0
    return 1
}
"""
if fixture_text.count(port_probe) != 1:
    raise SystemExit(
        "expected exactly one canonical test_tcp_port source block, "
        f"found {fixture_text.count(port_probe)}"
    )
fixture_text = fixture_text.replace(
    port_probe,
    "test_tcp_port() {\n    return 1\n}\n",
    1,
)

lines = fixture_text.splitlines(keepends=True)
catalog_start, catalog_end = catalog_bounds(lines, "temporary fixture")
source_lines = source_text.splitlines(keepends=True)
source_catalog_start, source_catalog_end = catalog_bounds(
    source_lines, "production source"
)
entry_pattern = re.compile(r'^(\s*)"([^"]*)"(\r?\n)?$')
rewritten = 0
source_pwntools_lines = [
    line
    for line in source_lines[source_catalog_start + 1 : source_catalog_end]
    if line.strip().startswith('"pwntools|')
]
if len(source_pwntools_lines) != 1:
    raise SystemExit(
        "production catalog must contain exactly one pwntools row; "
        f"found {len(source_pwntools_lines)}"
    )

source_pwntools_match = entry_pattern.fullmatch(source_pwntools_lines[0])
if source_pwntools_match is None:
    raise SystemExit(
        f"production pwntools catalog row is malformed: {source_pwntools_lines[0]!r}"
    )
source_pwntools_fields = source_pwntools_match.group(2).split("|")
if len(source_pwntools_fields) != 5:
    raise SystemExit(
        "production pwntools catalog row must have exactly five fields: "
        f"{source_pwntools_match.group(2)!r}"
    )
contract_errors = []
if source_pwntools_fields[4] != "pwn":
    contract_errors.append(
        "production pwntools fallback_text must be exactly 'pwn', "
        f"got {source_pwntools_fields[4]!r}"
    )
if source_pwntools_fields[3] != "--version":
    contract_errors.append(
        "production pwntools version_args must be exactly '--version', "
        f"got {source_pwntools_fields[3]!r}"
    )
if contract_errors:
    raise SystemExit(
        "production pwntools catalog contract failed:\n- "
        + "\n- ".join(contract_errors)
    )

for index in range(catalog_start + 1, catalog_end):
    stripped = lines[index].strip()
    if not stripped or stripped.startswith("#"):
        continue
    match = entry_pattern.fullmatch(lines[index])
    if match is None:
        raise SystemExit(f"malformed TOOL_CATALOG line {index + 1}: {lines[index]!r}")
    indent, payload, newline = match.groups()
    fields = payload.split("|")
    if len(fields) != 5:
        raise SystemExit(
            f"TOOL_CATALOG line {index + 1} must have exactly five fields: {payload!r}"
        )
    name, skill, purpose, version_args, fallback_text = fields
    if name == "pwntools":
        if lines[index] != source_pwntools_lines[0]:
            raise SystemExit("temporary pwntools catalog row differs from production")
        continue

    candidates = fallback_text.split(",") if fallback_text else []
    for candidate_index, candidate in enumerate(candidates):
        if not candidate.startswith("/"):
            continue
        candidates[candidate_index] = str(
            unavailable_root / f"{name}-{candidate_index}"
        )
        rewritten += 1
    fields[4] = ",".join(candidates)
    lines[index] = f'{indent}"{"|".join(fields)}"{newline or ""}'

if rewritten <= 0:
    raise SystemExit("expected to quarantine at least one absolute catalog fallback")

fixture_pwntools_lines = [
    line
    for line in lines[catalog_start + 1 : catalog_end]
    if line.strip().startswith('"pwntools|')
]
if fixture_pwntools_lines != source_pwntools_lines:
    raise SystemExit("pwntools row was not preserved exactly in the temporary catalog")

for index in range(catalog_start + 1, catalog_end):
    stripped = lines[index].strip()
    if not stripped or stripped.startswith("#"):
        continue
    match = entry_pattern.fullmatch(lines[index])
    if match is None:
        raise SystemExit(f"rewritten TOOL_CATALOG line {index + 1} is malformed")
    fields = match.group(2).split("|")
    for candidate in fields[4].split(",") if fields[4] else []:
        if candidate.startswith("/") and not candidate.startswith(f"{unavailable_root}/"):
            raise SystemExit(
                f"absolute fallback escaped quarantine on line {index + 1}: {candidate!r}"
            )

fixture_path.write_text("".join(lines), encoding="utf-8")
source_hash_after = hashlib.sha256(source_path.read_bytes()).hexdigest()
if source_hash_after != source_hash:
    raise SystemExit(
        "production tool-discovery.sh changed while creating the fixture: "
        f"before={source_hash}, after={source_hash_after}"
    )
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
    echo "INFO: jq is unavailable; validating the documented fallback JSON contract" >&2
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

"$REAL_PYTHON" - \
    "$OUTPUT_MD" \
    "$OUTPUT_JSON" \
    "$BIN_DIR/pwn" \
    "$HAVE_JQ" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

markdown_path = Path(sys.argv[1])
json_path = Path(sys.argv[2])
pwn_stub = sys.argv[3]
have_jq = sys.argv[4] == "true"
lines = markdown_path.read_text(encoding="utf-8").splitlines()
errors = []


def parse_markdown_row(line):
    stripped = line.strip()
    if not (stripped.startswith("|") and stripped.endswith("|")):
        return None
    return [cell.strip() for cell in stripped[1:-1].split("|")]


tool_header = ["工具", "归属 skill", "作用", "可用", "路径", "版本", "来源", "脚本引用"]
tool_headers = [
    index for index, line in enumerate(lines) if parse_markdown_row(line) == tool_header
]
tool_matches = []
if len(tool_headers) != 1:
    errors.append(f"expected exactly one Markdown tool table, got {len(tool_headers)}")
else:
    for line in lines[tool_headers[0] + 2 :]:
        row = parse_markdown_row(line)
        if row is None:
            break
        if row and row[0] == "pwntools":
            tool_matches.append(row)

if len(tool_matches) != 1:
    errors.append(
        f"expected exactly one pwntools Markdown tool row, got {len(tool_matches)}"
    )
else:
    tool_row = tool_matches[0]
    if len(tool_row) != 8:
        errors.append(
            f"pwntools Markdown tool row must have exactly 8 columns: {tool_row!r}"
        )
    else:
        if tool_row[3] != "yes":
            errors.append(f"pwntools Markdown availability must be 'yes', got {tool_row[3]!r}")
        if os.path.realpath(tool_row[4]) != os.path.realpath(pwn_stub):
            errors.append(
                "pwntools Markdown path must resolve to the pwn stub: "
                f"got {tool_row[4]!r}"
            )
        if tool_row[5] != "Pwntools 4.15.0":
            errors.append(
                "pwntools Markdown version must be 'Pwntools 4.15.0', "
                f"got {tool_row[5]!r}"
            )

capability_headings = [
    index
    for index, line in enumerate(lines)
    if line.startswith("## ") and line[3:].startswith("能力状态视图")
]
capability_matches = []
if len(capability_headings) != 1:
    errors.append(
        f"expected exactly one capability-view heading, got {len(capability_headings)}"
    )
else:
    section_start = capability_headings[0] + 1
    section_end = len(lines)
    for index in range(section_start, len(lines)):
        if re.match(r"^##(?:\s|$)", lines[index]):
            section_end = index
            break
    for line in lines[section_start:section_end]:
        row = parse_markdown_row(line)
        if row and row[0] == "pwntools":
            capability_matches.append(row)

if len(capability_matches) != 1:
    errors.append(
        "expected exactly one pwntools capability row before the next level-2 "
        f"heading, got {len(capability_matches)}"
    )
else:
    capability_row = capability_matches[0]
    if len(capability_row) != 6:
        errors.append(
            "pwntools capability row must have exactly 6 columns: "
            f"{capability_row!r}"
        )
    else:
        if capability_row[1] != "✓":
            errors.append(
                f"pwntools capability must be available, got {capability_row[1]!r}"
            )
        if capability_row[5] != "pip-package":
            errors.append(
                "pwntools install method must be 'pip-package', "
                f"got {capability_row[5]!r}"
            )

try:
    with json_path.open(encoding="utf-8") as stream:
        data = json.load(stream)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"tool-index JSON is not parseable: {exc}") from exc

if not isinstance(data, dict):
    errors.append(f"tool-index JSON root must be an object, got {type(data).__name__}")
elif have_jq:
    tools = data.get("tools")
    if not isinstance(tools, list):
        errors.append("jq JSON output must contain a tools array")
    else:
        json_matches = [
            tool
            for tool in tools
            if isinstance(tool, dict) and tool.get("name") == "pwntools"
        ]
        if len(json_matches) != 1:
            errors.append(
                f"expected exactly one pwntools JSON entry, got {len(json_matches)}"
            )
        else:
            pwntools = json_matches[0]
            if pwntools.get("available") is not True:
                errors.append("pwntools JSON availability must be true")
            if os.path.realpath(pwntools.get("resolved_path", "")) != os.path.realpath(pwn_stub):
                errors.append(
                    "pwntools JSON resolved_path must point to the pwn stub: "
                    f"{pwntools.get('resolved_path')!r}"
                )
            if pwntools.get("version") != "Pwntools 4.15.0":
                errors.append(
                    "pwntools JSON version must be 'Pwntools 4.15.0', "
                    f"got {pwntools.get('version')!r}"
                )
else:
    expected_note = "install jq for full JSON output"
    if data.get("note") != expected_note:
        errors.append(
            f"fallback JSON note must be {expected_note!r}, got {data.get('note')!r}"
        )

if errors:
    raise SystemExit("pwntools discovery validation failed:\n- " + "\n- ".join(errors))
PY

list_output="$(env PATH="$BIN_DIR" HOME="$HOME_DIR" "$REAL_BASH" "$BOOTSTRAP" --list)"
"$REAL_PYTHON" - "$list_output" <<'PY'
import sys

tokens = sys.argv[1].split()
if "pwntools" not in tokens:
    raise SystemExit("bootstrap --list must include the complete token 'pwntools'")
PY

set +e
help_output="$(env PATH="$BIN_DIR" HOME="$HOME_DIR" "$REAL_BASH" "$BOOTSTRAP" 2>&1)"
help_status=$?
set -e
if [[ $help_status -eq 0 ]]; then
    echo "bootstrap without arguments must exit non-zero" >&2
    exit 1
fi
"$REAL_PYTHON" - "$help_output" <<'PY'
import re
import sys

lines = sys.argv[1].splitlines()
section_pattern = re.compile(r"^\s*\[([^]]+)\]\s*$")
allowed_section_title = "逆向分析"
allowed_sections = []

for index, line in enumerate(lines):
    heading = section_pattern.fullmatch(line)
    if heading is None:
        continue
    title = heading.group(1)
    if title != allowed_section_title:
        continue
    section_end = len(lines)
    for candidate in range(index + 1, len(lines)):
        if section_pattern.fullmatch(lines[candidate]):
            section_end = candidate
            break
    allowed_sections.append((title, lines[index + 1 : section_end]))

matching_sections = [
    title
    for title, section_lines in allowed_sections
    if any("pwntools" in line.split() for line in section_lines)
]
if not matching_sections:
    inspected = [title for title, _ in allowed_sections]
    raise SystemExit(
        "bootstrap human help must include the complete token 'pwntools' inside "
        f"the [{allowed_section_title}] section before the next section heading; "
        f"inspected sections: {inspected!r}"
    )
PY

"$REAL_PYTHON" - \
    "$REPO_ROOT/skills/scripts/bootstrap-manifest.json" \
    "$REPO_ROOT/kali/scripts/bootstrap-manifest.json" <<'PY'
import json
import sys

for manifest_path in sys.argv[1:]:
    with open(manifest_path, encoding="utf-8") as stream:
        manifest = json.load(stream)
    capabilities = manifest.get("capabilities")
    if not isinstance(capabilities, list):
        raise SystemExit(f"{manifest_path}: capabilities must be an array")
    matches = [
        cap
        for cap in capabilities
        if isinstance(cap, dict) and cap.get("name") == "pwntools"
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"{manifest_path}: expected exactly one pwntools capability, got {len(matches)}"
        )
    if matches[0].get("verifyCommand") != "pwn":
        raise SystemExit(
            f"{manifest_path}: pwntools verifyCommand must be 'pwn', "
            f"got {matches[0].get('verifyCommand')!r}"
        )
PY

echo "Kali pwntools discovery regression passed"
