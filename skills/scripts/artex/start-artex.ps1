# Start, probe or stop the local ARTEX stack (Docker Compose, loopback only).
# ARTEX is an autonomous pentest platform with its own agents; this script only brings
# the containers up and reports readiness. It never logs in, never creates tasks,
# never prints .env or jwt.key, and fails closed when the compose override that pins
# the web UI/proxy to 127.0.0.1 is missing.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File skills\scripts\artex\start-artex.ps1 -Action Start
#   powershell -NoProfile -ExecutionPolicy Bypass -File skills\scripts\artex\start-artex.ps1 -Action Status
#   powershell -NoProfile -ExecutionPolicy Bypass -File skills\scripts\artex\start-artex.ps1 -Action Stop
#
# ARTEX root resolution: -ArtexRoot > $env:ARTEX_ROOT > <repo parent>\ARTEX.
[CmdletBinding()]
param(
    [ValidateSet('Start', 'Status', 'Stop')][string]$Action = 'Start',
    [string]$ArtexRoot = '',
    [ValidateRange(1, 65535)][int]$Port = 8787,
    [ValidateRange(1, 600)][int]$WaitSeconds = 120,
    [string]$LogDir = ''
)
$ErrorActionPreference = 'Stop'
$clock = [Diagnostics.Stopwatch]::StartNew()

function Resolve-ArtexRoot {
    param([string]$Requested)
    $candidates = @()
    if ($Requested) { $candidates += $Requested }
    if ($env:ARTEX_ROOT) { $candidates += $env:ARTEX_ROOT }
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir))
    $candidates += (Join-Path (Split-Path -Parent $repoRoot) 'ARTEX')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'docker-compose.yml') -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    throw "ARTEX root not found (tried: $($candidates -join '; ')). Pass -ArtexRoot or set ARTEX_ROOT."
}

function Invoke-LoopbackJson {
    # Direct HttpWebRequest with no proxy; Invoke-RestMethod can stall on proxy auto-detection.
    param([string]$Uri, [int]$TimeoutMs = 2000)
    $req = [Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'GET'
    $req.Proxy = $null
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.Accept = 'application/json'
    $resp = $req.GetResponse()
    try {
        $reader = [IO.StreamReader]::new($resp.GetResponseStream())
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
    } finally { $resp.Dispose() }
}

function Get-ArtexHealth {
    # /api/health is unauthenticated: {"ok":true,"service":"artex","version":"..."}.
    # /api/auth/status reports whether the admin password has been set (/setup done).
    try {
        $h = Invoke-LoopbackJson -Uri "http://127.0.0.1:$Port/api/health"
        if (-not ($h.ok -eq $true -and [string]$h.service -eq 'artex')) { return $null }
        $initialized = $null
        try { $a = Invoke-LoopbackJson -Uri "http://127.0.0.1:$Port/api/auth/status"; $initialized = [bool]$a.initialized } catch { $initialized = $null }
        return @{ version = [string]$h.version; initialized = $initialized }
    } catch { return $null }
}

function Test-ComposeOverride {
    # The upstream compose file publishes 8787 on every interface. The fork's override pins
    # both ports to 127.0.0.1 and must be present, or anyone on the LAN could reach /setup.
    param([string]$Root)
    $override = Join-Path $Root 'docker-compose.override.yml'
    if (-not (Test-Path -LiteralPath $override -PathType Leaf)) { throw "docker-compose.override.yml is missing in $Root; refusing to start ARTEX on all interfaces. See ARTEX/CLAUDE.md." }
    $text = Get-Content -LiteralPath $override -Raw
    if ($text -notmatch "127\.0\.0\.1:$Port`:$Port") { throw "docker-compose.override.yml does not bind $Port to 127.0.0.1; refusing to start." }
    if ($text -notmatch '127\.0\.0\.1:8788:8788') { throw 'docker-compose.override.yml does not bind the traffic proxy 8788 to 127.0.0.1; refusing to start.' }
}

function Test-ArtexPrerequisites {
    param([string]$Root)
    foreach ($name in @('.env', 'jwt.key')) {
        $p = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "$name is missing or is a directory in $Root; create it per ARTEX/CLAUDE.md (jwt.key must exist as a file before compose up)." }
    }
    Test-ComposeOverride -Root $Root
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { throw 'docker CLI not found on PATH.' }
    $null = & docker info --format '{{.ServerVersion}}' 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Docker engine is not reachable (is Docker Desktop running?).' }
    $null = & docker image inspect artex:local --format '{{.Id}}' 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Image artex:local is not built; the upstream image is gone. Build it per ARTEX/CLAUDE.md first.' }
}

$root = Resolve-ArtexRoot -Requested $ArtexRoot
$url = "http://127.0.0.1:$Port"

if ($Action -eq 'Status') {
    $health = Get-ArtexHealth
    $out = @{ action = 'Status'; artex_root = $root; url = $url; ready = [bool]$health; elapsed_ms = $clock.ElapsedMilliseconds }
    if ($health) { $out['version'] = $health.version; $out['initialized'] = $health.initialized }
    $out | ConvertTo-Json
    exit $(if ($health) { 0 } else { 2 })
}

if ($Action -eq 'Stop') {
    Push-Location $root
    try {
        # `stop`, not `down`: keep the pgdata volume and the data/ bind mount intact.
        $log = & docker compose stop 2>&1
        if ($LASTEXITCODE -ne 0) { throw "docker compose stop failed: $log" }
    } finally { Pop-Location }
    @{ action = 'Stop'; artex_root = $root; stopped = $true; elapsed_ms = $clock.ElapsedMilliseconds } | ConvertTo-Json
    exit 0
}

# Start: reuse a healthy instance, otherwise compose up and wait for /api/health.
$existing = Get-ArtexHealth
if ($existing) {
    @{ action = 'Start'; artex_root = $root; url = $url; ready = $true; reused = $true; version = $existing.version; initialized = $existing.initialized; elapsed_ms = $clock.ElapsedMilliseconds } | ConvertTo-Json
    exit 0
}

Test-ArtexPrerequisites -Root $root
if ($LogDir) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

Push-Location $root
try {
    $composeOut = & docker compose up -d 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker compose up -d failed: $composeOut" }
    if ($LogDir) { $composeOut | Set-Content -LiteralPath (Join-Path $LogDir ("artex-compose-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Encoding utf8 }
} finally { Pop-Location }

$deadline = (Get-Date).AddSeconds($WaitSeconds)
do {
    $health = Get-ArtexHealth
    if ($health) {
        @{ action = 'Start'; artex_root = $root; url = $url; ready = $true; reused = $false; version = $health.version; initialized = $health.initialized; log_dir = $LogDir; elapsed_ms = $clock.ElapsedMilliseconds } | ConvertTo-Json
        exit 0
    }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
throw "ARTEX did not answer on $url/api/health within $WaitSeconds s. Containers were left running; inspect `docker compose logs artex` in $root."
