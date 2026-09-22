# Kali pwntools Discovery Completion Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Preserve PR #144 contributor provenance and complete pwntools discovery, version reporting, capability visibility, bootstrap listing, manifest verification, and CI coverage.

**Architecture:** Treat the original PR head as the integration baseline, then add one hermetic Bash regression that drives the real Kali refresh/bootstrap scripts through a stub `pwn` executable. Make only targeted catalog, capability-list, help-list, manifest, and workflow changes; avoid broader manifest-generation refactors.

**Tech Stack:** Bash, JSON, Python 3 assertions, GitHub Actions YAML, Git.

---

### Task 1: Preserve the original PR commit

**Objective:** Make the original #144 head an ancestor of the integration branch before maintainer fixes.

**Files:**
- No file edits; merge `review/pr-144` into `integration/pr-144-pwntools-discovery`.

**Step 1: Verify the fetched head**

Run:

```bash
git rev-parse review/pr-144
git diff --stat origin/main...review/pr-144
```

Expected: head `cede1d28...`; one added catalog line.

**Step 2: Merge without squashing**

Run:

```bash
git merge --no-ff review/pr-144 -m "Merge PR #144: catalog pwntools in Kali discovery"
```

Expected: clean merge; original head is the second parent.

**Step 3: Verify ancestry**

Run:

```bash
git merge-base --is-ancestor review/pr-144 HEAD
git show --no-patch --format='%P' HEAD
```

Expected: exit 0; merge commit has two parents.

### Task 2: Add the failing end-to-end regression

**Objective:** Prove that the unmodified #144 change lacks version, capability, bootstrap-list, and manifest integration.

**Files:**
- Create: `kali/scripts/test-pwntools-discovery.sh`
- Modify: `.github/workflows/ci.yml`

**Step 1: Write the hermetic test**

The test must:

- create a temporary `bin` directory;
- link required host commands (`bash`, `date`, `dirname`, `head`, `mktemp`, `python3`, `uname`, and `jq` when present);
- create a stub executable `pwn` that prints `Pwntools 4.15.0` for `--version`;
- run `kali/scripts/refresh-tool-index.sh` into temporary Markdown and JSON files;
- assert exactly one `pwntools` JSON record with `available=true`, the stub path, and version `Pwntools 4.15.0`;
- assert the Markdown capability row marks `pwntools` available and installable through `pip-package`;
- assert `bootstrap-reverse.sh --list` contains the exact token `pwntools`;
- parse both `skills/scripts/bootstrap-manifest.json` and `kali/scripts/bootstrap-manifest.json` and assert `verifyCommand == "pwn"`.

The script must have `set -euo pipefail`, clean its temporary directory with a trap, and perform no package installation or network access.

**Step 2: Wire the test into Ubuntu CI**

Add after Bash syntax validation in `.github/workflows/ci.yml`:

```yaml
      - name: Kali pwntools discovery regression
        shell: bash
        run: bash kali/scripts/test-pwntools-discovery.sh
```

**Step 3: Run to verify RED**

Run:

```bash
bash kali/scripts/test-pwntools-discovery.sh
```

Expected: FAIL on missing version or another explicitly asserted incomplete #144 behaviour, not on test setup.

**Step 4: Commit the red test**

```bash
git add kali/scripts/test-pwntools-discovery.sh .github/workflows/ci.yml
git commit -m "test(kali): cover pwntools discovery integration"
```

### Task 3: Implement the minimum complete behaviour

**Objective:** Make the regression pass without unrelated refactoring.

**Files:**
- Modify: `kali/scripts/lib/tool-discovery.sh`
- Modify: `kali/scripts/refresh-tool-index.sh`
- Modify: `kali/scripts/bootstrap-reverse.sh`
- Modify: `kali/scripts/bootstrap-manifest.json`
- Modify: `skills/scripts/bootstrap-manifest.json`

**Step 1: Fix the catalog command and version**

Change the #144 row to:

```bash
"pwntools|reverse-engineering|CTF pwn 利用开发框架|--version|pwn"
```

