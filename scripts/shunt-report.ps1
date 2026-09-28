#Requires -Version 7.5

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.NewLine = "`n"
[Console]::Error.NewLine = "`n"
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture
$ErrorActionPreference = 'Stop'

$script:NullGroupKey = "$([char]0)null"

function Get-JqGroupKey {
    param($Value)
    if ($null -eq $Value) { return $script:NullGroupKey }
    return [string]$Value
}

function Write-Breakdown {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records, [Parameter(Mandatory)][scriptblock]$KeySelector)
    $counts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($record in $Records) {
        $key = & $KeySelector $record
        if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
    }
    $keys = [string[]]@($counts.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($key in $keys) {
        $displayKey = if ($key -ceq $script:NullGroupKey) { 'null' } else { $key }
        [Console]::Out.WriteLine("  ${displayKey}: $($counts[$key])")
    }
}

function Get-TopEntry {
    param([Parameter(Mandatory)][Collections.Generic.Dictionary[string, int]]$Counts, [Parameter(Mandatory)][int]$Limit)
    $keys = [string[]]@($Counts.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $items = foreach ($key in $keys) { [PSCustomObject]@{ Key = $key; Count = $Counts[$key] } }
    $sorted = @($items | Sort-Object -Property Count -Descending -Stable)
    return @($sorted | Select-Object -First $Limit)
}

$file = '.usage/shunt.jsonl'
$since = ''
$session = ''

$index = 0
while ($index -lt $args.Length) {
    $arg = $args[$index]
    switch -CaseSensitive ($arg) {
        { $_ -cin @('--file', '--since', '--session') } {
            if ($index + 1 -ge $args.Length) {
                [Console]::Error.WriteLine("shunt-report.ps1: $arg requires a value")
                exit 1
            }
        }
    }
    switch -CaseSensitive ($arg) {
        '--file' { $file = $args[$index + 1]; $index += 2 }
        '--since' { $since = $args[$index + 1]; $index += 2 }
        '--session' { $session = $args[$index + 1]; $index += 2 }
        default {
            [Console]::Error.WriteLine("shunt-report.ps1: unknown arg '$arg'")
            exit 1
        }
    }
}

if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
    [Console]::Error.WriteLine("shunt-report.ps1: no sink: $file")
    exit 1
}

$resolvedFile = (Resolve-Path -LiteralPath $file).ProviderPath
$bytes = [IO.File]::ReadAllBytes($resolvedFile)
$text = [Text.Encoding]::UTF8.GetString($bytes)
$lines = @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 })

$parsedRecords = [Collections.Generic.List[object]]::new()
foreach ($line in $lines) {
    try {
        $parsedRecords.Add((ConvertFrom-Json -InputObject $line -AsHashtable -DateKind String))
    } catch {
        [Console]::Error.WriteLine("shunt-report.ps1: invalid json in $($file): $($_.Exception.Message)")
        exit 5
    }
}

$records = [Collections.Generic.List[object]]::new()
foreach ($record in $parsedRecords) {
    if ([string]::CompareOrdinal([string]$record['ts'], $since) -le 0) { continue }
    if ($session -ne '' -and -not [string]::Equals([string]$record['session'], $session, [StringComparison]::Ordinal)) { continue }
    $decision = if ($null -ne $record['decision']) { [string]$record['decision'] } else { 'deny' }
    $record['DecisionResolved'] = $decision
    $records.Add($record)
}

$allow = @($records | Where-Object { $_['DecisionResolved'] -ceq 'allow' })
$deny = @($records | Where-Object { $_['DecisionResolved'] -ceq 'deny' })

[Console]::Out.WriteLine("records: $($records.Count)")
[Console]::Out.WriteLine("allowed: $($allow.Count)")
[Console]::Out.WriteLine("blocked: $($deny.Count)")
[Console]::Out.WriteLine('by decision/reason:')
Write-Breakdown -Records $records -KeySelector { param($record) "$($record['DecisionResolved'])/$($record['reason'])" }
[Console]::Out.WriteLine('by harness:')
Write-Breakdown -Records $records -KeySelector { param($record) Get-JqGroupKey -Value $record['harness'] }
[Console]::Out.WriteLine('by tool:')
Write-Breakdown -Records $records -KeySelector { param($record) Get-JqGroupKey -Value $record['tool'] }

[Console]::Out.WriteLine('top blocked files:')
$blockedCounts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
foreach ($record in $deny) {
    if ($null -eq $record['path']) { continue }
    $path = [string]$record['path']
    if ($blockedCounts.ContainsKey($path)) { $blockedCounts[$path]++ } else { $blockedCounts[$path] = 1 }
}
foreach ($entry in (Get-TopEntry -Counts $blockedCounts -Limit 10)) {
    [Console]::Out.WriteLine("  $($entry.Count)x  $($entry.Key)")
}

[Console]::Out.WriteLine('top allowed commands:')
$seenCalls = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$commandCounts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
foreach ($record in $allow) {
    if ($null -eq $record['command']) { continue }
    $command = [string]$record['command']
    $callKey = "$([string]$record['ts'])$([char]1)$([string]$record['session'])$([char]1)$command"
    if (-not $seenCalls.Add($callKey)) { continue }
    if ($commandCounts.ContainsKey($command)) { $commandCounts[$command]++ } else { $commandCounts[$command] = 1 }
}
foreach ($entry in (Get-TopEntry -Counts $commandCounts -Limit 10)) {
    $displayCommand = $entry.Key -replace "`n", '\n'
    [Console]::Out.WriteLine("  $($entry.Count)x  $displayCommand")
}

exit 0
