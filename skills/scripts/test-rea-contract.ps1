#Requires -Version 7.0
<#
.SYNOPSIS
Contract test for a candidate rea-agents version: real MCP handshake, full tools/list, catalog
file, wire hash, semantic diff against a previous catalog, and a check that every rea tool
name referenced from skills/ and docs/ exists in the candidate catalog.

.DESCRIPTION
Spawns `node.exe <npx-cli.js> -y rea-agents@<Version> mcp` as an isolated child process
(redirected stdio, scratch working directory, killed with its process tree on exit),
performs initialize -> notifications/initialized -> tools/list (cursor loop) -> prompts/list,
optionally tools/call binary_session {} (to read rea's own tools_sha256) and
tools/call analyze_javascript_application on -FixtureDir, then closes stdin.

The tools/list response is read as raw bytes until the frame's terminating newline, so the
~2.4 MB single frame is never truncated. `tools_list_sha256` is the SHA-256 of those raw
frame bytes (request id fixed at 2; multiple frames joined with "\n"). It is NOT rea's
`tools_sha256`, which hashes canonicalized tool contracts inside the server
(src/catalogIdentity.ts); the latter is reported separately as `rea_tools_sha256` when the
binary_session call succeeds.

Writes the catalog (-OutputPath) and a JSON report (-ReportPath). Exit 0 when the report
passes, 1 otherwise. update-rea.ps1 -Mode Apply requires a passing report for the version.

.EXAMPLE
pwsh -NoProfile -File skills/scripts/test-rea-contract.ps1 -Version 6.1.0 -FixtureDir work/rea-flow-test/sample
pwsh -NoProfile -File skills/scripts/test-rea-contract.ps1 -Version 6.3.0 -PreviousCatalog $env:TEMP\rea-contract\6.1.0-catalog.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$FixtureDir = '',
    [string]$OutputPath = '',
    [string]$ReportPath = '',
    [string]$PreviousCatalog = '',
    [string]$NodeExe = '',
    [string]$NpxCli = '',
    [string]$RepoRoot = '',
    [string]$WorkDir = '',
    [int]$StartupTimeoutSec = 180,
    [int]$CallTimeoutSec = 300,
    [switch]$SkipReferenceCheck,
    [switch]$SkipIdentityCall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir 'lib\ReaTooling.ps1')

