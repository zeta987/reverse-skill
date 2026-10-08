#Requires -Version 5.1
<#
.SYNOPSIS
Regression tests for the MCP client writers, archive extraction, VS detection and the
IDA start.ps1 backend-module detection.

Loads bootstrap-reverse.ps1 functions through the AST (no installation code runs) and
points every client config path at a scratch directory, so the repository's own
gitignored .mcp.json / .codex/config.toml / .agents/mcp_config.json are never touched.
#>
param(
    [string]$ScratchDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScratchDir)) {
    $ScratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ('reverse-skill-mcp-writers-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null

. (Join-Path $scriptDir 'lib\ToolDiscovery.ps1')

$bootstrapPath = Join-Path $scriptDir 'bootstrap-reverse.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($bootstrapPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw "bootstrap-reverse.ps1 parse failed: $($errors[0].Message)"
}
$functionNames = @(
    'Get-FirstCommandPath', 'Test-ReverseIsWindows', 'Get-McpScopeSetting', 'Get-McpHostTargets',
    'Get-VsWherePath', 'Test-VsBuildToolsInstalled', 'Expand-ArchiveIntoDirectory',
    'ConvertTo-TomlLiteral', 'Remove-CodexMcpServerBlocks', 'Set-CodexMcpServer',
    'Read-ReverseMcpJsonConfig', 'Save-ReverseMcpJsonConfig', 'Get-ClaudeMcpConfig', 'Save-ClaudeMcpConfig',
    'ConvertTo-ClaudeMcpServerDefinition', 'Enable-ClaudeMcpJsonServer', 'Register-ClaudeUserMcpServer',
    'ConvertTo-AntigravityMcpServerDefinition', 'Set-AntigravityMcpServer',
    'Ensure-McpServer', 'Get-McpCommandServerDefinition', 'Get-ManifestMcpServerDefinition',
    'Get-AnythingAnalyzerUserDataPaths', 'Ensure-AnythingAnalyzerMcpConfig',
    'Get-ReverseMcpBridgePython', 'Get-AnythingAnalyzerMcpServerDefinition'
)
foreach ($name in $functionNames) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if ($null -eq $functionAst) {
        throw "Function not found in bootstrap-reverse.ps1: $name"
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

# Script-level variables the extracted functions read.
$tmpBase = $ScratchDir
$McpHostTarget = 'None'
$McpScope = 'Project'

$passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
    $script:passed++
    Write-Host "[OK] $Message" -ForegroundColor Green
}

$oldEnv = @{}
foreach ($key in @('CLAUDE_MCP_CONFIG', 'CLAUDE_SETTINGS_LOCAL', 'CODEX_CONFIG_PATH', 'ANTIGRAVITY_MCP_CONFIG', 'REVERSE_VSWHERE', 'PYTHONPATH', 'REVERSE_IDA_START_FUNCTIONS_ONLY', 'APPDATA', 'REVERSE_MCP_BRIDGE_PYTHON')) {
    $oldEnv[$key] = [Environment]::GetEnvironmentVariable($key)
}

try {
    $clientDir = Join-Path $ScratchDir 'client'
    New-Item -ItemType Directory -Path $clientDir -Force | Out-Null
    $env:CLAUDE_MCP_CONFIG = Join-Path $clientDir '.mcp.json'
    $env:CLAUDE_SETTINGS_LOCAL = Join-Path $clientDir 'settings.local.json'
    $env:CODEX_CONFIG_PATH = Join-Path $clientDir 'config.toml'
    $env:ANTIGRAVITY_MCP_CONFIG = Join-Path $clientDir 'mcp_config.json'

    # --- 1. Claude writer: explicit transport type on every entry -------------------
    $McpHostTarget = 'All'
    $stdioDefinition = Get-McpCommandServerDefinition -Command 'npx' -Arguments @('-y', '@jshookmcp/jshook@0.3.4') -Env @{ JSHOOK_BASE_PROFILE = 'search' }
    Ensure-McpServer -ServerName 'jshook' -ServerDefinition $stdioDefinition
    Ensure-McpServer -ServerName 'xquik' -ServerDefinition @{ url = 'https://xquik.com/mcp' }
    # anything-analyzer registers as the stdio launcher (manifest mcpBridgeLauncher); the
    # bearer token must never appear in any client file.
    $fakeBridgePython = Join-Path $ScratchDir 'bridge\python.exe'
    New-Item -ItemType Directory -Path (Split-Path $fakeBridgePython) -Force | Out-Null
    Set-Content -LiteralPath $fakeBridgePython -Value 'fake' -Encoding ascii
    $env:REVERSE_MCP_BRIDGE_PYTHON = $fakeBridgePython
    $manifest = Get-Content -LiteralPath (Join-Path $scriptDir 'bootstrap-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $analyzerEntry = $manifest.capabilities | Where-Object { $_.name -eq 'anything-analyzer' } | Select-Object -First 1
    Assert-True ($null -ne $analyzerEntry -and $analyzerEntry.mcpBridgeLauncher -like '*anything-analyzer-stdio.py') 'manifest: anything-analyzer carries mcpBridgeLauncher'
    $analyzerDefinition = Get-AnythingAnalyzerMcpServerDefinition -Definition $analyzerEntry
    Assert-True ($analyzerDefinition.type -eq 'stdio' -and $analyzerDefinition.command -eq $fakeBridgePython) 'anything-analyzer: stdio definition uses REVERSE_MCP_BRIDGE_PYTHON'
    Assert-True (@($analyzerDefinition.args).Count -eq 1 -and (Test-Path -LiteralPath $analyzerDefinition.args[0]) -and $analyzerDefinition.args[0] -like '*skills\scripts\mcp\anything-analyzer-stdio.py') 'anything-analyzer: single arg is the existing launcher path'
    Assert-True (-not $analyzerDefinition.ContainsKey('url') -and -not $analyzerDefinition.ContainsKey('headers') -and -not $analyzerDefinition.ContainsKey('bearer_token_env_var')) 'anything-analyzer: no url/headers/bearer_token_env_var in the definition'
    Ensure-McpServer -ServerName 'anything-analyzer' -ServerDefinition $analyzerDefinition
    Ensure-McpServer -ServerName 'ida-pro-mcp' -ServerDefinition @{
        type    = 'stdio'
        command = 'C:\Python\python.exe'
        args    = @('C:\site-packages\ida_pro_mcp\server.py', '--ida-rpc', 'http://127.0.0.1:13337')
        env     = @{ PYTHONUTF8 = '1' }
        cwd     = 'C:\site-packages\ida_pro_mcp'
    }

    $claude = Get-Content -LiteralPath $env:CLAUDE_MCP_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($claude.mcpServers.jshook.type -eq 'stdio') 'Claude: command server carries "type": "stdio"'
    Assert-True ($claude.mcpServers.jshook.command -eq 'cmd' -and $claude.mcpServers.jshook.args[1] -eq 'npx') 'Claude: npx stays wrapped in cmd /c on Windows'
    Assert-True ($claude.mcpServers.xquik.type -eq 'http' -and $claude.mcpServers.xquik.url -eq 'https://xquik.com/mcp') 'Claude: url server carries "type": "http"'
    Assert-True ($claude.mcpServers.'anything-analyzer'.type -eq 'stdio' -and $claude.mcpServers.'anything-analyzer'.command -eq $fakeBridgePython) 'Claude: anything-analyzer is a stdio launcher entry'
    Assert-True ($claude.mcpServers.'anything-analyzer'.args[0] -like '*anything-analyzer-stdio.py' -and -not $claude.mcpServers.'anything-analyzer'.PSObject.Properties['url'] -and -not $claude.mcpServers.'anything-analyzer'.PSObject.Properties['headers']) 'Claude: anything-analyzer has the launcher arg and no url/headers'
    Assert-True ((Get-Content -LiteralPath $env:CLAUDE_MCP_CONFIG -Raw -Encoding UTF8) -notmatch 'Authorization|ANYTHING_ANALYZER_MCP_TOKEN|23816') 'Claude: no token, header or port leaks into .mcp.json'
    Assert-True ($claude.mcpServers.'ida-pro-mcp'.type -eq 'stdio' -and -not $claude.mcpServers.'ida-pro-mcp'.PSObject.Properties['cwd']) 'Claude: explicit stdio kept, cwd dropped'
    Assert-True ($claude.mcpServers.'ida-pro-mcp'.env.PYTHONUTF8 -eq '1') 'Claude: env map preserved'

    $settings = Get-Content -LiteralPath $env:CLAUDE_SETTINGS_LOCAL -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($settings.enabledMcpjsonServers) -contains 'jshook' -and @($settings.enabledMcpjsonServers) -contains 'xquik') 'Claude: settings.local.json enabledMcpjsonServers lists the servers'
    # Re-registering must not duplicate the approval entry, and unrelated settings survive a
    # real rewrite (registering a NEW server), including one-element arrays.
    $settingsMap = Read-ReverseJsonAsHashtable -Path $env:CLAUDE_SETTINGS_LOCAL
    $settingsMap['permissions'] = @{ allow = @('Bash(git status)'); deny = @() }
    ($settingsMap | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $env:CLAUDE_SETTINGS_LOCAL -Encoding utf8
    Ensure-McpServer -ServerName 'jshook' -ServerDefinition $stdioDefinition
    Ensure-McpServer -ServerName 'math-mcp' -ServerDefinition @{ command = 'C:\Program Files\nodejs\node.exe'; args = @('D:\WIN_MCP\math-mcp\build\index.js') }
    $settingsText = Get-Content -LiteralPath $env:CLAUDE_SETTINGS_LOCAL -Raw -Encoding UTF8
    $settings = $settingsText | ConvertFrom-Json
    Assert-True (@(@($settings.enabledMcpjsonServers) | Where-Object { $_ -eq 'jshook' }).Count -eq 1) 'Claude: enabledMcpjsonServers is idempotent'
    Assert-True (@($settings.enabledMcpjsonServers) -contains 'math-mcp') 'Claude: newly registered server is approved'
    Assert-True ($settings.permissions.allow[0] -eq 'Bash(git status)' -and $settingsText -match '"allow":\s*\[') 'Claude: one-element permissions.allow stays an array after rewrite'
    Assert-True ($settingsText -match '"deny":\s*\[\s*\]') 'Claude: empty permissions.deny stays an empty array after rewrite'

    # The verified host .mcp.json has a one-element args (math-mcp) and an empty args (r2mcp);
    # both must survive a read-modify-write of an unrelated server.
    $claudeText = Get-Content -LiteralPath $env:CLAUDE_MCP_CONFIG -Raw -Encoding UTF8
    Assert-True ($claudeText -match '"args":\s*\[\s*"D:\\\\WIN_MCP\\\\math-mcp\\\\build\\\\index\.js"\s*\]') 'Claude: one-element args is written as an array'
    Ensure-McpServer -ServerName 'r2mcp' -ServerDefinition @{ command = 'D:\tools\r2mcp.exe'; args = @() }
    Ensure-McpServer -ServerName 'probe' -ServerDefinition @{ url = 'http://127.0.0.1:1/mcp' }
    $claude = Get-Content -LiteralPath $env:CLAUDE_MCP_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
    $claudeText = Get-Content -LiteralPath $env:CLAUDE_MCP_CONFIG -Raw -Encoding UTF8
    Assert-True ($claude.mcpServers.'math-mcp'.args -is [array] -and @($claude.mcpServers.'math-mcp'.args).Count -eq 1) 'Claude: one-element args survives a later rewrite as an array'
    Assert-True ($claudeText -match '"r2mcp":\s*\{[^}]*"args":\s*\[\s*\]') 'Claude: empty args survives a later rewrite as []'
    $roundTrip = Read-ReverseJsonAsHashtable -Path $env:CLAUDE_MCP_CONFIG
    Assert-True ($roundTrip['mcpServers']['r2mcp']['args'] -is [array] -and @($roundTrip['mcpServers']['r2mcp']['args']).Count -eq 0) 'ToolDiscovery: Read-ReverseJsonAsHashtable keeps empty arrays'
    Assert-True ($roundTrip['mcpServers']['math-mcp']['args'] -is [array]) 'ToolDiscovery: Read-ReverseJsonAsHashtable keeps one-element arrays'
    $antigravityText = Get-Content -LiteralPath $env:ANTIGRAVITY_MCP_CONFIG -Raw -Encoding UTF8
    Assert-True ($antigravityText -match '"r2mcp":\s*\{[^}]*"args":\s*\[\s*\]') 'Antigravity: empty args survives rewrite as []'

    # --- 2. Antigravity writer: command/args/env or serverUrl, no type, no cwd ---------
    $antigravity = Get-Content -LiteralPath $env:ANTIGRAVITY_MCP_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($antigravity.mcpServers.jshook.command -eq 'npx' -and $antigravity.mcpServers.jshook.args[0] -eq '-y') 'Antigravity: cmd /c wrapper unwrapped to npx'
    Assert-True (-not $antigravity.mcpServers.jshook.PSObject.Properties['type']) 'Antigravity: no "type" field'
    Assert-True ($antigravity.mcpServers.jshook.env.JSHOOK_BASE_PROFILE -eq 'search') 'Antigravity: env preserved'
    Assert-True ($antigravity.mcpServers.xquik.serverUrl -eq 'https://xquik.com/mcp' -and -not $antigravity.mcpServers.xquik.PSObject.Properties['url']) 'Antigravity: url becomes serverUrl'
    Assert-True (-not $antigravity.mcpServers.'ida-pro-mcp'.PSObject.Properties['cwd']) 'Antigravity: cwd dropped'
    Assert-True ($antigravity.mcpServers.'anything-analyzer'.command -eq $fakeBridgePython -and $antigravity.mcpServers.'anything-analyzer'.args[0] -like '*anything-analyzer-stdio.py' -and -not $antigravity.mcpServers.'anything-analyzer'.PSObject.Properties['serverUrl']) 'Antigravity: anything-analyzer is command/args, no serverUrl'
    Assert-True ((Get-Content -LiteralPath $env:ANTIGRAVITY_MCP_CONFIG -Raw -Encoding UTF8) -notmatch 'Authorization|ANYTHING_ANALYZER_MCP_TOKEN|23816') 'Antigravity: no token, header or port leaks into mcp_config.json'

    # --- 3. Codex writer and quoted-table parsing --------------------------------------
    $codexText = Get-Content -LiteralPath $env:CODEX_CONFIG_PATH -Raw -Encoding UTF8
    Assert-True ($codexText -match '(?m)^\[mcp_servers\.jshook\]\r?$') 'Codex: bare table header for a simple name'
    Assert-True ($codexText -match '(?m)^\[mcp_servers\.ida-pro-mcp\]\r?$') 'Codex: hyphenated name stays a bare key'
    Assert-True ($codexText -notmatch '(?m)^type\s*=') 'Codex: no "type" key is written'
    Assert-True ($codexText -match '(?m)^\[mcp_servers\.anything-analyzer\]\r?$' -and $codexText -notmatch 'bearer_token_env_var|ANYTHING_ANALYZER_MCP_TOKEN|23816') 'Codex: anything-analyzer is a command table without token, env var name or url'
    Assert-True ($codexText -match '(?m)^args = \[\s*"[^"]*anything-analyzer-stdio\.py"\s*\]') 'Codex: anything-analyzer args is the launcher'
    Assert-True ($codexText -notmatch 'Authorization') 'Codex: literal headers are not written'

    Set-CodexMcpServer -ServerName 'ask-ai.editor' -ServerDefinition @{ command = 'node'; args = @('x.js') }
    $codexText = Get-Content -LiteralPath $env:CODEX_CONFIG_PATH -Raw -Encoding UTF8
    Assert-True ($codexText -match '(?m)^\[mcp_servers\."ask-ai\.editor"\]\r?$') 'Codex: names outside A-Za-z0-9_- are written as quoted keys'

    $fixture = Join-Path $ScratchDir 'codex-fixture.toml'
    @(
        '[projects."D:\\repo"]',
        'trust_level = "trusted"',
        '',
        '[mcp_servers.Zen]',
        'command = "zen"',
        '',
        '[mcp_servers."Jina"]',
        'url = "https://example.invalid/mcp"',
        '',
        "[mcp_servers.'chrome-devtools']",
        'command = "npx"',
        '',
        '[mcp_servers."chrome-devtools".tools.new_page]',
        'enabled = false',
        '',
        '[mcp_servers.node_repl]',
        'command = "node"',
        '',
        '[mcp_servers.node_repl.env]',
        'NODE_OPTIONS = "--max-old-space-size=512"',
        '',
        '[mcp_servers.playwright.tools.browser_navigate]',
        'enabled = true',
        '',
        '[mcp_servers.playwright]',
        'command = "npx"'
    ) | Set-Content -LiteralPath $fixture -Encoding utf8
    $names = @(Get-CodexMcpServerNamesFromFile -Path $fixture)
    Assert-True (($names -join ',') -eq 'chrome-devtools,Jina,node_repl,playwright,Zen') "Codex: quoted names are unquoted and sub-tables skipped (got: $($names -join ','))"
    Assert-True ($null -eq (ConvertFrom-CodexMcpServerHeader -Line '[mcp_servers."chrome-devtools".tools.new_page]')) 'Codex: .tools sub-table is not a server'
    Assert-True ((ConvertFrom-CodexMcpServerHeader -Line "[mcp_servers.'with.dot']") -eq 'with.dot') 'Codex: single-quoted name with a dot parses'

    $remaining = @(Remove-CodexMcpServerBlocks -Lines @(Get-Content -LiteralPath $fixture) -ServerName 'chrome-devtools')
    $remainingText = $remaining -join "`n"
    Assert-True ($remainingText -notmatch 'chrome-devtools') 'Codex: quoted server table and its .tools sub-table removed'
    Assert-True ($remainingText -match '\[mcp_servers\.node_repl\.env\]' -and $remainingText -match 'NODE_OPTIONS') 'Codex: other servers and their sub-tables untouched'
    $remaining = @(Remove-CodexMcpServerBlocks -Lines @(Get-Content -LiteralPath $fixture) -ServerName 'node_repl')
    Assert-True (($remaining -join "`n") -notmatch 'node_repl') 'Codex: bare server table and its .env sub-table removed'
    $remaining = @(Remove-CodexMcpServerBlocks -Lines @(Get-Content -LiteralPath $fixture) -ServerName 'Jina')
    Assert-True (($remaining -join "`n") -notmatch 'example\.invalid' -and ($remaining -join "`n") -match 'trust_level') 'Codex: double-quoted table removed, unrelated [projects] kept'

    $env:CODEX_CONFIG_PATH = $fixture
    Set-CodexMcpServer -ServerName 'Jina' -ServerDefinition @{ url = 'https://replacement.invalid/mcp' }
    $fixtureText = Get-Content -LiteralPath $fixture -Raw -Encoding UTF8
    Assert-True (([regex]::Matches($fixtureText, '(?m)^\[mcp_servers\.(?:"Jina"|Jina)\]\r?$')).Count -eq 1) 'Codex: re-registering a previously quoted server does not duplicate its table'
    Assert-True ($fixtureText -notmatch 'example\.invalid' -and $fixtureText -match 'replacement\.invalid') 'Codex: previously quoted server was replaced, not appended'

    # --- 4. Manifest -> server definition (canAutoInstall=false registration path) ------
    $burp = [pscustomobject]@{ name = 'burpsuite-mcp'; mcpNames = @('burpsuite'); mcpCommand = 'node'; mcpArgs = @('D:\repo\burp-mcp-full\mcp-bridge.js') }
    $burpDefinition = Get-ManifestMcpServerDefinition -Definition $burp
    Assert-True ($burpDefinition.type -eq 'stdio' -and $burpDefinition.command -eq 'node' -and $burpDefinition.args[0] -like '*mcp-bridge.js') 'manifest: mcpCommand/mcpArgs yield a stdio bridge definition'
    $remote = [pscustomobject]@{ name = 'xquik-mcp'; mcpNames = @('xquik'); mcpUrl = 'https://xquik.com/mcp' }
    Assert-True ((Get-ManifestMcpServerDefinition -Definition $remote).url -eq 'https://xquik.com/mcp') 'manifest: mcpUrl yields a url definition'
    Assert-True ($null -eq (Get-ManifestMcpServerDefinition -Definition ([pscustomobject]@{ name = 'manual' }))) 'manifest: neither command nor url yields no registration'

    # --- 4b. Anything Analyzer mcp-server-config.json: no BOM, loopback host, token reuse ---
    $fakeAppData = Join-Path $ScratchDir 'appdata'
    New-Item -ItemType Directory -Path $fakeAppData -Force | Out-Null
    $env:APPDATA = $fakeAppData
    $token = Ensure-AnythingAnalyzerMcpConfig -Port 23816
    $configPath = Join-Path $fakeAppData 'anything-analyzer\mcp-server-config.json'
    Assert-True (Test-Path -LiteralPath $configPath) 'anything-analyzer: mcp-server-config.json written'
    $bytes = [IO.File]::ReadAllBytes($configPath)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'anything-analyzer: config has no UTF-8 BOM (JSON.parse in the app would throw)'
    $aaConfig = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    Assert-True ($aaConfig.host -eq '127.0.0.1') 'anything-analyzer: host is explicitly 127.0.0.1 (app default is 0.0.0.0)'
    Assert-True ($aaConfig.enabled -eq $true -and $aaConfig.authEnabled -eq $true -and $aaConfig.port -eq 23816) 'anything-analyzer: enabled, authEnabled and port written'
    Assert-True ($aaConfig.authToken -eq $token -and -not [string]::IsNullOrWhiteSpace($token)) 'anything-analyzer: returned token matches the file'
    Assert-True ((Test-Path -LiteralPath (Join-Path $fakeAppData 'Anything Analyzer\mcp-server-config.json'))) 'anything-analyzer: both user-data folder spellings receive the config'
    # A pre-existing BOM-prefixed file (written by the old Set-Content path) must still have its token reused and be rewritten BOM-free.
    $bomText = '{"enabled":false,"port":23816,"authEnabled":true,"authToken":"legacy-token"}'
    [IO.File]::WriteAllText($configPath, $bomText, [Text.UTF8Encoding]::new($true))
    (Get-Item -LiteralPath $configPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(5)
    $reused = Ensure-AnythingAnalyzerMcpConfig -Port 23816
    Assert-True ($reused -eq 'legacy-token') 'anything-analyzer: token of the most recently written config is reused'
    $otherConfig = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $fakeAppData 'Anything Analyzer\mcp-server-config.json'))) | ConvertFrom-Json
    Assert-True ($otherConfig.authToken -eq 'legacy-token') 'anything-analyzer: both copies converge on the same token'
    $bytes = [IO.File]::ReadAllBytes($configPath)
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'anything-analyzer: legacy BOM file is rewritten without BOM'
    Assert-True (([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json).enabled -eq $true) 'anything-analyzer: rewrite re-enables the server'
    $env:APPDATA = $oldEnv['APPDATA']

    # --- 5. Zip extraction with a single top-level directory under StrictMode -----------
    $zipSource = Join-Path $ScratchDir 'zip-src\bkcrack-1.8.1-win64'
    New-Item -ItemType Directory -Path $zipSource -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $zipSource 'bkcrack.exe') -Value 'not a real binary' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $zipSource 'license.txt') -Value 'zlib' -Encoding ascii
    $zipPath = Join-Path $ScratchDir 'bkcrack-1.8.1-win64.zip'
    Compress-Archive -Path $zipSource -DestinationPath $zipPath
    $zipTarget = Join-Path $ScratchDir 'Tools\bkcrack'
    Expand-ArchiveIntoDirectory -ZipPath $zipPath -Destination $zipTarget
    Assert-True (Test-Path -LiteralPath (Join-Path $zipTarget 'bkcrack.exe')) 'zip: single top-level directory is flattened into the install dir'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $zipTarget 'bkcrack-1.8.1-win64'))) 'zip: nested directory name is not kept'
    $flatSource = Join-Path $ScratchDir 'zip-flat'
    New-Item -ItemType Directory -Path $flatSource -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $flatSource 'a.txt') -Value 'a' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $flatSource 'b.txt') -Value 'b' -Encoding ascii
    $flatZip = Join-Path $ScratchDir 'flat.zip'
    Compress-Archive -Path (Join-Path $flatSource '*') -DestinationPath $flatZip
    $flatTarget = Join-Path $ScratchDir 'Tools\flat'
    Expand-ArchiveIntoDirectory -ZipPath $flatZip -Destination $flatTarget
    Assert-True ((Test-Path -LiteralPath (Join-Path $flatTarget 'a.txt')) -and (Test-Path -LiteralPath (Join-Path $flatTarget 'b.txt'))) 'zip: multi-entry archive extracts as-is'

    # --- 6. Visual Studio detection through vswhere ---------------------------------------
    $fakeVsWhere = Join-Path $ScratchDir 'vswhere.cmd'
    @('@echo off', 'echo C:\Program Files\Microsoft Visual Studio\18\Community', 'exit /b 0') | Set-Content -LiteralPath $fakeVsWhere -Encoding ascii
    $env:REVERSE_VSWHERE = $fakeVsWhere
    Assert-True (Test-VsBuildToolsInstalled) 'vswhere: any product with the VC x86/x64 toolset counts (VS 2026 Community)'
    @('@echo off', 'exit /b 0') | Set-Content -LiteralPath $fakeVsWhere -Encoding ascii
    $vsResultWithoutToolset = Test-VsBuildToolsInstalled
    $buildToolsFolderPresent = @(
        (Join-ReverseOptionalPath -Path ${env:ProgramFiles(x86)} -ChildPath 'Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC'),
        (Join-ReverseOptionalPath -Path $env:ProgramFiles -ChildPath 'Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
    if (@($buildToolsFolderPresent).Count -eq 0) {
        Assert-True (-not $vsResultWithoutToolset) 'vswhere: empty result and no Build Tools folder means not installed'
    } else {
        Write-Host '[SKIP] vswhere negative case (VS 2022 Build Tools folder exists on this host)'
    }

    # --- 7. start.ps1 backend module detection and single-pass process enumeration -------
    $env:REVERSE_IDA_START_FUNCTIONS_ONLY = '1'
    . (Join-Path $scriptDir '..\ida-reverse\scripts\start.ps1')
    $python = Get-FirstCommandPath -Names @('python.exe', 'python')
    if ([string]::IsNullOrWhiteSpace($python) -or $python -match '\\WindowsApps\\') {
        Write-Host '[SKIP] real interpreter probe (no python on PATH)'
    } else {
        $fakeSite = Join-Path $ScratchDir 'site'
        New-Item -ItemType Directory -Path (Join-Path $fakeSite 'ida_pro_mcp') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fakeSite 'ida_pro_mcp\__init__.py') -Value '' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $fakeSite 'ida_pro_mcp\idalib_server.py') -Value 'def main(): pass' -Encoding ascii
        $env:PYTHONPATH = $fakeSite
        $env:PYTHONNOUSERSITE = '1'
        Assert-True ((Get-IdaProMcpBackendModule -PythonExe $python) -eq 'ida_pro_mcp.idalib_server') 'start.ps1: ida-pro-mcp 2.0.0 layout resolves to ida_pro_mcp.idalib_server'
        Set-Content -LiteralPath (Join-Path $fakeSite 'ida_pro_mcp\idalib_supervisor.py') -Value 'def main(): pass' -Encoding ascii
        Assert-True ((Get-IdaProMcpBackendModule -PythonExe $python) -eq 'ida_pro_mcp.idalib_supervisor') 'start.ps1: idalib_supervisor is preferred when present'
        Remove-Item -LiteralPath (Join-Path $fakeSite 'ida_pro_mcp') -Recurse -Force
        Assert-True ([string]::IsNullOrWhiteSpace((Get-IdaProMcpBackendModule -PythonExe $python))) 'start.ps1: missing ida_pro_mcp yields no module'
        Remove-Item Env:PYTHONNOUSERSITE -ErrorAction SilentlyContinue
    }

    # Find-IdalibServer must forward the detected module instead of a hard-coded supervisor.
    $fakeIda = Join-Path $ScratchDir 'ida'
    New-Item -ItemType Directory -Path (Join-Path $fakeIda 'Python314') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeIda 'Python314\python.exe') -Value 'stub' -Encoding ascii
    function Get-IdaProMcpBackendModule { param([string]$PythonExe) if ($PythonExe -like '*Python314\python.exe') { return 'ida_pro_mcp.idalib_server' } return '' }
    $server = Find-IdalibServer -IdaDirPath $fakeIda -PreferredServerPath ''
    Assert-True ($null -ne $server -and $server.Mode -eq 'module' -and $server.Module -eq 'ida_pro_mcp.idalib_server') 'start.ps1: Find-IdalibServer returns the detected module (idalib_server fallback)'
    Assert-True ($server.Path -like '*Python314\python.exe') 'start.ps1: Find-IdalibServer keeps the interpreter that owns the module'

    $script:cimCalls = 0
    function Get-CimInstance {
        param([string]$ClassName, [string]$Filter, $ErrorAction)
        $script:cimCalls++
        return @(
            [pscustomobject]@{ ProcessId = 11; Name = 'python.exe'; CommandLine = 'python.exe -u -m ida_pro_mcp.idalib_server --host 127.0.0.1 --port 13337' },
            [pscustomobject]@{ ProcessId = 12; Name = 'pythonw.exe'; CommandLine = 'pythonw.exe -u run-supervisor.py --port 13337' },
            [pscustomobject]@{ ProcessId = 13; Name = 'python.exe'; CommandLine = 'python.exe some_unrelated_script.py' },
            [pscustomobject]@{ ProcessId = 14; Name = 'ida.exe'; CommandLine = 'ida.exe target.exe' },
            [pscustomobject]@{ ProcessId = 15; Name = 'idalib-mcp.exe'; CommandLine = 'idalib-mcp.exe --port 13337' },
            [pscustomobject]@{ ProcessId = 0; Name = 'System Idle Process'; CommandLine = $null }
        )
    }
    $managed = @(Get-ManagedSupervisorProcessIds)
    Assert-True (($managed -join ',') -eq '11,12,15') "start.ps1: managed backend processes are classified in memory (got: $($managed -join ','))"
    Assert-True ($script:cimCalls -eq 1) "start.ps1: Win32_Process is enumerated exactly once (calls: $($script:cimCalls))"

    Write-Host "OVERALL: ALL PASS ($passed assertions)" -ForegroundColor Green
}
finally {
    foreach ($key in $oldEnv.Keys) {
        [Environment]::SetEnvironmentVariable($key, $oldEnv[$key])
    }
    Remove-Item -LiteralPath $ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}
