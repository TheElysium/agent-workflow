#Requires -Version 7.5

BeforeAll {
    $script:HookSource = Join-Path $PSScriptRoot 'shunt.ps1'
    $script:PwshCmd = (Get-Command pwsh).Source
    $script:TempDirs = [System.Collections.Generic.List[string]]::new()

    function Get-ShuntFixtureDir {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("shunt-test-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $dir | Out-Null
        $script:TempDirs.Add($dir)
        $utf8NoBom = [Text.UTF8Encoding]::new($false)

        $bigLines = 1..400 | ForEach-Object { "line $_ of the big file" }
        [IO.File]::WriteAllText((Join-Path $dir 'big.txt'), (($bigLines -join "`n") + "`n"), $utf8NoBom)

        $smallLines = 1..10 | ForEach-Object { "line $_" }
        [IO.File]::WriteAllText((Join-Path $dir 'small.txt'), (($smallLines -join "`n") + "`n"), $utf8NoBom)

        $small2Lines = 1..5 | ForEach-Object { "other $_" }
        [IO.File]::WriteAllText((Join-Path $dir 'small2.txt'), (($small2Lines -join "`n") + "`n"), $utf8NoBom)

        [IO.File]::WriteAllText((Join-Path $dir 'empty.txt'), '', $utf8NoBom)

        [IO.File]::WriteAllText((Join-Path $dir 'fat.json'), ('x' * 70000), $utf8NoBom)

        New-Item -ItemType Directory -Path (Join-Path $dir 'a-directory') | Out-Null

        $noTrailingLines = 1..351 | ForEach-Object { "row $_" }
        [IO.File]::WriteAllText((Join-Path $dir 'no-trailing-newline.txt'), ($noTrailingLines -join "`n"), $utf8NoBom)

        return $dir
    }

    function Get-ShuntInputJson {
        param(
            [Parameter(Mandatory)][string]$ToolName,
            [hashtable]$ToolInput = @{},
            [hashtable]$Extra
        )
        $obj = [ordered]@{
            session_id      = 's1'
            hook_event_name = 'PreToolUse'
            tool_name       = $ToolName
            tool_input      = $ToolInput
        }
        if ($Extra) {
            foreach ($key in $Extra.Keys) { $obj[$key] = $Extra[$key] }
        }
        return ($obj | ConvertTo-Json -Depth 10 -Compress)
    }

    function Invoke-ShuntHook {
        param(
            [Parameter(Mandatory)][string]$WorkingDirectory,
            [Parameter(Mandatory)][AllowEmptyString()][string]$InputJson,
            [hashtable]$EnvVars
        )
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:PwshCmd
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($script:HookSource)
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        if ($EnvVars) {
            foreach ($key in $EnvVars.Keys) { $psi.EnvironmentVariables[$key] = $EnvVars[$key] }
        }
        $proc = [Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Write($InputJson)
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
        }
    }

    function Test-ShuntDeny {
        param([Parameter(Mandatory)][PSCustomObject]$Result)
        if ([string]::IsNullOrWhiteSpace($Result.StdOut)) { return $false }
        try {
            $parsed = $Result.StdOut | ConvertFrom-Json
            return ($parsed.hookSpecificOutput.permissionDecision -eq 'deny')
        } catch {
            return $false
        }
    }

    function Get-ShuntSinkLine {
        param([Parameter(Mandatory)][string]$Dir)
        $sink = Join-Path $Dir '.usage/shunt.jsonl'
        if (-not (Test-Path -LiteralPath $sink)) { return @() }
        return @(Get-Content -LiteralPath $sink)
    }

    function Get-ShuntSinkLastRecord {
        param([Parameter(Mandatory)][string]$Dir)
        $lines = @(Get-ShuntSinkLine -Dir $Dir)
        if ($lines.Count -eq 0) { return $null }
        return ($lines[-1] | ConvertFrom-Json -DateKind String)
    }

    function Invoke-ShuntHookAndGetLastRecord {
        param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$InputJson, [hashtable]$EnvVars)
        $sink = Join-Path $Dir '.usage/shunt.jsonl'
        Remove-Item -LiteralPath $sink -Force -ErrorAction SilentlyContinue
        Invoke-ShuntHook -WorkingDirectory $Dir -InputJson $InputJson -EnvVars $EnvVars | Out-Null
        return Get-ShuntSinkLastRecord -Dir $Dir
    }
}