if (-not (Test-ReaVersionString $Version)) { throw "-Version '$Version' is not a version string" }
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir) }
if ([string]::IsNullOrWhiteSpace($NodeExe)) {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    $NodeExe = if ($cmd) { $cmd.Source } else { 'C:\Program Files\nodejs\node.exe' }
}
if ([string]::IsNullOrWhiteSpace($NpxCli)) {
    $NpxCli = Join-Path (Split-Path -Parent $NodeExe) 'node_modules\npm\bin\npx-cli.js'
}
if (-not (Test-Path -LiteralPath $NodeExe)) { throw "node.exe not found: $NodeExe" }
if (-not (Test-Path -LiteralPath $NpxCli)) { throw "npx-cli.js not found: $NpxCli" }
$outBase = Join-Path ([System.IO.Path]::GetTempPath()) 'rea-contract'
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $outBase ("{0}-catalog.json" -f $Version) }
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $outBase ("{0}-report.json" -f $Version) }
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Join-Path $outBase ("work-{0}-{1}" -f $Version, [guid]::NewGuid().ToString('N').Substring(0, 8)) }
foreach ($d in @((Split-Path -Parent $OutputPath), (Split-Path -Parent $ReportPath), $WorkDir)) {
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
if ($FixtureDir) {
    $FixtureDir = (Resolve-Path -LiteralPath $FixtureDir).Path
}

$failures = New-Object System.Collections.Generic.List[string]
function Note([string]$m) { Write-Host ("[contract] {0}" -f $m) }
function Fail([string]$m) { Write-Host ("[contract] FAIL {0}" -f $m) -ForegroundColor Red; [void]$failures.Add($m) }

# --- spawn ---------------------------------------------------------------------
$psi = [System.Diagnostics.ProcessStartInfo]::new($NodeExe)
foreach ($a in @($NpxCli, '-y', "rea-agents@$Version", 'mcp')) { $psi.ArgumentList.Add($a) }
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.WorkingDirectory = $WorkDir
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
$psi.Environment['NO_COLOR'] = '1'
$psi.Environment['NPM_CONFIG_UPDATE_NOTIFIER'] = 'false'

Note ("spawning {0} {1} -y rea-agents@{2} mcp (cwd {3})" -f $NodeExe, $NpxCli, $Version, $WorkDir)
$proc = [System.Diagnostics.Process]::Start($psi)
$stderrTask = $proc.StandardError.ReadToEndAsync()
$stdout = $proc.StandardOutput.BaseStream
$stdin = $proc.StandardInput.BaseStream
$utf8 = New-Object System.Text.UTF8Encoding($false)

$script:pending = New-Object System.Collections.Generic.List[byte]
$script:readBuf = New-Object byte[] 262144

function Read-Frame {
    param([int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $idx = $script:pending.IndexOf([byte]10)
        if ($idx -ge 0) {
            $frame = $script:pending.GetRange(0, $idx).ToArray()
            $script:pending.RemoveRange(0, $idx + 1)
            if ($frame.Length -gt 0 -and $frame[$frame.Length - 1] -eq 13) { $frame = $frame[0..($frame.Length - 2)] }
            if ($frame.Length -eq 0) { continue }
            return $frame
        }
        $remaining = [int][Math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds)
        if ((Get-Date) -gt $deadline) { throw "timeout after ${TimeoutSec}s waiting for a frame from rea" }
        $task = $stdout.ReadAsync($script:readBuf, 0, $script:readBuf.Length)
        if (-not $task.Wait($remaining)) { throw "timeout after ${TimeoutSec}s waiting for stdout from rea" }
        $n = $task.Result
        if ($n -le 0) { throw 'rea closed stdout (EOF) before answering' }
        for ($i = 0; $i -lt $n; $i++) { $script:pending.Add($script:readBuf[$i]) }
    }
}

function Send-Request {
    param([Parameter(Mandatory)]$Message)
    $json = ConvertTo-Json -InputObject $Message -Depth 20 -Compress
    $bytes = $utf8.GetBytes($json + "`n")
    $stdin.Write($bytes, 0, $bytes.Length)
    $stdin.Flush()
}

function Wait-Response {
    <# Reads frames until the one carrying $Id; returns @{ Bytes; Json } #>
    param([Parameter(Mandatory)][int]$Id, [int]$TimeoutSec)
    while ($true) {
        $frame = Read-Frame -TimeoutSec $TimeoutSec
        $text = $utf8.GetString($frame)
        try { $obj = $text | ConvertFrom-Json -Depth 100 } catch { Note ("skipping non-JSON frame ({0} bytes)" -f $frame.Length); continue }
        if ($null -ne $obj.PSObject.Properties['id'] -and $obj.id -eq $Id) {
            return @{ Bytes = $frame; Json = $obj }
        }
        if ($null -ne $obj.PSObject.Properties['method']) { Note ("server notification: {0}" -f $obj.method) }
    }
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function Find-KeyValue {
    param($Node, [string]$Key, [int]$Depth = 0)
    if ($null -eq $Node -or $Depth -gt 12) { return $null }
    if ($Node -is [string] -or $Node -is [ValueType]) { return $null }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($i in $Node) { $r = Find-KeyValue -Node $i -Key $Key -Depth ($Depth + 1); if ($null -ne $r) { return $r } }
        return $null
    }
    $p = $Node.PSObject.Properties[$Key]
    if ($null -ne $p) { return $p.Value }
    foreach ($pp in $Node.PSObject.Properties) { $r = Find-KeyValue -Node $pp.Value -Key $Key -Depth ($Depth + 1); if ($null -ne $r) { return $r } }
    return $null
}

$serverInfo = $null
$protocol = $null
$tools = New-Object System.Collections.Generic.List[object]
$frames = New-Object System.Collections.Generic.List[byte[]]
$promptCount = $null
$reaToolsSha = $null
$identity = $null
$fixture = $null
$exitCode = $null
$stderrText = ''
$handshakeOk = $false

try {
    # 1) initialize
    $t0 = Get-Date
    Send-Request @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{
        protocolVersion = '2025-06-18'
        capabilities    = @{}
        clientInfo      = @{ name = 'reverse-skill test-rea-contract'; version = '1.0.0' }
    } }
    $init = Wait-Response -Id 1 -TimeoutSec $StartupTimeoutSec
    if ($null -ne $init.Json.PSObject.Properties['error']) { throw "initialize error: $($init.Json.error | ConvertTo-Json -Compress)" }
    $serverInfo = $init.Json.result.serverInfo
    $protocol = [string]$init.Json.result.protocolVersion
    Note ("initialize ok in {0:n1}s: {1} {2}, protocol {3}" -f ((Get-Date) - $t0).TotalSeconds, $serverInfo.name, $serverInfo.version, $protocol)
    if ([string]$serverInfo.version -ne $Version) { Fail ("serverInfo.version '{0}' != requested {1}" -f $serverInfo.version, $Version) }
    Send-Request @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
    $handshakeOk = $true

    # 2) tools/list (cursor loop; id 2, 3, ... fixed so the wire hash is reproducible)
    $id = 2
    $cursor = $null
    while ($true) {
        $params = @{}
        if ($cursor) { $params['cursor'] = $cursor }
        Send-Request @{ jsonrpc = '2.0'; id = $id; method = 'tools/list'; params = $params }
        $t1 = Get-Date
        $resp = Wait-Response -Id $id -TimeoutSec $CallTimeoutSec
        if ($null -ne $resp.Json.PSObject.Properties['error']) { throw "tools/list error: $($resp.Json.error | ConvertTo-Json -Compress)" }
        [void]$frames.Add($resp.Bytes)
        foreach ($t in @($resp.Json.result.tools)) { [void]$tools.Add($t) }
        Note ("tools/list id {0}: {1} tools, {2:n0} bytes in {3:n1}s" -f $id, @($resp.Json.result.tools).Count, $resp.Bytes.Length, ((Get-Date) - $t1).TotalSeconds)
        $cursor = $null
        if ($null -ne $resp.Json.result.PSObject.Properties['nextCursor'] -and $resp.Json.result.nextCursor) { $cursor = [string]$resp.Json.result.nextCursor }
        $id++
        if (-not $cursor) { break }
        if ($id -gt 50) { throw 'tools/list cursor loop did not terminate' }
    }
    if ($tools.Count -eq 0) { Fail 'tools/list returned no tools' }
    $names = @($tools | ForEach-Object { [string]$_.name })
    $dups = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dups.Count -gt 0) { Fail ("duplicate tool names: {0}" -f ($dups -join ', ')) }

    # 3) prompts/list (informational)
    try {
        Send-Request @{ jsonrpc = '2.0'; id = 100; method = 'prompts/list'; params = @{} }
        $pr = Wait-Response -Id 100 -TimeoutSec 60
        if ($null -eq $pr.Json.PSObject.Properties['error']) { $promptCount = @($pr.Json.result.prompts).Count }
    } catch { Note "prompts/list skipped: $($_.Exception.Message)" }

    # 4) rea's own catalog identity through binary_session {} (optional)
    if (-not $SkipIdentityCall -and $names -contains 'binary_session') {
        try {
            Send-Request @{ jsonrpc = '2.0'; id = 101; method = 'tools/call'; params = @{ name = 'binary_session'; arguments = @{} } }
            $bs = Wait-Response -Id 101 -TimeoutSec 120
            if ($null -eq $bs.Json.PSObject.Properties['error']) {
                $sc = $null
                if ($null -ne $bs.Json.result.PSObject.Properties['structuredContent']) { $sc = $bs.Json.result.structuredContent }
                $reaToolsSha = Find-KeyValue -Node $sc -Key 'tools_sha256'
                $catalog = Find-KeyValue -Node $sc -Key 'catalog'
                if ($null -ne $catalog) { $identity = $catalog }
                Note ("binary_session: rea tools_sha256 = {0}" -f $(if ($reaToolsSha) { $reaToolsSha } else { '(not found)' }))
            } else {
                Note ("binary_session error (ignored): {0}" -f ($bs.Json.error | ConvertTo-Json -Compress))
            }
        } catch { Note "binary_session skipped: $($_.Exception.Message)" }
    }

    # 5) fixture run (optional)
    if ($FixtureDir) {
        if ($names -notcontains 'analyze_javascript_application') {
            Fail 'fixture requested but analyze_javascript_application is not in the catalog'
        } else {
            $t2 = Get-Date
            Send-Request @{ jsonrpc = '2.0'; id = 102; method = 'tools/call'; params = @{ name = 'analyze_javascript_application'; arguments = @{ input_path = $FixtureDir } } }
            $fx = Wait-Response -Id 102 -TimeoutSec $CallTimeoutSec
            $fixture = [ordered]@{ dir = $FixtureDir; ok = $false; evidence_id = $null; statistics_keys = @(); error = $null; seconds = [Math]::Round(((Get-Date) - $t2).TotalSeconds, 1) }
            if ($null -ne $fx.Json.PSObject.Properties['error']) {
                $fixture.error = ($fx.Json.error | ConvertTo-Json -Compress -Depth 10)
                Fail "fixture analyze_javascript_application returned a JSON-RPC error: $($fixture.error)"
            } elseif ($null -ne $fx.Json.result.PSObject.Properties['isError'] -and $fx.Json.result.isError -eq $true) {
                $fixture.error = (($fx.Json.result.content | ForEach-Object { $_.text }) -join ' ')
                Fail "fixture analyze_javascript_application isError: $($fixture.error)"
            } else {
                $sc = $null
                if ($null -ne $fx.Json.result.PSObject.Properties['structuredContent']) { $sc = $fx.Json.result.structuredContent }
                $ev = Find-KeyValue -Node $sc -Key 'evidence_id'
                $stats = Find-KeyValue -Node $sc -Key 'statistics'
                if ($ev) { $fixture.evidence_id = [string]$ev } else { Fail 'fixture result has no evidence_id' }
                if ($null -ne $stats) { $fixture.statistics_keys = @($stats.PSObject.Properties | ForEach-Object { $_.Name }) } else { Fail 'fixture result has no statistics' }
                $fixture.ok = [bool]($ev -and $null -ne $stats)
                Note ("fixture analyze_javascript_application: evidence_id {0}, statistics [{1}] in {2}s" -f $fixture.evidence_id, ($fixture.statistics_keys -join ', '), $fixture.seconds)
            }
        }
    }
} catch {
    Fail $_.Exception.Message
} finally {
    try { $stdin.Close() } catch { }
    if (-not $proc.WaitForExit(10000)) {
        Note 'rea did not exit after stdin close; killing process tree'
        try { $proc.Kill($true) } catch { }
        $proc.WaitForExit(5000) | Out-Null
    }
    try { $exitCode = $proc.ExitCode } catch { }
    try { if ($stderrTask.Wait(5000)) { $stderrText = $stderrTask.Result } } catch { }
    if ($stderrText) { Note ("stderr ({0} chars): {1}" -f $stderrText.Length, ($stderrText.Substring(0, [Math]::Min(400, $stderrText.Length)) -replace '\s+', ' ')) }
}

