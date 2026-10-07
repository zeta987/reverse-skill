#requires -Version 5

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootstrap = Join-Path $scriptDir 'bootstrap-reverse.ps1'
$toolDiscovery = Join-Path $scriptDir 'lib\ToolDiscovery.ps1'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('reverse-client-neutral-' + [guid]::NewGuid().ToString('n'))
$binDir = Join-Path $scratch 'bin'
$clientDir = Join-Path $scratch 'client'
$claudeConfig = Join-Path $clientDir 'claude.json'
$claudeSettings = Join-Path $clientDir 'settings.local.json'
$codexConfig = Join-Path $clientDir 'codex.toml'
$antigravityConfig = Join-Path $clientDir 'mcp_config.json'

New-Item -ItemType Directory -Force -Path $binDir, $clientDir | Out-Null
try {
    foreach ($name in @('node', 'npm', 'npx')) {
        $cmdPath = Join-Path $binDir ($name + '.cmd')
        @('@echo off', 'if "%1"=="--version" echo 1.0.0', 'exit /b 0') | Set-Content -LiteralPath $cmdPath -Encoding ascii
    }

    $oldPath = $env:PATH
    $oldClaudeConfig = $env:CLAUDE_MCP_CONFIG
    $oldClaudeSettings = $env:CLAUDE_SETTINGS_LOCAL
    $oldCodexConfig = $env:CODEX_CONFIG_PATH
    $oldAntigravityConfig = $env:ANTIGRAVITY_MCP_CONFIG
    $env:PATH = "$binDir;$oldPath"
    $env:CLAUDE_MCP_CONFIG = $claudeConfig
    $env:CLAUDE_SETTINGS_LOCAL = $claudeSettings
    $env:CODEX_CONFIG_PATH = $codexConfig
    $env:ANTIGRAVITY_MCP_CONFIG = $antigravityConfig

    $defaultOutput = (& $bootstrap -Capability jshookmcp -SkipRefresh | Out-String)
    if (Test-Path -LiteralPath $claudeConfig) { throw 'default bootstrap wrote Claude global config' }
    if (Test-Path -LiteralPath $codexConfig) { throw 'default bootstrap wrote Codex global config' }
    if (Test-Path -LiteralPath $antigravityConfig) { throw 'default bootstrap wrote Antigravity config' }
    if ($defaultOutput -notmatch 'configured-not-ready') { throw 'default MCP bootstrap did not report configured-not-ready' }

    $codexOutput = (& $bootstrap -Capability jshookmcp -SkipRefresh -McpHostTarget Codex | Out-String)
    if (Test-Path -LiteralPath $claudeConfig) { throw 'Codex-only bootstrap wrote Claude config' }
    if (-not (Test-Path -LiteralPath $codexConfig)) { throw 'Codex-only bootstrap did not write Codex config' }
    if ((Get-Content -LiteralPath $codexConfig -Raw) -notmatch '(?m)^\[mcp_servers\.jshook\]\r?$') { throw 'Codex config missing jshook MCP block' }
    if ($codexOutput -notmatch '"status"\s*:\s*"ready"') { throw 'Codex-only bootstrap did not report ready' }

    . $toolDiscovery
    $tool = Resolve-ReverseToolSpec -Name 'jshookmcp'
    if ($tool.Available) { throw 'npx must not masquerade as jshookmcp tool availability' }
    $state = Get-ReverseCapabilityState -Name 'jshookmcp'
    if (-not $state.Registered) { throw 'Codex-only registration was not discovered' }
    if (-not $state.RuntimeAvailable) { throw 'npx runtime was not detected' }
    if (-not $state.Ready) { throw 'Codex registration plus npx runtime should be ready' }

    Remove-Item -LiteralPath $codexConfig -Force
    $claudeOutput = (& $bootstrap -Capability jshookmcp -SkipRefresh -McpHostTarget Claude | Out-String)
    if (-not (Test-Path -LiteralPath $claudeConfig)) { throw 'Claude-only bootstrap did not write Claude config' }
    if (Test-Path -LiteralPath $codexConfig) { throw 'Claude-only bootstrap wrote Codex config' }
    $json = Get-Content -LiteralPath $claudeConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $json.mcpServers.jshook) { throw 'Claude config missing jshook MCP server' }
    if ($json.mcpServers.jshook.type -ne 'stdio') { throw 'Claude stdio server is missing "type": "stdio"' }
    if ($claudeOutput -notmatch '"status"\s*:\s*"ready"') { throw 'Claude-only bootstrap did not report ready' }
    if (Test-Path -LiteralPath $antigravityConfig) { throw 'Claude-only bootstrap wrote Antigravity config' }
    $settings = Get-Content -LiteralPath $claudeSettings -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($settings.enabledMcpjsonServers) -notcontains 'jshook') { throw 'Claude settings.local.json did not approve the .mcp.json server' }

    # remote-http-mcp -> "type": "http" for Claude; All also writes Codex and Antigravity.
    $allOutput = (& $bootstrap -Capability xquik-mcp -SkipRefresh -McpHostTarget All | Out-String)
    if ($allOutput -notmatch '"status"\s*:\s*"ready"') { throw 'All-hosts bootstrap did not report ready' }
    $json = Get-Content -LiteralPath $claudeConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($json.mcpServers.xquik.type -ne 'http' -or $json.mcpServers.xquik.url -ne 'https://xquik.com/mcp') { throw 'Claude http server is missing "type": "http"' }
    if ($null -eq $json.mcpServers.jshook) { throw 'All-hosts bootstrap dropped the existing Claude jshook entry' }
    if ((Get-Content -LiteralPath $codexConfig -Raw) -notmatch '(?m)^\[mcp_servers\.xquik\]\r?$') { throw 'Codex config missing xquik MCP block' }
    if (-not (Test-Path -LiteralPath $antigravityConfig)) { throw 'All-hosts bootstrap did not write Antigravity config' }
    $antigravity = Get-Content -LiteralPath $antigravityConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($antigravity.mcpServers.xquik.serverUrl -ne 'https://xquik.com/mcp') { throw 'Antigravity remote server is missing serverUrl' }
    if ($antigravity.mcpServers.xquik.PSObject.Properties['type']) { throw 'Antigravity config must not carry a type field' }

    $antigravityOnly = (& $bootstrap -Capability jshookmcp -SkipRefresh -McpHostTarget Antigravity | Out-String)
    if ($antigravityOnly -notmatch '"status"\s*:\s*"ready"') { throw 'Antigravity-only bootstrap did not report ready' }
    $antigravity = Get-Content -LiteralPath $antigravityConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($antigravity.mcpServers.jshook.command -ne 'npx' -or $antigravity.mcpServers.jshook.args[0] -ne '-y') { throw 'Antigravity stdio server must launch npx directly (no cmd /c)' }
    if ($antigravity.mcpServers.jshook.env.JSHOOK_BASE_PROFILE -ne 'search') { throw 'Antigravity stdio server lost its env map' }
    $state = Get-ReverseCapabilityState -Name 'jshookmcp'
    if (-not $state.Registered) { throw 'Antigravity registration was not discovered' }

    Write-Host 'client-neutral PowerShell bootstrap/discovery regression passed'
}
finally {
    if ($null -ne $oldPath) { $env:PATH = $oldPath }
    $env:CLAUDE_MCP_CONFIG = $oldClaudeConfig
    $env:CLAUDE_SETTINGS_LOCAL = $oldClaudeSettings
    $env:CODEX_CONFIG_PATH = $oldCodexConfig
    $env:ANTIGRAVITY_MCP_CONFIG = $oldAntigravityConfig
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
