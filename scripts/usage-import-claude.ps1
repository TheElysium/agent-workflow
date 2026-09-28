#Requires -Version 7.5

[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture

$ErrorActionPreference = 'Stop'

function Get-DefaultProjectsDir {
    return Join-Path $HOME '.claude' 'projects'
}

function Get-StringOrDefault {
    param($Value, [string]$Default)
    if ($null -eq $Value) { return $Default }
    return [string]$Value
}

function Get-NumberOrDefault {
    param($Value, [long]$Default)
    if ($null -eq $Value) { return $Default }
    return [long]$Value
}

function Get-NormalizedTimestamp {
    param([string]$Timestamp)
    return $Timestamp -replace '\.[0-9]+Z$', 'Z'
}

function Get-SortKey {
    param([string]$Timestamp)
    if ($Timestamp -match '(?<base>[^.]+)\.(?<frac>[0-9]+)Z$') {
        $frac = ($Matches['frac'] + '000000').Substring(0, 6)
        return "$($Matches['base']).$frac"
    }
    $stripped = $Timestamp -replace 'Z$', ''
    return "$stripped.000000"
}

function Get-SinceMark {
    param([Parameter(Mandatory)][string]$MetaPath, [Parameter(Mandatory)][string]$Session)
    if (-not (Test-Path -LiteralPath $MetaPath)) { return '' }
    foreach ($line in Get-Content -LiteralPath $MetaPath) {
        $parts = $line.Split("`t", 2)
        if ($parts.Length -ge 1 -and [string]::Equals($parts[0], $Session, [StringComparison]::Ordinal)) {
            if ($parts.Length -ge 2) { return $parts[1] }
            return ''
        }
    }
    return ''
}

function Write-MetaMark {
    param([Parameter(Mandatory)][string]$MetaPath, [Parameter(Mandatory)][string]$Session, [Parameter(Mandatory)][string]$MaxTs)
    $existing = @()
    if (Test-Path -LiteralPath $MetaPath) {
        $existing = @(Get-Content -LiteralPath $MetaPath)
    }
    $prefix = "$Session`t"
    $kept = @($existing | Where-Object { -not $_.StartsWith($prefix, [StringComparison]::Ordinal) })
    $newLines = $kept + "$Session`t$MaxTs"
    $tempPath = "$MetaPath.tmp"
    $content = ($newLines -join "`n") + "`n"
    [IO.File]::WriteAllText($tempPath, $content, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $MetaPath -Force
}

function Add-TextLineWithRetry {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Line)
    $encoding = [Text.UTF8Encoding]::new($false)
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            [IO.File]::AppendAllText($Path, "$Line`n", $encoding)
            return
        } catch [IO.IOException] {
            if ($attempt -eq $maxAttempts) { throw }
            Start-Sleep -Milliseconds (20 * $attempt)
        }
    }
}

function Get-RoleFromSidechain {
    param($IsSidechain)
    if ($IsSidechain -eq $true) { return 'subagent' }
    if ($IsSidechain -eq $false) { return 'primary' }
    return 'unknown'
}

function Import-TranscriptFile {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$FallbackSession)
    $records = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $FilePath) {
        $recordObject = $null
        try {
            $recordObject = $line | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        } catch {
            continue
        }
        if ($null -eq $recordObject) { continue }
        if ($recordObject['type'] -cne 'assistant') { continue }
        $message = $recordObject['message']
        if ($null -eq $message) { continue }
        if (($null -eq $message['id']) -or ($null -eq $message['usage'])) { continue }

        $usage = $message['usage']
        $timestamp = [string]$recordObject['timestamp']

        $fields = [ordered]@{
            ts          = Get-NormalizedTimestamp -Timestamp $timestamp
            harness     = 'claude'
            session     = Get-StringOrDefault -Value $recordObject['sessionId'] -Default $FallbackSession
            msg         = [string]$message['id']
            role        = Get-RoleFromSidechain -IsSidechain $recordObject['isSidechain']
            model       = Get-StringOrDefault -Value $message['model'] -Default 'unknown'
            tokens_in   = Get-NumberOrDefault -Value $usage['input_tokens'] -Default 0
            tokens_out  = Get-NumberOrDefault -Value $usage['output_tokens'] -Default 0
            cache_read  = Get-NumberOrDefault -Value $usage['cache_read_input_tokens'] -Default 0
            cache_write = Get-NumberOrDefault -Value $usage['cache_creation_input_tokens'] -Default 0
        }

        $records.Add([PSCustomObject]@{
                Fields  = $fields
                SortKey = Get-SortKey -Timestamp $timestamp
                Index   = $records.Count
            })
    }
    return $records
}