# --- hash, catalog file ----------------------------------------------------------
$allBytes = New-Object System.Collections.Generic.List[byte]
for ($i = 0; $i -lt $frames.Count; $i++) {
    if ($i -gt 0) { $allBytes.Add([byte]10) }
    $allBytes.AddRange($frames[$i])
}
$wireBytes = $allBytes.ToArray()
$toolsListSha = if ($wireBytes.Length -gt 0) { Get-Sha256Hex $wireBytes } else { $null }

$catalogDoc = [ordered]@{
    package           = "rea-agents@$Version"
    version           = $Version
    generated_at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    server_info       = $serverInfo
    protocol_version  = $protocol
    tool_count        = $tools.Count
    tools_list_bytes  = $wireBytes.Length
    tools_list_frames = $frames.Count
    tools_list_sha256 = $toolsListSha
    rea_tools_sha256  = $reaToolsSha
    tools             = @($tools.ToArray())
}
if ($tools.Count -gt 0) {
    [System.IO.File]::WriteAllText($OutputPath, (ConvertTo-Json -InputObject $catalogDoc -Depth 100), $utf8)
    Note ("catalog written: {0} ({1} tools, wire {2:n0} bytes, tools_list_sha256 {3})" -f $OutputPath, $tools.Count, $wireBytes.Length, $toolsListSha)
}

