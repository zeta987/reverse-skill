#Requires -Version 5.1
<#
.SYNOPSIS
Shared helpers for the rea (reverse-engineer-anything, npm package rea-agents) upstream
tracking and bump tooling: check-rea-upstream.ps1, test-rea-contract.ps1, update-rea.ps1
and their regression test test-rea-tooling.ps1.

Everything here is pure string/JSON work so the test can exercise it against fixtures
without spawning rea or touching the network. File writes preserve the BOM state and the
line endings of the original bytes (several targets are LF-only, one mirror has mixed
CRLF/LF, two scripts carry a UTF-8 BOM).
#>
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# Byte-preserving text IO
# ----------------------------------------------------------------------------

function Read-ReaTextFile {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($false, $true)
    if ($hasBom) {
        $text = $enc.GetString($bytes, 3, $bytes.Length - 3)
    } else {
        $text = $enc.GetString($bytes)
    }
    [pscustomobject]@{ Path = $Path; Text = $text; Bom = $hasBom; Length = $bytes.Length }
}

function Write-ReaTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [bool]$Bom = $false
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    $body = $enc.GetBytes($Text)
    if ($Bom) {
        $out = New-Object byte[] ($body.Length + 3)
        $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
        [Array]::Copy($body, 0, $out, 3, $body.Length)
    } else {
        $out = $body
    }
    [System.IO.File]::WriteAllBytes($Path, $out)
}

# ----------------------------------------------------------------------------
# Versions
# ----------------------------------------------------------------------------

function Compare-ReaVersion {
    <# Returns -1 when $Left is older than $Right, 0 when equal, 1 when newer. Numeric
       dotted components only; a pre-release suffix is ignored for ordering. #>
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $l = @(($Left -split '-', 2)[0] -split '\.' | ForEach-Object { [int]$_ })
    $r = @(($Right -split '-', 2)[0] -split '\.' | ForEach-Object { [int]$_ })
    $n = [Math]::Max($l.Count, $r.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $a = if ($i -lt $l.Count) { $l[$i] } else { 0 }
        $b = if ($i -lt $r.Count) { $r[$i] } else { 0 }
        if ($a -lt $b) { return -1 }
        if ($a -gt $b) { return 1 }
    }
    return 0
}

function Test-ReaVersionString {
    param([Parameter(Mandatory)][string]$Version)
    return [bool]($Version -match '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')
}

# ----------------------------------------------------------------------------
# Manifest pin (single version authority: skills/scripts/bootstrap-manifest.json)
# ----------------------------------------------------------------------------