AfterAll {
    foreach ($d in $script:TempDirs) {
        Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'shunt hook' {
    Context 'thresholds' {
        It '<EnvVar>=<Value> yields <Expected> for a 10-line small file' -ForEach @(
            @{ EnvVar = 'SHUNT_MIN_LINES'; Value = '5'; Expected = 'deny' }
            @{ EnvVar = 'SHUNT_MAX_BYTES'; Value = '10'; Expected = 'deny' }
            @{ EnvVar = 'SHUNT_MIN_LINES'; Value = '0'; Expected = 'pass' }
            @{ EnvVar = 'SHUNT_MIN_LINES'; Value = 'notanumber'; Expected = 'pass' }
            @{ EnvVar = 'SHUNT_MIN_LINES'; Value = ''; Expected = 'pass' }
            @{ EnvVar = 'SHUNT_MAX_BYTES'; Value = 'notanumber'; Expected = 'pass' }
        ) {
            $dir = Get-ShuntFixtureDir
            $envVars = @{ $EnvVar = $Value }
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'small.txt') }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson -EnvVars $envVars
            $isDeny = Test-ShuntDeny -Result $result
            if ($Expected -eq 'deny') { $isDeny | Should -BeTrue } else { $isDeny | Should -BeFalse }
        }
    }

    Context 'threshold parsing edge cases' {
        It 'SHUNT_MIN_LINES overflowing Int64 falls back to the default without crashing, telemetry still recorded' {
            $dir = Get-ShuntFixtureDir
            $envVars = @{ SHUNT_MIN_LINES = '99999999999999999999' }
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'small.txt') }
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson $inputJson -EnvVars $envVars
            $record | Should -Not -BeNullOrEmpty
            $record.decision | Should -Be 'allow'
            $record.threshold_lines | Should -Be 350
            $record.threshold_bytes | Should -Be 65536
        }

        It 'SHUNT_MAX_BYTES overflowing Int64 falls back to the default without crashing, telemetry still recorded' {
            $dir = Get-ShuntFixtureDir
            $envVars = @{ SHUNT_MAX_BYTES = '99999999999999999999' }
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'small.txt') }
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson $inputJson -EnvVars $envVars
            $record | Should -Not -BeNullOrEmpty
            $record.threshold_bytes | Should -Be 65536
            $record.threshold_lines | Should -Be 350
        }

        It 'SHUNT_MIN_LINES with a trailing newline is not truncated to its numeric prefix, falls back to the default' {
            $dir = Get-ShuntFixtureDir
            $envVars = @{ SHUNT_MIN_LINES = "5`n" }
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'small.txt') }
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson $inputJson -EnvVars $envVars
            $record.decision | Should -Be 'allow'
            $record.threshold_lines | Should -Be 350
        }
    }

    Context 'subagent calls always pass' {
        It '<ToolName> call with a top-level agent_id passes untouched' -ForEach @(
            @{ ToolName = 'Read' }
            @{ ToolName = 'Bash' }
        ) {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            if ($ToolName -eq 'Read') { $ToolInput = @{ file_path = $bigPath } } else { $ToolInput = @{ command = "cat $bigPath" } }
            $inputJson = Get-ShuntInputJson -ToolName $ToolName -ToolInput $ToolInput -Extra @{ agent_id = 'ag1' }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
            $result.StdErr | Should -BeNullOrEmpty
        }
    }

    Context 'Read tool targeting' {
        It '<Desc>' -ForEach @(
            @{ Desc = 'offset and limit both present is targeted'; ToolInput = @{ offset = 10; limit = 20 }; Expected = 'pass' }
            @{ Desc = 'offset=0 and limit present is targeted'; ToolInput = @{ offset = 0; limit = 20 }; Expected = 'pass' }
            @{ Desc = 'offset alone is not targeted'; ToolInput = @{ offset = 10 }; Expected = 'deny' }
            @{ Desc = 'limit alone is not targeted'; ToolInput = @{ limit = 50 }; Expected = 'deny' }
            @{ Desc = 'offset="" and limit="" are both absent'; ToolInput = @{ offset = ''; limit = '' }; Expected = 'deny' }
            @{ Desc = 'offset=false is absent, limit alone is not targeted'; ToolInput = @{ offset = $false; limit = 5 }; Expected = 'deny' }
            @{ Desc = 'offset="null" is absent, limit alone is not targeted'; ToolInput = @{ offset = 'null'; limit = 5 }; Expected = 'deny' }
        ) {
            $dir = Get-ShuntFixtureDir
            $ToolInput['file_path'] = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput $ToolInput
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            $isDeny = Test-ShuntDeny -Result $result
            if ($Expected -eq 'deny') { $isDeny | Should -BeTrue } else { $isDeny | Should -BeFalse }
        }
    }

    Context 'Read size checks' {
        It '<Desc>' -ForEach @(
            @{ Desc = 'small file passes'; File = 'small.txt'; Expected = 'pass' }
            @{ Desc = 'big file (400 lines) is denied'; File = 'big.txt'; Expected = 'deny' }
            @{ Desc = '70KB single-line file is denied by bytes'; File = 'fat.json'; Expected = 'deny' }
            @{ Desc = 'zero-byte file passes'; File = 'empty.txt'; Expected = 'pass' }
            @{ Desc = 'missing file passes'; File = 'does-not-exist.txt'; Expected = 'pass' }
            @{ Desc = 'a directory passes'; File = 'a-directory'; Expected = 'pass' }
        ) {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir $File) }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            $isDeny = Test-ShuntDeny -Result $result
            if ($Expected -eq 'deny') { $isDeny | Should -BeTrue } else { $isDeny | Should -BeFalse }
        }

        It 'a file with exactly 350 embedded newlines and no trailing newline passes (wc -l parity)' {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'no-trailing-newline.txt') }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
        }
    }

    Context 'deny JSON shape and redirect guidance' {
        It 'denies with the exact hookSpecificOutput shape and names bulk-reader' {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'big.txt') }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            $parsed = $result.StdOut | ConvertFrom-Json
            $parsed.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
            $parsed.hookSpecificOutput.permissionDecision | Should -Be 'deny'
            $parsed.hookSpecificOutput.permissionDecisionReason | Should -Match 'BLOCKED by shunt'
            $parsed.hookSpecificOutput.permissionDecisionReason | Should -Match 'bulk-reader'
            $parsed.hookSpecificOutput.permissionDecisionReason | Should -Match 'code-writer'
        }
    }

    Context 'Bash whitelisted verbs' {
        It '<Verb> on a big file is denied' -ForEach @(
            @{ Verb = 'cat' }
            @{ Verb = 'head' }
            @{ Verb = 'tail' }
            @{ Verb = 'less' }
            @{ Verb = 'more' }
            @{ Verb = 'bat' }
            @{ Verb = 'grep' }
            @{ Verb = 'sed' }
            @{ Verb = 'awk' }
            @{ Verb = 'rg' }
            @{ Verb = 'xxd' }
            @{ Verb = 'base64' }
            @{ Verb = 'strings' }
        ) {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $cmd = if ($Verb -eq 'grep') { "grep foo $bigPath" } elseif ($Verb -eq 'sed') { "sed p $bigPath" } else { "$Verb $bigPath" }
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = $cmd }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeTrue
        }

        It 'a non-whitelisted verb passes untouched' {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "ls -la $dir" }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
        }

        It 'a verb-boundary lookalike (head-file) passes untouched' {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "head-file $(Join-Path $dir 'big.txt')" }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
        }

        It 'a whitelisted verb with only flag args (no non-flag args) allows with no_input' {
            $dir = Get-ShuntFixtureDir
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = 'cat -n' })
            $record.decision | Should -Be 'allow'
            $record.reason | Should -Be 'no_input'
        }

        It 'the verb match is case-sensitive: "CAT" passes untouched even on a big file' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "CAT $bigPath" }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
        }

        It '<Desc>' -ForEach @(
            @{ Desc = 'leading form feed before a whitelisted verb is still denied'; Command = "`fcat {0}" }
            @{ Desc = 'leading carriage return before a whitelisted verb is still denied'; Command = "`rcat {0}" }
        ) {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = ($Command -f $bigPath) }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeTrue
        }
    }

    Context 'tool_name dispatch is case-sensitive' {
        It 'a lowercase "read" tool_name is not routed to the Read handler' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'read' -ToolInput @{ file_path = $bigPath }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
        }
    }

    Context 'Bash compound commands pass untouched' {
        It 'a command containing "<Char>" passes' -ForEach @(
            @{ Char = '|'; Cmd = 'cat {0} | head -20' }
            @{ Char = '>'; Cmd = 'cat {0} > /dev/null' }
            @{ Char = ';'; Cmd = 'cat {0}; echo ok' }
            @{ Char = '&'; Cmd = 'cat {0} && echo ok' }
            @{ Char = 'backtick'; Cmd = 'cat {0} `echo x`' }
        ) {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = ($Cmd -f $bigPath) }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
        }

        It 'a multi-line command passes' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "cat $bigPath`necho ok" }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
        }
    }

    Context 'Bash trailing newline is stripped before compound/verb parsing' {
        It '<Desc>' -ForEach @(
            @{ Desc = 'a single trailing newline still denies a bare cat of a big file'; Command = "cat {0}`n" }
            @{ Desc = 'two trailing newlines still deny a bare cat of a big file'; Command = "cat {0}`n`n" }
        ) {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = ($Command -f $bigPath) }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeTrue
        }

        It 'a command that is only a newline is trimmed to empty before the verb check, reason is no_input not verb' {
            $dir = Get-ShuntFixtureDir
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "`n" })
            $record.decision | Should -Be 'allow'
            $record.reason | Should -Be 'no_input'
        }
    }

    Context 'Bash bounded single-command reads skip the size check' {
        It '<Desc>' -ForEach @(
            @{ Desc = 'sed -n 244,260p unquoted'; Cmd = 'sed -n 244,260p {0}' }
            @{ Desc = "sed -n '244,260p' quoted"; Cmd = "sed -n '244,260p' {0}" }
            @{ Desc = 'sed -n 1p'; Cmd = 'sed -n 1p {0}' }
            @{ Desc = 'head -n 20'; Cmd = 'head -n 20 {0}' }
            @{ Desc = 'head -n20'; Cmd = 'head -n20 {0}' }
            @{ Desc = 'head -n 0'; Cmd = 'head -n 0 {0}' }
            @{ Desc = 'head -c 500'; Cmd = 'head -c 500 {0}' }
            @{ Desc = 'tail -n 20'; Cmd = 'tail -n 20 {0}' }
        ) {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = ($Cmd -f $bigPath) }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
        }

        It '<Desc>' -ForEach @(
            @{ Desc = 'sed -n ''100,$p'' (unbounded to EOF) is denied'; Cmd = 'sed -n ''100,$p'' {0}' }
            @{ Desc = 'sed without -n is denied'; Cmd = "sed '244,260p' {0}" }
            @{ Desc = "sed -ne '100p' (script, not window) is denied"; Cmd = "sed -ne '100p' {0}" }
            @{ Desc = 'sed -n mismatched quotes is denied'; Cmd = 'sed -n ''"244,260p'' {0}' }
            @{ Desc = "sed -n '244, 260p' (space in range) is denied"; Cmd = "sed -n '244, 260p' {0}" }
            @{ Desc = 'head -n +20 (start-at-N) is denied'; Cmd = 'head -n +20 {0}' }
            @{ Desc = 'tail -n +100 (start-at-N) is denied'; Cmd = 'tail -n +100 {0}' }
            @{ Desc = 'tail -c +100 (start-at-N) is denied'; Cmd = 'tail -c +100 {0}' }
            @{ Desc = 'head -N 5 (uppercase flag) is denied, case-sensitive'; Cmd = 'head -N 5 {0}' }
            @{ Desc = 'head -N5 (uppercase flag) is denied, case-sensitive'; Cmd = 'head -N5 {0}' }
            @{ Desc = "sed -n '1,5P' (uppercase command) is denied, case-sensitive"; Cmd = "sed -n '1,5P' {0}" }
            @{ Desc = "sed -N '1,5p' (uppercase flag) is denied, case-sensitive"; Cmd = "sed -N '1,5p' {0}" }
        ) {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = ($Cmd -f $bigPath) }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeTrue
        }
    }

    Context 'Bash multi-file telemetry ordering' {
        It 'logs one allow record per file in order' {
            $dir = Get-ShuntFixtureDir
            $sink = Join-Path $dir '.usage/shunt.jsonl'
            Remove-Item -LiteralPath $sink -Force -ErrorAction SilentlyContinue
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "cat $(Join-Path $dir 'small.txt') $(Join-Path $dir 'small2.txt')" }
            Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson | Out-Null
            $lines = @(Get-ShuntSinkLine -Dir $dir)
            $lines.Count | Should -Be 2
            ($lines[0] | ConvertFrom-Json).path | Should -Match 'small\.txt$'
            ($lines[1] | ConvertFrom-Json).path | Should -Match 'small2\.txt$'
        }

        It 'stops logging at the first oversized file' {
            $dir = Get-ShuntFixtureDir
            $sink = Join-Path $dir '.usage/shunt.jsonl'
            Remove-Item -LiteralPath $sink -Force -ErrorAction SilentlyContinue
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "cat $(Join-Path $dir 'small.txt') $(Join-Path $dir 'big.txt') $(Join-Path $dir 'small2.txt')" }
            Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson | Out-Null
            $lines = @(Get-ShuntSinkLine -Dir $dir)
            $lines.Count | Should -Be 2
            ($lines[0] | ConvertFrom-Json).decision | Should -Be 'allow'
            ($lines[1] | ConvertFrom-Json).decision | Should -Be 'deny'
        }
    }

    Context 'telemetry record shape' {
        It 'Read deny record carries offset/limit keys, no command key' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = $bigPath })
            $record.harness | Should -Be 'claude'
            $record.tool | Should -Be 'read'
            $record.decision | Should -Be 'deny'
            $record.reason | Should -Be 'lines'
            $record.lines | Should -Be 400
            $record.path | Should -Be $bigPath
            $record.PSObject.Properties.Name | Should -Contain 'offset'
            $record.PSObject.Properties.Name | Should -Contain 'limit'
            $record.PSObject.Properties.Name | Should -Not -Contain 'command'
            $record.offset | Should -BeNullOrEmpty
            $record.limit | Should -BeNullOrEmpty
        }

        It 'Read bytes-deny record has null lines' {
            $dir = Get-ShuntFixtureDir
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'fat.json') })
            $record.decision | Should -Be 'deny'
            $record.reason | Should -Be 'bytes'
            $record.lines | Should -BeNullOrEmpty
        }

        It 'Bash deny record carries the exact command and file path, no offset/limit keys' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $cmd = "cat $bigPath"
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = $cmd })
            $record.tool | Should -Be 'bash'
            $record.decision | Should -Be 'deny'
            $record.command | Should -Be $cmd
            $record.path | Should -Be $bigPath
            $record.PSObject.Properties.Name | Should -Not -Contain 'offset'
            $record.PSObject.Properties.Name | Should -Not -Contain 'limit'
        }

        It 'threshold fields reflect the effective thresholds' {
            $dir = Get-ShuntFixtureDir
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'small.txt') })
            $record.threshold_bytes | Should -Be 65536
            $record.threshold_lines | Should -Be 350
        }

        It 'Read targeted offset=0 keeps its number type in telemetry (not treated as absent)' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = $bigPath; offset = 0; limit = 20 })
            $record.reason | Should -Be 'targeted'
            $record.offset | Should -Be 0
            ($record.offset.GetType().Name) | Should -Match 'Int'
            $record.limit | Should -Be 20
        }

        It 'a falsy offset is logged as null, not the string "False"' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = $bigPath; offset = $false; limit = 5 })
            $record.offset | Should -BeNullOrEmpty
            $record.limit | Should -Be 5
        }

        It 'record field order matches the bash reference on the raw sink line' {
            $dir = Get-ShuntFixtureDir
            $sink = Join-Path $dir '.usage/shunt.jsonl'
            Remove-Item -LiteralPath $sink -Force -ErrorAction SilentlyContinue
            Invoke-ShuntHook -WorkingDirectory $dir -InputJson (Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'small.txt') }) | Out-Null
            $lines = @(Get-ShuntSinkLine -Dir $dir)
            $line = $lines[0]
            $keys = [regex]::Matches($line, '"([a-z_]+)":') | ForEach-Object { $_.Groups[1].Value }
            @($keys) | Should -Be @('ts', 'harness', 'session', 'tool', 'decision', 'reason', 'path', 'bytes', 'lines', 'threshold_bytes', 'threshold_lines', 'offset', 'limit')
        }

        It 'Bash record field order matches the bash reference on the raw sink line (command last)' {
            $dir = Get-ShuntFixtureDir
            $sink = Join-Path $dir '.usage/shunt.jsonl'
            Remove-Item -LiteralPath $sink -Force -ErrorAction SilentlyContinue
            Invoke-ShuntHook -WorkingDirectory $dir -InputJson (Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = 'ls -la' }) | Out-Null
            $lines = @(Get-ShuntSinkLine -Dir $dir)
            $line = $lines[0]
            $keys = [regex]::Matches($line, '"([a-z_]+)":') | ForEach-Object { $_.Groups[1].Value }
            @($keys) | Should -Be @('ts', 'harness', 'session', 'tool', 'decision', 'reason', 'path', 'bytes', 'lines', 'threshold_bytes', 'threshold_lines', 'command')
        }

        It 'a command that looks like an ISO-8601 date is kept as an exact string, not parsed into a DateTime' {
            $dir = Get-ShuntFixtureDir
            $cmd = '2024-01-01T00:00:00Z'
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = $cmd })
            $record.command | Should -Be $cmd
        }

        It 'an argument that is culture-ignorable but not ordinally a flag is checked as a file, not skipped' {
            $dir = Get-ShuntFixtureDir
            $shy = [string]([char]0x00AD) + '-x'
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "cat $shy" })
            $record.reason | Should -Be 'missing'
        }

        It 'a top-level agent_id:false is not treated as a subagent call' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = $bigPath } -Extra @{ agent_id = $false }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeTrue
        }

        It 'a top-level JSON array input is not processed as if it were the hook payload' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $obj = [ordered]@{ session_id = 's1'; hook_event_name = 'PreToolUse'; tool_name = 'Read'; tool_input = @{ file_path = $bigPath } }
            $arrayJson = '[' + (($obj | ConvertTo-Json -Depth 10 -Compress)) + ',' + (($obj | ConvertTo-Json -Depth 10 -Compress)) + ']'
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $arrayJson
            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -BeNullOrEmpty
            $result.StdErr | Should -BeNullOrEmpty
        }

        It '<Desc>' -ForEach @(
            @{ Desc = 'Read no_input reason when file_path is absent'; ToolName = 'Read'; ToolInput = @{}; Reason = 'no_input' }
            @{ Desc = 'Bash no_input reason when command is empty'; ToolName = 'Bash'; ToolInput = @{ command = '' }; Reason = 'no_input' }
            @{ Desc = 'Bash verb reason for a non-whitelisted verb'; ToolName = 'Bash'; ToolInput = @{ command = 'ls -la' }; Reason = 'verb' }
            @{ Desc = 'Bash compound reason for a piped command'; ToolName = 'Bash'; ToolInput = @{ command = 'cat x | head' }; Reason = 'compound' }
        ) {
            $dir = Get-ShuntFixtureDir
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName $ToolName -ToolInput $ToolInput)
            $record.decision | Should -Be 'allow'
            $record.reason | Should -Be $Reason
            $record.path | Should -BeNullOrEmpty
        }

        It 'Read subagent record keeps the real path (per-file decision)' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = $bigPath } -Extra @{ agent_id = 'ag1' })
            $record.decision | Should -Be 'allow'
            $record.reason | Should -Be 'subagent'
            $record.path | Should -Be $bigPath
        }

        It 'Bash subagent record has a null path (whole-command decision)' {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson (Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "cat $bigPath" } -Extra @{ agent_id = 'ag2' })
            $record.decision | Should -Be 'allow'
            $record.reason | Should -Be 'subagent'
            $record.path | Should -BeNullOrEmpty
            $record.command | Should -Be "cat $bigPath"
        }

        It 'no CR bytes ever reach the sink' {
            $dir = Get-ShuntFixtureDir
            $sink = Join-Path $dir '.usage/shunt.jsonl'
            Remove-Item -LiteralPath $sink -Force -ErrorAction SilentlyContinue
            Invoke-ShuntHook -WorkingDirectory $dir -InputJson (Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'small.txt') }) | Out-Null
            Invoke-ShuntHook -WorkingDirectory $dir -InputJson (Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = "cat $(Join-Path $dir 'big.txt')" }) | Out-Null
            $bytes = [IO.File]::ReadAllBytes($sink)
            $bytes | Should -Not -Contain 13
        }
    }

    Context 'MSYS and POSIX path resolution' {
        It 'an MSYS-style /c/... path resolves to the Windows drive and is denied' -Skip:(-not $IsWindows) {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $drive = $bigPath.Substring(0, 1).ToLowerInvariant()
            $rest = $bigPath.Substring(2).Replace('\', '/')
            $msysPath = "/$drive$rest"
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = $msysPath }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeTrue
        }

        It '<Desc>' -ForEach @(
            @{ Desc = 'a /tmp path is treated as missing (passes)'; Path = '/tmp/does-not-exist-on-windows.txt' }
            @{ Desc = 'a ~ path is treated as missing (passes)'; Path = '~/does-not-exist-on-windows.txt' }
        ) {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = $Path }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeFalse
        }

        It 'a PowerShell provider-qualified path (Env:/PATH) is checked as a literal filesystem path, not resolved through the Environment provider (passes as missing)' {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = 'Env:/PATH' }
            $record = Invoke-ShuntHookAndGetLastRecord -Dir $dir -InputJson $inputJson
            $record.reason | Should -Be 'missing'
            $record.bytes | Should -BeNullOrEmpty
        }

        It 'a relative path resolves against the hook working directory' {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = 'big.txt' }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeTrue
        }

        It 'an extended-length \\?\ path is stat''ed as Windows-native, not treated as MSYS-missing' -Skip:(-not $IsWindows) {
            $dir = Get-ShuntFixtureDir
            $bigPath = Join-Path $dir 'big.txt'
            $extendedPath = '\\?\' + $bigPath
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = $extendedPath }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            Test-ShuntDeny -Result $result | Should -BeTrue
        }
    }

    Context 'fail-open behavior' {
        It '<Desc>' -ForEach @(
            @{ Desc = 'empty stdin'; Payload = '' }
            @{ Desc = 'malformed JSON'; Payload = '{not json' }
            @{ Desc = 'a bare JSON number'; Payload = '42' }
        ) {
            $dir = Get-ShuntFixtureDir
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $Payload
            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -BeNullOrEmpty
            $result.StdErr | Should -BeNullOrEmpty
        }

        It 'an unhandled tool name passes through with no telemetry and no output' {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Write' -ToolInput @{ file_path = (Join-Path $dir 'big.txt') }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -BeNullOrEmpty
            (Get-ShuntSinkLine -Dir $dir).Count | Should -Be 0
        }
    }

    Context 'unwritable telemetry sink is best-effort' {
        It 'deny decision and stderr are unaffected when .usage cannot be created' {
            $dir = Get-ShuntFixtureDir
            [IO.File]::WriteAllText((Join-Path $dir '.usage'), '')
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'big.txt') }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            $result.StdErr | Should -BeNullOrEmpty
            Test-ShuntDeny -Result $result | Should -BeTrue
        }

        It 'allow decision, stdout and stderr are unaffected when .usage cannot be created' {
            $dir = Get-ShuntFixtureDir
            [IO.File]::WriteAllText((Join-Path $dir '.usage'), '')
            $inputJson = Get-ShuntInputJson -ToolName 'Read' -ToolInput @{ file_path = (Join-Path $dir 'small.txt') }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            $result.StdErr | Should -BeNullOrEmpty
            $result.StdOut | Should -BeNullOrEmpty
        }
    }

    Context 'literal glob arguments' {
        It 'a glob argument is checked literally, never expanded' {
            $dir = Get-ShuntFixtureDir
            $inputJson = Get-ShuntInputJson -ToolName 'Bash' -ToolInput @{ command = 'cat *.json' }
            $result = Invoke-ShuntHook -WorkingDirectory $dir -InputJson $inputJson
            $result.StdOut | Should -BeNullOrEmpty
        }
    }
}