function Select-DedupedRecord {
    param([Collections.Generic.List[object]]$Records, [string]$Since)

    $filtered = @($Records | Where-Object { [string]::CompareOrdinal($_.SortKey, $Since) -gt 0 })
    if ($filtered.Count -eq 0) {
        return [PSCustomObject]@{ Lines = @(); MaxTs = '' }
    }

    $maxTs = $filtered[0].SortKey
    foreach ($record in $filtered) {
        if ([string]::CompareOrdinal($record.SortKey, $maxTs) -gt 0) { $maxTs = $record.SortKey }
    }

    $winners = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $order = [Collections.Generic.List[string]]::new()
    foreach ($record in $filtered) {
        $key = $record.Fields['msg']
        if (-not $winners.ContainsKey($key)) {
            $winners[$key] = $record
            $order.Add($key)
            continue
        }
        $current = $winners[$key]
        $comparison = [string]::CompareOrdinal($record.SortKey, $current.SortKey)
        if ($comparison -gt 0 -or ($comparison -eq 0 -and $record.Index -gt $current.Index)) {
            $winners[$key] = $record
        }
    }

    $sortedKeys = [string[]]$order.ToArray()
    [Array]::Sort($sortedKeys, [StringComparer]::Ordinal)

    $lines = @(foreach ($key in $sortedKeys) {
            $winners[$key].Fields | ConvertTo-Json -Compress -Depth 5
        })

    return [PSCustomObject]@{ Lines = $lines; MaxTs = $maxTs }
}

function Get-RequiredArgValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$ArgList, [Parameter(Mandatory)][int]$Index, [Parameter(Mandatory)][string]$Name)
    if ($Index + 1 -ge $ArgList.Count) {
        [Console]::Error.WriteLine("usage-import-claude.ps1: missing value for '$Name'")
        exit 1
    }
    return $ArgList[$Index + 1]
}

$dirArg = $null
$projectArg = ''
$outArg = '.usage/usage.jsonl'

$i = 0
while ($i -lt $args.Count) {
    $token = $args[$i]
    switch -CaseSensitive ($token) {
        '--dir' { $dirArg = Get-RequiredArgValue -ArgList $args -Index $i -Name $token; $i += 2 }
        '--project' { $projectArg = Get-RequiredArgValue -ArgList $args -Index $i -Name $token; $i += 2 }
        '--out' { $outArg = Get-RequiredArgValue -ArgList $args -Index $i -Name $token; $i += 2 }
        default {
            [Console]::Error.WriteLine("usage-import-claude.ps1: unknown arg '$token'")
            exit 1
        }
    }
}

if ([string]::IsNullOrEmpty($dirArg)) { $dirArg = Get-DefaultProjectsDir }

if ([string]::IsNullOrEmpty($projectArg)) {
    [Console]::Error.WriteLine('usage-import-claude.ps1: --project is required')
    exit 1
}

$src = [IO.Path]::Join($dirArg, $projectArg)
if (-not (Test-Path -LiteralPath $src -PathType Container)) {
    [Console]::Error.WriteLine("usage-import-claude.ps1: no transcript dir: $src")
    exit 1
}

$outParent = Split-Path -Path $outArg -Parent
if ($outParent) {
    New-Item -ItemType Directory -Force -Path $outParent | Out-Null
}

$metaPath = if ($outArg.EndsWith('.jsonl', [StringComparison]::Ordinal)) {
    $outArg.Substring(0, $outArg.Length - 6) + '.meta'
} else {
    $outArg + '.meta'
}

foreach ($path in @($outArg, $metaPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        [IO.File]::WriteAllText($path, '', [Text.UTF8Encoding]::new($false))
    }
}

$transcriptFiles = @(Get-ChildItem -LiteralPath $src -Filter '*.jsonl' -File)
if ($transcriptFiles.Count -eq 0) {
    exit 0
}

$names = [string[]]($transcriptFiles | ForEach-Object { $_.Name })
[Array]::Sort($names, [StringComparer]::Ordinal)

foreach ($name in $names) {
    $filePath = Join-Path $src $name
    $session = if ($name.EndsWith('.jsonl', [StringComparison]::Ordinal)) {
        $name.Substring(0, $name.Length - 6)
    } else {
        $name
    }

    $since = Get-SinceMark -MetaPath $metaPath -Session $session
    $records = Import-TranscriptFile -FilePath $filePath -FallbackSession $session
    $result = Select-DedupedRecord -Records $records -Since $since

    foreach ($line in $result.Lines) {
        Add-TextLineWithRetry -Path $outArg -Line $line
    }

    if ($env:USAGE_IMPORT_DEBUG) {
        $debugPath = Join-Path (Get-Location).Path ".usage-import-debug-$session.jsonl"
        $debugContent = if ($result.Lines.Count -gt 0) { ($result.Lines -join "`n") + "`n" } else { '' }
        [IO.File]::WriteAllText($debugPath, $debugContent, [Text.UTF8Encoding]::new($false))
    }

    if (-not [string]::IsNullOrEmpty($result.MaxTs)) {
        Write-MetaMark -MetaPath $metaPath -Session $session -MaxTs $result.MaxTs
    }
}

exit 0
