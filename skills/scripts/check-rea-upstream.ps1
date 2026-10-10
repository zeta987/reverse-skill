#Requires -Version 5.1
<#
.SYNOPSIS
Read-only check of the rea (npm package rea-agents) pin against the npm registry.

.DESCRIPTION
Reads the pin from skills/scripts/bootstrap-manifest.json (the single version authority),
asks npm for dist-tags.latest, the published version list, the engines field and the
dist.integrity of the latest release, and reads the CHANGELOG sections between the pin and
latest from the sibling source clone when it is present (the clone is read as it is; this
script never runs git fetch). Prints one JSON report on stdout and never writes a file.

Exit codes:
  0  pin equals latest (or is newer than latest)
  3  an update is available
  2  latest could not be determined (npm lookup failed)
Secondary lookups (versions, integrity, engines, changelog) that fail are listed in
lookup_failures[] and do not change the exit code by themselves.

.EXAMPLE
pwsh -NoProfile -File skills/scripts/check-rea-upstream.ps1 | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [string]$ManifestPath = '',
    [string]$ReaCloneDir = '',
    [string]$Package = 'rea-agents',
    [int]$NpmTimeoutMs = 20000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\ReaTooling.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $scriptDir 'bootstrap-manifest.json' }
if ([string]::IsNullOrWhiteSpace($ReaCloneDir)) { $ReaCloneDir = Join-Path (Split-Path -Parent $repoRoot) 'rea' }

$failures = New-Object System.Collections.Generic.List[string]

function Invoke-NpmViewJson {
    param([string[]]$ViewArgs)
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($null -eq $npm) { return [pscustomobject]@{ Ok = $false; Value = $null; Error = 'npm not found on PATH' } }
    $allArgs = @('view') + $ViewArgs + @('--json', '--fetch-retries', '1', '--fetch-timeout', [string]$NpmTimeoutMs, '--loglevel', 'error')
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # 5.1: redirected native stderr must not terminate
    try {
        $out = & $npm.Source @allArgs 2>&1
        $code = $LASTEXITCODE
    } catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Error = $_.Exception.Message }
    } finally { $ErrorActionPreference = $prevEap }
    $stdout = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n"
    if ($code -ne 0) {
        $msg = if ($stderr) { $stderr } elseif ($stdout) { $stdout } else { "npm exit $code" }
        return [pscustomobject]@{ Ok = $false; Value = $null; Error = ("npm view {0}: {1}" -f ($ViewArgs -join ' '), ($msg -replace '\s+', ' ').Trim()) }
    }
    if ([string]::IsNullOrWhiteSpace($stdout)) { return [pscustomobject]@{ Ok = $true; Value = $null; Error = $null } }
    try {
        $value = $stdout | ConvertFrom-Json
        # npm wraps a multi-field answer in a one-element array; pwsh 7 unrolls it on
        # assignment, Windows PowerShell 5.1 does not. Normalise both to the object.
        if ($value -is [System.Collections.IList] -and $value.Count -eq 1 -and $value[0] -is [psobject] -and $value[0] -isnot [string]) {
            $value = $value[0]
        }
        return [pscustomobject]@{ Ok = $true; Value = $value; Error = $null }
    } catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Error = ("npm view {0}: output is not JSON" -f ($ViewArgs -join ' ')) }
    }
}

# --- pin ---------------------------------------------------------------------
$pin = $null
try {
    $pin = (Get-ReaManifestPin -ManifestPath $ManifestPath).Version
} catch {
    [void]$failures.Add("manifest: $($_.Exception.Message)")
}

# --- npm: latest + versions + publish times ----------------------------------
$latest = $null
$versions = @()
$times = $null
$r1 = Invoke-NpmViewJson -ViewArgs @($Package, 'dist-tags.latest', 'versions', 'time')
if ($r1.Ok -and $null -ne $r1.Value) {
    $v = $r1.Value
    if ($null -ne $v.PSObject.Properties['dist-tags.latest']) { $latest = [string]$v.'dist-tags.latest' }
    if ($null -ne $v.PSObject.Properties['versions']) { $versions = @($v.versions) }
    if ($null -ne $v.PSObject.Properties['time']) { $times = $v.time }
    if (-not $latest) { [void]$failures.Add('npm: dist-tags.latest missing from response') }
} else {
    [void]$failures.Add($(if ($r1.Error) { $r1.Error } else { 'npm: empty response for dist-tags/versions/time' }))
}

# --- npm: engines + integrity of latest ---------------------------------------
$integrity = $null
$engines = $null
if ($latest) {
    $r2 = Invoke-NpmViewJson -ViewArgs @("$Package@$latest", 'engines', 'dist.integrity')
    if ($r2.Ok -and $null -ne $r2.Value) {
        $v2 = $r2.Value
        if ($null -ne $v2.PSObject.Properties['dist.integrity']) { $integrity = [string]$v2.'dist.integrity' }
        if ($null -ne $v2.PSObject.Properties['engines']) { $engines = $v2.engines }
        if (-not $integrity) { [void]$failures.Add("npm: dist.integrity missing for $Package@$latest") }
        if ($null -eq $engines) { [void]$failures.Add("npm: engines missing for $Package@$latest") }
    } else {
        [void]$failures.Add($(if ($r2.Error) { $r2.Error } else { "npm: empty response for $Package@$latest engines/integrity" }))
    }
}

