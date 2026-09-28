#Requires -Version 7.5

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.NewLine = "`n"
[Console]::Error.NewLine = "`n"
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture
$ErrorActionPreference = 'Stop'

$script:FailurePattern = 'BLOCKED|error TS|Error:|FAIL(?!=0(?![0-9]))|(?<![^0-9]0 )(?<!^0 )failed|non-zero|[Ee]xit code [1-9]'

function Show-Usage {
    [Console]::Error.WriteLine('usage: session-tools.ps1 <session.jsonl> [--thread <label>] [--cut <ISO-8601-Z>] [--subagents <dir>] [--summary]')
}

function Write-UsageError {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("session-tools.ps1: $Message")
    Show-Usage
}

function Get-TsvField {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value.Replace('\', '\\')
    $escaped = $escaped.Replace("`t", '\t')
    $escaped = $escaped.Replace("`n", '\n')
    $escaped = $escaped.Replace("`r", '\r')
    return $escaped
}

function Get-TruncatedText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Length)
    $codepoints = [Collections.Generic.List[Text.Rune]]::new()
    foreach ($rune in $Text.EnumerateRunes()) { $codepoints.Add($rune) }
    if ($codepoints.Count -le $Length) { return $Text }
    $builder = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Length; $i++) { $null = $builder.Append($codepoints[$i].ToString()) }
    return $builder.ToString()
}

function Get-FlatText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, '[\t\n\r]+', ' ')
}

function Get-ToolText {
    param($Content)
    if ($Content -is [string]) { return $Content }
    if ($Content -is [array]) {
        $parts = foreach ($item in $Content) {
            if ($item['type'] -ceq 'text') {
                if ($null -ne $item['text']) { [string]$item['text'] } else { '' }
            }
        }
        return ($parts -join ' ')
    }
    if ($null -eq $Content) { return 'null' }
    return (ConvertTo-Json -InputObject $Content -Compress -Depth 20)
}

function Test-Flaggable {
    param([string]$Name)
    return ($Name -ceq 'Bash' -or $Name -ceq 'PowerShell')
}

function Test-FailureText {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    return [regex]::IsMatch($Text, $script:FailurePattern)
}

function Get-InputField {
    param($ToolInput, [Parameter(Mandatory)][string]$Field, [string]$Default = '')
    if ($null -eq $ToolInput) { return $Default }
    $value = $ToolInput[$Field]
    if ($null -ne $value) { return [string]$value }
    return $Default
}

function Get-BashSummary {
    param($ToolInput)
    return Get-InputField -ToolInput $ToolInput -Field 'command'
}

function Get-ReadSummary {
    param($ToolInput)
    $filePath = Get-InputField -ToolInput $ToolInput -Field 'file_path'
    if ($null -eq $ToolInput -or ($null -eq $ToolInput['offset'] -and $null -eq $ToolInput['limit'])) { return $filePath }
    $offsetText = Get-InputField -ToolInput $ToolInput -Field 'offset' -Default '-'
    $limitText = Get-InputField -ToolInput $ToolInput -Field 'limit' -Default '-'
    return "$filePath [offset=$offsetText limit=$limitText]"
}

function Get-FilePathSummary {
    param($ToolInput)
    return Get-InputField -ToolInput $ToolInput -Field 'file_path'
}

function Get-GrepSummary {
    param($ToolInput)
    $pattern = Get-InputField -ToolInput $ToolInput -Field 'pattern'
    $path = Get-InputField -ToolInput $ToolInput -Field 'path'
    $glob = Get-InputField -ToolInput $ToolInput -Field 'glob'
    return "pattern=$pattern path=$path glob=$glob"
}

function Get-GlobSummary {
    param($ToolInput)
    $pattern = Get-InputField -ToolInput $ToolInput -Field 'pattern'
    $path = Get-InputField -ToolInput $ToolInput -Field 'path'
    return "pattern=$pattern path=$path"
}

function Get-AgentSummary {
    param($ToolInput)
    $subagentType = Get-InputField -ToolInput $ToolInput -Field 'subagent_type'
    $description = Get-InputField -ToolInput $ToolInput -Field 'description'
    return "$subagentType | $description"
}

function Get-AskUserQuestionSummary {
    param($ToolInput)
    $questions = if ($null -eq $ToolInput) { $null } else { $ToolInput['questions'] }
    if ($null -eq $questions) { $questions = @() }
    $headers = foreach ($question in @($questions)) { Get-InputField -ToolInput $question -Field 'header' }
    return ($headers -join ', ')
}

function Get-ToolSearchSummary {
    param($ToolInput)
    return Get-InputField -ToolInput $ToolInput -Field 'query'
}

function Get-FallbackSummary {
    param($ToolInput)
    if ($null -eq $ToolInput) { return 'null' }
    return (ConvertTo-Json -InputObject $ToolInput -Compress -Depth 20)
}