# --- diff against previous catalog -------------------------------------------------
$diff = $null
if ($PreviousCatalog) {
    if (-not (Test-Path -LiteralPath $PreviousCatalog)) {
        Fail "previous catalog not found: $PreviousCatalog"
    } elseif ($tools.Count -gt 0) {
        $diff = Compare-ReaCatalog -Previous $PreviousCatalog -Current (@($tools.ToArray()))
        Note ("diff vs {0}: +{1} -{2} ~{3} (identical={4})" -f $PreviousCatalog, $diff.added.Count, $diff.removed.Count, $diff.changed.Count, $diff.identical)
    }
}

# --- referenced tool names in skills/ and docs/ -------------------------------------
$referenced = $null
if (-not $SkipReferenceCheck) {
    $scan = Get-ReaReferencedToolNames -RepoRoot $RepoRoot
    $present = @($tools | ForEach-Object { [string]$_.name })
    $missing = @($scan.Names | Where-Object { $present -notcontains $_ })
    $referenced = [ordered]@{ scanner = $scan.Scanner; roots = @('skills', 'docs'); count = $scan.Names.Count; names = $scan.Names; missing = $missing }
    if ($tools.Count -gt 0 -and $missing.Count -gt 0) { Fail ("referenced rea tools absent from the {0} catalog: {1}" -f $Version, ($missing -join ', ')) }
    Note ("referenced tools: {0} names via {1}, missing {2}" -f $scan.Names.Count, $scan.Scanner, $missing.Count)
}