function Get-ReaManifestPin {
    param([Parameter(Mandatory)][string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "manifest not found: $ManifestPath" }
    $json = (Read-ReaTextFile -Path $ManifestPath).Text | ConvertFrom-Json
    $cap = @($json.capabilities | Where-Object { $_.name -eq 'rea' })
    if ($cap.Count -ne 1) { throw "manifest $ManifestPath must contain exactly one capability named 'rea' (found $($cap.Count))" }
    $cap = $cap[0]
    $pin = [string]$cap.pinnedVersion
    if (-not (Test-ReaVersionString $pin)) { throw "manifest pinnedVersion '$pin' is not a version" }
    if ([string]$cap.npmPackage -ne "rea-agents@$pin") {
        throw "manifest npmPackage '$($cap.npmPackage)' does not match pinnedVersion '$pin'"
    }
    $argHit = @($cap.mcpArgs | Where-Object { $_ -eq "rea-agents@$pin" })
    if ($argHit.Count -ne 1) { throw "manifest mcpArgs must contain 'rea-agents@$pin' exactly once" }
    return [pscustomobject]@{
        Version    = $pin
        NpmPackage = [string]$cap.npmPackage
        McpCommand = [string]$cap.mcpCommand
        McpArgs    = @($cap.mcpArgs)
        Note       = [string]$cap.note
    }
}

# ----------------------------------------------------------------------------
# CHANGELOG (release-please layout: "## [x.y.z](compare-url) (date)")
# ----------------------------------------------------------------------------

function Get-ReaChangelogSections {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = $Text -split "\r?\n"
    $sections = New-Object System.Collections.Generic.List[object]
    $current = $null
    $inBreaking = $false
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^##\s+\[?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\]?')
        if ($m.Success) {
            if ($null -ne $current) { [void]$sections.Add($current) }
            $current = [pscustomobject]@{
                Version         = $m.Groups[1].Value
                Heading         = $line
                Lines           = New-Object System.Collections.Generic.List[string]
                BreakingChanges = New-Object System.Collections.Generic.List[string]
            }
            $inBreaking = $false
            continue
        }
        if ($null -eq $current) { continue }
        [void]$current.Lines.Add($line)
        if ($line -match '^###\s') {
            $inBreaking = [bool]($line -match 'BREAKING CHANGES')
            continue
        }
        if ($inBreaking -and $line -match '^\s*[\*\-]\s+\S') {
            [void]$current.BreakingChanges.Add($line.Trim())
        }
    }
    if ($null -ne $current) { [void]$sections.Add($current) }
    foreach ($s in $sections) {
        $s | Add-Member -NotePropertyName Body -NotePropertyValue (($s.Lines -join "`n").Trim()) -Force
    }
    return @($sections.ToArray())
}

function Select-ReaChangelogBetween {
    <# Sections with $Pin < Version <= $Latest, newest first (CHANGELOG order). #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sections,
        [Parameter(Mandatory)][string]$Pin,
        [Parameter(Mandatory)][string]$Latest
    )
    return @($Sections | Where-Object {
        (Compare-ReaVersion $_.Version $Pin) -gt 0 -and (Compare-ReaVersion $_.Version $Latest) -le 0
    })
}

# ----------------------------------------------------------------------------
# Canonical JSON + catalog diff
# ----------------------------------------------------------------------------

function ConvertTo-ReaCanonicalValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Value.Keys | Sort-Object { [string]$_ })) {
            $o[[string]$k] = ConvertTo-ReaCanonicalValue -Value $Value[$k]
        }
        return $o
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$list.Add((ConvertTo-ReaCanonicalValue -Value $item)) }
        return , $list.ToArray()
    }
    if ($Value -is [psobject]) {
        $o = [ordered]@{}
        foreach ($p in @($Value.PSObject.Properties | Sort-Object Name)) {
            $o[$p.Name] = ConvertTo-ReaCanonicalValue -Value $p.Value
        }
        return $o
    }
    return $Value
}

function ConvertTo-ReaCanonicalJson {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return 'null' }
    $canon = ConvertTo-ReaCanonicalValue -Value $Value
    return (ConvertTo-Json -InputObject $canon -Depth 100 -Compress)
}

function Get-ReaCatalogTools {
    <# Accepts a tools array, a wrapper object with .tools, or a path to a JSON file holding either. #>
    param([Parameter(Mandatory)]$Catalog)
    if ($Catalog -is [string]) {
        if (-not (Test-Path -LiteralPath $Catalog)) { throw "catalog file not found: $Catalog" }
        $Catalog = (Read-ReaTextFile -Path $Catalog).Text | ConvertFrom-Json
    }
    if ($Catalog -is [System.Collections.IEnumerable] -and -not ($Catalog -is [string])) { return @($Catalog) }
    if ($null -ne $Catalog.PSObject.Properties['tools']) { return @($Catalog.tools) }
    throw 'catalog is neither a tools array nor an object with a tools property'
}