$script:ToolSummaryHandlers = [Collections.Generic.Dictionary[string, scriptblock]]::new([StringComparer]::Ordinal)
$script:ToolSummaryHandlers['Bash'] = { param($ToolInput) Get-BashSummary -ToolInput $ToolInput }
$script:ToolSummaryHandlers['PowerShell'] = { param($ToolInput) Get-BashSummary -ToolInput $ToolInput }
$script:ToolSummaryHandlers['Read'] = { param($ToolInput) Get-ReadSummary -ToolInput $ToolInput }
$script:ToolSummaryHandlers['Edit'] = { param($ToolInput) Get-FilePathSummary -ToolInput $ToolInput }
$script:ToolSummaryHandlers['Write'] = { param($ToolInput) Get-FilePathSummary -ToolInput $ToolInput }
$script:ToolSummaryHandlers['Grep'] = { param($ToolInput) Get-GrepSummary -ToolInput $ToolInput }
$script:ToolSummaryHandlers['Glob'] = { param($ToolInput) Get-GlobSummary -ToolInput $ToolInput }
$script:ToolSummaryHandlers['Agent'] = { param($ToolInput) Get-AgentSummary -ToolInput $ToolInput }
$script:ToolSummaryHandlers['AskUserQuestion'] = { param($ToolInput) Get-AskUserQuestionSummary -ToolInput $ToolInput }
$script:ToolSummaryHandlers['ToolSearch'] = { param($ToolInput) Get-ToolSearchSummary -ToolInput $ToolInput }

function Get-ToolSummary {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, $ToolInput)
    $handler = $null
    if ($script:ToolSummaryHandlers.TryGetValue($Name, [ref]$handler)) { return (& $handler $ToolInput) }
    return Get-FallbackSummary -ToolInput $ToolInput
}

function Get-CallStatus {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [Parameter(Mandatory)]$Outcome)
    if ($Outcome.err) { return 'ERROR' }
    if ((Test-Flaggable -Name $Name) -and (Test-FailureText -Text $Outcome.text)) { return 'FLAG' }
    return ''
}

function Get-JsonLineRecord {
    param([Parameter(Mandatory)][string]$Path)
    $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $bytes = [IO.File]::ReadAllBytes($resolvedPath)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $lines = @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
    $records = [Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        try {
            $records.Add((ConvertFrom-Json -InputObject $line -AsHashtable -DateKind String))
        } catch {
            [Console]::Error.WriteLine("session-tools.ps1: invalid json in $($Path): $($_.Exception.Message)")
            exit 5
        }
    }
    return $records
}

function Get-TranscriptRecord {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Label, [Parameter(Mandatory)][AllowEmptyString()][string]$Cut)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($record in (Get-JsonLineRecord -Path $Path)) {
        if ($record['type'] -ceq 'assistant' -and $Cut -ne '') {
            $timestamp = if ($null -ne $record['timestamp']) { [string]$record['timestamp'] } else { '' }
            $tsPrefix = Get-TruncatedText -Text $timestamp -Length 19
            $cutPrefix = Get-TruncatedText -Text $Cut -Length 19
            if ([string]::CompareOrdinal($tsPrefix, $cutPrefix) -ge 0) { continue }
        }
        $record['_thread'] = $Label
        $result.Add($record)
    }
    return $result
}

function Get-SubagentLabel {
    param([Parameter(Mandatory)][string]$AgentFile)
    $leaf = Split-Path -Path $AgentFile -Leaf
    $label = $leaf -replace '\.jsonl$', ''
    $metaPath = ($AgentFile -replace '\.jsonl$', '') + '.meta.json'
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
        try {
            $resolvedMetaPath = (Resolve-Path -LiteralPath $metaPath).ProviderPath
            $metaBytes = [IO.File]::ReadAllBytes($resolvedMetaPath)
            $metaText = [Text.Encoding]::UTF8.GetString($metaBytes)
            $metaObject = ConvertFrom-Json -InputObject $metaText -AsHashtable -DateKind String
            if ($null -ne $metaObject['agentType'] -and [string]$metaObject['agentType'] -ne '') {
                $label = [string]$metaObject['agentType']
            }
        } catch {
            $null = $_
        }
    }
    return $label
}

$transcript = ''
$thread = 'main'
$cut = ''
$subagents = ''
$summary = $false