# --- report ----------------------------------------------------------------------------
$passed = ($failures.Count -eq 0 -and $handshakeOk -and $tools.Count -gt 0)
$report = [ordered]@{
    version           = $Version
    package           = "rea-agents@$Version"
    generated_at      = $catalogDoc.generated_at
    node_exe          = $NodeExe
    npx_cli           = $NpxCli
    server_info       = $serverInfo
    protocol_version  = $protocol
    handshake_ok      = $handshakeOk
    tool_count        = $tools.Count
    prompt_count      = $promptCount
    tools_list_bytes  = $wireBytes.Length
    tools_list_frames = $frames.Count
    tools_list_sha256 = $toolsListSha
    rea_tools_sha256  = $reaToolsSha
    rea_catalog_identity = $identity
    catalog_path      = $(if ($tools.Count -gt 0) { $OutputPath } else { $null })
    previous_catalog  = $(if ($PreviousCatalog) { $PreviousCatalog } else { $null })
    diff              = $diff
    referenced_tools  = $referenced
    fixture           = $fixture
    process_exit_code = $exitCode
    stderr_excerpt    = $(if ($stderrText) { $stderrText.Substring(0, [Math]::Min(2000, $stderrText.Length)) } else { '' })
    failures          = @($failures.ToArray())
    passed            = $passed
}
[System.IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $report -Depth 100), $utf8)
Note ("report written: {0} (passed={1})" -f $ReportPath, $passed)
if ($passed) { Note 'PASS' } else { Write-Host ("[contract] FAILED: {0}" -f ($failures -join ' | ')) -ForegroundColor Red }
exit $(if ($passed) { 0 } else { 1 })
