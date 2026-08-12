#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/bootstrap-reverse.sh"
MANIFEST="$SCRIPT_DIR/bootstrap-manifest.json"
KALI_BOOTSTRAP="$SCRIPT_DIR/../../kali/scripts/bootstrap-reverse.sh"
REAL_PYTHON="$(command -v python3)"
SCRATCH="$(mktemp -d /tmp/reverse-bootstrap-test-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

STUB_BIN="$SCRATCH/bin"
CALL_LOG="$SCRATCH/calls.log"
mkdir -p "$STUB_BIN" "$SCRATCH/home" "$SCRATCH/tools"

cat > "$STUB_BIN/command-stub" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
{
  printf '%s' "$name"
  for arg in "$@"; do printf '|%s' "$arg"; done
  printf '\n'
} >> "$CALL_LOG"

if [[ "${STUB_FAIL_COMMAND:-}" == "$name" ]]; then
  exit 1
fi

if [[ "$name" == "git" ]]; then
  if [[ "${1:-}" == "init" ]]; then
    target="${!#}"
    mkdir -p "$target/.git"
    printf '%s\n' 'unpinned-head' > "$target/.stub-head"
  elif [[ "${1:-}" == "-C" && "${3:-}" == "fetch" ]]; then
    printf '%s\n' "${7:-}" > "$2/.stub-fetch"
  elif [[ "${1:-}" == "-C" && "${3:-}" == "checkout" ]]; then
    cat "$2/.stub-fetch" > "$2/.stub-head"
  elif [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" ]]; then
    cat "$2/.stub-head"
  fi
fi
exit 0
STUB
chmod +x "$STUB_BIN/command-stub"
for command_name in git node npm npx pipx pnpm sleep; do
  ln -s command-stub "$STUB_BIN/$command_name"
done

cat > "$STUB_BIN/python3" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "-" && "\${2:-}" == "23816" ]]; then
  exit 0
fi
if [[ "\${1:-}" == "-c" && "\${2:-}" == "import pwn" ]]; then
  exit 1
fi
exec "$REAL_PYTHON" "\$@"
STUB
chmod +x "$STUB_BIN/python3"

manifest_value() {
  "$REAL_PYTHON" - "$MANIFEST" "$1" "$2" <<'PY'
import json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
capability = next(item for item in manifest['capabilities'] if item['name'] == sys.argv[2])
value = capability.get(sys.argv[3], '')
print(value if isinstance(value, str) else json.dumps(value, separators=(',', ':')))
PY
}

run_bootstrap() {
  env \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    HOME="$SCRATCH/home" \
    CALL_LOG="$CALL_LOG" \
    REVERSE_SKILL_TOOLS_DIR="$SCRATCH/tools" \
    CLAUDE_MCP_CONFIG="$SCRATCH/home/mcp.json" \
    bash "$BOOTSTRAP" "$@"
}

run_bootstrap_with_failing_pipx() {
  env \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    HOME="$SCRATCH/home" \
    CALL_LOG="$CALL_LOG" \
    STUB_FAIL_COMMAND=pipx \
    REVERSE_SKILL_TOOLS_DIR="$SCRATCH/tools" \
    CLAUDE_MCP_CONFIG="$SCRATCH/home/mcp.json" \
    bash "$BOOTSTRAP" "$@"
}

run_kali_bootstrap() {
  env \
    PATH="$STUB_BIN:/opt/homebrew/bin:/usr/bin:/bin" \
    HOME="$SCRATCH/home" \
    CALL_LOG="$CALL_LOG" \
    bash "$KALI_BOOTSTRAP" "$@"
}

failures=0
check_log_line() {
  if ! grep -Fqx "$1" "$CALL_LOG"; then
    printf 'missing argv: %s\n' "$1" >&2
    failures=$((failures + 1))
  fi
}

: > "$CALL_LOG"
run_bootstrap frida --skip-refresh >/dev/null
frida_package="$(manifest_value frida pipPackage)"
check_log_line "pipx|install|--force|$frida_package"

: > "$CALL_LOG"
run_bootstrap idalib-mcp --skip-refresh >/dev/null
idalib_source="$(manifest_value idalib-mcp pipSource)"
check_log_line "pipx|install|--force|$idalib_source"

: > "$CALL_LOG"
set +e
run_bootstrap_with_failing_pipx idalib-mcp --skip-refresh >/dev/null 2>&1
idalib_fail_exit=$?
set -e
if [[ "$idalib_fail_exit" -eq 0 ]]; then
  printf 'idalib-mcp reported success after its pinned install failed\n' >&2
  failures=$((failures + 1))
fi
check_log_line "pipx|install|--force|$idalib_source"
if [[ "$(wc -l < "$CALL_LOG" | tr -d ' ')" -ne 1 ]]; then
  printf 'idalib-mcp attempted an unpinned fallback after pinned install failure\n' >&2
  failures=$((failures + 1))
fi

: > "$CALL_LOG"
run_bootstrap agent-browser --skip-refresh >/dev/null
agent_package="$(manifest_value agent-browser npmPackage)"
check_log_line "npm|install|-g|$agent_package"