function Compare-ReaCatalog {
    param(
        [Parameter(Mandatory)]$Previous,
        [Parameter(Mandatory)]$Current,
        [string[]]$Fields = @('description', 'inputSchema', 'outputSchema', 'annotations')
    )
    $prevTools = Get-ReaCatalogTools -Catalog $Previous
    $curTools = Get-ReaCatalogTools -Catalog $Current
    $prevMap = @{}
    foreach ($t in $prevTools) { $prevMap[[string]$t.name] = $t }
    $curMap = @{}
    foreach ($t in $curTools) { $curMap[[string]$t.name] = $t }
    $added = @($curMap.Keys | Where-Object { -not $prevMap.ContainsKey($_) } | Sort-Object)
    $removed = @($prevMap.Keys | Where-Object { -not $curMap.ContainsKey($_) } | Sort-Object)
    $changed = New-Object System.Collections.Generic.List[object]
    $unchanged = 0
    foreach ($name in @($curMap.Keys | Where-Object { $prevMap.ContainsKey($_) } | Sort-Object)) {
        $diffFields = New-Object System.Collections.Generic.List[string]
        foreach ($f in $Fields) {
            $pv = $null; $cv = $null
            if ($null -ne $prevMap[$name].PSObject.Properties[$f]) { $pv = $prevMap[$name].$f }
            if ($null -ne $curMap[$name].PSObject.Properties[$f]) { $cv = $curMap[$name].$f }
            if ((ConvertTo-ReaCanonicalJson $pv) -ne (ConvertTo-ReaCanonicalJson $cv)) { [void]$diffFields.Add($f) }
        }
        if ($diffFields.Count -gt 0) {
            [void]$changed.Add([pscustomobject]@{ name = $name; fields = @($diffFields.ToArray()) })
        } else {
            $unchanged++
        }
    }
    return [pscustomobject]@{
        previous_count  = $prevTools.Count
        current_count   = $curTools.Count
        added           = $added
        removed         = $removed
        changed         = @($changed.ToArray())
        unchanged_count = $unchanged
        identical       = ($added.Count -eq 0 -and $removed.Count -eq 0 -and $changed.Count -eq 0)
    }
}

# ----------------------------------------------------------------------------
# Referenced rea tool names in skills/ and docs/
# ----------------------------------------------------------------------------

function Get-ReaReferencedToolRegex {
    return 'mcp__rea__\w+|\b(analyze_javascript_application|trace_application_feature|inspect_managed_\w+|project_\w+_application_graph|inspect_android_\w+|search_android_classes|trace_android_references|list_browser_targets|inspect_web_page|analyze_web_bundle|capture_browser_scenario|inspect_web_network_capture|export_evidence_bundle|import_evidence_bundle|get_evidence_bundle|open_binary|inspect_artifact|close_binary)\b'
}

function Get-ReaReferencedToolNames {
    <# Mirrors `rg -o <regex> skills/ docs/`: rg when it is on PATH, otherwise Select-String
       over the git-visible files (tracked + untracked, .gitignore honoured) under the roots. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Roots = @('skills', 'docs'),
        [switch]$ForceSelectString
    )
    $regex = Get-ReaReferencedToolRegex
    $rootsAbs = @($Roots | ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ })
    $names = New-Object System.Collections.Generic.HashSet[string]
    $scanner = $null
    $fileCount = 0

    $rg = $null
    if (-not $ForceSelectString) { $rg = Get-Command rg -ErrorAction SilentlyContinue }
    if ($null -ne $rg) {
        $out = & $rg.Source -o --no-filename --no-line-number --no-messages -e $regex -- @rootsAbs 2>$null
        $code = $LASTEXITCODE
        if ($code -eq 0 -or $code -eq 1) {
            $scanner = 'rg'
            foreach ($line in @($out)) {
                $v = ([string]$line).Trim()
                if ($v) { [void]$names.Add(($v -replace '^mcp__rea__', '')) }
            }
        }
    }
    if ($null -eq $scanner) {
        $scanner = 'select-string'
        $files = @()
        $gitOk = $false
        try {
            $raw = & git -C $RepoRoot ls-files -z --cached --others --exclude-standard -- @Roots 2>$null
            if ($LASTEXITCODE -eq 0 -and $null -ne $raw) {
                $joined = ($raw -join '')
                $files = @($joined -split "`0" | Where-Object { $_ } | ForEach-Object { Join-Path $RepoRoot $_ })
                $gitOk = $true
            }
        } catch { $gitOk = $false }
        if (-not $gitOk) {
            $files = @(Get-ChildItem -LiteralPath $rootsAbs -Recurse -File | Where-Object { $_.Name -ne 'tool-index.md' -and $_.FullName -notmatch '__pycache__' } | ForEach-Object { $_.FullName })
        }
        $textExt = @('.md', '.json', '.ps1', '.py', '.sh', '.template', '.toml', '.yml', '.yaml', '.txt', '.psm1')
        foreach ($f in $files) {
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
            if ($textExt -notcontains ([System.IO.Path]::GetExtension($f).ToLowerInvariant())) { continue }
            $fileCount++
            $text = [System.IO.File]::ReadAllText($f)
            foreach ($m in [regex]::Matches($text, $regex)) {
                [void]$names.Add(($m.Value -replace '^mcp__rea__', ''))
            }
        }
    }
    return [pscustomobject]@{
        Scanner   = $scanner
        FileCount = $fileCount
        Names     = @($names | Sort-Object)
    }
}