**Step 2: Add capability visibility**

- Add `pwntools` to `CAPABILITY_NAMES`.
- Add a dedicated availability branch:

```bash
pwntools)
    if command -v pwn &>/dev/null; then tool_available="✓"; fi
    ;;
```

- Include `pwntools` in the `pip-package` bootstrap-kind branch.

**Step 3: Add bootstrap discoverability**

- Add `pwntools` to `bootstrap-reverse.sh --list`.
- Add it to the human-readable reverse-analysis/CTF help output.

**Step 4: Correct both manifest verification commands**

Change `verifyCommand` from `pwntools` to `pwn` in both manifests.

**Step 5: Run focused test to verify GREEN**

Run:

```bash
bash kali/scripts/test-pwntools-discovery.sh
```

Expected: exit 0 and a final success message.

**Step 6: Commit implementation**

```bash
git add kali/scripts/lib/tool-discovery.sh \
  kali/scripts/refresh-tool-index.sh \
  kali/scripts/bootstrap-reverse.sh \
  kali/scripts/bootstrap-manifest.json \
  skills/scripts/bootstrap-manifest.json
git commit -m "fix(kali): complete pwntools discovery integration"
```

### Task 4: Run complete local verification

**Objective:** Verify focused behaviour and repository-wide gates before any push.

**Files:**
- No production edits unless a test exposes a defect.

**Step 1: Focused and syntax checks**

```bash
bash kali/scripts/test-pwntools-discovery.sh
bash -n kali/scripts/test-pwntools-discovery.sh
bash -n kali/scripts/lib/tool-discovery.sh
bash -n kali/scripts/refresh-tool-index.sh
bash -n kali/scripts/bootstrap-reverse.sh
```

Expected: all exit 0.

**Step 2: Repository regression checks**

```bash
bash skills/scripts/test-bootstrap-manifest.sh
bash skills/scripts/test-client-neutral-bootstrap.sh
bash skills/scripts/test-routing.sh
bash skills/scripts/test-bash-workflow.sh
python3 skills/scripts/verify-repository-security.py
python3 skills/scripts/verify-doc-links.py
```

Expected: all exit 0; routing reports no failures.

**Step 3: Structured-file and encoding checks**

- Parse every tracked JSON file with Python.
- Parse every tracked YAML/YML file with an available Python YAML parser.
- Decode all changed text as UTF-8/UTF-8-SIG.
- Scan changed text for common mojibake markers.
- Preserve any expected PowerShell BOM outside this change set.

Expected: zero parse, decode, or mojibake failures.

**Step 4: Verify history and worktree**

```bash
git status --short
git merge-base --is-ancestor review/pr-144 HEAD
git log --oneline --decorate origin/main..HEAD
```

Expected: clean worktree; #144 head is an ancestor; design, merge, test, and implementation commits are visible.

### Task 5: Review, publish, CI, and integrate

**Objective:** Obtain independent review, publish safely, and update `main` only after green CI.

**Files:**
- No code changes unless review or CI identifies a defect.

**Step 1: Independent reviews**

Run two reviews:

1. Spec-compliance review against the approved design.
2. Code-quality review for Bash portability, hermetic testing, false positives, and security boundaries.

Fix any blocker and repeat focused/full verification.

**Step 2: Publish integration branch**

Use a temporary, repository-authorized credential. Push:

```bash
git push <authenticated-remote> HEAD:refs/heads/integration/pr-144-pwntools-discovery
```

No force-push.

**Step 3: Wait for GitHub Actions**

Poll all runs for the integration head until completed. Any failure blocks integration.

**Step 4: Fast-forward main safely**

Fetch `main`, verify it is an ancestor of the integration head, then push `HEAD:main` without force. If remote main advanced incompatibly, stop and re-integrate.

**Step 5: Verify GitHub state and clean credentials**

- Verify remote `main` equals the integration head.
- Verify #144 is marked merged.
- Verify all main-branch Actions runs succeed.
- Delete the temporary integration branch.
- Remove temporary credentials from GitHub and local disk.