# --- versions between pin and latest ------------------------------------------
$between = @()
$behindBy = $null
if ($pin -and $latest) {
    if ($versions.Count -gt 0) {
        $between = @($versions | Where-Object {
            (Test-ReaVersionString $_) -and (Compare-ReaVersion $_ $pin) -gt 0 -and (Compare-ReaVersion $_ $latest) -le 0
        })
        $behindBy = $between.Count
    } elseif ((Compare-ReaVersion $latest $pin) -gt 0) {
        [void]$failures.Add('npm: versions list unavailable, behind_by unknown')
    } else {
        $behindBy = 0
    }
}

function Get-PublishTime { param($Map, [string]$Version)
    if ($null -eq $Map -or -not $Version) { return $null }
    $p = $Map.PSObject.Properties[$Version]
    if ($null -ne $p) {
        if ($p.Value -is [datetime]) { return $p.Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        return [string]$p.Value
    }
    return $null
}

# --- sibling clone + CHANGELOG -------------------------------------------------
$clone = [ordered]@{
    path            = $ReaCloneDir
    present         = $false
    head            = $null
    head_date       = $null
    head_subject    = $null
    package_version = $null
    changelog_path  = $null
}
$changelogExcerpt = $null
$breaking = @()
if (Test-Path -LiteralPath $ReaCloneDir -PathType Container) {
    $clone.present = $true
    try {
        $head = & git -C $ReaCloneDir -c log.showSignature=false log -1 --format='%H%n%cs%n%s' 2>$null
        if ($LASTEXITCODE -eq 0 -and $head) {
            $parts = @($head)
            $clone.head = $parts[0]
            if ($parts.Count -gt 1) { $clone.head_date = $parts[1] }
            if ($parts.Count -gt 2) { $clone.head_subject = $parts[2] }
        } else {
            [void]$failures.Add("clone: git log failed in $ReaCloneDir")
        }
    } catch { [void]$failures.Add("clone: $($_.Exception.Message)") }
    $pkgJson = Join-Path $ReaCloneDir 'package.json'
    if (Test-Path -LiteralPath $pkgJson) {
        try { $clone.package_version = [string]((Get-Content -LiteralPath $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json).version) } catch { }
    }
    $changelogPath = Join-Path $ReaCloneDir 'CHANGELOG.md'
    if (Test-Path -LiteralPath $changelogPath) {
        $clone.changelog_path = $changelogPath
        if ($pin -and $latest -and (Compare-ReaVersion $latest $pin) -gt 0) {
            $sections = @(Get-ReaChangelogSections -Text (Read-ReaTextFile -Path $changelogPath).Text)
            $wanted = @(Select-ReaChangelogBetween -Sections $sections -Pin $pin -Latest $latest)
            $found = @($wanted | ForEach-Object { $_.Version })
            $expected = if ($between.Count -gt 0) { $between } else { @($latest) }
            foreach ($v in $expected) {
                if ($found -notcontains $v) {
                    [void]$failures.Add("changelog: no section for $v in $changelogPath (clone HEAD $($clone.head) $($clone.head_date)); refresh the clone with git fetch / git pull")
                }
            }
            if ($wanted.Count -gt 0) {
                $changelogExcerpt = (@($wanted | ForEach-Object { $_.Heading + "`n" + $_.Body }) -join "`n`n")
                $breaking = @($wanted | ForEach-Object { $ver = $_.Version; $_.BreakingChanges | ForEach-Object { "$ver`: $_" } })
            }
        }
    } else {
        [void]$failures.Add("clone: CHANGELOG.md not found in $ReaCloneDir")
    }
} else {
    [void]$failures.Add("clone: sibling source clone not found at $ReaCloneDir (changelog not read)")
}

# --- status / exit ------------------------------------------------------------
$status = 'lookup_failed'
$exitCode = 2
if ($pin -and $latest) {
    $cmp = Compare-ReaVersion $latest $pin
    if ($cmp -gt 0) { $status = 'update_available'; $exitCode = 3 }
    elseif ($cmp -eq 0) { $status = 'up_to_date'; $exitCode = 0 }
    else { $status = 'pin_newer_than_latest'; $exitCode = 0 }
}

$report = [ordered]@{
    package             = $Package
    checked_at          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    manifest            = $ManifestPath
    pin                 = $pin
    pin_published_at    = (Get-PublishTime $times $pin)
    latest              = $latest
    latest_published_at = (Get-PublishTime $times $latest)
    behind_by           = $behindBy
    versions_between    = $between
    integrity           = $integrity
    node_engines        = $(if ($null -ne $engines -and $null -ne $engines.PSObject.Properties['node']) { [string]$engines.node } else { $null })
    engines             = $engines
    clone               = $clone
    changelog_excerpt   = $changelogExcerpt
    breaking_changes    = $breaking
    lookup_failures     = @($failures.ToArray())
    status              = $status
    exit_code           = $exitCode
}

$report | ConvertTo-Json -Depth 10
exit $exitCode