# ----------------------------------------------------------------------------
# Client mirror entry location (.mcp.json / .codex/config.toml / .agents/mcp_config.json / dsh yml)
# ----------------------------------------------------------------------------

function Get-ReaMirrorDefinitions {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return @(
        [pscustomobject]@{ Name = 'claude';      Kind = 'json'; Path = (Join-Path $RepoRoot '.mcp.json') }
        [pscustomobject]@{ Name = 'codex';       Kind = 'toml'; Path = (Join-Path $RepoRoot '.codex\config.toml') }
        [pscustomobject]@{ Name = 'antigravity'; Kind = 'json'; Path = (Join-Path $RepoRoot '.agents\mcp_config.json') }
        [pscustomobject]@{ Name = 'dsh';         Kind = 'yml';  Path = (Join-Path $RepoRoot '.dsh\agent-presets\reverse-skill\agent.cordis.yml') }
    )
}

function Get-ReaMirrorEntryRange {
    <# Returns @{Start; End} (inclusive character indexes) of the rea entry, or $null. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('json', 'toml', 'yml')][string]$Kind
    )
    switch ($Kind) {
        'json' {
            $m = [regex]::Match($Text, '"rea"\s*:\s*\{')
            if (-not $m.Success) { return $null }
            $i = $m.Index + $m.Length - 1
            $depth = 0; $inStr = $false; $esc = $false
            for ($j = $i; $j -lt $Text.Length; $j++) {
                $c = $Text[$j]
                if ($inStr) {
                    if ($esc) { $esc = $false }
                    elseif ($c -eq '\') { $esc = $true }
                    elseif ($c -eq '"') { $inStr = $false }
                    continue
                }
                if ($c -eq '"') { $inStr = $true; continue }
                if ($c -eq '{') { $depth++; continue }
                if ($c -eq '}') {
                    $depth--
                    if ($depth -eq 0) { return @{ Start = $m.Index; End = $j } }
                }
            }
            throw 'unbalanced braces after "rea": in JSON mirror'
        }
        'toml' {
            $m = [regex]::Match($Text, '(?m)^\[mcp_servers\.(?:"rea"|rea)\][^\r\n]*')
            if (-not $m.Success) { return $null }
            $after = $m.Index + $m.Length
            $next = [regex]::Match($Text.Substring($after), '(?m)^\[')
            if ($next.Success) {
                $end = $after + $next.Index - 1
                # keep the newline(s) that separate the blocks outside the entry
                while ($end -gt $m.Index -and ($Text[$end] -eq "`n" -or $Text[$end] -eq "`r")) { $end-- }
                return @{ Start = $m.Index; End = $end }
            }
            return @{ Start = $m.Index; End = $Text.Length - 1 }
        }
        'yml' {
            $m = [regex]::Match($Text, '(?m)^([ \t]*)- id: mcp-rea[ \t]*\r?$')
            if (-not $m.Success) { return $null }
            $indent = $m.Groups[1].Value.Length
            $rest = $Text.Substring($m.Index)
            $lines = [regex]::Matches($rest, '(?m)^[^\r\n]*')
            $end = $Text.Length - 1
            for ($k = 1; $k -lt $lines.Count; $k++) {
                $lm = $lines[$k]
                $trimmed = $lm.Value.Trim()
                if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
                $lead = ($lm.Value.Length - $lm.Value.TrimStart(' ', "`t").Length)
                if ($lead -le $indent) {
                    $end = $m.Index + $lm.Index - 1
                    while ($end -gt $m.Index -and ($Text[$end] -eq "`n" -or $Text[$end] -eq "`r")) { $end-- }
                    break
                }
            }
            return @{ Start = $m.Index; End = $end }
        }
    }
}

