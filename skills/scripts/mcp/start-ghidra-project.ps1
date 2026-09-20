# Open an existing, authorized Ghidra project and verify its GhydraMCP instance.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GhidraRun,
    [Parameter(Mandatory)][string]$ProjectPath,
    [string]$ProgramPath = '',
    [ValidateRange(8192,65535)][int]$Port = 8192,
    [ValidateRange(1,120)][int]$WaitSeconds = 60
)
$ErrorActionPreference = 'Stop'
foreach ($path in @($GhidraRun,$ProjectPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "File not found: $path" }
}
$GhidraRun = (Resolve-Path -LiteralPath $GhidraRun).Path
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if ([IO.Path]::GetExtension($ProjectPath) -ne '.gpr') { throw 'ProjectPath must be an existing .gpr project.' }
$expectedProject = [IO.Path]::GetFileNameWithoutExtension($ProjectPath)
$expectedRepository = [IO.Path]::ChangeExtension($ProjectPath, '.rep')
$baseUrl = "http://127.0.0.1:$Port"
function Get-LocalListeners {
    return @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object Port -EQ $Port)
}
function Get-ProjectState {
    try { return Invoke-RestMethod "$baseUrl/project" -TimeoutSec 2 }
    catch { return $null }
}
function Get-ProgramState {
    try { return Invoke-RestMethod "$baseUrl/program" -TimeoutSec 5 }
    catch { return $null }
}
function Assert-ProjectIdentity($State) {
    if (-not $State.result.projectPath -or $State.result.name -ne $expectedProject -or
        [IO.Path]::GetFullPath([string]$State.result.projectPath) -ne $expectedRepository) {
        throw 'The selected instance does not match the requested project path; no program was opened.'
    }
}
$startupMutex = [Threading.Mutex]::new($false, "Local\reverse-skill-Ghidra-$Port")
$lockAcquired = $false
try {
    try { $lockAcquired = $startupMutex.WaitOne([TimeSpan]::FromSeconds([Math]::Min($WaitSeconds,30))) }
    catch [Threading.AbandonedMutexException] { $lockAcquired = $true }
    if (-not $lockAcquired) { throw 'Another Ghidra startup is in progress on the selected port.' }
$state = Get-ProjectState
$reused = $false
if ($state) {
    Assert-ProjectIdentity $state
    $reused = $true
} elseif (@(Get-LocalListeners).Count -gt 0) {
    throw "Port $Port is occupied but the expected project API is unavailable; existing processes were preserved."
} else {
    $launcher = Start-Process -FilePath $GhidraRun -ArgumentList ('"' + $ProjectPath + '"') -WorkingDirectory (Split-Path $GhidraRun -Parent) -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $state = Get-ProjectState
        if ($state) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    if (-not $state) { throw "GhydraMCP did not become ready on expected port $Port. Launcher PID $($launcher.Id) was preserved; inspect Ghidra logs and instance discovery." }
    Assert-ProjectIdentity $state
}
$listeners = @(Get-LocalListeners)
if ($listeners.Count -eq 0 -or @($listeners | Where-Object { -not [Net.IPAddress]::IsLoopback($_.Address) }).Count -gt 0) {
    throw 'The GhydraMCP listener is not verified as loopback-only. Inspect the plugin binding before using it.'
}
$info = Invoke-RestMethod "$baseUrl/info" -TimeoutSec 5
if ($ProgramPath) {
    if (-not $ProgramPath.StartsWith('/')) { throw 'ProgramPath must be an absolute path inside the Ghidra project, such as /sample.exe.' }
    $expectedProgramId = $expectedProject + ':' + $ProgramPath
    $program = Get-ProgramState
    if ($program.result.programId -ne $expectedProgramId) {
        $reply = Invoke-RestMethod "$baseUrl/project/open" -Method Post -ContentType 'application/json' -Body (@{path=$ProgramPath} | ConvertTo-Json -Compress) -TimeoutSec 30
        if (-not $reply.success) { throw 'GhydraMCP rejected the project program open request.' }
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        do {
            $program = Get-ProgramState
            if ($program.result.programId -eq $expectedProgramId) { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)
        if ($program.result.programId -ne $expectedProgramId) { throw 'Requested program was not confirmed; inspect discovered instances before proceeding.' }
    }
    $info = Invoke-RestMethod "$baseUrl/info" -TimeoutSec 5
}
@{project=$expectedProject;project_path=$ProjectPath;program=$info.result.file;port=$Port;reused=$reused;listeners=@($listeners | ForEach-Object ToString);sample_executed=$false} | ConvertTo-Json -Depth 4
} finally {
    if ($lockAcquired) { $startupMutex.ReleaseMutex() }
    $startupMutex.Dispose()
}
