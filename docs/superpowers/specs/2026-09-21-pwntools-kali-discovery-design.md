# Kali pwntools discovery integration design

## Context

Pull request #144 adds `pwntools` to the Kali tool catalog, but only as a single catalog row. The current change cannot report a version, does not expose `pwntools` in the capability status table, and does not list it through the Kali bootstrap discovery interfaces. Existing CI has no regression that exercises the Kali refresh output with an installed `pwn` command.

## Goal

Integrate #144 while preserving its contributor commit, then complete the Kali-facing discovery path and keep the client-neutral index on the same real CLI contract so that:

1. `pwn` is detected as the executable supplied by pwntools.
2. The generated tool index records its resolved path and version.
3. The generated capability table includes `pwntools`, reports runtime availability through `pwn`, and identifies its installer as `pip-package`.
4. `bootstrap-reverse.sh --list` and its human-readable help include `pwntools`.
5. Both bootstrap manifests use the executable command `pwn` for post-install verification.
6. Both Kali and client-neutral index regressions exercise the real `pwn version` CLI contract without installing pwntools or touching the host environment.

## Non-goals

- Do not install the real pwntools package during tests.
- Do not change routing rules or the pwntools package/version pin.
- Do not refactor every duplicated capability list into generated data.
- Do not change unrelated bootstrap behaviour.

## Design

### Tool catalog

Keep the #144 catalog entry but use the `version` subcommand and the executable fallback `pwn`. The logical tool name remains `pwntools`; the resolved executable is `pwn`. Pwntools 4.15.0 exposes its version through `pwn version`; `pwn --version` is not a valid equivalent and exits non-zero.

Expected generated record:

```text
pwntools|reverse-engineering|CTF pwn 利用开发框架|yes|<stub>/pwn|[*] Pwntools v4.15.0|command
```

### Capability status

Add `pwntools` to `CAPABILITY_NAMES`. Its availability check is a dedicated `command -v pwn`, because `command -v pwntools` is not valid. Its bootstrap kind is `pip-package`, matching both manifests and the existing installer branch.

### Bootstrap discovery

Add `pwntools` to the machine-readable `--list` output and to the CTF/reverse-analysis help section. Change `verifyCommand` from the nonexistent `pwntools` executable to `pwn` in both platform manifests.

### Regression test

Add a hermetic Bash test under `kali/scripts/` that:

1. Creates a temporary `PATH` with only required system-command links and a stub `pwn` command.
2. Runs `kali/scripts/refresh-tool-index.sh` into temporary Markdown/JSON outputs.
3. Asserts exactly one pwntools tool record, available status, canonical stub path, and version text.
4. Asserts the Markdown capability row reports pwntools as available and `pip-package` installable.
5. Asserts `bootstrap-reverse.sh --list` advertises pwntools.
6. Parses both manifests and asserts `verifyCommand == "pwn"`.

The `pwn` fixture accepts exactly one argument, `version`, writes the exact real CLI line `[*] Pwntools v4.15.0` to stderr, and fails every other invocation. This prevents the invalid `pwn --version` spelling from passing through a permissive stub. The test must not invoke package installation, network access, client configuration, or repository output paths.

The same executable has one version-command contract on every supported host path. Therefore the minimum change also updates `skills/scripts/refresh-tool-index.sh` from `pwn --version` to `pwn version`, ensures its version runner does not append empty placeholder arguments, and extends the existing `skills/scripts/test-client-neutral-bootstrap.sh` regression with the same strict stub and generated-record assertions.

### CI wiring

Run the new regression in the existing Ubuntu Bash CI job after shell syntax validation. It is a Kali-script behaviour test but remains host-independent through command stubs, so a Kali container is unnecessary.

## TDD sequence

1. Add strict real-CLI regressions for the Kali and client-neutral refresh paths and the CI invocation.
2. Run them against the current production scripts and confirm both fail because production invokes `pwn --version` rather than `pwn version`.
3. Apply the smallest production changes required for the assertions, including both refresh catalogs.
4. Re-run both focused tests until green.
5. Run Bash syntax, bootstrap-manifest, routing, repository-security, document-link, JSON, YAML, UTF-8/BOM and mojibake checks.

## Integration and provenance

Create a merge commit whose second parent is the original #144 head, preserving contributor provenance. Add the completion changes as a separate maintainer commit. Push only after local verification; wait for GitHub CI before fast-forwarding `main`. No force-push is permitted.

## Failure handling

- A missing `pwn` command must produce an unavailable pwntools record without aborting refresh.
- A failing `pwn version` command may leave the version empty, consistent with existing discovery behaviour, but detection remains based on executable presence.
- Any CI failure blocks integration into `main`.
