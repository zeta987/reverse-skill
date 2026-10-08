# Start or reuse a verified local analysis backend. Never opens or executes a target.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Ida', 'X64dbg', 'AnythingAnalyzer', 'PentestSwarm')][string]$Backend,
    [string]$Executable = '',
    [string]$IdaDir = '',
    [string]$RepoDir = '',
    [string]$PnpmPath = '',
    [string]$ConfigPath = '',
    [string]$OllamaPath = '',
    [ValidateRange(0,65535)][int]$OllamaPort = 11434,
    [ValidateRange(0,65535)][int]$RedisPort = 6379,
    [ValidateRange(0,65535)][int]$Port = 0,
    [Parameter(Mandatory)][string]$LogDir,
    [ValidateRange(1,180)][int]$WaitSeconds = 30
)
$ErrorActionPreference = 'Stop'
$Backend = switch ($Backend.ToLowerInvariant()) { 'ida' { 'Ida' } 'x64dbg' { 'X64dbg' } 'pentestswarm' { 'PentestSwarm' } default { 'AnythingAnalyzer' } }
if ($Backend -eq 'Ida' -or $Backend -eq 'X64dbg') {
    if ([string]::IsNullOrWhiteSpace($Executable)) { throw "-Executable is required for the $Backend backend." }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Executable not found: $Executable" }
    $Executable = (Resolve-Path -LiteralPath $Executable).Path
}
if ($Port -eq 0) { $Port = switch ($Backend) { 'Ida' { 13337 } 'X64dbg' { 8888 } 'PentestSwarm' { 8080 } default { 23816 } } }
$script:lastHealthError = ''
$script:bindAllInterfaces = $false

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
        } elseif ($Backend -eq 'PentestSwarm') {
            $reply = Invoke-LoopbackJson -Uri "http://127.0.0.1:$Port/api/v1/health"
            $names = @($reply.PSObject.Properties.Name)
            if ($names -contains 'service' -and [string]$reply.service -eq 'pentestswarm' -and [string]$reply.status -eq 'ok') { return @{status=[string]$reply.status;service=[string]$reply.service} }
            $script:lastHealthError = if ($names -contains 'service') { "health answered with service '$($reply.service)' instead of 'pentestswarm'." } else { 'GET /api/v1/health returned no pentestswarm health body.' }
        } else {
            $token = Get-AnythingAnalyzerToken
            if ([string]::IsNullOrWhiteSpace($token)) { $script:lastHealthError = 'ANYTHING_ANALYZER_MCP_TOKEN is not set in the process or User environment.'; return $null }
            $init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"reverse-skill-start-local-backend","version":"1.0"}}}'
            $reply = Invoke-McpStreamableHttp -Uri "http://127.0.0.1:$Port/mcp" -Method POST -Body $init -BearerToken $token
            $serverInfo = $null
            if ($reply.message -and $reply.message.PSObject.Properties.Name -contains 'result') { $serverInfo = $reply.message.result.serverInfo }
            if ($reply.session_id -and $env:ANYTHING_ANALYZER_CLOSE_SESSIONS -eq '1') {
                # Opt-in only: an explicit DELETE is the one path that fires the pinned app's
                # transport.onclose -> srv.close() -> transport.close() recursion (RangeError spam,
                # one reported crash). By default the probe session is left to the app.
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
    $owners = @(); $wildcardOwners = @()
    foreach ($line in $lines) {
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -ne 5 -or $parts[3] -ne 'LISTENING') { continue }
        if ($parts[1] -eq "127.0.0.1:$Port") { $owners += [int]$parts[4] }
        elseif ($parts[1] -eq "0.0.0.0:$Port" -or $parts[1] -eq "[::]:$Port") { $wildcardOwners += [int]$parts[4] }
    }
    $owners = @($owners | Select-Object -Unique)
    $wildcardOwners = @($wildcardOwners | Select-Object -Unique)
    if ($owners.Count -eq 0 -and $wildcardOwners.Count -gt 0) {
        if ($Backend -eq 'PentestSwarm' -and $wildcardOwners.Count -eq 1) {
            # pentestswarm v0.1.0 ignores server.host (api.Server.Start listens on ":<port>"), so a
            # wildcard bind is the upstream behaviour, not a misconfiguration; it is reported, not refused.
            $script:bindAllInterfaces = $true
            return $wildcardOwners[0]
        }
        throw "Port $Port is bound to all interfaces (0.0.0.0), not loopback only; for AnythingAnalyzer set `"host`": `"127.0.0.1`" in mcp-server-config.json and restart the app yourself."
    }
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
function Write-LauncherWarning {
    # stdout carries the JSON result, so every advisory line goes to stderr.
    param([string]$Message)
    [Console]::Error.WriteLine("WARNING: $Message")
}
function ConvertFrom-SimpleYaml {
    # Scalars of the indentation-based YAML subset config.example.yaml uses: `key: value` and
    # `key:` section lines -> hashtable of dotted keys. Lists/flow values are ignored. Mirrors
    # parse_simple_yaml in pentestswarm-stdio.py.
    param([string]$Text)
    $values = @{}
    $stack = New-Object System.Collections.ArrayList
    foreach ($raw in ($Text -split "`r?`n")) {
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.StartsWith('-')) { continue }
        $indent = $raw.Length - $raw.TrimStart(' ').Length
        $match = [regex]::Match($trimmed, '^([A-Za-z0-9_.-]+)\s*:(.*)$')
        if (-not $match.Success) { continue }
        $key = $match.Groups[1].Value; $rest = $match.Groups[2].Value.Trim()
        while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent) { $stack.RemoveAt($stack.Count - 1) }
        $dotted = (@($stack | ForEach-Object { $_.Key }) + @($key)) -join '.'
        if ($rest -eq '' -or $rest.StartsWith('#')) { [void]$stack.Add(@{ Indent = $indent; Key = $key }); continue }
        if ($rest[0] -eq '"' -or $rest[0] -eq "'") {
            $quote = $rest[0]; $end = $rest.IndexOf($quote, 1)
            $value = if ($end -gt 0) { $rest.Substring(1, $end - 1) } else { $rest.Substring(1) }
        } else {
            $value = ($rest -split '#', 2)[0].Trim()
            if ($value -eq '{}' -or $value -eq '[]') { [void]$stack.Add(@{ Indent = $indent; Key = $key }); continue }
        }
        $values[$dotted] = $value
    }
    return $values
}
function Test-PentestSwarmConfig {
    # Read-only validation of config.yaml: loopback host, provider ollama, no API key, model set.
    param([string]$Path, [int]$ExpectedPort, [int]$ExpectedOllamaPort)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "pentestswarm config not found: $Path. Write it as described in docs/mcp/host-deviations.md (provider ollama, server.host 127.0.0.1)." }
    $config = ConvertFrom-SimpleYaml -Text ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
    $hostValue = if ($config.ContainsKey('server.host')) { $config['server.host'] } else { '<missing>' }
    if ($hostValue -ne '127.0.0.1') { throw "pentestswarm config server.host is '$hostValue', expected 127.0.0.1: $Path" }
    $portValue = if ($config.ContainsKey('server.port')) { $config['server.port'] } else { '<missing>' }
    if ($portValue -ne "$ExpectedPort") { throw "pentestswarm config server.port is '$portValue', expected $ExpectedPort`: $Path" }
    $provider = if ($config.ContainsKey('orchestrator.provider')) { $config['orchestrator.provider'] } else { '<missing>' }
    if ($provider -ne 'ollama' -and $provider -ne 'openai') { throw "pentestswarm config orchestrator.provider is '$provider', expected one of ollama, openai: $Path" }
    if ($config.ContainsKey('orchestrator.api_key') -and $config['orchestrator.api_key']) { throw "pentestswarm config orchestrator.api_key is set; keys never live in the file (use the PENTESTSWARM_ORCHESTRATOR_API_KEY User environment variable): $Path" }
    if (-not $config.ContainsKey('orchestrator.model') -or -not $config['orchestrator.model']) { throw "pentestswarm config orchestrator.model is empty: $Path" }
    $endpoint = if ($config.ContainsKey('orchestrator.endpoint')) { $config['orchestrator.endpoint'] } else { '' }
    if ($provider -eq 'ollama') {
        $endpointMatch = [regex]::Match($endpoint, '^http://(127\.0\.0\.1|localhost)(?::(\d+))?/?$')
        $expectedOllama = if ($ExpectedOllamaPort -gt 0) { $ExpectedOllamaPort } else { 11434 }
        if (-not $endpointMatch.Success) { throw "pentestswarm config orchestrator.endpoint is '$(if ($endpoint) { $endpoint } else { '<missing>' })', expected http://127.0.0.1:$expectedOllama`: $Path" }
        $endpointPort = if ($endpointMatch.Groups[2].Value) { [int]$endpointMatch.Groups[2].Value } else { 80 }
        if ($ExpectedOllamaPort -gt 0 -and $endpointPort -ne $ExpectedOllamaPort) { throw "pentestswarm config orchestrator.endpoint uses port $endpointPort, expected $ExpectedOllamaPort`: $Path" }
    } else {
        # openai: an OpenAI-compatible relay over TLS (or a loopback relay); the key is environment-only.
        if (-not [regex]::IsMatch($endpoint, '^(https://[^/\s]+|http://(127\.0\.0\.1|localhost)(?::\d+)?)(/\S*)?$')) { throw "pentestswarm config orchestrator.endpoint is '$(if ($endpoint) { $endpoint } else { '<missing>' })', expected an https:// (or loopback http://) OpenAI-compatible base URL: $Path" }
        if ([string]::IsNullOrWhiteSpace((Get-OrchestratorApiKey))) { throw 'PENTESTSWARM_ORCHESTRATOR_API_KEY is not set in the process or User environment; the openai provider cannot authenticate. The value is never read from a file or argument.' }
    }
    return $config
}
function Get-OrchestratorApiKey {
    # The owner's relay credential: process scope first, else the persisted User value. Never printed.
    $value = [string]$env:PENTESTSWARM_ORCHESTRATOR_API_KEY
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [string][Environment]::GetEnvironmentVariable('PENTESTSWARM_ORCHESTRATOR_API_KEY', 'User') }
    return $value
}
function Test-LoopbackPort {
    param([int]$ProbePort)
    $client = [Net.Sockets.TcpClient]::new()
    try { $task = $client.ConnectAsync('127.0.0.1', $ProbePort); return ($task.Wait(400) -and $client.Connected) }
    catch { return $false }
    finally { $client.Dispose() }
}
function Get-OllamaHealth {
    # GET /api/tags must answer with a models list; reports whether $Model is pulled.
    param([int]$ProbePort, [string]$Model)
    $reply = Invoke-LoopbackJson -Uri "http://127.0.0.1:$ProbePort/api/tags"
    if (-not ($reply.PSObject.Properties.Name -contains 'models')) { throw "GET /api/tags on port $ProbePort returned no Ollama models list." }
    $names = @($reply.models | ForEach-Object { [string]$_.name })
    return @{ models = $names.Count; model = $Model; model_present = [bool](($names -contains $Model) -or ($names -contains "$Model`:latest")) }
}
function Invoke-WithScrubbedProviderEnv {
    # Start-Process inherits this process's environment, so provider/API-key variables are removed
    # around every pentestswarm-related spawn (no paid provider, ever) and the database password is
    # handed only to `pentestswarm serve`. Mirrors child_environment() in pentestswarm-stdio.py.
    param([scriptblock]$Body, [switch]$KeepDatabasePassword, [switch]$KeepOrchestratorApiKey)
    $saved = @{}
    foreach ($entry in (Get-ChildItem Env:)) {
        $upper = $entry.Name.ToUpperInvariant()
        $scrub = ($upper -eq 'ANTHROPIC_API_KEY') -or $upper.StartsWith('PENTESTSWARM_ORCHESTRATOR_') -or $upper.StartsWith('PENTESTSWARM_AGENTS_') -or ((-not $KeepDatabasePassword) -and $upper -eq 'PENTESTSWARM_DATABASE_PASSWORD')
        if ($scrub) { $saved[$entry.Name] = $entry.Value; [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process') }
    }
    $savedApiKey = $null
    if ($KeepOrchestratorApiKey) {
        # Hand the relay credential (process, else User scope) to this child only; the saved copy restores the original state.
        $savedApiKey = $env:PENTESTSWARM_ORCHESTRATOR_API_KEY
        [Environment]::SetEnvironmentVariable('PENTESTSWARM_ORCHESTRATOR_API_KEY', (Get-OrchestratorApiKey), 'Process')
    }
    try { return (& $Body) }
    finally {
        if ($KeepOrchestratorApiKey) { [Environment]::SetEnvironmentVariable('PENTESTSWARM_ORCHESTRATOR_API_KEY', $savedApiKey, 'Process') }
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}
function Ensure-RedisListener {
    # Warning only: pentestswarm v0.1.0 never opens Redis; `pentestswarm doctor` merely dials the port.
    param([int]$ProbePort)
    if ($ProbePort -eq 0) { return 'skipped' }
    if (Test-LoopbackPort -ProbePort $ProbePort) { return 'listening' }
    $service = Get-Service -Name 'Memurai' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Running') {
        try {
            Start-Service -Name 'Memurai' -ErrorAction Stop
            for ($i = 0; $i -lt 25; $i++) { if (Test-LoopbackPort -ProbePort $ProbePort) { Write-LauncherWarning "started the Memurai service on 127.0.0.1:$ProbePort"; return 'started' }; Start-Sleep -Milliseconds 200 }
        } catch { Write-LauncherWarning "could not start the Memurai service: $($_.Exception.Message)" }
    }
    Write-LauncherWarning "no Redis-compatible listener on 127.0.0.1:$ProbePort; pentestswarm doctor will flag it (v0.1.0 does not use Redis at runtime)"
    return 'down'
}
function Ensure-OllamaListener {
    # Reuse a healthy Ollama; start `ollama serve` detached on loopback when the port is closed.
    param([int]$ProbePort, [string]$Model, [string]$Preferred, [string]$LogDirectory, [string]$Stamp, [int]$Wait)
    if ($ProbePort -eq 0) { return @{ state = 'skipped' } }
    if (Test-LoopbackPort -ProbePort $ProbePort) {
        try { $health = Get-OllamaHealth -ProbePort $ProbePort -Model $Model }
        catch { throw "Port $ProbePort is occupied but Ollama is unavailable ($($_.Exception.Message)); existing processes were preserved." }
        if (-not $health.model_present) { Write-LauncherWarning "model '$Model' is not pulled; swarm tool calls will fail until 'ollama pull $Model' runs" }
        return @{ state = 'reused' } + $health
    }
    $ollama = $Preferred
    if ([string]::IsNullOrWhiteSpace($ollama)) { $ollama = (Get-Command ollama -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if ([string]::IsNullOrWhiteSpace($ollama)) { $ollama = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe' }
    if (-not (Test-Path -LiteralPath $ollama -PathType Leaf)) { throw "ollama launcher not found: $ollama (pass -OllamaPath or install Ollama)." }
    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    $savedHost = $env:OLLAMA_HOST
    $env:OLLAMA_HOST = "127.0.0.1:$ProbePort"
    try {
        $process = Invoke-WithScrubbedProviderEnv -Body { Start-Process -FilePath $ollama -ArgumentList @('serve') -WorkingDirectory $LogDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $LogDirectory "Ollama-$Stamp.stdout.log") -RedirectStandardError (Join-Path $LogDirectory "Ollama-$Stamp.stderr.log") -PassThru }
    } finally { $env:OLLAMA_HOST = $savedHost }
    $null = $process.Handle
    @{backend='Ollama';pid=$process.Id;port=$ProbePort;executable=$ollama;started_at=(Get-Date -Format o)} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDirectory "Ollama-$Stamp.process.json") -Encoding utf8
    $deadline = (Get-Date).AddSeconds($Wait)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "ollama serve exited with code $($process.ExitCode) before readiness; inspect $LogDirectory." }
        if (Test-LoopbackPort -ProbePort $ProbePort) {
            try { $health = Get-OllamaHealth -ProbePort $ProbePort -Model $Model } catch { $health = $null }
            if ($health) {
                if (-not $health.model_present) { Write-LauncherWarning "model '$Model' is not pulled; swarm tool calls will fail until 'ollama pull $Model' runs" }
                return @{ state = 'started'; pid = $process.Id } + $health
            }
        }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    throw "ollama serve did not become ready on loopback port $ProbePort. PID $($process.Id) was preserved; inspect $LogDirectory."
}

$scriptClock = [Diagnostics.Stopwatch]::StartNew()
$startupMutex = [Threading.Mutex]::new($false, "Local\reverse-skill-$Backend-$Port")
$lockAcquired = $false
try {
    try { $lockAcquired = $startupMutex.WaitOne([TimeSpan]::FromSeconds([Math]::Min($WaitSeconds,30))) }
    catch [Threading.AbandonedMutexException] { $lockAcquired = $true }
    if (-not $lockAcquired) { throw "Another $Backend startup still owns port $Port; retry after it finishes." }

$dependencies = @{}
if ($Backend -eq 'PentestSwarm') {
    # Validate before anything is started or created; the stamp is shared by every log name.
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $env:USERPROFILE '.pentestswarm\config.yaml' }
    $swarmConfig = Test-PentestSwarmConfig -Path $ConfigPath -ExpectedPort $Port -ExpectedOllamaPort $OllamaPort
    if ([string]::IsNullOrWhiteSpace($Executable)) { $Executable = (Get-Command pentestswarm -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if ([string]::IsNullOrWhiteSpace($Executable)) { $Executable = Join-Path $env:USERPROFILE 'go\bin\pentestswarm.exe' }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "pentestswarm executable not found: $Executable (pass -Executable or go install it)." }
    $Executable = (Resolve-Path -LiteralPath $Executable).Path
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $dependencyStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $dependencies['redis'] = Ensure-RedisListener -ProbePort $RedisPort
    $dependencies['provider'] = $swarmConfig['orchestrator.provider']
    if ($swarmConfig['orchestrator.provider'] -eq 'ollama') {
        $dependencies['ollama'] = Ensure-OllamaListener -ProbePort $OllamaPort -Model $swarmConfig['orchestrator.model'] -Preferred $OllamaPath -LogDirectory $LogDir -Stamp $dependencyStamp -Wait $WaitSeconds
    } else {
        $dependencies['ollama'] = @{ state = 'not_required' }
    }
}
if (Test-BackendPort) {
    $health = Get-BackendHealth
    if (-not $health) {
        $detail = if ($script:lastHealthError) { " ($script:lastHealthError)" } else { '' }
        throw "Port $Port is occupied but the expected $Backend API is unavailable or busy$detail; existing processes were preserved."
    }
    $owner = Get-ListenerPid
    $result = @{backend=$Backend;pid=$owner;port=$Port;reused=$true;health=$health;elapsed_ms=$scriptClock.ElapsedMilliseconds}
    if ($Backend -eq 'PentestSwarm') {
        $result['dependencies'] = $dependencies; $result['bind_all_interfaces'] = $script:bindAllInterfaces
        if ($script:bindAllInterfaces) { Write-LauncherWarning "pentestswarm serve listens on all interfaces (upstream v0.1.0 ignores server.host); see docs/mcp/host-deviations.md" }
    }
    $result | ConvertTo-Json -Depth 4
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
} elseif ($Backend -eq 'PentestSwarm') {
    # `pentestswarm serve --config <path>`: the API server for doctor/campaign commands. The
    # database password reaches the child only through its environment (User scope fallback).
    $savedDbPassword = $env:PENTESTSWARM_DATABASE_PASSWORD
    if ([string]::IsNullOrWhiteSpace($savedDbPassword)) { $env:PENTESTSWARM_DATABASE_PASSWORD = [Environment]::GetEnvironmentVariable('PENTESTSWARM_DATABASE_PASSWORD', 'User') }
    try {
        $keepKey = ($swarmConfig['orchestrator.provider'] -eq 'openai')
        $process = Invoke-WithScrubbedProviderEnv -KeepDatabasePassword -KeepOrchestratorApiKey:$keepKey -Body { Start-Process -FilePath $Executable -ArgumentList @('serve', '--config', $ConfigPath, '--port', "$Port") -WorkingDirectory $LogDir -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru }
    } finally { $env:PENTESTSWARM_DATABASE_PASSWORD = $savedDbPassword }
    $record = @{backend=$Backend;pid=$process.Id;port=$Port;executable=$Executable;config_path=$ConfigPath;started_at=(Get-Date -Format o);sample_opened=$false}
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
        $result = @{backend=$Backend;pid=$owner;launcher_pid=$process.Id;port=$Port;reused=$false;health=$health;log_dir=$LogDir;elapsed_ms=$scriptClock.ElapsedMilliseconds}
        if ($Backend -eq 'PentestSwarm') {
            $result['dependencies'] = $dependencies; $result['bind_all_interfaces'] = $script:bindAllInterfaces
            if ($script:bindAllInterfaces) { Write-LauncherWarning "pentestswarm serve listens on all interfaces (upstream v0.1.0 ignores server.host); see docs/mcp/host-deviations.md" }
        }
        $result | ConvertTo-Json -Depth 4
        exit 0
    }
    Start-Sleep -Milliseconds 400
} while ((Get-Date) -lt $deadline)
throw "$Backend did not become ready on loopback port $Port. PID $($process.Id) was preserved; inspect $LogDir."
} finally {
    if ($lockAcquired) { $startupMutex.ReleaseMutex() }
    $startupMutex.Dispose()
}