$argIndex = 0
while ($argIndex -lt $args.Length) {
    $arg = $args[$argIndex]
    if ($arg -ceq '--thread' -or $arg -ceq '--cut' -or $arg -ceq '--subagents') {
        if ($argIndex + 1 -ge $args.Length) { Write-UsageError -Message "$arg requires a value"; exit 1 }
        $value = $args[$argIndex + 1]
        switch -CaseSensitive ($arg) {
            '--thread' { $thread = $value }
            '--cut' { $cut = $value }
            '--subagents' { $subagents = $value }
        }
        $argIndex += 2
        continue
    }
    if ($arg -ceq '--summary') { $summary = $true; $argIndex++; continue }
    if ($arg -ceq '-h' -or $arg -ceq '--help') { Show-Usage; exit 0 }
    if ($arg.StartsWith('-', [StringComparison]::Ordinal)) { Write-UsageError -Message "unknown option '$arg'"; exit 1 }
    if ($transcript -ne '') { Write-UsageError -Message "unexpected argument '$arg'"; exit 1 }
    $transcript = $arg
    $argIndex++
}

if ($transcript -eq '') { Write-UsageError -Message 'missing transcript argument'; exit 1 }

if (-not (Test-Path -LiteralPath $transcript -PathType Leaf)) {
    [Console]::Error.WriteLine("session-tools.ps1: transcript not found: $transcript")
    exit 1
}

$allRecords = [Collections.Generic.List[object]]::new()
foreach ($record in (Get-TranscriptRecord -Path $transcript -Label $thread -Cut $cut)) { $allRecords.Add($record) }

if ($subagents -ne '') {
    if (Test-Path -LiteralPath $subagents -PathType Container) {
        $agentFiles = [string[]]@(Get-ChildItem -LiteralPath $subagents -Filter 'agent-*.jsonl' -File -Force |
                Where-Object { $_.Name -cmatch '^agent-.*\.jsonl$' } |
                ForEach-Object { $_.FullName })
        [Array]::Sort($agentFiles, [StringComparer]::Ordinal)
        foreach ($agentFile in $agentFiles) {
            $label = Get-SubagentLabel -AgentFile $agentFile
            foreach ($record in (Get-TranscriptRecord -Path $agentFile -Label $label -Cut $cut)) { $allRecords.Add($record) }
        }
    } else {
        [Console]::Error.WriteLine("session-tools.ps1: subagents dir not found, skipped: $subagents")
    }
}

function Get-MessageContent {
    param($Record)
    $message = $Record['message']
    if ($null -eq $message) { return $null }
    $content = $message['content']
    if ($content -is [array]) { return , $content }
    return $content
}

$allCalls = [Collections.Generic.List[object]]::new()
foreach ($record in $allRecords) {
    if ($record['type'] -cne 'assistant') { continue }
    $content = Get-MessageContent -Record $record
    if ($content -isnot [array]) { continue }
    foreach ($item in $content) {
        if ($item['type'] -cne 'tool_use') { continue }
        $allCalls.Add([PSCustomObject]@{
                id     = [string]$item['id']
                ts     = if ($null -ne $record['timestamp']) { [string]$record['timestamp'] } else { '' }
                thread = [string]$record['_thread']
                name   = [string]$item['name']
                input  = $item['input']
            })
    }
}

$results = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($record in $allRecords) {
    if ($record['type'] -cne 'user') { continue }
    $content = Get-MessageContent -Record $record
    if ($content -isnot [array]) { continue }
    foreach ($item in $content) {
        if ($item['type'] -cne 'tool_result') { continue }
        $err = [bool]$item['is_error']
        $text = Get-ToolText -Content $item['content']
        $results[[string]$item['tool_use_id']] = [PSCustomObject]@{ err = $err; text = $text }
    }
}

$callGroups = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
foreach ($call in $allCalls) {
    $key = "$($call.thread)$([char]1)$($call.id)"
    if (-not $callGroups.Contains($key)) { $callGroups[$key] = $call }
}
$sortedCallKeys = [string[]]@($callGroups.Keys)
[Array]::Sort($sortedCallKeys, [StringComparer]::Ordinal)
$uniqueCalls = @(foreach ($key in $sortedCallKeys) { $callGroups[$key] })
$tsSelector = [Func[object, string]] { param($call) $call.ts }
$calls = @([Linq.Enumerable]::OrderBy($uniqueCalls, $tsSelector, [StringComparer]::Ordinal))

function Get-CallOutcome {
    param($Call)
    if ($results.ContainsKey($Call.id)) { return $results[$Call.id] }
    return [PSCustomObject]@{ err = $false; text = '' }
}

$logLines = [Collections.Generic.List[string]]::new()
foreach ($call in $calls) {
    $outcome = Get-CallOutcome -Call $call
    $status = Get-CallStatus -Name $call.name -Outcome $outcome
    $summaryText = Get-TruncatedText -Text (Get-FlatText -Text (Get-ToolSummary -Name $call.name -ToolInput $call.input)) -Length 240
    $timePart = ''
    if ($call.ts.Length -gt 11) {
        $timePart = Get-TruncatedText -Text $call.ts.Substring(11) -Length 8
    }
    $errorText = if ($status -ne '') { Get-TruncatedText -Text (Get-FlatText -Text $outcome.text) -Length 200 } else { '' }
    $tsvFields = @($call.thread, $timePart, $call.name, $summaryText, $status, $errorText) | ForEach-Object { Get-TsvField -Value $_ }
    $logLines.Add(($tsvFields -join "`t"))
}