function Update-ReaMirrorEntry {
    <# Rewrites rea-agents@<old> to rea-agents@<new> inside the rea entry only. Every byte
       outside the entry is preserved. Returns a status object; never throws for a missing entry. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('json', 'toml', 'yml')][string]$Kind,
        [Parameter(Mandatory)][string]$NewVersion,
        [switch]$WhatIf
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Path = $Path; Kind = $Kind; Status = 'missing-file'; OldVersion = $null; NewVersion = $NewVersion }
    }
    $file = Read-ReaTextFile -Path $Path
    $range = Get-ReaMirrorEntryRange -Text $file.Text -Kind $Kind
    if ($null -eq $range) {
        return [pscustomobject]@{ Path = $Path; Kind = $Kind; Status = 'no-entry'; OldVersion = $null; NewVersion = $NewVersion }
    }
    $len = $range.End - $range.Start + 1
    $segment = $file.Text.Substring($range.Start, $len)
    $hits = [regex]::Matches($segment, 'rea-agents@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)')
    if ($hits.Count -ne 1) {
        throw "rea entry in $Path must reference rea-agents@<version> exactly once (found $($hits.Count))"
    }
    $old = $hits[0].Groups[1].Value
    if ($old -eq $NewVersion) {
        return [pscustomobject]@{ Path = $Path; Kind = $Kind; Status = 'already'; OldVersion = $old; NewVersion = $NewVersion }
    }
    $newSegment = $segment.Substring(0, $hits[0].Index) + "rea-agents@$NewVersion" + $segment.Substring($hits[0].Index + $hits[0].Length)
    $newText = $file.Text.Substring(0, $range.Start) + $newSegment + $file.Text.Substring($range.End + 1)
    if ($Kind -eq 'json') {
        try { $null = $newText | ConvertFrom-Json } catch { throw "edited $Path would not parse as JSON: $($_.Exception.Message)" }
    }
    if (-not $WhatIf) { Write-ReaTextFile -Path $Path -Text $newText -Bom $file.Bom }
    return [pscustomobject]@{ Path = $Path; Kind = $Kind; Status = 'updated'; OldVersion = $old; NewVersion = $NewVersion }
}

# ----------------------------------------------------------------------------
# Anchored string edits for tracked files
# ----------------------------------------------------------------------------

