#Requires -Version 7.5

$script:NewlineChar = [char]10
$script:EmDash = [char]0x2014

function Get-ShuntThreshold {
    param([string]$EnvValue, [long]$Default)
    if ($EnvValue -notmatch '\A[0-9]+\z') { return $Default }
    $parsed = 0L
    $ok = [long]::TryParse($EnvValue, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)
    if (-not $ok) { return $Default }
    if ($parsed -gt 0) { return $parsed }
    return $Default
}

function ConvertTo-ShuntJsonString {
    param([string]$Value)
    $sb = [Text.StringBuilder]::new($Value.Length + 2)
    [void]$sb.Append('"')
    foreach ($ch in [char[]]$Value) {
        $code = [int]$ch
        switch ($code) {
            34 { [void]$sb.Append('\"') }
            92 { [void]$sb.Append('\\') }
            8 { [void]$sb.Append('\b') }
            12 { [void]$sb.Append('\f') }
            10 { [void]$sb.Append('\n') }
            13 { [void]$sb.Append('\r') }
            9 { [void]$sb.Append('\t') }
            default {
                if ($code -lt 0x20) {
                    [void]$sb.Append([string]::Format([Globalization.CultureInfo]::InvariantCulture, '\u{0:x4}', $code))
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-ShuntJsonValue {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [byte] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    return ConvertTo-ShuntJsonString ([string]$Value)
}

function Get-ShuntJqOrEmpty {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool] -and $Value -eq $false) { return '' }
    return [string]$Value
}

function Get-ShuntJqOrNull {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool] -and $Value -eq $false) { return $null }
    return $Value
}

function Resolve-ShuntWindowsPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if (-not $IsWindows) { return $Path }
    if ($Path -match '^[A-Za-z]:[\\/]') { return $Path }
    if ($Path -match '^/([A-Za-z])(/.*)?$') {
        $drive = $Matches[1].ToUpperInvariant()
        $rest = if ($Matches[2]) { $Matches[2].Replace('/', '\') } else { '\' }
        return "$drive`:$rest"
    }
    if ($Path -match '^\\\\') { return $Path }
    if ($Path -match '^[\\/~]') { return $null }
    return $Path
}

function Get-ShuntLineCount {
    param([string]$Path)
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $buffer = [byte[]]::new(65536)
        $count = 0L
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            for ($i = 0; $i -lt $read; $i++) {
                if ($buffer[$i] -eq 10) { $count++ }
            }
        }
        return $count
    } catch {
        return 0L
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-ShuntRedirectReason {
    param([string]$DisplayPath, [string]$Why)
    $l1 = "BLOCKED by shunt: `"$DisplayPath`" has $Why."
    $l2 = "Do NOT read this file directly $script:EmDash delegate I/O instead:"
    $l3 = '  - For analysis/questions across files (incl. minified JSON): use the task tool with subagent "bulk-reader" (pass file paths + your question; you only consume the summary).'
    $l4 = '  - For boilerplate generation: use the task tool with subagent "code-writer" (pass spec + reference file + target path).'
    $l5 = "  - If you must edit a specific section of this file, do a targeted read with BOTH offset and limit (an offset alone reads the unbounded rest of the file) $script:EmDash that is allowed."
    return ($l1, $l2, $l3, $l4, $l5) -join $script:NewlineChar
}

function Test-ShuntFile {
    param([string]$RawPath, [long]$MaxBytes, [long]$MinLines)
    $resolved = Resolve-ShuntWindowsPath -Path $RawPath
    if ($null -eq $resolved) {
        return [PSCustomObject]@{ Reason = 'missing'; Bytes = $null; Lines = $null; Deny = $false; Message = $null }
    }
    try {
        if ([IO.Directory]::Exists($resolved)) {
            return [PSCustomObject]@{ Reason = 'missing'; Bytes = $null; Lines = $null; Deny = $false; Message = $null }
        }
        $fileInfo = [IO.FileInfo]::new($resolved)
        if (-not $fileInfo.Exists) {
            return [PSCustomObject]@{ Reason = 'missing'; Bytes = $null; Lines = $null; Deny = $false; Message = $null }
        }
    } catch {
        return [PSCustomObject]@{ Reason = 'missing'; Bytes = $null; Lines = $null; Deny = $false; Message = $null }
    }
    $bytes = [long]$fileInfo.Length
    if ($bytes -gt $MaxBytes) {
        $bytesKb = [long][math]::Floor($bytes / 1024)
        $maxKb = [long][math]::Floor($MaxBytes / 1024)
        $why = "$bytesKb KB (threshold: $maxKb KB)"
        $message = Get-ShuntRedirectReason -DisplayPath $RawPath -Why $why
        return [PSCustomObject]@{ Reason = 'bytes'; Bytes = $bytes; Lines = $null; Deny = $true; Message = $message }
    }
    if ($bytes -eq 0) {
        return [PSCustomObject]@{ Reason = 'under_threshold'; Bytes = 0L; Lines = $null; Deny = $false; Message = $null }
    }
    $lines = Get-ShuntLineCount -Path $fileInfo.FullName
    if ($lines -gt $MinLines) {
        $why = "$lines lines (threshold: $MinLines)"
        $message = Get-ShuntRedirectReason -DisplayPath $RawPath -Why $why
        return [PSCustomObject]@{ Reason = 'lines'; Bytes = $bytes; Lines = $lines; Deny = $true; Message = $message }
    }
    return [PSCustomObject]@{ Reason = 'under_threshold'; Bytes = $bytes; Lines = $lines; Deny = $false; Message = $null }
}

function Get-ShuntUnquotedValue {
    param([string]$Value)
    if ($Value.Length -lt 2) { return $Value }
    $first = $Value[0]
    $last = $Value[$Value.Length - 1]
    if (($first -eq '"' -or $first -eq "'") -and $first -eq $last) {
        return $Value.Substring(1, $Value.Length - 2)
    }
    return $Value
}

function Test-ShuntBoundedSed {
    param([string[]]$ArgList)
    $hasN = $false
    foreach ($arg in $ArgList) {
        if ($arg -ceq '-n' -or $arg -ceq '--quiet' -or $arg -ceq '--silent') { $hasN = $true }
        $stripped = Get-ShuntUnquotedValue -Value $arg
        if ($stripped.Contains('$')) { return $false }
    }
    if (-not $hasN) { return $false }
    foreach ($arg in $ArgList) {
        $stripped = Get-ShuntUnquotedValue -Value $arg
        if ($stripped -cmatch '^[0-9]+(,[0-9]+)?p$') { return $true }
    }
    return $false
}

function Test-ShuntBoundedHeadTail {
    param([string[]]$ArgList)
    $next = $false
    foreach ($arg in $ArgList) {
        if ($next) {
            return ($arg -cmatch '^[0-9]+$')
        }
        if ($arg -ceq '-n' -or $arg -ceq '-c') {
            $next = $true
            continue
        }
        if ($arg -cmatch '^-[nc][0-9]') {
            $val = $arg.Substring(2)
            return ($val -cmatch '^[0-9]+$')
        }
    }
    return $false
}

function Split-ShuntCommandToken {
    param([string]$Command)
    $trimmed = $Command.Trim(' ', "`t")
    if ($trimmed.Length -eq 0) { return @() }
    return @($trimmed -split '[ \t]+')
}

function Write-ShuntDenyOutput {
    param([string]$Reason)
    $json = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":' + (ConvertTo-ShuntJsonValue $Reason) + '}}'
    [Console]::Out.Write($json + $script:NewlineChar)
}

function Write-ShuntTelemetryLine {
    param([string]$SinkPath, [string]$Line)
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            [IO.File]::AppendAllText($SinkPath, $Line + $script:NewlineChar, $utf8NoBom)
            return
        } catch [IO.IOException] {
            if ($attempt -eq $maxAttempts) { return }
            Start-Sleep -Milliseconds 20
        } catch {
            return
        }
    }
}

