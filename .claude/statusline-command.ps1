#Requires -Version 7.5

function Get-StringOrDefault {
    param($Value, [string]$Default)
    if ($null -eq $Value) { return $Default }
    return [string]$Value
}

function Get-Bar {
    param([int]$FilledCount, [int]$EmptyCount)
    $filledChar = [string][char]0x2588
    $emptyChar = [string][char]0x2591
    return ($filledChar * $FilledCount) + ($emptyChar * $EmptyCount)
}

function Get-EmptyBar {
    return Get-Bar -FilledCount 0 -EmptyCount 20
}

function Format-Duration {
    param([double]$Milliseconds)
    $totalSeconds = [long][math]::Floor($Milliseconds / 1000)
    $hours = [long][math]::Floor($totalSeconds / 3600)
    $minutes = [long][math]::Floor(($totalSeconds % 3600) / 60)
    $seconds = $totalSeconds % 60
    if ($hours -gt 0) {
        return '{0}h{1:D2}m' -f $hours, $minutes
    }
    return '{0}m{1:D2}s' -f $minutes, $seconds
}

function Test-CompactBoundaryLine {
    param([string]$Line)
    return $Line.Contains('"subtype":"compact_boundary"')
}

function Test-RealUserRound {
    param([string]$Line)
    $recordObject = $null
    try {
        $recordObject = $Line | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
    } catch {
        return $false
    }
    if ($null -eq $recordObject) { return $false }
    if ($recordObject['type'] -cne 'user') { return $false }
    $message = $recordObject['message']
    if ($null -eq $message) { return $false }
    if (-not ($message['content'] -is [string])) { return $false }
    if ($recordObject['isCompactSummary'] -eq $true) { return $false }
    return $true
}

function Write-Status {
    param([string]$Text)
    [Console]::Out.Write($Text)
}

function Get-TokensSuffix {
    param($TotalTokens)
    if ($null -eq $TotalTokens) { return '' }
    return " | $([long]$TotalTokens) tokens"
}

function Get-SessionSuffix {
    param($FiveHourRemaining)
    if ($null -eq $FiveHourRemaining) { return '' }
    $fiveHourInt = [long][math]::Round([double]$FiveHourRemaining)
    return " | session: ${fiveHourInt}% left"
}

function Get-DurationSuffix {
    param($SessionDurationMs)
    if ($null -eq $SessionDurationMs) { return '' }
    return " | $(Format-Duration -Milliseconds ([double]$SessionDurationMs))"
}

function Get-RoundsSuffix {
    param($Rounds)
    if ($null -eq $Rounds) { return '' }
    return " | $Rounds rounds"
}

function Get-CompactionsSuffix {
    param($Compactions)
    if ($null -eq $Compactions) { return '' }
    return " | $Compactions compact"
}

function Get-TranscriptCount {
    param([string]$TranscriptPath)
    $result = [PSCustomObject]@{ Compactions = $null; Rounds = $null }
    if (-not ($TranscriptPath -and (Test-Path -LiteralPath $TranscriptPath -PathType Leaf))) {
        return $result
    }
    $transcriptLines = @()
    try {
        $transcriptLines = @(Get-Content -LiteralPath $TranscriptPath)
    } catch {
        $transcriptLines = @()
    }
    $result.Compactions = @($transcriptLines | Where-Object { Test-CompactBoundaryLine -Line $_ }).Count
    $result.Rounds = @($transcriptLines | Where-Object { Test-RealUserRound -Line $_ }).Count
    return $result
}

function Format-StatusLine {
    param($StatusJson)
    $model = Get-StringOrDefault -Value $StatusJson.model.display_name -Default 'Unknown'
    $used = $StatusJson.context_window.used_percentage
    $totalTokens = $StatusJson.context_window.total_input_tokens
    $fiveHourUsed = $StatusJson.rate_limits.five_hour.used_percentage
    $fiveHourRemaining = if ($null -ne $fiveHourUsed) { 100 - [double]$fiveHourUsed } else { $null }
    $sessionDurationMs = $StatusJson.cost.total_duration_ms
    $transcriptPath = $StatusJson.transcript_path

    $counts = Get-TranscriptCount -TranscriptPath $transcriptPath

    if ($null -eq $used) {
        return "$model  [$(Get-EmptyBar)] -"
    }

    $usedInt = [long][math]::Round([double]$used)
    $filled = [long][math]::Floor($usedInt / 5)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt 20) { $filled = 20 }
    $bar = Get-Bar -FilledCount $filled -EmptyCount (20 - $filled)

    $esc = [char]0x1B
    $green = "$esc[0;32m"
    $red = "$esc[0;31m"
    $reset = "$esc[0m"
    $color = if ($usedInt -ge 50) { $red } else { $green }

    $tokensStr = Get-TokensSuffix -TotalTokens $totalTokens
    $sessionStr = Get-SessionSuffix -FiveHourRemaining $fiveHourRemaining
    $durationStr = Get-DurationSuffix -SessionDurationMs $sessionDurationMs
    $roundsStr = Get-RoundsSuffix -Rounds $counts.Rounds
    $compactionsStr = Get-CompactionsSuffix -Compactions $counts.Compactions

    return "$model  $color[$bar] $usedInt%$reset$tokensStr$sessionStr$durationStr$roundsStr$compactionsStr"
}

$ErrorActionPreference = 'Stop'

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture

    $rawInput = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        throw [FormatException]::new('empty statusline input')
    }
    $statusJson = ConvertFrom-Json -InputObject $rawInput -DateKind String

    Write-Status (Format-StatusLine -StatusJson $statusJson)
} catch {
    Write-Status "  [$(Get-EmptyBar)] -"
}

exit 0
