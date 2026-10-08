# Exercise start-local-backend.ps1 -Backend AnythingAnalyzer with a stub pnpm and an inert
# HTTP fixture: config validation, fresh start, reuse, wrong-owner refusal, early exit.
# The real app, its config and the real token are never touched; every port is random.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This test covers the Windows backend launcher.' }

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$launcherScript = Join-Path $repo 'skills\scripts\mcp\start-local-backend.ps1'
$hostExe = (Get-Process -Id $PID).Path
$python = (Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $python) { throw 'python is required for the HTTP fixture.' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('reverse-aa-launcher-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$fakeRepo = Join-Path $scratch 'anything-analyzer'
New-Item -ItemType Directory -Path $fakeRepo | Out-Null
Set-Content -LiteralPath (Join-Path $fakeRepo 'package.json') -Value '{"name":"anything-analyzer","scripts":{"dev":"electron-vite dev"}}' -Encoding ascii
$marker = Join-Path $scratch 'pnpm-invocations.txt'
$fixture = Join-Path $scratch 'fixture.py'
$stubDir = Join-Path $scratch 'stub'
New-Item -ItemType Directory -Path $stubDir | Out-Null
$stubPnpm = Join-Path $stubDir 'pnpm.cmd'
$testToken = 'test-token-' + [Guid]::NewGuid().ToString('N')
$nonce = [Guid]::NewGuid().ToString('N')

$fixtureSource = @'
import json, os, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
if os.environ.get('REVERSE_TEST_EARLY_EXIT') == '1':
    raise SystemExit(7)
port = int(os.environ['REVERSE_TEST_PORT'])
token = os.environ['REVERSE_TEST_TOKEN']
name = os.environ.get('REVERSE_TEST_SERVER_NAME', 'anything-analyzer')
nonce = os.environ['REVERSE_TEST_NONCE']
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def _authorized(self):
        if self.headers.get('Authorization') != 'Bearer ' + token:
            self._json(401, {'error': 'Unauthorized: invalid or missing token'}); return False
        return True
    def do_GET(self):
        if self.path == '/owner': self._json(200, {'fixture': nonce, 'pid': os.getpid(), 'name': name}); return
        if self.path == '/shutdown':
            self._json(200, {'ok': True}); threading.Thread(target=self.server.shutdown, daemon=True).start(); return
        self._json(404, {'error': 'Not Found'})
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if not self._authorized(): return
        if self.path != '/mcp': self._json(404, {'error': 'Not Found'}); return
        accept = self.headers.get('Accept', '')
        if 'application/json' not in accept or 'text/event-stream' not in accept:
            self._json(406, {'jsonrpc': '2.0', 'error': {'code': -32000, 'message': 'Not Acceptable'}, 'id': None}); return
        request = json.loads(raw)
        if request.get('method') != 'initialize': self._json(400, {'error': 'not an initialize request'}); return
        params = request.get('params', {})
        if not all(key in params for key in ('protocolVersion', 'capabilities', 'clientInfo')):
            self._json(400, {'error': 'initialize params incomplete'}); return
        result = {'jsonrpc': '2.0', 'id': request.get('id'), 'result': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'serverInfo': {'name': name, 'version': '1.0.0'}}}
        body = ('event: message\ndata: ' + json.dumps(result) + '\n\n').encode()
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('mcp-session-id', 'fixture-' + nonce); self.end_headers(); self.wfile.write(body)
    def do_DELETE(self):
        if not self._authorized(): return
        self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()
server = HTTPServer(('127.0.0.1', port), Handler); server.serve_forever(); server.server_close()
'@
[IO.File]::WriteAllText($fixture, ($fixtureSource -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
$stubSource = @"
@echo off
echo invoked %* >> "%REVERSE_TEST_MARKER%"
if not "%1"=="dev" exit /b 9
"$python" -I "$fixture"
"@
[IO.File]::WriteAllText($stubPnpm, $stubSource, [Text.ASCIIEncoding]::new())

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Get-FreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}
function Invoke-LoopbackGet {
    param([int]$Port, [string]$Path, [int]$TimeoutMs = 3000)
    $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Port$Path")
    $req.Proxy = $null; $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
    $resp = $req.GetResponse()
    try { $reader = [IO.StreamReader]::new($resp.GetResponseStream()); try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() } }
    finally { $resp.Dispose() }
}
function Write-AnalyzerConfig {
    param([string]$Path, [hashtable]$Overrides = @{}, [switch]$WithBom, [string]$RawText)
    $payload = [ordered]@{ enabled = $true; host = '127.0.0.1'; port = 0; authEnabled = $true; authToken = $testToken }
    foreach ($key in $Overrides.Keys) { if ($null -eq $Overrides[$key]) { $payload.Remove($key) } else { $payload[$key] = $Overrides[$key] } }
    $text = if ($PSBoundParameters.ContainsKey('RawText')) { $RawText } else { $payload | ConvertTo-Json }
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new([bool]$WithBom))
}
function Invoke-Launcher {
    # Child process with file redirection: a pipe would be inherited by the deliberately
    # persistent fixture and never reach EOF. -Wait is avoided for the same reason (it
    # waits for descendants); WaitForExit only waits for the launcher itself.
    param([int]$Port, [string]$ConfigPath, [string]$LogDir, [hashtable]$EnvOverrides = @{}, [string]$RepoDir = $fakeRepo, [string]$PnpmPath = $stubPnpm)
    $saved = @{}
    $allEnv = @{ REVERSE_TEST_PORT = "$Port"; REVERSE_TEST_TOKEN = $testToken; REVERSE_TEST_NONCE = $nonce; REVERSE_TEST_MARKER = $marker; REVERSE_TEST_SERVER_NAME = 'anything-analyzer'; REVERSE_TEST_EARLY_EXIT = '0'; ANYTHING_ANALYZER_MCP_TOKEN = $testToken }
    foreach ($key in $EnvOverrides.Keys) { $allEnv[$key] = $EnvOverrides[$key] }
    foreach ($key in $allEnv.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process'); [Environment]::SetEnvironmentVariable($key, $allEnv[$key], 'Process') }
    $token = [Guid]::NewGuid().ToString('N')
    $outPath = Join-Path $scratch "$token.stdout"; $errPath = Join-Path $scratch "$token.stderr"
    try {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcherScript, '-Backend', 'AnythingAnalyzer', '-RepoDir', $RepoDir, '-PnpmPath', $PnpmPath, '-ConfigPath', $ConfigPath, '-Port', "$Port", '-LogDir', $LogDir, '-WaitSeconds', '15')
        $process = Start-Process -FilePath $hostExe -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errPath -PassThru
        $null = $process.Handle   # Windows PowerShell 5.1 reports ExitCode only when the handle was cached before exit
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'launcher did not finish within 60 s' }
        $exitCode = $process.ExitCode
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }
    return @{ exit_code = $exitCode; stdout = (Get-Content -LiteralPath $outPath -Raw -ErrorAction SilentlyContinue); stderr = (Get-Content -LiteralPath $errPath -Raw -ErrorAction SilentlyContinue) }
}
function Start-DirectFixture {
    # A listener the launcher did not start: the "wrong owner" cases.
    param([int]$Port, [string]$Token, [string]$Name)
    $saved = @{}
    $vars = @{ REVERSE_TEST_PORT = "$Port"; REVERSE_TEST_TOKEN = $Token; REVERSE_TEST_NONCE = $nonce; REVERSE_TEST_SERVER_NAME = $Name; REVERSE_TEST_EARLY_EXIT = '0' }
    foreach ($key in $vars.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process'); [Environment]::SetEnvironmentVariable($key, $vars[$key], 'Process') }
    try { $process = Start-Process -FilePath $python -ArgumentList @('-I', $fixture) -WindowStyle Hidden -PassThru }
    finally { foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') } }
    $deadline = (Get-Date).AddSeconds(10)
    do { try { $owner = Invoke-LoopbackGet -Port $Port -Path '/owner'; if ($owner.fixture -eq $nonce) { return $process } } catch { }; Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt $deadline)
    throw "direct fixture did not come up on $Port"
}
function Stop-FixtureOnPort {
    param([int]$Port)
    try { $owner = Invoke-LoopbackGet -Port $Port -Path '/owner' -TimeoutMs 1500; if ($owner.fixture -eq $nonce) { Invoke-LoopbackGet -Port $Port -Path '/shutdown' -TimeoutMs 1500 | Out-Null } } catch { }
}
function Get-MarkerLineCount { if (Test-Path -LiteralPath $marker) { return @(Get-Content -LiteralPath $marker).Count } else { return 0 } }
function Assert-Refused {
    param([hashtable]$Result, [string]$Needle, [string]$Case)
    Assert-True ($Result.exit_code -ne 0) "$Case`: launcher exit code was 0"
    Assert-True ([string]$Result.stderr -match [regex]::Escape($Needle)) "$Case`: expected '$Needle' in stderr, got: $($Result.stderr)"
}

$fixturePorts = New-Object System.Collections.Generic.List[int]
$checks = 0
try {
    $configPath = Join-Path $scratch 'mcp-server-config.json'
    $port = Get-FreePort
    $logDir = Join-Path $scratch 'logs-validation'

    # --- 1. config validation: each failure is precise and never invokes pnpm ---
    $validationCases = @(
        @{ name = 'missing config'; setup = { Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }; needle = 'config not found' },
        @{ name = 'BOM'; setup = { Write-AnalyzerConfig -Path $configPath -Overrides @{ port = $port } -WithBom }; needle = 'UTF-8 BOM' },
        @{ name = 'invalid JSON'; setup = { Write-AnalyzerConfig -Path $configPath -RawText '{"enabled":true,' }; needle = 'not valid JSON' },
        @{ name = 'enabled=false'; setup = { Write-AnalyzerConfig -Path $configPath -Overrides @{ port = $port; enabled = $false } }; needle = 'enabled != true' },
        @{ name = 'host missing'; setup = { Write-AnalyzerConfig -Path $configPath -Overrides @{ port = $port; host = $null } }; needle = "host is '<missing>'" },
        @{ name = 'host 0.0.0.0'; setup = { Write-AnalyzerConfig -Path $configPath -Overrides @{ port = $port; host = '0.0.0.0' } }; needle = 'expected 127.0.0.1' },
        @{ name = 'port mismatch'; setup = { Write-AnalyzerConfig -Path $configPath -Overrides @{ port = ($port + 1) } }; needle = "expected $port" },
        @{ name = 'authEnabled=false'; setup = { Write-AnalyzerConfig -Path $configPath -Overrides @{ port = $port; authEnabled = $false } }; needle = 'authEnabled=true' },
        @{ name = 'empty token'; setup = { Write-AnalyzerConfig -Path $configPath -Overrides @{ port = $port; authToken = '' } }; needle = 'non-empty authToken' },
        @{ name = 'token mismatch'; setup = { Write-AnalyzerConfig -Path $configPath -Overrides @{ port = $port; authToken = 'another-token' } }; needle = 'differs from ANYTHING_ANALYZER_MCP_TOKEN' }
    )
    foreach ($case in $validationCases) {
        & $case.setup
        $result = Invoke-Launcher -Port $port -ConfigPath $configPath -LogDir $logDir
        Assert-Refused -Result $result -Needle $case.needle -Case $case.name
        Assert-True ((Get-MarkerLineCount) -eq 0) "$($case.name): pnpm was invoked although the config was rejected"
        Assert-True (-not (Test-Path -LiteralPath $logDir)) "$($case.name): LogDir was created before validation passed"
        $checks++
    }
    $bytes = [IO.File]::ReadAllBytes($configPath)
    Assert-True (([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json).authToken -eq 'another-token') 'validation rewrote the user config'
    Write-AnalyzerConfig -Path $configPath -Overrides @{ port = $port }
    $result = Invoke-Launcher -Port $port -ConfigPath $configPath -LogDir $logDir -RepoDir (Join-Path $scratch 'no-checkout')
    Assert-Refused -Result $result -Needle 'no package.json' -Case 'missing checkout'
    Assert-True ((Get-MarkerLineCount) -eq 0) 'missing checkout: pnpm was invoked'
    $checks++

    # --- 2. fresh start through the stub pnpm ---
    $startLogDir = Join-Path $scratch 'logs-start'
    $fixturePorts.Add($port)
    $started = Invoke-Launcher -Port $port -ConfigPath $configPath -LogDir $startLogDir
    Assert-True ($started.exit_code -eq 0) "fresh start failed: $($started.stderr)"
    $startedJson = $started.stdout | ConvertFrom-Json
    $owner = Invoke-LoopbackGet -Port $port -Path '/owner'
    Assert-True ($owner.fixture -eq $nonce) 'fresh start: listener is not our fixture'
    Assert-True ($startedJson.backend -eq 'AnythingAnalyzer' -and $startedJson.reused -eq $false) "fresh start: unexpected JSON $($started.stdout)"
    Assert-True ([int]$startedJson.pid -eq [int]$owner.pid) "fresh start: reported pid $($startedJson.pid) is not the listener pid $($owner.pid)"
    Assert-True ($startedJson.health.server_name -eq 'anything-analyzer' -and $startedJson.health.protocol_version -eq '2025-03-26') 'fresh start: health lacks serverInfo'
    Assert-True ($startedJson.port -eq $port -and $startedJson.launcher_pid -gt 0) 'fresh start: port/launcher_pid missing'
    Assert-True ((Get-MarkerLineCount) -eq 1 -and ((Get-Content -LiteralPath $marker) -match '^invoked dev')) 'fresh start: stub pnpm was not invoked with dev'
    $records = @(Get-ChildItem -LiteralPath $startLogDir -Filter 'AnythingAnalyzer-*.process.json')
    Assert-True ($records.Count -eq 1) "fresh start: expected one process record, found $($records.Count)"
    $record = Get-Content -LiteralPath $records[0].FullName -Raw | ConvertFrom-Json
    Assert-True ($record.backend -eq 'AnythingAnalyzer' -and [int]$record.pid -eq [int]$startedJson.launcher_pid -and $record.port -eq $port) 'process record: backend/pid/port'
    Assert-True ($record.repo_dir -eq $fakeRepo -and $record.executable -eq $stubPnpm -and $record.config_path -eq $configPath -and $record.sample_opened -eq $false) 'process record: repo_dir/executable/config_path/sample_opened'
    Assert-True ((Get-Content -LiteralPath $records[0].FullName -Raw) -notmatch [regex]::Escape($testToken)) 'process record leaks the token'
    Assert-True (($started.stdout + $started.stderr) -notmatch [regex]::Escape($testToken)) 'launcher output leaks the token'
    Assert-True (@(Get-ChildItem -LiteralPath $startLogDir -Filter 'AnythingAnalyzer-*.stdout.log').Count -eq 1 -and @(Get-ChildItem -LiteralPath $startLogDir -Filter 'AnythingAnalyzer-*.stderr.log').Count -eq 1) 'fresh start: stdout/stderr logs missing'
    $checks++

    # --- 3. reuse of the healthy listener: no new process, no new record, config not re-read ---
    Remove-Item -LiteralPath $configPath -Force
    $reused = Invoke-Launcher -Port $port -ConfigPath $configPath -LogDir $startLogDir
    Assert-True ($reused.exit_code -eq 0) "reuse failed: $($reused.stderr)"
    $reusedJson = $reused.stdout | ConvertFrom-Json
    Assert-True ($reusedJson.reused -eq $true -and [int]$reusedJson.pid -eq [int]$owner.pid) "reuse: unexpected JSON $($reused.stdout)"
    Assert-True ((Get-MarkerLineCount) -eq 1) 'reuse: pnpm was invoked again'
    Assert-True (@(Get-ChildItem -LiteralPath $startLogDir -Filter '*.process.json').Count -eq 1) 'reuse: a second process record was written'
    Write-AnalyzerConfig -Path $configPath -Overrides @{ port = $port }
    $checks++

    # --- 4. wrong owner: a listener that is not anything-analyzer is refused and preserved ---
    $otherPort = Get-FreePort
    $fixturePorts.Add($otherPort)
    $otherProcess = Start-DirectFixture -Port $otherPort -Token $testToken -Name 'other-mcp-server'
    $otherConfig = Join-Path $scratch 'other-config.json'
    Write-AnalyzerConfig -Path $otherConfig -Overrides @{ port = $otherPort }
    $otherLogDir = Join-Path $scratch 'logs-other'
    $refused = Invoke-Launcher -Port $otherPort -ConfigPath $otherConfig -LogDir $otherLogDir
    Assert-Refused -Result $refused -Needle "serverInfo.name 'other-mcp-server'" -Case 'wrong owner'
    Assert-True ([string]$refused.stderr -match 'existing processes were preserved') 'wrong owner: preservation notice missing'
    Assert-True (-not $otherProcess.HasExited) 'wrong owner: the foreign listener was killed'
    Assert-True ((Invoke-LoopbackGet -Port $otherPort -Path '/owner').pid -eq $otherProcess.Id) 'wrong owner: foreign listener no longer answers'
    Assert-True (-not (Test-Path -LiteralPath $otherLogDir)) 'wrong owner: LogDir was created'
    Assert-True ((Get-MarkerLineCount) -eq 1) 'wrong owner: pnpm was invoked'
    $checks++

    # --- 5. wrong token on an occupied port: 401 is named, nothing is started ---
    $authPort = Get-FreePort
    $fixturePorts.Add($authPort)
    $authProcess = Start-DirectFixture -Port $authPort -Token 'a-token-the-launcher-does-not-have' -Name 'anything-analyzer'
    $authConfig = Join-Path $scratch 'auth-config.json'
    Write-AnalyzerConfig -Path $authConfig -Overrides @{ port = $authPort }
    $rejected = Invoke-Launcher -Port $authPort -ConfigPath $authConfig -LogDir (Join-Path $scratch 'logs-auth')
    Assert-Refused -Result $rejected -Needle 'HTTP 401 Unauthorized' -Case '401'
    Assert-True (-not $authProcess.HasExited) '401: the listener was killed'
    Assert-True ((Get-MarkerLineCount) -eq 1) '401: pnpm was invoked'
    $checks++

    # --- 6. launcher exits before readiness ---
    $earlyPort = Get-FreePort
    $earlyConfig = Join-Path $scratch 'early-config.json'
    Write-AnalyzerConfig -Path $earlyConfig -Overrides @{ port = $earlyPort }
    $early = Invoke-Launcher -Port $earlyPort -ConfigPath $earlyConfig -LogDir (Join-Path $scratch 'logs-early') -EnvOverrides @{ REVERSE_TEST_EARLY_EXIT = '1' }
    Assert-Refused -Result $early -Needle 'exited with code' -Case 'early exit'
    Assert-True ((Get-MarkerLineCount) -eq 2) 'early exit: pnpm was not invoked'
    $checks++

    Write-Host "PowerShell Anything Analyzer launcher regression passed ($checks groups, host $hostExe)"
}
finally {
    foreach ($fixturePort in $fixturePorts) { Stop-FixtureOnPort -Port $fixturePort }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