function Write-ShuntTelemetry {
    param(
        [hashtable]$ParsedInput,
        [long]$MaxBytes,
        [long]$MinLines,
        [string]$Tool,
        [string]$Decision,
        [string]$Reason,
        [string]$Path,
        $Bytes,
        $Lines
    )
    try {
        $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        $sessionValue = if ($ParsedInput.ContainsKey('session_id')) { $ParsedInput['session_id'] } else { $null }
        $pathValue = if ([string]::IsNullOrEmpty($Path)) { $null } else { $Path }
        $toolInput = if ($ParsedInput.ContainsKey('tool_input') -and $ParsedInput['tool_input'] -is [hashtable]) { $ParsedInput['tool_input'] } else { @{} }

        $sb = [Text.StringBuilder]::new()
        [void]$sb.Append('{"ts":').Append((ConvertTo-ShuntJsonValue $ts))
        [void]$sb.Append(',"harness":').Append((ConvertTo-ShuntJsonValue 'claude'))
        [void]$sb.Append(',"session":').Append((ConvertTo-ShuntJsonValue $sessionValue))
        [void]$sb.Append(',"tool":').Append((ConvertTo-ShuntJsonValue $Tool))
        [void]$sb.Append(',"decision":').Append((ConvertTo-ShuntJsonValue $Decision))
        [void]$sb.Append(',"reason":').Append((ConvertTo-ShuntJsonValue $Reason))
        [void]$sb.Append(',"path":').Append((ConvertTo-ShuntJsonValue $pathValue))
        [void]$sb.Append(',"bytes":').Append((ConvertTo-ShuntJsonValue $Bytes))
        [void]$sb.Append(',"lines":').Append((ConvertTo-ShuntJsonValue $Lines))
        [void]$sb.Append(',"threshold_bytes":').Append((ConvertTo-ShuntJsonValue $MaxBytes))
        [void]$sb.Append(',"threshold_lines":').Append((ConvertTo-ShuntJsonValue $MinLines))
        if ($Tool -eq 'bash') {
            $commandValue = ''
            if ($toolInput.ContainsKey('command') -and $null -ne $toolInput['command']) {
                $commandValue = $toolInput['command']
            }
            [void]$sb.Append(',"command":').Append((ConvertTo-ShuntJsonValue $commandValue))
        } else {
            $offsetValue = Get-ShuntJqOrNull $toolInput['offset']
            $limitValue = Get-ShuntJqOrNull $toolInput['limit']
            [void]$sb.Append(',"offset":').Append((ConvertTo-ShuntJsonValue $offsetValue))
            [void]$sb.Append(',"limit":').Append((ConvertTo-ShuntJsonValue $limitValue))
        }
        [void]$sb.Append('}')
        $line = $sb.ToString()

        $sinkDir = Join-Path (Get-Location).Path '.usage'
        New-Item -ItemType Directory -Path $sinkDir -Force -ErrorAction Stop | Out-Null
        $sinkPath = Join-Path $sinkDir 'shunt.jsonl'
        Write-ShuntTelemetryLine -SinkPath $sinkPath -Line $line
    } catch {
        return
    }
}

