#Requires -Version 5.1
<#
.SYNOPSIS
Bump the rea (rea-agents) pin: tracked repository files (Tracked), the gitignored local
client mirrors (Apply), or both.

.DESCRIPTION
Tracked: string-level, anchored edits (each pattern must match exactly the expected number of
times, validated for every file before anything is written) in
  skills/scripts/bootstrap-manifest.json and kali/scripts/bootstrap-manifest.json
    (npmPackage, mcpArgs element, pinnedVersion, note),
  skills/scripts/lib/ToolDiscovery.ps1 (FixedVersion),
  RULES.md / RULES_zh.md (rea service rows),
  the five SKILL.md "rea 可用" paragraphs (js-reverse carries the version; the other four
    are checked to contain no stale version),
  skills/ops/evidence-finding-path.md, skills/references/community-security-skills.md,
  docs/mcp/rea.md (Current pin line + a dated row appended to the Bump log).
Tool count / tools-list size / prompt count phrases are rewritten from -ContractReport when
it is given; otherwise the existing numbers are kept. JSON files are never re-serialized.
A residual `git grep` for the old version runs afterwards (excluding the dated registers).

Apply: rewrites rea-agents@<old> -> rea-agents@<new> inside the rea entry of each existing
mirror (.mcp.json, .codex/config.toml, .agents/mcp_config.json,
.dsh/agent-presets/reverse-skill/agent.cordis.yml), preserving every other byte, then prints
the client commands to run by hand. Apply refuses to run without a passing
test-rea-contract.ps1 report for the same version (-ContractReport).

Exit codes: 0 ok, 1 validation/edit failure, 4 tracked edits applied but stale references
remain (review them), 5 Apply refused (no/invalid contract report).

.EXAMPLE
pwsh -NoProfile -File skills/scripts/update-rea.ps1 -Version 6.3.0 -Mode Tracked -ContractReport $env:TEMP\rea-contract\6.3.0-report.json
pwsh -NoProfile -File skills/scripts/update-rea.ps1 -Version 6.3.0 -Mode Apply -ContractReport $env:TEMP\rea-contract\6.3.0-report.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('Tracked', 'Apply', 'Both')][string]$Mode = 'Tracked',
    [string]$ContractReport = '',
    [string]$RepoRoot = '',
    [string]$Note = '',
    [string]$Date = '',
    [switch]$SkipResidualScan
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\ReaTooling.ps1')

if (-not (Test-ReaVersionString $Version)) { throw "-Version '$Version' is not a version string" }
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir) }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($Date)) { $Date = (Get-Date).ToString('yyyy-MM-dd') }

function Info([string]$m) { Write-Host ("[update-rea] {0}" -f $m) }
function Warn([string]$m) { Write-Host ("[update-rea] WARN {0}" -f $m) -ForegroundColor Yellow }

# --- contract report (optional for Tracked, mandatory for Apply) --------------------
$report = $null
$reportProblems = @()
if ($ContractReport) {
    try {
        $report = Read-ReaContractReport -Path $ContractReport
        $reportProblems = @(Test-ReaContractReport -Report $report -Version $Version)
    } catch {
        $reportProblems = @("contract report unreadable: $($_.Exception.Message)")
    }
    if ($reportProblems.Count -gt 0) {
        foreach ($p in $reportProblems) { Warn "contract report: $p" }
    } else {
        Info ("contract report accepted: {0} (tool_count {1}, tools_list_sha256 {2})" -f $ContractReport, $report.tool_count, $report.tools_list_sha256)
    }
}

$exitCode = 0

