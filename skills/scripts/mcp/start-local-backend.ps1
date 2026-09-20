# Start or reuse a verified local analysis backend. Never opens or executes a target.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Ida', 'X64dbg')][string]$Backend,
    [Parameter(Mandatory)][string]$Executable,
    [string]$IdaDir = '',
    [ValidateRange(0,65535)][int]$Port = 0,
    [Parameter(Mandatory)][string]$LogDir,
    [ValidateRange(1,60)][int]$WaitSeconds = 30
)
$ErrorActionPreference = 'Stop'
$Backend = if ($Backend -eq 'Ida') { 'Ida' } else { 'X64dbg' }
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Executable not found: $Executable" }
$Executable = (Resolve-Path -LiteralPath $Executable).Path
if ($Port -eq 0) { $Port = if ($Backend -eq 'Ida') { 13337 } else { 8888 } }

function Test-BackendPort {
    $client = [Net.Sockets.TcpClient]::new()
    try { $task = $client.ConnectAsync('127.0.0.1', $Port); return ($task.Wait(400) -and $client.Connected) }
    catch { return $false }
    finally { $client.Dispose() }
}
function Get-BackendHealth {
    try {
        if ($Backend -eq 'Ida') {
            $reply = Invoke-RestMethod "http://127.0.0.1:$Port/mcp" -Method Post -ContentType 'application/json' -Body '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' -TimeoutSec 2
            $names = @($reply.result.tools | ForEach-Object name)
            if ($names -contains 'decompile' -and $names -contains 'list_funcs') { return @{tool_count=$names.Count} }
        } else {
            $reply = Invoke-RestMethod "http://127.0.0.1:$Port/Is_Debugging" -TimeoutSec 2
            if ($reply.PSObject.Properties.Name -contains 'isDebugging' -and $reply.isDebugging -is [bool]) { return @{is_debugging=$reply.isDebugging} }
        }
    } catch { }
    return $null
}
function Get-ListenerPid {
    $lines = & netstat.exe -ano -p TCP
    $netstatExit = $LASTEXITCODE
    if ($netstatExit -ne 0) { throw 'Could not verify the backend listener owner.' }
    $owners = foreach ($line in $lines) {
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -eq 5 -and $parts[3] -eq 'LISTENING' -and $parts[1] -eq "127.0.0.1:$Port") { [int]$parts[4] }
    }
    $owners = @($owners | Select-Object -Unique)
    if ($owners.Count -ne 1) { throw "Expected one IPv4 loopback listener on port $Port." }
    return $owners[0]
}
function Test-StartedProcessOwner([int]$Owner, [int]$Launcher) {
    $seen = @{}
    for ($depth=0; $depth -lt 8 -and $Owner -gt 0; $depth++) {
        if ($Owner -eq $Launcher) { return $true }
        if ($seen.ContainsKey($Owner)) { return $false }
        $seen[$Owner] = $true
        $details = Get-CimInstance Win32_Process -Filter "ProcessId=$Owner" -ErrorAction Stop
        if (-not $details) { return $false }
        $Owner = [int]$details.ParentProcessId
    }
    return $false
}

$startupMutex = [Threading.Mutex]::new($false, "Local\reverse-skill-$Backend-$Port")
$lockAcquired = $false
try {
    try { $lockAcquired = $startupMutex.WaitOne([TimeSpan]::FromSeconds([Math]::Min($WaitSeconds,30))) }
    catch [Threading.AbandonedMutexException] { $lockAcquired = $true }
    if (-not $lockAcquired) { throw "Another $Backend startup still owns port $Port; retry after it finishes." }

if (Test-BackendPort) {
    $health = Get-BackendHealth
    if (-not $health) { throw "Port $Port is occupied but the expected $Backend API is unavailable or busy; existing processes were preserved." }
    @{backend=$Backend;pid=(Get-ListenerPid);port=$Port;reused=$true;health=$health} | ConvertTo-Json -Depth 4
    exit 0
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path -LiteralPath $LogDir).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$stdout = Join-Path $LogDir "$Backend-$stamp.stdout.log"
$stderr = Join-Path $LogDir "$Backend-$stamp.stderr.log"
if ($Backend -eq 'Ida') {
    if (-not (Test-Path -LiteralPath (Join-Path $IdaDir 'idalib.dll') -PathType Leaf)) { throw 'IdaDir must contain the installed idalib.dll.' }
    $env:IDADIR = (Resolve-Path -LiteralPath $IdaDir).Path
    $env:PYTHONUTF8 = '1'
    $process = Start-Process -FilePath $Executable -ArgumentList @('-u','-m','ida_pro_mcp.idalib_server','--host','127.0.0.1','--port',"$Port") -WorkingDirectory $LogDir -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
} else {
    # Port selects the probe address; configure a non-default port in the plugin itself.
    $process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable -Parent) -WindowStyle Hidden -PassThru
}
$record = @{backend=$Backend;pid=$process.Id;port=$Port;executable=$Executable;started_at=(Get-Date -Format o);sample_opened=$false}
$record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDir "$Backend-$stamp.process.json") -Encoding utf8
$deadline = (Get-Date).AddSeconds($WaitSeconds)
do {
    $process.Refresh()
    if ($process.HasExited) { throw "$Backend launcher exited with code $($process.ExitCode) before readiness; inspect $LogDir." }
    $health = Get-BackendHealth
    if ($health) {
        $owner = Get-ListenerPid
        if (-not (Test-StartedProcessOwner -Owner $owner -Launcher $process.Id)) { throw "Port $Port is owned by a different process; startup was not confirmed." }
        @{backend=$Backend;pid=$owner;launcher_pid=$process.Id;port=$Port;reused=$false;health=$health;log_dir=$LogDir} | ConvertTo-Json -Depth 4
        exit 0
    }
    Start-Sleep -Milliseconds 400
} while ((Get-Date) -lt $deadline)
throw "$Backend did not become ready on loopback port $Port. PID $($process.Id) was preserved; inspect $LogDir."
} finally {
    if ($lockAcquired) { $startupMutex.ReleaseMutex() }
    $startupMutex.Dispose()
}