function Get-ShuntTelemetrySink {
    param([hashtable]$ParsedInput, [long]$MaxBytes, [long]$MinLines)
    $capturedInput = $ParsedInput
    $capturedMaxBytes = $MaxBytes
    $capturedMinLines = $MinLines
    $writeTelemetry = ${function:Write-ShuntTelemetry}
    return {
        param([string]$Tool, [string]$Decision, [string]$Reason, [string]$Path, $Bytes, $Lines)
        & $writeTelemetry -ParsedInput $capturedInput -MaxBytes $capturedMaxBytes -MinLines $capturedMinLines -Tool $Tool -Decision $Decision -Reason $Reason -Path $Path -Bytes $Bytes -Lines $Lines
    }.GetNewClosure()
}

function Invoke-ShuntReadTool {
    param([hashtable]$ToolInput, [long]$MaxBytes, [long]$MinLines, [scriptblock]$Sink)
    $filePath = if ($ToolInput.ContainsKey('file_path')) { [string]$ToolInput['file_path'] } else { $null }
    if ([string]::IsNullOrEmpty($filePath)) {
        & $Sink 'read' 'allow' 'no_input' '' $null $null
        return
    }
    $offsetStr = Get-ShuntJqOrEmpty $ToolInput['offset']
    $limitStr = Get-ShuntJqOrEmpty $ToolInput['limit']
    $hasOffset = ($offsetStr -cne '') -and ($offsetStr -cne 'null')
    $hasLimit = ($limitStr -cne '') -and ($limitStr -cne 'null')
    if ($hasOffset -and $hasLimit) {
        & $Sink 'read' 'allow' 'targeted' $filePath $null $null
        return
    }
    $result = Test-ShuntFile -RawPath $filePath -MaxBytes $MaxBytes -MinLines $MinLines
    if ($result.Deny) {
        & $Sink 'read' 'deny' $result.Reason $filePath $result.Bytes $result.Lines
        Write-ShuntDenyOutput -Reason $result.Message
        return
    }
    & $Sink 'read' 'allow' $result.Reason $filePath $result.Bytes $result.Lines
}