function Test-ReaAnchoredEdits {
    <# Validates match counts without writing. Returns an array of problem strings (empty = ok).
       Edit = @{ Pattern; Replacement (null = check only); Expect (exact) | ExpectMin } #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Edits
    )
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) {
        [void]$problems.Add("missing file: $Path")
        return @($problems.ToArray())
    }
    $text = (Read-ReaTextFile -Path $Path).Text
    foreach ($e in $Edits) {
        $count = [regex]::Matches($text, [string]$e.Pattern).Count
        if ($e.ContainsKey('ExpectMin')) {
            if ($count -lt [int]$e.ExpectMin) { [void]$problems.Add("$Path`: pattern /$($e.Pattern)/ matched $count times, expected at least $($e.ExpectMin)") }
        } else {
            if ($count -ne [int]$e.Expect) { [void]$problems.Add("$Path`: pattern /$($e.Pattern)/ matched $count times, expected exactly $($e.Expect)") }
        }
    }
    return @($problems.ToArray())
}

function Invoke-ReaAnchoredEdits {
    <# Applies the replacement edits (Replacement not null) after Test-ReaAnchoredEdits passed.
       Returns the number of substitutions made. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Edits
    )
    $problems = @(Test-ReaAnchoredEdits -Path $Path -Edits $Edits)
    if ($problems.Count -gt 0) { throw ($problems -join "`n") }
    $file = Read-ReaTextFile -Path $Path
    $text = $file.Text
    $subs = 0
    foreach ($e in $Edits) {
        if ($null -eq $e.Replacement) { continue }
        $subs += [regex]::Matches($text, [string]$e.Pattern).Count
        $text = [regex]::Replace($text, [string]$e.Pattern, [string]$e.Replacement)
    }
    if ($text -ne $file.Text) { Write-ReaTextFile -Path $Path -Text $text -Bom $file.Bom }
    return $subs
}