# --- Tracked -----------------------------------------------------------------------
if ($Mode -eq 'Tracked' -or $Mode -eq 'Both') {
    $manifestPath = Join-Path $RepoRoot 'skills\scripts\bootstrap-manifest.json'
    $old = (Get-ReaManifestPin -ManifestPath $manifestPath).Version
    if ($old -eq $Version) { throw "manifest already pins $Version; nothing to do for Tracked" }
    $cmp = Compare-ReaVersion $Version $old
    if ($cmp -lt 0) { Warn "downgrade $old -> $Version (rollback)" } else { Info "tracked bump $old -> $Version" }

    $toolCount = $null; $bytesMb = $null; $promptCount = $null
    if ($null -ne $report -and $reportProblems.Count -eq 0) {
        $toolCount = [int]$report.tool_count
        if ($null -ne $report.PSObject.Properties['tools_list_bytes'] -and $report.tools_list_bytes) {
            $bytesMb = ([Math]::Round([double]$report.tools_list_bytes / 1MB, 1)).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        if ($null -ne $report.PSObject.Properties['prompt_count'] -and $null -ne $report.prompt_count) { $promptCount = [int]$report.prompt_count }
    } else {
        Warn 'no accepted contract report: tool count / size / prompt count phrases are kept as they are'
    }

    $plan = @(Get-ReaTrackedEditPlan -RepoRoot $RepoRoot -OldVersion $old -NewVersion $Version -ToolCount $toolCount -BytesMb $bytesMb -PromptCount $promptCount)

    # phase 1: validate every file, write nothing
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($step in $plan) {
        $path = Join-Path $RepoRoot $step.Path
        foreach ($p in @(Test-ReaAnchoredEdits -Path $path -Edits $step.Edits)) { [void]$problems.Add($p) }
    }
    $reaDoc = Join-Path $RepoRoot 'docs\mcp\rea.md'
    if ((Test-Path -LiteralPath $reaDoc) -and ((Read-ReaTextFile -Path $reaDoc).Text -notmatch '(?m)^## Bump log\s*$')) {
        [void]$problems.Add("$reaDoc has no '## Bump log' section")
    }
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Host ("[update-rea] FAIL {0}" -f $p) -ForegroundColor Red }
        throw "tracked update aborted before writing: $($problems.Count) anchor problem(s)"
    }

    # phase 2: apply
    foreach ($step in $plan) {
        $path = Join-Path $RepoRoot $step.Path
        $subs = Invoke-ReaAnchoredEdits -Path $path -Edits $step.Edits
        if ($step.ContainsKey('Json') -and $step.Json) {
            $null = (Read-ReaTextFile -Path $path).Text | ConvertFrom-Json
        }
        Info ("{0}: {1} substitution(s)" -f $step.Path, $subs)
    }
    $after = Get-ReaManifestPin -ManifestPath $manifestPath
    if ($after.Version -ne $Version) { throw "manifest pin is '$($after.Version)' after the edit, expected $Version" }

    $counts = if ($null -ne $toolCount) { "{0}" -f $toolCount } else { $null }
    $sha = if ($null -ne $report -and $reportProblems.Count -eq 0) { [string]$report.tools_list_sha256 } else { $null }
    $row = Add-ReaBumpLogRow -Path $reaDoc -Date $Date -OldVersion $old -NewVersion $Version -ToolCounts $counts -ToolsListSha256 $sha -Note $Note
    Info "docs/mcp/rea.md: bump log row appended: $row"

    # phase 3: residual scan
    if (-not $SkipResidualScan) {
        $isGit = $false
        try { & git -C $RepoRoot rev-parse --is-inside-work-tree 2>$null | Out-Null; $isGit = ($LASTEXITCODE -eq 0) } catch { $isGit = $false }
        if ($isGit) {
            $o = [regex]::Escape($old)
            $pattern = ('rea-agents@{0}|rea-agents {0}|reverse-engineer-anything {0}' -f $o)
            $left = @(& git -C $RepoRoot grep -n -I -E $pattern -- . ':!docs/mcp/host-deviations.md' ':!docs/mcp/rea.md' ':!CHANGELOG.md' 2>$null)
            if ($LASTEXITCODE -eq 0 -and $left.Count -gt 0) {
                foreach ($l in $left) { Warn ("stale reference: {0}" -f $l) }
                $exitCode = 4
            } else {
                Info 'residual scan: no stale references in tracked files (dated registers excluded)'
            }
        } else {
            Warn 'residual scan skipped: not a git work tree'
        }
    }
    Info 'tracked update done; review `git diff` and commit it on a short-lived branch'
}

# --- Apply -------------------------------------------------------------------------
if ($Mode -eq 'Apply' -or $Mode -eq 'Both') {
    if (-not $ContractReport) {
        Write-Host '[update-rea] REFUSED: -Mode Apply needs -ContractReport <passing test-rea-contract.ps1 report for this version>' -ForegroundColor Red
        exit 5
    }
    if ($reportProblems.Count -gt 0) {
        Write-Host ("[update-rea] REFUSED: contract report does not pass for {0}: {1}" -f $Version, ($reportProblems -join '; ')) -ForegroundColor Red
        exit 5
    }
    $results = @()
    foreach ($m in @(Get-ReaMirrorDefinitions -RepoRoot $RepoRoot)) {
        $r = Update-ReaMirrorEntry -Path $m.Path -Kind $m.Kind -NewVersion $Version
        $results += $r
        switch ($r.Status) {
            'updated'      { Info ("{0} ({1}): rea-agents@{2} -> rea-agents@{3}" -f $m.Name, $m.Path, $r.OldVersion, $r.NewVersion) }
            'already'      { Info ("{0} ({1}): already rea-agents@{2}" -f $m.Name, $m.Path, $r.NewVersion) }
            'no-entry'     { Warn ("{0} ({1}): no rea entry, left untouched" -f $m.Name, $m.Path) }
            'missing-file' { Info ("{0} ({1}): file absent, skipped" -f $m.Name, $m.Path) }
        }
    }
    $updated = @($results | Where-Object { $_.Status -eq 'updated' }).Count
    Info ("apply done: {0} mirror(s) updated" -f $updated)
    Write-Host ''
    Write-Host 'Reconnect the clients and verify by hand (not run by this script):'
    Write-Host '  claude mcp list'
    Write-Host '  codex mcp get rea'
    Write-Host '  # Antigravity / dsh web: restart the client so it re-reads its project config'
    Write-Host ''
}

exit $exitCode
