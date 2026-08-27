# Shared IDA open lock policy. Never delete .i64/.idb.
function Get-IdaOpenLockPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BinaryPath
    )
    $dir = [System.IO.Path]::GetDirectoryName($BinaryPath)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($BinaryPath)
    $lockExts = @('.id0', '.id1', '.id2', '.nam', '.til')
    $dbExts = @('.i64', '.idb')
    $hasLocked = $false
    foreach ($ext in $lockExts) {
        $f = Join-Path $dir ($base + $ext)
        if (Test-Path -LiteralPath $f) { $hasLocked = $true }
    }
    $hasDatabase = $false
    foreach ($ext in $dbExts) {
        $f = Join-Path $dir ($base + $ext)
        if (Test-Path -LiteralPath $f) { $hasDatabase = $true }
    }
    return [pscustomobject]@{
        HasLocked            = $hasLocked
        HasDatabase          = $hasDatabase
        WouldDeleteDatabase  = $false
        PreferTempCopy       = $hasLocked
    }
}

function Get-IdaMcpKeepaliveDir {
    $dir = Join-Path $env:LOCALAPPDATA 'reverse-skill\ida-mcp'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-IdaMcpLastHealthyPath {
    return Join-Path (Get-IdaMcpKeepaliveDir) 'last-healthy.txt'
}

function Get-IdaMcpOpeningLockPath {
    return Join-Path (Get-IdaMcpKeepaliveDir) 'opening.lock'
}

function Write-IdaMcpLastHealthy {
    Set-Content -LiteralPath (Get-IdaMcpLastHealthyPath) -Value 'ok' -Encoding ASCII
}

function Read-IdaMcpLastHealthy {
    $path = Get-IdaMcpLastHealthyPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Item -LiteralPath $path).LastWriteTime
}

function Set-IdaMcpOpeningLock {
    param([int]$TtlSeconds = 600)
    $ttl = [Math]::Max(1, $TtlSeconds)
    $until = (Get-Date).AddSeconds($ttl).ToString('o')
    Set-Content -LiteralPath (Get-IdaMcpOpeningLockPath) -Value $until -Encoding ASCII
}

function Clear-IdaMcpOpeningLock {
    $path = Get-IdaMcpOpeningLockPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Test-IdaMcpOpeningInFlight {
    param([datetime]$Now = (Get-Date))
    $path = Get-IdaMcpOpeningLockPath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $raw = (Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    try {
        $until = [datetime]::Parse($raw.Trim(), $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $true
    }
    if ($Now -gt $until) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

function Test-IdaMcpKeepaliveDeadlockFromFacts {
    param(
        [bool]$GuiOwnsPort = $false,
        [bool]$OpeningInFlight = $false,
        $LastHealthy = $null,
        [datetime]$Now = (Get-Date),
        [int]$MaxUnhealthySeconds = 180
    )
    if ($GuiOwnsPort) { return $false }
    if ($OpeningInFlight) { return $false }
    if ($null -eq $LastHealthy) { return $false }
    return ($Now - [datetime]$LastHealthy).TotalSeconds -ge $MaxUnhealthySeconds
}