function Get-ReaTrackedEditPlan {
    <# The per-file anchored edits for a tracked bump Old -> New. Counts (tool count, bytes in MB,
       prompt count) are rewritten when supplied, otherwise the existing numbers are kept. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$OldVersion,
        [Parameter(Mandatory)][string]$NewVersion,
        [AllowNull()][Nullable[int]]$ToolCount = $null,
        [AllowNull()][string]$BytesMb = $null,
        [AllowNull()][Nullable[int]]$PromptCount = $null
    )
    $o = [regex]::Escape($OldVersion)
    $n = $NewVersion
    $cnt = if ($null -ne $ToolCount) { [string]$ToolCount } else { '$1' }
    $mb = if (-not [string]::IsNullOrEmpty($BytesMb)) { $BytesMb } else { '$2' }
    $pc = if ($null -ne $PromptCount) { [string]$PromptCount } else { '$2' }
    # Full-width punctuation used by the Chinese notes/rows.
    $lp = [string][char]0xFF08   # （
    $rp = [string][char]0xFF09   # ）
    $fc = [string][char]0xFF1A   # ：
    $cm = [string][char]0xFF0C   # ，
    $ed = [string][char]0x3001   # 、

    $manifestEdits = @(
        @{ Pattern = ('"npmPackage": "rea-agents@{0}"' -f $o); Replacement = ('"npmPackage": "rea-agents@{0}"' -f $n); Expect = 1 }
        @{ Pattern = ('(?m)^(\s*)"rea-agents@{0}",' -f $o); Replacement = ('$1"rea-agents@{0}",' -f $n); Expect = 1 }
        @{ Pattern = ('"pinnedVersion": "{0}"' -f $o); Replacement = ('"pinnedVersion": "{0}"' -f $n); Expect = 1 }
        @{ Pattern = ('{1}{0}{2}(\d+) 个 MCP 工具{3}tools/list 约 ([0-9.]+) MB{4}' -f $o, $lp, $fc, $cm, $rp)
           Replacement = ('{1}{0}{2}{5} 个 MCP 工具{3}tools/list 约 {6} MB{4}' -f $n, $lp, $fc, $cm, $rp, $cnt, $mb); Expect = 1 }
        @{ Pattern = ('`npx -y rea-agents@{0} mcp`' -f $o); Replacement = ('`npx -y rea-agents@{0} mcp`' -f $n); Expect = 1 }
    )
    $plan = New-Object System.Collections.Generic.List[object]
    [void]$plan.Add(@{ Path = 'skills/scripts/bootstrap-manifest.json'; Edits = $manifestEdits; Json = $true })
    [void]$plan.Add(@{ Path = 'kali/scripts/bootstrap-manifest.json'; Edits = $manifestEdits; Json = $true })
    [void]$plan.Add(@{ Path = 'skills/scripts/lib/ToolDiscovery.ps1'; Edits = @(
        @{ Pattern = ("FixedVersion = 'rea-agents@{0}'" -f $o); Replacement = ("FixedVersion = 'rea-agents@{0}'" -f $n); Expect = 1 }
    ) })
    [void]$plan.Add(@{ Path = 'RULES.md'; Edits = @(
        @{ Pattern = ('reverse-engineer-anything {0} \((\d+) MCP tools\)' -f $o); Replacement = ('reverse-engineer-anything {0} ({1} MCP tools)' -f $n, $cnt); Expect = 1 }
        @{ Pattern = ('`npx -y rea-agents@{0} mcp`' -f $o); Replacement = ('`npx -y rea-agents@{0} mcp`' -f $n); Expect = 1 }
    ) })
    [void]$plan.Add(@{ Path = 'RULES_zh.md'; Edits = @(
        @{ Pattern = ('reverse-engineer-anything {0}{1}(\d+) 个 MCP 工具{2}' -f $o, $lp, $rp); Replacement = ('reverse-engineer-anything {0}{1}{3} 个 MCP 工具{2}' -f $n, $lp, $rp, $cnt); Expect = 1 }
        @{ Pattern = ('`npx -y rea-agents@{0} mcp`' -f $o); Replacement = ('`npx -y rea-agents@{0} mcp`' -f $n); Expect = 1 }
    ) })
    [void]$plan.Add(@{ Path = 'skills/js-reverse/SKILL.md'; Edits = @(
        @{ Pattern = 'rea 可用'; Replacement = $null; ExpectMin = 1 }
        @{ Pattern = ('reverse-engineer-anything {0}' -f $o); Replacement = ('reverse-engineer-anything {0}' -f $n); Expect = 1 }
    ) })
    foreach ($skill in @('dotnet-reverse', 'macos-reverse', 'apk-reverse', 'browser-extension-reverse')) {
        [void]$plan.Add(@{ Path = "skills/$skill/SKILL.md"; Edits = @(
            @{ Pattern = 'rea 可用'; Replacement = $null; ExpectMin = 1 }
            @{ Pattern = ('(?<![\d.]){0}(?![\d.])' -f $o); Replacement = $null; Expect = 0 }
        ) })
    }
    [void]$plan.Add(@{ Path = 'skills/ops/evidence-finding-path.md'; Edits = @(
        @{ Pattern = ('rea-agents {0}' -f $o); Replacement = ('rea-agents {0}' -f $n); Expect = 2 }
    ) })
    [void]$plan.Add(@{ Path = 'skills/references/community-security-skills.md'; Edits = @(
        @{ Pattern = ('rea-agents {0}{1}接入日期' -f $o, $cm); Replacement = ('rea-agents {0}{1}接入日期' -f $n, $cm); Expect = 1 }
        @{ Pattern = ('`rea-agents@{0}`' -f $o); Replacement = ('`rea-agents@{0}`' -f $n); Expect = 1 }
        @{ Pattern = ('{0}(\d+) 个 MCP 工具{1}(\d+) 个 prompt{2}' -f $lp, $ed, $rp); Replacement = ('{0}{3} 个 MCP 工具{1}{4} 个 prompt{2}' -f $lp, $ed, $rp, $cnt, $pc); Expect = 1 }
    ) })
    # rea.md: the pin line and the four registration-shape code blocks (two JSON, one TOML, one
    # YAML) follow the pin; the dated facts-table rows (`--version`, `"rea-agents@X" "mcp"`
    # without a comma, `-y rea-agents@X mcp`) are history and are deliberately not matched.
    [void]$plan.Add(@{ Path = 'docs/mcp/rea.md'; Edits = @(
        @{ Pattern = ('Current pin: \*\*rea-agents@{0}\*\*' -f $o); Replacement = ('Current pin: **rea-agents@{0}**' -f $n); Expect = 1 }
        @{ Pattern = ('"rea-agents@{0}", "mcp"\]' -f $o); Replacement = ('"rea-agents@{0}", "mcp"]' -f $n); Expect = 2 }
        @{ Pattern = ("'rea-agents@{0}', 'mcp'\]" -f $o); Replacement = ("'rea-agents@{0}', 'mcp']" -f $n); Expect = 1 }
        @{ Pattern = ('(?m)^([ \t]+)- rea-agents@{0}[ \t]*$' -f $o); Replacement = ('$1- rea-agents@{0}' -f $n); Expect = 1 }
    ) })
    return @($plan.ToArray())
}

