#Requires -Version 7.5

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.NewLine = "`n"
[Console]::Error.NewLine = "`n"
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture
$ErrorActionPreference = 'Stop'

function Get-TokenSum {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records, [Parameter(Mandatory)][string]$Field)
    $sum = 0L
    foreach ($record in $Records) {
        $value = $record[$Field]
        if ($null -ne $value) { $sum += [long]$value }
    }
    return $sum
}

$file = '.usage/usage.jsonl'
$since = ''
$session = ''

$index = 0
while ($index -lt $args.Length) {
    $arg = $args[$index]
    switch -CaseSensitive ($arg) {
        { $_ -cin @('--file', '--since', '--session') } {
            if ($index + 1 -ge $args.Length) {
                [Console]::Error.WriteLine("usage-report.ps1: $arg requires a value")
                exit 1
            }
        }
    }
    switch -CaseSensitive ($arg) {
        '--file' { $file = $args[$index + 1]; $index += 2 }
        '--since' { $since = $args[$index + 1]; $index += 2 }
        '--session' { $session = $args[$index + 1]; $index += 2 }
        default {
            [Console]::Error.WriteLine("usage-report.ps1: unknown arg '$arg'")
            exit 1
        }
    }
}

if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
    [Console]::Error.WriteLine("usage-report.ps1: no sink: $file")
    exit 1
}

$resolvedFile = (Resolve-Path -LiteralPath $file).ProviderPath
$bytes = [IO.File]::ReadAllBytes($resolvedFile)
$raw = ($bytes -eq 10).Count
$text = [Text.Encoding]::UTF8.GetString($bytes)
$lines = @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 })

$parsedRecords = [Collections.Generic.List[object]]::new()
foreach ($line in $lines) {
    try {
        $parsedRecords.Add((ConvertFrom-Json -InputObject $line -AsHashtable -DateKind String))
    } catch {
        [Console]::Error.WriteLine("usage-report.ps1: invalid json in $($file): $($_.Exception.Message)")
        exit 5
    }
}

$groups = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
foreach ($record in $parsedRecords) {
    if ([string]::CompareOrdinal([string]$record['ts'], $since) -le 0) { continue }
    if ($session -ne '' -and -not [string]::Equals([string]$record['session'], $session, [StringComparison]::Ordinal)) { continue }
    $key = "$($record['harness'])$([char]1)$($record['session'])$([char]1)$($record['msg'])"
    $groups[$key] = $record
}

$recs = @($groups.Values)
$primary = @($recs | Where-Object { $_['role'] -ceq 'primary' })
$subagent = @($recs | Where-Object { $_['role'] -ceq 'subagent' })
$unknown = @($recs | Where-Object { $_['role'] -cne 'primary' -and $_['role'] -cne 'subagent' })

[Console]::Out.WriteLine("records: $($recs.Count) (deduped from $raw)")
$primaryIn = Get-TokenSum -Records $primary -Field 'tokens_in'
$primaryOut = Get-TokenSum -Records $primary -Field 'tokens_out'
$cacheRead = Get-TokenSum -Records $primary -Field 'cache_read'
$cacheWrite = Get-TokenSum -Records $primary -Field 'cache_write'
[Console]::Out.WriteLine("primary: $primaryIn in / $primaryOut out   (cache_read $cacheRead, cache_write $cacheWrite)")
$subIn = Get-TokenSum -Records $subagent -Field 'tokens_in'
$subOut = Get-TokenSum -Records $subagent -Field 'tokens_out'
$subCacheRead = Get-TokenSum -Records $subagent -Field 'cache_read'
$subCacheWrite = Get-TokenSum -Records $subagent -Field 'cache_write'
[Console]::Out.WriteLine("subagent: $subIn in / $subOut out   (cache_read $subCacheRead, cache_write $subCacheWrite)")
$unkIn = Get-TokenSum -Records $unknown -Field 'tokens_in'
$unkOut = Get-TokenSum -Records $unknown -Field 'tokens_out'
[Console]::Out.WriteLine("unknown: $unkIn in / $unkOut out")
[Console]::Out.WriteLine('by model:')

$script:NullModelKey = "$([char]0)null"
$modelGroups = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
foreach ($record in ($primary + $subagent + $unknown)) {
    $modelRaw = $record['model']
    $modelKey = if ($null -eq $modelRaw) { $script:NullModelKey } else { [string]$modelRaw }
    if (-not $modelGroups.Contains($modelKey)) { $modelGroups[$modelKey] = [Collections.Generic.List[object]]::new() }
    $modelGroups[$modelKey].Add($record)
}
$modelNames = [string[]]@($modelGroups.Keys)
[Array]::Sort($modelNames, [StringComparer]::Ordinal)
foreach ($modelName in $modelNames) {
    $modelIn = Get-TokenSum -Records $modelGroups[$modelName] -Field 'tokens_in'
    $modelOut = Get-TokenSum -Records $modelGroups[$modelName] -Field 'tokens_out'
    $displayName = if ($modelName -ceq $script:NullModelKey) { 'null' } else { $modelName }
    [Console]::Out.WriteLine("  ${displayName}: $modelIn in / $modelOut out")
}

exit 0
