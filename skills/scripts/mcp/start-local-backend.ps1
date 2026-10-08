# Start or reuse a verified local analysis backend. Never opens or executes a target.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Ida', 'X64dbg', 'AnythingAnalyzer')][string]$Backend,
    [string]$Executable = '',
    [string]$IdaDir = '',
    [string]$RepoDir = '',
    [string]$PnpmPath = '',
    [string]$ConfigPath = '',
    [ValidateRange(0,65535)][int]$Port = 0,
    [Parameter(Mandatory)][string]$LogDir,
    [ValidateRange(1,180)][int]$WaitSeconds = 30
)
$ErrorActionPreference = 'Stop'
$Backend = switch ($Backend.ToLowerInvariant()) { 'ida' { 'Ida' } 'x64dbg' { 'X64dbg' } default { 'AnythingAnalyzer' } }
if ($Backend -ne 'AnythingAnalyzer') {
    if ([string]::IsNullOrWhiteSpace($Executable)) { throw "-Executable is required for the $Backend backend." }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Executable not found: $Executable" }
    $Executable = (Resolve-Path -LiteralPath $Executable).Path
}
if ($Port -eq 0) { $Port = switch ($Backend) { 'Ida' { 13337 } 'X64dbg' { 8888 } default { 23816 } } }
$script:lastHealthError = ''