function Add-ReaBumpLogRow {
    <# Appends a row to the "## Bump log" table that closes docs/mcp/rea.md. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][string]$OldVersion,
        [Parameter(Mandatory)][string]$NewVersion,
        [AllowNull()][string]$ToolCounts,
        [AllowNull()][string]$ToolsListSha256,
        [AllowNull()][string]$Note
    )
    $file = Read-ReaTextFile -Path $Path
    if ($file.Text -notmatch '(?m)^## Bump log\s*$') { throw "$Path has no '## Bump log' section" }
    $tail = $file.Text.Substring($file.Text.LastIndexOf('## Bump log'))
    if ($tail -notmatch '(?m)^\|\s*Date\s*\|') { throw "$Path bump log has no table header" }
    $tc = if ($ToolCounts) { $ToolCounts } else { '-' }
    $sha = if ($ToolsListSha256) { '`' + $ToolsListSha256 + '`' } else { '-' }
    $nt = if ($Note) { $Note -replace '\|', '\|' } else { 'update-rea.ps1 Tracked' }
    $arrow = [string][char]0x2192
    $row = ('| {0} | {1} {2} {3} | {4} | {5} | {6} |' -f $Date, $OldVersion, $arrow, $NewVersion, $tc, $sha, $nt)
    $nl = if ($file.Text -match "`r`n") { "`r`n" } else { "`n" }
    $text = $file.Text
    if (-not $text.EndsWith("`n")) { $text += $nl }
    $text += $row + $nl
    Write-ReaTextFile -Path $Path -Text $text -Bom $file.Bom
    return $row
}

# ----------------------------------------------------------------------------
# Contract report gate
# ----------------------------------------------------------------------------

function Read-ReaContractReport {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "contract report not found: $Path" }
    return ((Read-ReaTextFile -Path $Path).Text | ConvertFrom-Json)
}

function Test-ReaContractReport {
    <# Returns problem strings; empty means the report is a passing report for $Version. #>
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Version
    )
    $problems = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Report.PSObject.Properties['version'] -or [string]$Report.version -ne $Version) {
        [void]$problems.Add("report version '$($Report.version)' does not match requested version '$Version'")
    }
    if ($null -eq $Report.PSObject.Properties['passed'] -or $Report.passed -ne $true) {
        [void]$problems.Add('report.passed is not true')
    }
    if ($null -eq $Report.PSObject.Properties['tool_count'] -or [int]$Report.tool_count -lt 1) {
        [void]$problems.Add('report.tool_count is missing or zero')
    }
    if ($null -ne $Report.PSObject.Properties['referenced_tools'] -and $null -ne $Report.referenced_tools) {
        $missing = @($Report.referenced_tools.missing)
        if ($missing.Count -gt 0) { [void]$problems.Add("report lists missing referenced tools: $($missing -join ', ')") }
    } else {
        [void]$problems.Add('report has no referenced_tools section')
    }
    return @($problems.ToArray())
}