if (-not $summary) {
    if ($logLines.Count -gt 0) { [Console]::Out.WriteLine(($logLines -join "`n")) }
    exit 0
}

$toolCountGroups = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
foreach ($call in $calls) {
    $key = "$($call.thread)$([char]1)$($call.name)"
    if (-not $toolCountGroups.Contains($key)) {
        $toolCountGroups[$key] = [PSCustomObject]@{ Thread = $call.thread; Name = $call.name; Count = 0 }
    }
    $toolCountGroups[$key].Count++
}
$toolCountKeys = [string[]]@($toolCountGroups.Keys)
[Array]::Sort($toolCountKeys, [StringComparer]::Ordinal)
$toolCountLines = @(foreach ($key in $toolCountKeys) {
        $group = $toolCountGroups[$key]
        "$(Get-TsvField -Value $group.Thread)`t$(Get-TsvField -Value $group.Name)`t$($group.Count)"
    })

$callStatsByThread = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
foreach ($call in $calls) {
    if (-not $callStatsByThread.Contains($call.thread)) {
        $callStatsByThread[$call.thread] = [PSCustomObject]@{ Calls = 0; Errors = 0; Flags = 0 }
    }
    $stat = $callStatsByThread[$call.thread]
    $stat.Calls++
    $outcome = Get-CallOutcome -Call $call
    $status = Get-CallStatus -Name $call.name -Outcome $outcome
    if ($status -ceq 'ERROR') { $stat.Errors++ }
    if ($status -ceq 'FLAG') { $stat.Flags++ }
}

$assistantStatsByThread = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
foreach ($record in $allRecords) {
    if ($record['type'] -cne 'assistant') { continue }
    $threadName = [string]$record['_thread']
    if (-not $assistantStatsByThread.Contains($threadName)) {
        $assistantStatsByThread[$threadName] = [PSCustomObject]@{ Turns = 0; Input = 0L; Output = 0L; CWrite = 0L; CRead = 0L }
    }
    $stat = $assistantStatsByThread[$threadName]
    $stat.Turns++
    $message = $record['message']
    $usage = if ($null -eq $message) { $null } else { $message['usage'] }
    if ($null -ne $usage) {
        if ($null -ne $usage['input_tokens']) { $stat.Input += [long]$usage['input_tokens'] }
        if ($null -ne $usage['output_tokens']) { $stat.Output += [long]$usage['output_tokens'] }
        if ($null -ne $usage['cache_creation_input_tokens']) { $stat.CWrite += [long]$usage['cache_creation_input_tokens'] }
        if ($null -ne $usage['cache_read_input_tokens']) { $stat.CRead += [long]$usage['cache_read_input_tokens'] }
    }
}

$totalsKeys = [string[]]@($assistantStatsByThread.Keys)
[Array]::Sort($totalsKeys, [StringComparer]::Ordinal)
$totalsLines = @(foreach ($threadName in $totalsKeys) {
        $ut = $assistantStatsByThread[$threadName]
        $ct = if ($callStatsByThread.Contains($threadName)) { $callStatsByThread[$threadName] } else { [PSCustomObject]@{ Calls = 0; Errors = 0; Flags = 0 } }
        $totalVolume = $ut.Input + $ut.Output + $ut.CWrite + $ut.CRead
        "$(Get-TsvField -Value $threadName)`t$($ct.Calls)`t$($ct.Errors)`t$($ct.Flags)`t$($ut.Turns)`t$($ut.Input)`t$($ut.Output)`t$($ut.CWrite)`t$($ut.CRead)`t$totalVolume"
    })

$toolCountsText = $toolCountLines -join "`n"
$totalsText = $totalsLines -join "`n"

if ($logLines.Count -gt 0) {
    [Console]::Out.WriteLine(($logLines -join "`n"))
    if ($toolCountsText -ne '' -or $totalsText -ne '') { [Console]::Out.WriteLine('') }
}

if ($toolCountsText -ne '') {
    [Console]::Out.WriteLine("thread`ttool`tcount")
    [Console]::Out.WriteLine($toolCountsText)
}

if ($totalsText -ne '') {
    if ($toolCountsText -ne '') { [Console]::Out.WriteLine('') }
    [Console]::Out.WriteLine("thread`tcalls`terrors`tflags`tassistant_turns`tinput_tokens`toutput_tokens`tcache_creation_input_tokens`tcache_read_input_tokens`tbilled_volume")
    [Console]::Out.WriteLine($totalsText)
}

exit 0