function Test-ShuntBoundedRead {
    param([string]$Verb, [string[]]$ArgList)
    if ($Verb -ceq 'sed') { return Test-ShuntBoundedSed -ArgList $ArgList }
    if ($Verb -ceq 'head' -or $Verb -ceq 'tail') { return Test-ShuntBoundedHeadTail -ArgList $ArgList }
    return $false
}

function Invoke-ShuntBashTool {
    param([hashtable]$ToolInput, [long]$MaxBytes, [long]$MinLines, [scriptblock]$Sink)
    $cmd = if ($ToolInput.ContainsKey('command')) { [string]$ToolInput['command'] } else { '' }
    $cmd = $cmd.TrimEnd($script:NewlineChar)
    if ([string]::IsNullOrEmpty($cmd)) {
        & $Sink 'bash' 'allow' 'no_input' '' $null $null
        return
    }
    if ($cmd -match '[|>;`&]' -or $cmd.Contains($script:NewlineChar)) {
        & $Sink 'bash' 'allow' 'compound' '' $null $null
        return
    }
    if ($cmd -cnotmatch '^[ \t\r\f\v]*(cat|head|tail|less|more|bat|grep|sed|awk|rg|xxd|base64|strings)([ \t\r\f\v]|$)') {
        & $Sink 'bash' 'allow' 'verb' '' $null $null
        return
    }

    $tokens = @(Split-ShuntCommandToken -Command $cmd)
    $verb = if ($tokens.Count -gt 0) { $tokens[0] } else { '' }
    $argList = if ($tokens.Count -gt 1) { $tokens[1..($tokens.Count - 1)] } else { @() }

    if (Test-ShuntBoundedRead -Verb $verb -ArgList $argList) {
        & $Sink 'bash' 'allow' 'bounded' '' $null $null
        return
    }

    $fileCount = 0
    foreach ($arg in $argList) {
        if ($arg.StartsWith('-', [StringComparison]::Ordinal)) { continue }
        $fileCount++
        $result = Test-ShuntFile -RawPath $arg -MaxBytes $MaxBytes -MinLines $MinLines
        if ($result.Deny) {
            & $Sink 'bash' 'deny' $result.Reason $arg $result.Bytes $result.Lines
            Write-ShuntDenyOutput -Reason $result.Message
            return
        }
        & $Sink 'bash' 'allow' $result.Reason $arg $result.Bytes $result.Lines
    }
    if ($fileCount -eq 0) {
        & $Sink 'bash' 'allow' 'no_input' '' $null $null
    }
}

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture

    $minLines = Get-ShuntThreshold -EnvValue $env:SHUNT_MIN_LINES -Default 350
    $maxBytes = Get-ShuntThreshold -EnvValue $env:SHUNT_MAX_BYTES -Default 65536

    $rawInput = [Console]::In.ReadToEnd()
    if ($rawInput.TrimStart().StartsWith('[', [StringComparison]::Ordinal)) {
        exit 0
    }
    $parsed = $rawInput | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String

    $agentId = Get-ShuntJqOrEmpty $parsed['agent_id']
    $toolName = if ($parsed.ContainsKey('tool_name')) { [string]$parsed['tool_name'] } else { '' }
    $toolInput = if ($parsed.ContainsKey('tool_input') -and $parsed['tool_input'] -is [hashtable]) { $parsed['tool_input'] } else { @{} }

    $sink = Get-ShuntTelemetrySink -ParsedInput $parsed -MaxBytes $maxBytes -MinLines $minLines

    if (-not [string]::IsNullOrEmpty($agentId)) {
        switch -CaseSensitive ($toolName) {
            'Read' {
                $filePath = if ($toolInput.ContainsKey('file_path')) { [string]$toolInput['file_path'] } else { '' }
                & $sink 'read' 'allow' 'subagent' $filePath $null $null
            }
            'Bash' {
                & $sink 'bash' 'allow' 'subagent' '' $null $null
            }
        }
        exit 0
    }

    switch -CaseSensitive ($toolName) {
        'Read' { Invoke-ShuntReadTool -ToolInput $toolInput -MaxBytes $maxBytes -MinLines $minLines -Sink $sink }
        'Bash' { Invoke-ShuntBashTool -ToolInput $toolInput -MaxBytes $maxBytes -MinLines $minLines -Sink $sink }
    }

    exit 0
} catch {
    exit 0
}
