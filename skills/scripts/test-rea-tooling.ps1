#Requires -Version 5.1
<#
.SYNOPSIS
Fixture-based regression tests for the rea bump tooling (lib/ReaTooling.ps1, update-rea.ps1).

Builds a throw-away repository tree with fake manifests, ToolDiscovery row, RULES rows, SKILL
paragraphs, ops/reference docs, docs/mcp/rea.md and the four client mirrors, then exercises
update-rea.ps1 -Mode Tracked / Apply against it, plus the catalog diff, changelog parsing,
version compare, mirror entry location and the referenced-tool scanner. The real repository
files and mirrors are never touched; no network, no rea process.
#>
param(
    [string]$ScratchDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptDir 'lib\ReaTooling.ps1')
$updateScript = Join-Path $scriptDir 'update-rea.ps1'

if ([string]::IsNullOrWhiteSpace($ScratchDir)) {
    $ScratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ('reverse-skill-rea-tooling-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null

$pass = 0
$failList = New-Object System.Collections.Generic.List[string]
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:pass++; Write-Host ("[OK] {0}" -f $Message) -ForegroundColor Green }
    else { Write-Host ("[FAIL] {0}" -f $Message) -ForegroundColor Red; [void]$script:failList.Add($Message) }
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    $ok = ([string]$Expected -eq [string]$Actual)
    Assert-True $ok ("{0} (expected '{1}', got '{2}')" -f $Message, $Expected, $Actual)
}
function Write-Fixture([string]$Rel, [string]$Text, [bool]$Bom = $false) {
    $path = Join-Path $script:fx $Rel
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-ReaTextFile -Path $path -Text $Text -Bom $Bom
    return $path
}
function Read-Fixture([string]$Rel) { return (Read-ReaTextFile -Path (Join-Path $script:fx $Rel)).Text }
function Get-FileSha([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Invoke-Update([string[]]$Arguments) {
    $hostExe = (Get-Process -Id $PID).Path
    # Windows PowerShell 5.1 turns redirected native stderr into terminating errors under Stop.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $updateScript -RepoRoot $script:fx @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap }
    return [pscustomobject]@{ Exit = $code; Output = (@($out | ForEach-Object { $_.ToString() }) -join "`n") }
}

# Full-width punctuation used by the Chinese rows.
$lp = [string][char]0xFF08; $rp = [string][char]0xFF09; $fc = [string][char]0xFF1A; $cm = [string][char]0xFF0C; $ed = [string][char]0x3001

function New-FixtureTree([string]$Root, [string]$Version) {
    $script:fx = $Root
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $v = $Version
    $manifest = @"
{
  "capabilities": [
    {
      "name": "jshookmcp",
      "bootstrapKind": "npm-mcp",
      "npmPackage": "jshookmcp@1.2.3",
      "mcpArgs": [
        "-y",
        "jshookmcp@1.2.3"
      ],
      "pinnedVersion": "1.2.3"
    },
    {
      "name": "rea",
      "bootstrapKind": "npm-mcp",
      "npmPackage": "rea-agents@$v",
      "mcpNames": [
        "rea"
      ],
      "mcpCommand": "npx",
      "mcpArgs": [
        "-y",
        "rea-agents@$v",
        "mcp"
      ],
      "mcpEnv": {},
      "canAutoInstall": true,
      "pinnedVersion": "$v",
      "note": "reverse-engineer-anything (REA) 单一 MCP server + CLI${lp}${v}${fc}138 个 MCP 工具${cm}tools/list 约 2.4 MB${rp}${fc}JS/Electron 应用图。stdio 入口 ``npx -y rea-agents@$v mcp``${cm}无需 token。"
    }
  ]
}
"@
    $null = Write-Fixture 'skills/scripts/bootstrap-manifest.json' ($manifest -replace "`r`n", "`n")
    $null = Write-Fixture 'kali/scripts/bootstrap-manifest.json' ($manifest -replace "`r`n", "`n")
    $td = "# ToolDiscovery`r`n`$catalog = @(`r`n    [pscustomobject]@{`r`n        Name = 'rea'`r`n        FixedVersion = 'rea-agents@$v'`r`n    }`r`n    [pscustomobject]@{`r`n        Name = 'reqable-mcp'`r`n        FixedVersion = 'reqable-mcp-server@1.0.1'`r`n    }`r`n)`r`n"
    $null = Write-Fixture 'skills/scripts/lib/ToolDiscovery.ps1' $td $true
    $null = Write-Fixture 'RULES.md' ("# RULES`n`n| x | y | z | w |`n|---|---|---|---|`n| rea | — (stdio) | reverse-engineer-anything $v (138 MCP tools): JS | Clients register ``npx -y rea-agents@$v mcp`` (project scope) |`n")
    $null = Write-Fixture 'RULES_zh.md' ("# RULES`n`n| rea | —${lp}stdio${rp} | reverse-engineer-anything $v${lp}138 个 MCP 工具${rp}${fc}JS | 客户端注册 ``npx -y rea-agents@$v mcp``${lp}项目级${rp} |`n")
    $null = Write-Fixture 'skills/js-reverse/SKILL.md' ("# js`n`n> **rea 可用**${lp}MCP 后端 ``rea`` = reverse-engineer-anything $v${cm}项目级 stdio 注册${rp}${fc}先 ``analyze_javascript_application``。`n")
    foreach ($s in @('dotnet-reverse', 'macos-reverse', 'apk-reverse', 'browser-extension-reverse')) {
        $null = Write-Fixture "skills/$s/SKILL.md" ("# $s`n`n> **rea 可用**${fc}``inspect_managed_artifact`` / ``open_binary`` / ``inspect_artifact``。`n")
    }
    $null = Write-Fixture 'skills/ops/evidence-finding-path.md' ("# ops`n`n| rea${lp}reverse-engineer-anything MCP${cm}rea-agents $v${rp} | ``export_evidence_bundle`` |`n`n   -ReproCommand `"rea MCP export_evidence_bundle (rea-agents $v)`" ```n")
    $null = Write-Fixture 'skills/references/community-security-skills.md' ("# refs`n`n| [morluto/rea](https://github.com/morluto/rea)${lp}rea-agents $v${cm}接入日期 2026-10-09${rp} | 单一 MCP server + CLI${lp}138 个 MCP 工具${ed}6 个 prompt${rp} | pinned ``rea-agents@$v`` |`n")
    $null = Write-Fixture 'docs/mcp/rea.md' ("# rea runbook`n`nCurrent pin: **rea-agents@$v** (Node engines x).`n`n| Fact | Evidence |`n|---|---|`n| ``npx -y rea-agents@$v --version`` | ``$v`` |`n| dry-run | ```"cmd.exe`" `"/d`" `"/c`" `"npx`" `"-y`" `"rea-agents@$v`" `"mcp`"`` |`n| handshake ``node.exe npx-cli.js -y rea-agents@$v mcp`` | ok |`n`n``````json`n`"rea`": {`n  `"args`": [`"npx-cli.js`", `"-y`", `"rea-agents@$v`", `"mcp`"]`n}`n```````n`n``````json`n`"rea`": {`n  `"args`": [`"npx-cli.js`", `"-y`", `"rea-agents@$v`", `"mcp`"]`n}`n```````n`n``````yaml`n    args:`n      - npx-cli.js`n      - -y`n      - rea-agents@$v`n      - mcp`n```````n`n``````toml`nargs = ['npx-cli.js', '-y', 'rea-agents@$v', 'mcp']`n```````n`n## Bump log`n`n| Date | From → To | Tool count | tools_list_sha256 | Note |`n|---|---|---|---|---|`n| 2026-10-09 | — → $v | 138 | ``abc`` | initial |`n")
    # mirrors
    $null = Write-Fixture '.mcp.json' ("{`n  `"mcpServers`": {`n    `"math`": {`n      `"type`": `"stdio`",`n      `"command`": `"node`",`n      `"args`": [`"math.js`", `"{not-rea}`"]`n    },`n    `"rea`": {`n      `"type`": `"stdio`",`n      `"command`": `"C:\\Program Files\\nodejs\\node.exe`",`n      `"args`": [`n        `"C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npx-cli.js`",`n        `"-y`",`n        `"rea-agents@$v`",`n        `"mcp`"`n      ]`n    },`n    `"zz`": { `"command`": `"x`", `"args`": [`"rea-agents@0.0.1`"] }`n  }`n}`n")
    $null = Write-Fixture '.codex/config.toml' ("model = 'x'`n`n[mcp_servers.`"math`"]`ncommand = 'node'`nargs = ['math.js']`nenabled = true`n`n[mcp_servers.`"rea`"]`ncommand = 'C:\Program Files\nodejs\node.exe'`nargs = ['C:\Program Files\nodejs\node_modules\npm\bin\npx-cli.js', '-y', 'rea-agents@$v', 'mcp']`nstartup_timeout_sec = 90`nenabled = true`n`n[mcp_servers.`"after`"]`ncommand = 'y'`nargs = ['rea-agents@0.0.1']`n")
    # mixed line endings on purpose (the real file has them)
    $null = Write-Fixture '.agents/mcp_config.json' ("{`r`n  `"mcpServers`": {`r`n    `"math`": {`n      `"command`": `"node`",`n      `"args`": [`"math.js`"]`r`n    },`r`n    `"rea`": {`n      `"command`": `"C:\\Program Files\\nodejs\\node.exe`",`r`n      `"args`": [`n        `"C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npx-cli.js`",`r`n        `"-y`",`n        `"rea-agents@$v`",`r`n        `"mcp`"`n      ]`r`n    }`n  }`r`n}`n")
    $null = Write-Fixture '.dsh/agent-presets/reverse-skill/agent.cordis.yml' ("services:`n  - group: mcp`n    isolate: true`n    items:`n      - id: mcp-math`n        name: `"@deepseek-ai/dsh-mcp-client`"`n        config:`n          serverName: math`n      - id: mcp-rea`n        name: `"@deepseek-ai/dsh-mcp-client`"`n        config:`n          serverName: rea`n          transport: stdio`n          command: C:\Program Files\nodejs\node.exe`n          args:`n            - C:\Program Files\nodejs\node_modules\npm\bin\npx-cli.js`n            - -y`n            - rea-agents@$v`n            - mcp`n`n          # trailing comment inside the entry`n          cwd: D:\repo`n      - id: mcp-after`n        config:`n          args:`n            - rea-agents@0.0.1`n    other: rea-agents@0.0.1`n")
}

function New-FakeReport([string]$Path, [string]$Version, [bool]$Passed, [int]$ToolCount = 140, [string[]]$Missing = @()) {
    $r = [ordered]@{
        version = $Version; passed = $Passed; tool_count = $ToolCount; prompt_count = 7
        tools_list_bytes = 2500000; tools_list_sha256 = ('f' * 64)
        referenced_tools = [ordered]@{ scanner = 'select-string'; count = 3; names = @('a', 'b', 'c'); missing = $Missing }
    }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $r -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

Write-Host "=== test-rea-tooling | scratch $ScratchDir ==="

# ---------------------------------------------------------------- unit: versions
Assert-Equal -1 (Compare-ReaVersion '6.1.0' '6.3.0') 'Compare-ReaVersion 6.1.0 < 6.3.0'
Assert-Equal 1 (Compare-ReaVersion '6.10.0' '6.9.0') 'Compare-ReaVersion 6.10.0 > 6.9.0 (numeric, not lexical)'
Assert-Equal 0 (Compare-ReaVersion '6.1.0' '6.1.0') 'Compare-ReaVersion equal'
Assert-True (Test-ReaVersionString '6.1.0') 'Test-ReaVersionString accepts 6.1.0'
Assert-True (-not (Test-ReaVersionString 'latest')) 'Test-ReaVersionString rejects latest'

# ---------------------------------------------------------------- unit: changelog
$changelog = @"
# Changelog

## [6.3.0](https://x/compare/rea-agents-6.2.0...rea-agents-6.3.0) (2026-10-10)

### Features

* **web:** thing ([abc](https://x))

## [6.2.0](https://x/compare/rea-agents-6.1.0...rea-agents-6.2.0) (2026-10-09)

### ⚠ BREAKING CHANGES

* **hopper:** remove set_current_document.
* **mcp:** rename foo to bar.

### Bug Fixes

* **cli:** fix ([def](https://x))

## [6.1.0](https://x/compare/rea-agents-6.0.0...rea-agents-6.1.0) (2026-10-09)

### ⚠ BREAKING CHANGES

* **old:** should not be selected.
"@
$sections = @(Get-ReaChangelogSections -Text $changelog)
Assert-Equal 3 $sections.Count 'changelog: three sections parsed'
$sel = @(Select-ReaChangelogBetween -Sections $sections -Pin '6.1.0' -Latest '6.3.0')
Assert-Equal '6.3.0,6.2.0' (($sel | ForEach-Object { $_.Version }) -join ',') 'changelog: sections strictly after pin up to latest'
$brk = @($sel | ForEach-Object { $_.BreakingChanges })
Assert-Equal 2 $brk.Count 'changelog: two breaking bullets from 6.2.0 only'
Assert-True ($brk[0] -like '* **hopper:** remove set_current_document.') 'changelog: breaking bullet text kept'
Assert-True ($sel[1].Body -match 'Bug Fixes') 'changelog: section body includes later headings'
$none = @(Select-ReaChangelogBetween -Sections $sections -Pin '6.3.0' -Latest '6.3.0')
Assert-Equal 0 $none.Count 'changelog: nothing selected when pin == latest'

# ---------------------------------------------------------------- unit: canonical json + catalog diff
$a = '{"b":1,"a":{"y":[1,2],"x":"s"}}' | ConvertFrom-Json
$b = '{"a":{"x":"s","y":[1,2]},"b":1}' | ConvertFrom-Json
Assert-Equal (ConvertTo-ReaCanonicalJson $a) (ConvertTo-ReaCanonicalJson $b) 'canonical json is key-order independent'
$c = '{"a":{"x":"s","y":[2,1]},"b":1}' | ConvertFrom-Json
Assert-True ((ConvertTo-ReaCanonicalJson $a) -ne (ConvertTo-ReaCanonicalJson $c)) 'canonical json keeps array order significant'

$prev = @'
[
 {"name":"keep","description":"d","inputSchema":{"type":"object","properties":{"p":{"type":"string"}}},"outputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}},
 {"name":"reorder","description":"d","inputSchema":{"properties":{"p":{"type":"string"}},"type":"object"},"annotations":{"readOnlyHint":true}},
 {"name":"changed_schema","description":"d","inputSchema":{"type":"object","properties":{"p":{"type":"string","deep":{"a":1}}}}},
 {"name":"changed_desc","description":"old"},
 {"name":"gone","description":"d"}
]
'@ | ConvertFrom-Json
$cur = @'
{"tools":[
 {"name":"keep","description":"d","inputSchema":{"type":"object","properties":{"p":{"type":"string"}}},"outputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}},
 {"name":"reorder","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"p":{"type":"string"}}},"description":"d"},
 {"name":"changed_schema","description":"d","inputSchema":{"type":"object","properties":{"p":{"type":"string","deep":{"a":2}}}}},
 {"name":"changed_desc","description":"new"},
 {"name":"added","description":"d"}
]}
'@ | ConvertFrom-Json
$diff = Compare-ReaCatalog -Previous $prev -Current $cur
Assert-Equal 'added' ($diff.added -join ',') 'diff: added tool detected'
Assert-Equal 'gone' ($diff.removed -join ',') 'diff: removed tool detected'
Assert-Equal 'changed_desc,changed_schema' (($diff.changed | ForEach-Object { $_.name }) -join ',') 'diff: changed tools (deep schema + description), reorder not flagged'
Assert-Equal 'inputSchema' ((($diff.changed | Where-Object { $_.name -eq 'changed_schema' }).fields) -join ',') 'diff: changed field named'
Assert-Equal 2 $diff.unchanged_count 'diff: unchanged count'
Assert-True (-not $diff.identical) 'diff: identical=false'
$catalogFile = Join-Path $ScratchDir 'prev-catalog.json'
[System.IO.File]::WriteAllText($catalogFile, (ConvertTo-Json -InputObject @($prev) -Depth 50), (New-Object System.Text.UTF8Encoding($false)))
$diff2 = Compare-ReaCatalog -Previous $catalogFile -Current $cur
Assert-Equal 'gone' ($diff2.removed -join ',') 'diff: previous catalog accepted as a file path'
$same = Compare-ReaCatalog -Previous $prev -Current @($prev)
Assert-True $same.identical 'diff: identical catalogs report identical=true'

# ---------------------------------------------------------------- unit: mirror entry ranges
$jsonText = '{"a":{"rea-agents@1.0.0":"{"},"rea": {"args":["x}","rea-agents@6.1.0"],"o":{"k":"}"}},"z":{"args":["rea-agents@0.0.1"]}}'
$range = Get-ReaMirrorEntryRange -Text $jsonText -Kind json
$seg = $jsonText.Substring($range.Start, $range.End - $range.Start + 1)
Assert-True ($seg.StartsWith('"rea": {') -and $seg.EndsWith('"k":"}"}}')) 'json range: brace matching ignores braces inside strings'
Assert-True ($seg -notmatch 'rea-agents@0\.0\.1' -and $seg -notmatch 'rea-agents@1\.0\.0') 'json range: neighbours excluded'
Assert-True ($null -eq (Get-ReaMirrorEntryRange -Text '{"a":1}' -Kind json)) 'json range: null when absent'

# ---------------------------------------------------------------- unit: referenced-tool scanner (Select-String path)
$scanRoot = Join-Path $ScratchDir 'scan'
New-Item -ItemType Directory -Path (Join-Path $scanRoot 'skills') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $scanRoot 'docs') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $scanRoot 'skills\a.md'), 'use `analyze_javascript_application` then mcp__rea__trace_application_feature; inspect_managed_members too, not_a_tool_name')
[System.IO.File]::WriteAllText((Join-Path $scanRoot 'docs\b.json'), '{"x":"project_apple_application_graph open_binary close_binary"}')
[System.IO.File]::WriteAllText((Join-Path $scanRoot 'docs\c.bin'), 'inspect_web_page')
$scan = Get-ReaReferencedToolNames -RepoRoot $scanRoot -ForceSelectString
Assert-Equal 'select-string' $scan.Scanner 'scanner: Select-String fallback used'
Assert-Equal 'analyze_javascript_application,close_binary,inspect_managed_members,open_binary,project_apple_application_graph,trace_application_feature' ($scan.Names -join ',') 'scanner: names found, mcp__rea__ prefix stripped, binary extension skipped'

# ---------------------------------------------------------------- integration: Tracked
$fxRoot = Join-Path $ScratchDir 'repo-tracked'
New-FixtureTree -Root $fxRoot -Version '6.1.0'
$untouched = @('skills/dotnet-reverse/SKILL.md', 'skills/macos-reverse/SKILL.md', 'skills/apk-reverse/SKILL.md', 'skills/browser-extension-reverse/SKILL.md', '.mcp.json', '.codex/config.toml', '.agents/mcp_config.json', '.dsh/agent-presets/reverse-skill/agent.cordis.yml')
$before = @{}
foreach ($u in $untouched) { $before[$u] = Get-FileSha (Join-Path $fxRoot $u) }
$goodReport = New-FakeReport -Path (Join-Path $ScratchDir 'report-6.3.0.json') -Version '6.3.0' -Passed $true -ToolCount 140

$res = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Tracked', '-ContractReport', $goodReport, '-Date', '2026-10-11', '-Note', 'test bump')
Assert-Equal 0 $res.Exit "Tracked: exit 0 (output: $($res.Output -replace "`n", ' | '))"
$m = Read-Fixture 'skills/scripts/bootstrap-manifest.json'
$mj = $m | ConvertFrom-Json
$reaCap = $mj.capabilities | Where-Object { $_.name -eq 'rea' }
Assert-Equal '6.3.0' $reaCap.pinnedVersion 'Tracked: manifest pinnedVersion'
Assert-Equal 'rea-agents@6.3.0' $reaCap.npmPackage 'Tracked: manifest npmPackage'
Assert-Equal '-y,rea-agents@6.3.0,mcp' ($reaCap.mcpArgs -join ',') 'Tracked: manifest mcpArgs element'
Assert-True ($reaCap.note -like "*${lp}6.3.0${fc}140 个 MCP 工具${cm}tools/list 约 2.4 MB${rp}*") 'Tracked: manifest note version + tool count rewritten, size from report'
Assert-True ($reaCap.note.Contains('`npx -y rea-agents@6.3.0 mcp`')) 'Tracked: manifest note runner command'
Assert-Equal 'jshookmcp@1.2.3' ($mj.capabilities | Where-Object { $_.name -eq 'jshookmcp' }).npmPackage 'Tracked: other capability untouched'
Assert-True ($m -notmatch "`r") 'Tracked: manifest keeps LF line endings'
Assert-Equal (Read-Fixture 'skills/scripts/bootstrap-manifest.json') (Read-Fixture 'kali/scripts/bootstrap-manifest.json') 'Tracked: kali manifest edited identically'
$tdFile = Read-ReaTextFile -Path (Join-Path $fxRoot 'skills/scripts/lib/ToolDiscovery.ps1')
Assert-True $tdFile.Bom 'Tracked: ToolDiscovery BOM preserved'
Assert-True ($tdFile.Text -match "FixedVersion = 'rea-agents@6.3.0'`r`n") 'Tracked: ToolDiscovery FixedVersion + CRLF preserved'
Assert-True ($tdFile.Text -match "reqable-mcp-server@1.0.1") 'Tracked: ToolDiscovery neighbour row untouched'
$rules = Read-Fixture 'RULES.md'
Assert-True ($rules -match 'reverse-engineer-anything 6\.3\.0 \(140 MCP tools\)' -and $rules -match '`npx -y rea-agents@6\.3\.0 mcp`') 'Tracked: RULES.md row'
$rulesZh = Read-Fixture 'RULES_zh.md'
Assert-True ($rulesZh -match ('reverse-engineer-anything 6\.3\.0' + [regex]::Escape($lp) + '140 个 MCP 工具' + [regex]::Escape($rp)) -and $rulesZh -match '`npx -y rea-agents@6\.3\.0 mcp`') 'Tracked: RULES_zh.md row'
Assert-True ((Read-Fixture 'skills/js-reverse/SKILL.md') -match 'reverse-engineer-anything 6\.3\.0') 'Tracked: js-reverse paragraph'
$ev = Read-Fixture 'skills/ops/evidence-finding-path.md'
Assert-Equal 2 ([regex]::Matches($ev, 'rea-agents 6\.3\.0').Count) 'Tracked: evidence-finding-path both occurrences'
$comm = Read-Fixture 'skills/references/community-security-skills.md'
Assert-True ($comm -match ('rea-agents 6\.3\.0' + [regex]::Escape($cm) + '接入日期') -and $comm -match '`rea-agents@6\.3\.0`' -and $comm -match ([regex]::Escape($lp) + '140 个 MCP 工具' + [regex]::Escape($ed) + '7 个 prompt' + [regex]::Escape($rp))) 'Tracked: community row version, tool + prompt counts'
$doc = Read-Fixture 'docs/mcp/rea.md'
Assert-True ($doc -match 'Current pin: \*\*rea-agents@6\.3\.0\*\*') 'Tracked: rea.md Current pin'
Assert-Equal 2 ([regex]::Matches($doc, '"rea-agents@6\.3\.0", "mcp"\]').Count) 'Tracked: rea.md both JSON shape blocks rewritten'
Assert-True ($doc -match "'rea-agents@6\.3\.0', 'mcp'\]") 'Tracked: rea.md TOML shape rewritten'
Assert-True ($doc -match '(?m)^      - rea-agents@6\.3\.0$') 'Tracked: rea.md YAML shape rewritten'
Assert-True (($doc -match 'npx -y rea-agents@6\.1\.0 --version') -and ($doc -match '"rea-agents@6\.1\.0" "mcp"') -and ($doc -match 'npx-cli\.js -y rea-agents@6\.1\.0 mcp')) 'Tracked: rea.md dated facts-table rows untouched'
$lastLine = @($doc.TrimEnd("`n") -split "`n")[-1]
Assert-Equal ('| 2026-10-11 | 6.1.0 ' + [char]0x2192 + ' 6.3.0 | 140 | `' + ('f' * 64) + '` | test bump |') $lastLine 'Tracked: bump log row appended'
foreach ($u in $untouched) { Assert-Equal $before[$u] (Get-FileSha (Join-Path $fxRoot $u)) "Tracked: $u byte-identical" }
$stale = 0
foreach ($rel in @('skills/scripts/bootstrap-manifest.json', 'kali/scripts/bootstrap-manifest.json', 'skills/scripts/lib/ToolDiscovery.ps1', 'RULES.md', 'RULES_zh.md', 'skills/js-reverse/SKILL.md', 'skills/ops/evidence-finding-path.md', 'skills/references/community-security-skills.md')) {
    $stale += [regex]::Matches((Read-Fixture $rel), '6\.1\.0').Count
}
Assert-Equal 0 $stale 'Tracked: no 6.1.0 left in the rewritten carriers'

# Tracked: already pinned -> refuses, nothing changes
$shaBefore = Get-FileSha (Join-Path $fxRoot 'RULES.md')
$res2 = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Tracked', '-SkipResidualScan')
Assert-True ($res2.Exit -ne 0) 'Tracked: refuses when already pinned'
Assert-Equal $shaBefore (Get-FileSha (Join-Path $fxRoot 'RULES.md')) 'Tracked: already-pinned run writes nothing'

# Tracked: anchor count mismatch aborts before any write
$fxRoot2 = Join-Path $ScratchDir 'repo-tracked-bad'
New-FixtureTree -Root $fxRoot2 -Version '6.1.0'
$badRules = Join-Path $fxRoot2 'RULES.md'
Write-ReaTextFile -Path $badRules -Text ((Read-ReaTextFile -Path $badRules).Text + "| dup | reverse-engineer-anything 6.1.0 (138 MCP tools) |`n")
$all = @(Get-ChildItem -LiteralPath $fxRoot2 -Recurse -File -Force)
$shas = @{}
foreach ($f in $all) { $shas[$f.FullName] = Get-FileSha $f.FullName }
$res3 = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Tracked', '-SkipResidualScan')
Assert-True ($res3.Exit -ne 0) 'Tracked: duplicate anchor -> non-zero exit'
Assert-True ($res3.Output -match 'expected exactly 1') 'Tracked: duplicate anchor reported with the count'
$changed = @($all | Where-Object { $shas[$_.FullName] -ne (Get-FileSha $_.FullName) })
Assert-Equal 0 $changed.Count 'Tracked: validation failure writes no file at all'

# Tracked without a report keeps the existing counts
$fxRoot3 = Join-Path $ScratchDir 'repo-tracked-noreport'
New-FixtureTree -Root $fxRoot3 -Version '6.1.0'
$res4 = Invoke-Update @('-Version', '6.2.0', '-Mode', 'Tracked', '-SkipResidualScan', '-Date', '2026-10-11')
Assert-Equal 0 $res4.Exit 'Tracked (no report): exit 0'
Assert-True ((Read-Fixture 'RULES.md') -match 'reverse-engineer-anything 6\.2\.0 \(138 MCP tools\)') 'Tracked (no report): tool count kept'
Assert-True ((Read-Fixture 'skills/references/community-security-skills.md') -match ([regex]::Escape($lp) + '138 个 MCP 工具' + [regex]::Escape($ed) + '6 个 prompt')) 'Tracked (no report): prompt count kept'
Assert-True ((Read-Fixture 'docs/mcp/rea.md') -match '\| 2026-10-11 \| 6\.1\.0 . 6\.2\.0 \| - \| - \| update-rea\.ps1 Tracked \|') 'Tracked (no report): bump row with placeholders'

# ---------------------------------------------------------------- integration: Apply
$fxRoot4 = Join-Path $ScratchDir 'repo-apply'
New-FixtureTree -Root $fxRoot4 -Version '6.1.0'
$mirrors = @('.mcp.json', '.codex/config.toml', '.agents/mcp_config.json', '.dsh/agent-presets/reverse-skill/agent.cordis.yml')
$mirrorBefore = @{}
foreach ($mm in $mirrors) { $mirrorBefore[$mm] = Get-FileSha (Join-Path $fxRoot4 $mm) }

$resA = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Apply')
Assert-Equal 5 $resA.Exit 'Apply: refused without -ContractReport (exit 5)'
$badReport = New-FakeReport -Path (Join-Path $ScratchDir 'report-bad.json') -Version '6.3.0' -Passed $false
$resB = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Apply', '-ContractReport', $badReport)
Assert-Equal 5 $resB.Exit 'Apply: refused with a failing report (exit 5)'
$otherReport = New-FakeReport -Path (Join-Path $ScratchDir 'report-6.2.0.json') -Version '6.2.0' -Passed $true
$resC = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Apply', '-ContractReport', $otherReport)
Assert-Equal 5 $resC.Exit 'Apply: refused when the report is for another version (exit 5)'
$missingReport = New-FakeReport -Path (Join-Path $ScratchDir 'report-missing.json') -Version '6.3.0' -Passed $true -Missing @('open_binary')
$resD = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Apply', '-ContractReport', $missingReport)
Assert-Equal 5 $resD.Exit 'Apply: refused when the report lists missing referenced tools (exit 5)'
foreach ($mm in $mirrors) { Assert-Equal $mirrorBefore[$mm] (Get-FileSha (Join-Path $fxRoot4 $mm)) "Apply refusals leave $mm untouched" }

# capture prefix/suffix around each rea entry before the real apply
$ctx = @{}
foreach ($d in @(Get-ReaMirrorDefinitions -RepoRoot $fxRoot4)) {
    $t = (Read-ReaTextFile -Path $d.Path).Text
    $r = Get-ReaMirrorEntryRange -Text $t -Kind $d.Kind
    $ctx[$d.Name] = @{ Prefix = $t.Substring(0, $r.Start); Suffix = $t.Substring($r.End + 1); Entry = $t.Substring($r.Start, $r.End - $r.Start + 1); Decoys = [regex]::Matches($t, 'rea-agents@0\.0\.1').Count }
}
$resE = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Apply', '-ContractReport', $goodReport)
Assert-Equal 0 $resE.Exit "Apply: exit 0 ($($resE.Output -replace "`n", ' | '))"
Assert-True ($resE.Output -match 'claude mcp list' -and $resE.Output -match 'codex mcp get rea') 'Apply: prints the client verification commands'
foreach ($d in @(Get-ReaMirrorDefinitions -RepoRoot $fxRoot4)) {
    $t = (Read-ReaTextFile -Path $d.Path).Text
    $r = Get-ReaMirrorEntryRange -Text $t -Kind $d.Kind
    $entry = $t.Substring($r.Start, $r.End - $r.Start + 1)
    Assert-True ($t.StartsWith($ctx[$d.Name].Prefix) -and $t.EndsWith($ctx[$d.Name].Suffix)) "Apply: $($d.Name) prefix/suffix bytes unchanged"
    Assert-Equal ($ctx[$d.Name].Entry.Replace('rea-agents@6.1.0', 'rea-agents@6.3.0')) $entry "Apply: $($d.Name) entry differs only in the version"
    Assert-Equal $ctx[$d.Name].Decoys ([regex]::Matches($t, 'rea-agents@0\.0\.1').Count) "Apply: $($d.Name) neighbouring rea-agents@0.0.1 decoys untouched"
}
$ag = Read-Fixture '.agents/mcp_config.json'
Assert-True (($ag -match "`r`n") -and ($ag -match "(?<!`r)`n")) 'Apply: mixed CRLF/LF preserved in .agents/mcp_config.json'
Assert-True ($null -ne ((Read-Fixture '.mcp.json') | ConvertFrom-Json)) 'Apply: .mcp.json still parses'
Assert-True ((Read-Fixture '.codex/config.toml') -match "(?m)^\[mcp_servers\.`"after`"\]`ncommand = 'y'") 'Apply: toml block after rea intact'
$yml = Read-Fixture '.dsh/agent-presets/reverse-skill/agent.cordis.yml'
Assert-True ($yml -match '- rea-agents@6\.3\.0\n            - mcp\n\n          # trailing comment inside the entry\n          cwd: D:\\repo\n      - id: mcp-after') 'Apply: yml entry including comment/blank line handled, next item intact'

# Apply again: idempotent, 'already'
$resF = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Apply', '-ContractReport', $goodReport)
Assert-Equal 0 $resF.Exit 'Apply: second run exit 0'
Assert-True ($resF.Output -match 'already rea-agents@6\.3\.0') 'Apply: second run reports already'
Assert-True ($resF.Output -match '0 mirror\(s\) updated') 'Apply: second run updates nothing'

# Apply with a missing mirror file: skipped, others updated
Remove-Item -LiteralPath (Join-Path $fxRoot4 '.codex/config.toml') -Force
$resG = Invoke-Update @('-Version', '6.1.0', '-Mode', 'Apply', '-ContractReport', (New-FakeReport -Path (Join-Path $ScratchDir 'report-6.1.0.json') -Version '6.1.0' -Passed $true))
Assert-Equal 0 $resG.Exit 'Apply (rollback to 6.1.0, codex mirror absent): exit 0'
Assert-True ($resG.Output -match 'file absent, skipped' -and $resG.Output -match '3 mirror\(s\) updated') 'Apply: absent mirror skipped, three updated'
Assert-Equal $mirrorBefore['.mcp.json'] (Get-FileSha (Join-Path $fxRoot4 '.mcp.json')) 'Apply: rollback restores .mcp.json byte-for-byte'
Assert-Equal $mirrorBefore['.agents/mcp_config.json'] (Get-FileSha (Join-Path $fxRoot4 '.agents/mcp_config.json')) 'Apply: rollback restores .agents/mcp_config.json byte-for-byte'

# ---------------------------------------------------------------- integration: Both
$fxRoot5 = Join-Path $ScratchDir 'repo-both'
New-FixtureTree -Root $fxRoot5 -Version '6.1.0'
$resH = Invoke-Update @('-Version', '6.3.0', '-Mode', 'Both', '-ContractReport', $goodReport, '-SkipResidualScan', '-Date', '2026-10-11')
Assert-Equal 0 $resH.Exit 'Both: exit 0'
Assert-Equal '6.3.0' (Get-ReaManifestPin -ManifestPath (Join-Path $fxRoot5 'skills/scripts/bootstrap-manifest.json')).Version 'Both: manifest pin'
Assert-True ((Read-Fixture '.codex/config.toml') -match "'rea-agents@6\.3\.0'") 'Both: codex mirror'

Write-Host ''
Write-Host ("=== test-rea-tooling: {0} passed, {1} failed ===" -f $pass, $failList.Count)
if ($failList.Count -gt 0) {
    foreach ($f in $failList) { Write-Host (" - {0}" -f $f) -ForegroundColor Red }
    exit 1
}
exit 0