function Test-BackendPort {
    $client = [Net.Sockets.TcpClient]::new()
    try { $task = $client.ConnectAsync('127.0.0.1', $Port); return ($task.Wait(400) -and $client.Connected) }
    catch { return $false }
    finally { $client.Dispose() }
}
function Invoke-LoopbackJson {
    # Direct HttpWebRequest with no proxy: Windows PowerShell 5.1's Invoke-RestMethod can
    # spend seconds per call on proxy auto-detection even for 127.0.0.1, and this probe
    # runs every 400 ms during startup.
    param([string]$Uri, [string]$Method = 'GET', [string]$Body = '', [int]$TimeoutMs = 2000)
    $req = [Net.HttpWebRequest]::Create($Uri)
    $req.Method = $Method
    $req.Proxy = $null
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.Accept = 'application/json'
    if ($Method -eq 'POST') {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/json'
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $resp = $req.GetResponse()
    try {
        $reader = [IO.StreamReader]::new($resp.GetResponseStream())
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
    } finally { $resp.Dispose() }
}
function Invoke-McpStreamableHttp {
    # Streamable HTTP MCP probe. The SDK server answers a POST only when Accept lists both
    # application/json and text/event-stream, and by default replies as an SSE stream
    # ("event: message" / "data: {...}") that it closes after the response is written.
    param([string]$Uri, [string]$Method = 'POST', [string]$Body = '', [string]$BearerToken = '', [string]$SessionId = '', [int]$TimeoutMs = 4000)
    $req = [Net.HttpWebRequest]::Create($Uri)
    $req.Method = $Method
    $req.Proxy = $null
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.Accept = 'application/json, text/event-stream'
    if ($BearerToken) { $req.Headers['Authorization'] = "Bearer $BearerToken" }
    if ($SessionId) { $req.Headers['mcp-session-id'] = $SessionId }
    if ($Method -eq 'POST') {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/json'
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $resp = $req.GetResponse()
    try {
        $reader = [IO.StreamReader]::new($resp.GetResponseStream())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $contentType = [string]$resp.ContentType
        $message = $null
        if ($contentType -like 'text/event-stream*') {
            foreach ($line in ($text -split "`n")) {
                $line = $line.TrimEnd("`r")
                if ($line.StartsWith('data:')) { $message = $line.Substring(5).Trim() | ConvertFrom-Json; break }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($text)) {
            $message = $text | ConvertFrom-Json
        }
        return @{ status = [int]$resp.StatusCode; session_id = [string]$resp.Headers['mcp-session-id']; message = $message }
    } finally { $resp.Dispose() }
}
function Get-AnythingAnalyzerToken {
    # The bootstrap persists the bearer token in the User environment; a process-scope value
    # (inherited at logon, or set deliberately by a caller) takes precedence so tests never
    # read the real token.
    $token = [string]$env:ANYTHING_ANALYZER_MCP_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) { $token = [string][Environment]::GetEnvironmentVariable('ANYTHING_ANALYZER_MCP_TOKEN', 'User') }
    return $token
}
function Get-BackendHealth {
    $script:lastHealthError = ''
    try {
        if ($Backend -eq 'Ida') {
            $reply = Invoke-LoopbackJson -Uri "http://127.0.0.1:$Port/mcp" -Method Post -Body '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
            $names = @($reply.result.tools | ForEach-Object name)
            if ($names -contains 'decompile' -and $names -contains 'list_funcs') { return @{tool_count=$names.Count} }
        } elseif ($Backend -eq 'X64dbg') {
            $reply = Invoke-LoopbackJson -Uri "http://127.0.0.1:$Port/Is_Debugging"
            if ($reply.PSObject.Properties.Name -contains 'isDebugging' -and $reply.isDebugging -is [bool]) { return @{is_debugging=$reply.isDebugging} }
        } else {
            $token = Get-AnythingAnalyzerToken
            if ([string]::IsNullOrWhiteSpace($token)) { $script:lastHealthError = 'ANYTHING_ANALYZER_MCP_TOKEN is not set in the process or User environment.'; return $null }
            $init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"reverse-skill-start-local-backend","version":"1.0"}}}'
            $reply = Invoke-McpStreamableHttp -Uri "http://127.0.0.1:$Port/mcp" -Method POST -Body $init -BearerToken $token
            $serverInfo = $null
            if ($reply.message -and $reply.message.PSObject.Properties.Name -contains 'result') { $serverInfo = $reply.message.result.serverInfo }
            if ($reply.session_id) {
                # Close the probe session. The pinned app's transport.onclose -> srv.close() recursion
                # logs one RangeError per close (documented upstream bug); the session is still removed.
                try { Invoke-McpStreamableHttp -Uri "http://127.0.0.1:$Port/mcp" -Method DELETE -BearerToken $token -SessionId $reply.session_id -TimeoutMs 1500 | Out-Null } catch { }
            }
            if ($serverInfo -and [string]$serverInfo.name -eq 'anything-analyzer') {
                return @{server_name=[string]$serverInfo.name;server_version=[string]$serverInfo.version;protocol_version=[string]$reply.message.result.protocolVersion}
            }
            $script:lastHealthError = if ($serverInfo) { "initialize answered with serverInfo.name '$($serverInfo.name)' instead of 'anything-analyzer'." } else { "initialize returned HTTP $($reply.status) without an MCP result." }
        }
    } catch [Net.WebException] {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $script:lastHealthError = if ($status -eq 401) { 'HTTP 401 Unauthorized: the listener rejected the bearer token from ANYTHING_ANALYZER_MCP_TOKEN.' } elseif ($status) { "HTTP $status from the listener." } else { "no HTTP reply: $($_.Exception.Message)" }
    } catch { $script:lastHealthError = $_.Exception.Message }
    return $null
}
function Get-ListenerPid {
    $lines = & netstat.exe -ano -p TCP
    $netstatExit = $LASTEXITCODE
    if ($netstatExit -ne 0) { throw 'Could not verify the backend listener owner.' }
    $owners = @(); $wildcard = $false
    foreach ($line in $lines) {
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -ne 5 -or $parts[3] -ne 'LISTENING') { continue }
        if ($parts[1] -eq "127.0.0.1:$Port") { $owners += [int]$parts[4] }
        elseif ($parts[1] -eq "0.0.0.0:$Port") { $wildcard = $true }
    }
    $owners = @($owners | Select-Object -Unique)
    if ($owners.Count -eq 0 -and $wildcard) { throw "Port $Port is bound to all interfaces (0.0.0.0), not loopback only; for AnythingAnalyzer set `"host`": `"127.0.0.1`" in mcp-server-config.json and restart the app yourself." }
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
function Test-AnythingAnalyzerConfig {
    # Read-only validation of the app's own config. The app does JSON.parse(readFileSync(path,'utf-8')):
    # a BOM makes it fall back to enabled=false with a fresh token, and an omitted host means 0.0.0.0.
    param([string]$Path, [int]$ExpectedPort)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Anything Analyzer config not found: $Path. Run bootstrap-reverse.ps1 -Capability anything-analyzer first." }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw "Anything Analyzer config has a UTF-8 BOM, which the app cannot parse: $Path. Rewrite it without a BOM (bootstrap-reverse.ps1 does); the token was left untouched." }
    try { $config = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json } catch { throw "Anything Analyzer config is not valid JSON: $Path ($($_.Exception.Message))" }
    $names = @($config.PSObject.Properties.Name)
    if (-not ($names -contains 'enabled') -or $config.enabled -ne $true) { throw "Anything Analyzer config has enabled != true: $Path. The app would not start its MCP server." }
    if (-not ($names -contains 'host') -or [string]$config.host -ne '127.0.0.1') { throw "Anything Analyzer config host is '$(if ($names -contains 'host') { $config.host } else { '<missing>' })', expected 127.0.0.1 (the app default binds 0.0.0.0): $Path" }
    if (-not ($names -contains 'port') -or [int]$config.port -ne $ExpectedPort) { throw "Anything Analyzer config port is '$(if ($names -contains 'port') { $config.port } else { '<missing>' })', expected $ExpectedPort`: $Path" }
    if (-not ($names -contains 'authEnabled') -or $config.authEnabled -ne $true -or -not ($names -contains 'authToken') -or [string]::IsNullOrWhiteSpace([string]$config.authToken)) { throw "Anything Analyzer config must have authEnabled=true and a non-empty authToken: $Path. An empty token makes the app generate a new one that no client knows." }
    $envToken = Get-AnythingAnalyzerToken
    if ([string]::IsNullOrWhiteSpace($envToken)) { throw 'ANYTHING_ANALYZER_MCP_TOKEN is not set in the process or User environment; clients could not authenticate to the backend.' }
    if ([string]$config.authToken -ne $envToken) { throw "The authToken in $Path differs from ANYTHING_ANALYZER_MCP_TOKEN; clients would get HTTP 401. Re-run the bootstrap to realign them (neither value is printed here)." }
}
function Resolve-PnpmLauncher {
    # Returns @{FilePath; Arguments} for Start-Process. Start-Process cannot run a .ps1 shim
    # with stdio redirection, so prefer the .exe, then the .cmd shim, and wrap .ps1 last.
    param([string]$Preferred)
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        if (-not (Test-Path -LiteralPath $Preferred -PathType Leaf)) { throw "pnpm launcher not found: $Preferred" }
        $candidates = @((Resolve-Path -LiteralPath $Preferred).Path)
    } else {
        $candidates = @(Get-Command pnpm -All -ErrorAction SilentlyContinue | ForEach-Object Source | Where-Object { $_ })
        if ($candidates.Count -eq 0) { throw 'pnpm was not found on PATH; pass -PnpmPath or install pnpm.' }
        # Keep the user's PATH order (the same pnpm `pnpm dev` would use in a shell); only the
        # .ps1 shim and extension-less shims are demoted because Start-Process cannot run them.
        $direct = @($candidates | Where-Object { @('.exe', '.cmd', '.bat') -contains [IO.Path]::GetExtension($_).ToLowerInvariant() })
        $candidates = if ($direct.Count -gt 0) { $direct } else { @($candidates | Where-Object { [IO.Path]::GetExtension($_).ToLowerInvariant() -eq '.ps1' }) }
        if ($candidates.Count -eq 0) { throw 'pnpm on PATH has no .exe/.cmd/.bat/.ps1 launcher; pass -PnpmPath.' }
    }
    $chosen = $candidates[0]
    if ([IO.Path]::GetExtension($chosen).ToLowerInvariant() -eq '.ps1') {
        $hostExe = (Get-Process -Id $PID).Path
        return @{ FilePath = $hostExe; Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $chosen, 'dev'); Resolved = $chosen }
    }
    return @{ FilePath = $chosen; Arguments = @('dev'); Resolved = $chosen }
}