: > "$CALL_LOG"
run_bootstrap seclists --skip-refresh >/dev/null
seclists_repo="$(manifest_value seclists repo)"
seclists_pin="$(manifest_value seclists pinnedCommit)"
seclists_dir="$SCRATCH/tools/SecLists"
check_log_line "git|-C|$seclists_dir|remote|add|origin|$seclists_repo"
check_log_line "git|-C|$seclists_dir|fetch|--depth|1|origin|$seclists_pin"

: > "$CALL_LOG"
run_bootstrap proxycat --skip-refresh >/dev/null
proxycat_repo="$(manifest_value proxycat repo)"
proxycat_pin="$(manifest_value proxycat pinnedCommit)"
check_log_line "pipx|install|git+${proxycat_repo}@${proxycat_pin}"

: > "$CALL_LOG"
run_bootstrap pwntools --skip-refresh >/dev/null
pwntools_package="$(manifest_value pwntools pipPackage)"
check_log_line "pipx|install|$pwntools_package"

: > "$CALL_LOG"
run_bootstrap anything-analyzer --start-services --skip-refresh >/dev/null
anything_repo="$(manifest_value anything-analyzer repoUrl)"
anything_pin="$(manifest_value anything-analyzer pinnedCommit)"
anything_dir="$SCRATCH/tools/anything-analyzer"
if [[ -z "$anything_pin" ]]; then
  printf 'anything-analyzer is missing pinnedCommit in bootstrap-manifest.json\n' >&2
  failures=$((failures + 1))
else
  check_log_line "git|init|--quiet|$anything_dir"
  check_log_line "git|-C|$anything_dir|remote|add|origin|$anything_repo"
  check_log_line "git|-C|$anything_dir|fetch|--depth|1|origin|$anything_pin"
  check_log_line "git|-C|$anything_dir|checkout|--quiet|--detach|FETCH_HEAD"
  check_log_line "git|-C|$anything_dir|rev-parse|HEAD"
fi
check_log_line 'pnpm|install'
check_log_line 'pnpm|dev'

if [[ -n "$anything_pin" ]]; then
  checkout_line="$(grep -nF "git|-C|$anything_dir|checkout|--quiet|--detach|FETCH_HEAD" "$CALL_LOG" | cut -d: -f1 | head -n1)"
  install_line="$(grep -nF 'pnpm|install' "$CALL_LOG" | cut -d: -f1 | head -n1)"
  if [[ -z "$checkout_line" || -z "$install_line" || "$checkout_line" -ge "$install_line" ]]; then
    printf 'anything-analyzer dependencies ran before the pinned checkout\n' >&2
    failures=$((failures + 1))
  fi
fi

: > "$CALL_LOG"
mkdir -p "$anything_dir/.git"
printf '%s\n' 'different-commit' > "$anything_dir/.stub-head"
set +e
run_bootstrap anything-analyzer --start-services --skip-refresh >/dev/null 2>&1
mismatch_exit=$?
set -e
if [[ "$mismatch_exit" -eq 0 ]]; then
  printf 'anything-analyzer accepted an existing checkout at a different commit\n' >&2
  failures=$((failures + 1))
fi
if grep -Eq '^pnpm\|(install|dev)$' "$CALL_LOG"; then
  printf 'anything-analyzer ran dependencies from an unpinned existing checkout\n' >&2
  failures=$((failures + 1))
fi

if (( BASH_VERSINFO[0] >= 4 )); then
  : > "$CALL_LOG"
  kali_dir="$SCRATCH/home/tools/anything-analyzer"
  rm -rf "$kali_dir"
  set +e
  run_kali_bootstrap anything-analyzer --start-services --skip-refresh >"$SCRATCH/kali-bootstrap.out" 2>&1
  set -e
  check_log_line "git|init|-q|$kali_dir"
  check_log_line "git|-C|$kali_dir|remote|add|origin|$anything_repo"
  check_log_line "git|-C|$kali_dir|fetch|--depth|1|origin|$anything_pin"
  check_log_line "git|-C|$kali_dir|checkout|-q|--detach|FETCH_HEAD"
  check_log_line 'pnpm|install'
  check_log_line 'pnpm|dev'

  : > "$CALL_LOG"
  mkdir -p "$kali_dir/.git"
  printf '%s\n' 'different-commit' > "$kali_dir/.stub-head"
  set +e
  run_kali_bootstrap anything-analyzer --start-services --skip-refresh >/dev/null 2>&1
  kali_mismatch_exit=$?
  set -e
  if [[ "$kali_mismatch_exit" -eq 0 ]]; then
    printf 'Kali anything-analyzer accepted an existing checkout at a different commit\n' >&2
    failures=$((failures + 1))
  fi
  if grep -Eq '^pnpm\|(install|dev)$' "$CALL_LOG"; then
    printf 'Kali anything-analyzer ran dependencies from an unpinned existing checkout\n' >&2
    failures=$((failures + 1))
  fi
fi

if [[ "$failures" -ne 0 ]]; then
  if [[ -f "$SCRATCH/kali-bootstrap.out" ]]; then cat "$SCRATCH/kali-bootstrap.out" >&2; fi
  printf '%s\n' 'captured argv:' >&2
  cat "$CALL_LOG" >&2
  exit 1
fi

printf '%s\n' 'bootstrap manifest source regression passed'