$scriptClock = [Diagnostics.Stopwatch]::StartNew()
$startupMutex = [Threading.Mutex]::new($false, "Local\reverse-skill-$Backend-$Port")
$lockAcquired = $false
try {
    try { $lockAcquired = $startupMutex.WaitOne([TimeSpan]::FromSeconds([Math]::Min($WaitSeconds,30))) }
    catch [Threading.AbandonedMutexException] { $lockAcquired = $true }
    if (-not $lockAcquired) { throw "Another $Backend startup still owns port $Port; retry after it finishes." }

if (Test-BackendPort) {
    $health = Get-BackendHealth
    if (-not $health) {
        $detail = if ($script:lastHealthError) { " ($script:lastHealthError)" } else { '' }
        throw "Port $Port is occupied but the expected $Backend API is unavailable or busy$detail; existing processes were preserved."
    }
    @{backend=$Backend;pid=(Get-ListenerPid);port=$Port;reused=$true;health=$health;elapsed_ms=$scriptClock.ElapsedMilliseconds} | ConvertTo-Json -Depth 4
    exit 0
}
if ($Backend -eq 'AnythingAnalyzer') {
    # Validate everything the start needs before creating LogDir or touching the user's config.
    if ([string]::IsNullOrWhiteSpace($RepoDir)) { $RepoDir = Join-Path $env:USERPROFILE 'Tools\anything-analyzer' }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoDir 'package.json') -PathType Leaf)) { throw "Anything Analyzer checkout not found (no package.json): $RepoDir" }
    $RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $env:APPDATA 'anything-analyzer\mcp-server-config.json' }
    Test-AnythingAnalyzerConfig -Path $ConfigPath -ExpectedPort $Port
    if ([string]::IsNullOrWhiteSpace($PnpmPath) -and -not [string]::IsNullOrWhiteSpace($Executable)) { $PnpmPath = $Executable }
    $launcher = Resolve-PnpmLauncher -Preferred $PnpmPath
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path -LiteralPath $LogDir).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$stdout = Join-Path $LogDir "$Backend-$stamp.stdout.log"
$stderr = Join-Path $LogDir "$Backend-$stamp.stderr.log"
$record = $null
if ($Backend -eq 'Ida') {
    if (-not (Test-Path -LiteralPath (Join-Path $IdaDir 'idalib.dll') -PathType Leaf)) { throw 'IdaDir must contain the installed idalib.dll.' }
    $env:IDADIR = (Resolve-Path -LiteralPath $IdaDir).Path
    $env:PYTHONUTF8 = '1'
    $process = Start-Process -FilePath $Executable -ArgumentList @('-u','-m','ida_pro_mcp.idalib_server','--host','127.0.0.1','--port',"$Port") -WorkingDirectory $LogDir -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $record = @{backend=$Backend;pid=$process.Id;port=$Port;executable=$Executable;started_at=(Get-Date -Format o);sample_opened=$false}
} elseif ($Backend -eq 'X64dbg') {
    # Port selects the probe address; configure a non-default port in the plugin itself.
    $process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable -Parent) -WindowStyle Hidden -PassThru
    $record = @{backend=$Backend;pid=$process.Id;port=$Port;executable=$Executable;started_at=(Get-Date -Format o);sample_opened=$false}
} else {
    # `pnpm dev` runs electron-vite dev; the Electron window is the service and the MCP listener.
    $process = Start-Process -FilePath $launcher.FilePath -ArgumentList $launcher.Arguments -WorkingDirectory $RepoDir -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $record = @{backend=$Backend;pid=$process.Id;port=$Port;executable=$launcher.Resolved;repo_dir=$RepoDir;config_path=$ConfigPath;started_at=(Get-Date -Format o);sample_opened=$false}
}
$null = $process.Handle   # cache the handle so Windows PowerShell 5.1 can report ExitCode after an early exit
$record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDir "$Backend-$stamp.process.json") -Encoding utf8
$deadline = (Get-Date).AddSeconds($WaitSeconds)
do {
    $process.Refresh()
    if ($process.HasExited) { throw "$Backend launcher exited with code $($process.ExitCode) before readiness; inspect $LogDir." }
    $health = Get-BackendHealth
    if ($health) {
        $owner = Get-ListenerPid
        if (-not (Test-StartedProcessOwner -Owner $owner -Launcher $process.Id)) { throw "Port $Port is owned by a different process; startup was not confirmed." }
        @{backend=$Backend;pid=$owner;launcher_pid=$process.Id;port=$Port;reused=$false;health=$health;log_dir=$LogDir;elapsed_ms=$scriptClock.ElapsedMilliseconds} | ConvertTo-Json -Depth 4
        exit 0
    }
    Start-Sleep -Milliseconds 400
} while ((Get-Date) -lt $deadline)
throw "$Backend did not become ready on loopback port $Port. PID $($process.Id) was preserved; inspect $LogDir."
} finally {
    if ($lockAcquired) { $startupMutex.ReleaseMutex() }
    $startupMutex.Dispose()
}
