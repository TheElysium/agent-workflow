#Requires -Version 7.5

BeforeAll {
    $script:RealRepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:RealRepoRoot 'scripts/usage-import-claude.ps1'
    $script:PwshCmd = (Get-Command pwsh).Source

    function Initialize-IsolatedRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        return $root
    }

    function Format-AssistantLine {
        param(
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Timestamp,
            [object]$SessionId,
            [object]$IsSidechain,
            [string]$Model = 'claude-test',
            [long]$InputTokens = 1,
            [long]$OutputTokens = 2,
            [long]$CacheRead = 0,
            [long]$CacheWrite = 0
        )
        $usage = [ordered]@{
            input_tokens                  = $InputTokens
            output_tokens                 = $OutputTokens
            cache_read_input_tokens       = $CacheRead
            cache_creation_input_tokens   = $CacheWrite
        }
        $message = [ordered]@{ id = $Id; model = $Model; usage = $usage }
        $record = [ordered]@{ type = 'assistant'; timestamp = $Timestamp; message = $message }
        if ($null -ne $SessionId) { $record['sessionId'] = $SessionId }
        if ($null -ne $IsSidechain) { $record['isSidechain'] = [bool]$IsSidechain }
        return ($record | ConvertTo-Json -Compress -Depth 5)
    }

    function Get-MetaFile {
        param([Parameter(Mandatory)][string]$OutFile)
        if ($OutFile.EndsWith('.jsonl', [StringComparison]::Ordinal)) {
            return $OutFile.Substring(0, $OutFile.Length - 6) + '.meta'
        }
        return $OutFile + '.meta'
    }

    function Invoke-Import {
        param(
            [Parameter(Mandatory)][string]$ProjectsDir,
            [Parameter(Mandatory)][string]$Project,
            [Parameter(Mandatory)][string]$OutFile,
            [string]$WorkingDirectory,
            [hashtable]$EnvVars
        )
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:PwshCmd
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($script:ScriptPath)
        $psi.ArgumentList.Add('--dir')
        $psi.ArgumentList.Add($ProjectsDir)
        $psi.ArgumentList.Add('--project')
        $psi.ArgumentList.Add($Project)
        $psi.ArgumentList.Add('--out')
        $psi.ArgumentList.Add($OutFile)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { $script:RealRepoRoot }
        $psi.EnvironmentVariables.Remove('USAGE_IMPORT_DEBUG')
        if ($EnvVars) {
            foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[$k] = $EnvVars[$k] }
        }
        $proc = [Diagnostics.Process]::Start($psi)
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [PSCustomObject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }
}

Describe 'usage-import-claude subagent transcripts' {
    It 'imports a subagent record with role subagent and parent sessionId' {
        $root = Initialize-IsolatedRoot
        $projectsDir = Join-Path $root 'projects'
        $projectDir = Join-Path $projectsDir 'proj'
        $subDir = Join-Path $projectDir 'sess1/subagents'
        New-Item -ItemType Directory -Force -Path $subDir | Out-Null
        $line = Format-AssistantLine -Id 'msg-sub-1' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sess1' -IsSidechain $true
        Set-Content -LiteralPath (Join-Path $subDir 'agent-abc.jsonl') -Value $line -NoNewline -Encoding utf8NoBOM

        $outFile = Join-Path $root 'out/usage.jsonl'
        $result = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $result.ExitCode | Should -Be 0

        $records = @(Get-Content -LiteralPath $outFile | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $records.Count | Should -Be 1
        $records[0]['role'] | Should -Be 'subagent'
        $records[0]['session'] | Should -Be 'sess1'
        $records[0]['msg'] | Should -Be 'msg-sub-1'
    }

    It 'falls back to the parent directory name when a subagent record has no sessionId' {
        $root = Initialize-IsolatedRoot
        $projectsDir = Join-Path $root 'projects'
        $projectDir = Join-Path $projectsDir 'proj'
        $subDir = Join-Path $projectDir 'sess2/subagents'
        New-Item -ItemType Directory -Force -Path $subDir | Out-Null
        $line = Format-AssistantLine -Id 'msg-sub-2' -Timestamp '2026-01-01T00:00:00.000Z' -IsSidechain $true
        Set-Content -LiteralPath (Join-Path $subDir 'agent-xyz.jsonl') -Value $line -NoNewline -Encoding utf8NoBOM

        $outFile = Join-Path $root 'out/usage.jsonl'
        $result = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $result.ExitCode | Should -Be 0

        $records = @(Get-Content -LiteralPath $outFile | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $records.Count | Should -Be 1
        $records[0]['session'] | Should -Be 'sess2'
    }

    It 'skips a subagent file without parsing when its mtime ticks are unchanged' {
        $root = Initialize-IsolatedRoot
        $projectsDir = Join-Path $root 'projects'
        $projectDir = Join-Path $projectsDir 'proj'
        $subDir = Join-Path $projectDir 'sess3/subagents'
        New-Item -ItemType Directory -Force -Path $subDir | Out-Null
        $filePath = Join-Path $subDir 'agent-aaa.jsonl'
        $line1 = Format-AssistantLine -Id 'msg-1' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sess3' -IsSidechain $true
        Set-Content -LiteralPath $filePath -Value $line1 -Encoding utf8NoBOM

        $outFile = Join-Path $root 'out/usage.jsonl'
        $first = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $first.ExitCode | Should -Be 0

        $originalTicks = (Get-Item -LiteralPath $filePath).LastWriteTimeUtc
        $line2 = Format-AssistantLine -Id 'msg-2' -Timestamp '2026-01-01T00:01:00.000Z' -SessionId 'sess3' -IsSidechain $true
        Add-Content -LiteralPath $filePath -Value $line2 -Encoding utf8NoBOM
        [IO.File]::SetLastWriteTimeUtc($filePath, $originalTicks)

        $second = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $second.ExitCode | Should -Be 0

        $records = @(Get-Content -LiteralPath $outFile | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $records.Count | Should -Be 1
        $records[0]['msg'] | Should -Be 'msg-1'
    }

    It 'imports only the newly appended record when a subagent file grows' {
        $root = Initialize-IsolatedRoot
        $projectsDir = Join-Path $root 'projects'
        $projectDir = Join-Path $projectsDir 'proj'
        $subDir = Join-Path $projectDir 'sess4/subagents'
        New-Item -ItemType Directory -Force -Path $subDir | Out-Null
        $filePath = Join-Path $subDir 'agent-bbb.jsonl'
        $line1 = Format-AssistantLine -Id 'msg-a' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sess4' -IsSidechain $true
        Set-Content -LiteralPath $filePath -Value $line1 -Encoding utf8NoBOM

        $outFile = Join-Path $root 'out/usage.jsonl'
        $first = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $first.ExitCode | Should -Be 0

        $before = (Get-Item -LiteralPath $filePath).LastWriteTimeUtc
        $line2 = Format-AssistantLine -Id 'msg-b' -Timestamp '2026-01-01T00:01:00.000Z' -SessionId 'sess4' -IsSidechain $true
        Add-Content -LiteralPath $filePath -Value $line2 -Encoding utf8NoBOM
        [IO.File]::SetLastWriteTimeUtc($filePath, $before.AddSeconds(2))

        $second = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $second.ExitCode | Should -Be 0

        $records = @(Get-Content -LiteralPath $outFile | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $records.Count | Should -Be 2
        $records[1]['msg'] | Should -Be 'msg-b'
    }

    It 'upgrades a legacy two-column meta entry for a parent session without duplicating lines' {
        $root = Initialize-IsolatedRoot
        $projectsDir = Join-Path $root 'projects'
        $projectDir = Join-Path $projectsDir 'proj'
        New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
        $filePath = Join-Path $projectDir 'sess5.jsonl'
        $line1 = Format-AssistantLine -Id 'msg-legacy' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sess5' -IsSidechain $false
        Set-Content -LiteralPath $filePath -Value $line1 -NoNewline -Encoding utf8NoBOM

        $outFile = Join-Path $root 'out/usage.jsonl'
        $first = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $first.ExitCode | Should -Be 0

        $metaFile = Get-MetaFile -OutFile $outFile
        $metaLines = @(Get-Content -LiteralPath $metaFile)
        $sess5Line = $metaLines | Where-Object { $_.StartsWith('sess5' + [char]9, [StringComparison]::Ordinal) }
        $legacyParts = $sess5Line.Split([char]9)
        $preUpgradeMaxTs = $legacyParts[1]
        $legacyLine = "$($legacyParts[0])$([char]9)$preUpgradeMaxTs"
        $otherLines = @($metaLines | Where-Object { -not $_.StartsWith('sess5' + [char]9, [StringComparison]::Ordinal) })
        [IO.File]::WriteAllText($metaFile, (($otherLines + $legacyLine) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))

        $expectedTicks = [string](Get-Item -LiteralPath $filePath).LastWriteTimeUtc.Ticks

        $second = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $second.ExitCode | Should -Be 0

        $records = @(Get-Content -LiteralPath $outFile | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $records.Count | Should -Be 1

        $upgradedLines = @(Get-Content -LiteralPath $metaFile)
        $upgradedSess5 = $upgradedLines | Where-Object { $_.StartsWith('sess5' + [char]9, [StringComparison]::Ordinal) }
        $upgradedParts = $upgradedSess5.Split([char]9)
        $upgradedParts.Count | Should -Be 3
        $upgradedParts[1] | Should -Be $preUpgradeMaxTs
        $upgradedParts[2] | Should -Be $expectedTicks
    }

    It 'ignores files deeper than subagents or outside it' {
        $root = Initialize-IsolatedRoot
        $projectsDir = Join-Path $root 'projects'
        $projectDir = Join-Path $projectsDir 'proj'
        $wrongDir = Join-Path $projectDir 'sess6/other'
        $nestedDir = Join-Path $projectDir 'sess6/subagents/nested'
        $subDir = Join-Path $projectDir 'sess6/subagents'
        New-Item -ItemType Directory -Force -Path $wrongDir | Out-Null
        New-Item -ItemType Directory -Force -Path $nestedDir | Out-Null

        $wrongLine = Format-AssistantLine -Id 'msg-wrong' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sess6' -IsSidechain $true
        Set-Content -LiteralPath (Join-Path $wrongDir 'agent-w.jsonl') -Value $wrongLine -NoNewline -Encoding utf8NoBOM
        $nestedLine = Format-AssistantLine -Id 'msg-nested' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sess6' -IsSidechain $true
        Set-Content -LiteralPath (Join-Path $nestedDir 'agent-n.jsonl') -Value $nestedLine -NoNewline -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $subDir 'agent-m.meta.json') -Value '{}' -NoNewline -Encoding utf8NoBOM

        $validLine = Format-AssistantLine -Id 'msg-valid' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sess6' -IsSidechain $true
        Set-Content -LiteralPath (Join-Path $subDir 'agent-v.jsonl') -Value $validLine -NoNewline -Encoding utf8NoBOM

        $outFile = Join-Path $root 'out/usage.jsonl'
        $result = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $result.ExitCode | Should -Be 0

        $records = @(Get-Content -LiteralPath $outFile | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $records.Count | Should -Be 1
        $records[0]['msg'] | Should -Be 'msg-valid'
    }

    It 'dedups records by message id within a subagent file' {
        $root = Initialize-IsolatedRoot
        $projectsDir = Join-Path $root 'projects'
        $projectDir = Join-Path $projectsDir 'proj'
        $subDir = Join-Path $projectDir 'sess7/subagents'
        New-Item -ItemType Directory -Force -Path $subDir | Out-Null
        $filePath = Join-Path $subDir 'agent-ddd.jsonl'
        $line1 = Format-AssistantLine -Id 'msg-dup' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sess7' -IsSidechain $true -OutputTokens 2
        $line2 = Format-AssistantLine -Id 'msg-dup' -Timestamp '2026-01-01T00:00:01.000Z' -SessionId 'sess7' -IsSidechain $true -OutputTokens 9
        Set-Content -LiteralPath $filePath -Value @($line1, $line2) -Encoding utf8NoBOM

        $outFile = Join-Path $root 'out/usage.jsonl'
        $result = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $result.ExitCode | Should -Be 0

        $records = @(Get-Content -LiteralPath $outFile | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $records.Count | Should -Be 1
        $records[0]['tokens_out'] | Should -Be 9
    }

    It 'imports a valid file even when a transcript with no assistant records sorts before it' {
        $root = Initialize-IsolatedRoot
        $projectsDir = Join-Path $root 'projects'
        $projectDir = Join-Path $projectsDir 'proj'
        New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
        $emptyFilePath = Join-Path $projectDir 'sessA.jsonl'
        $validFilePath = Join-Path $projectDir 'sessB.jsonl'
        Set-Content -LiteralPath $emptyFilePath -Value '{"type":"summary","summary":"killed before answering"}' -NoNewline -Encoding utf8NoBOM
        $validLine = Format-AssistantLine -Id 'msg-valid-after-empty' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sessB' -IsSidechain $false
        Set-Content -LiteralPath $validFilePath -Value $validLine -NoNewline -Encoding utf8NoBOM

        $outFile = Join-Path $root 'out/usage.jsonl'
        $first = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $first.ExitCode | Should -Be 0

        $records = @(Get-Content -LiteralPath $outFile | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $records.Count | Should -Be 1
        $records[0]['msg'] | Should -Be 'msg-valid-after-empty'

        $metaFile = Get-MetaFile -OutFile $outFile
        $metaLines = @(Get-Content -LiteralPath $metaFile)
        $emptyMetaLine = $metaLines | Where-Object { $_.StartsWith('sessA' + [char]9, [StringComparison]::Ordinal) }
        $emptyParts = $emptyMetaLine.Split([char]9)
        $emptyParts.Count | Should -Be 3
        $emptyParts[1] | Should -Be ''
        $emptyParts[2] | Should -Not -BeNullOrEmpty

        $second = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile
        $second.ExitCode | Should -Be 0

        $recordsAfterSecondRun = @(Get-Content -LiteralPath $outFile | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $recordsAfterSecondRun.Count | Should -Be 1
    }

    It 'writes a debug file with slashes replaced by dashes when USAGE_IMPORT_DEBUG is set' {
        $root = Initialize-IsolatedRoot
        $projectsDir = Join-Path $root 'projects'
        $projectDir = Join-Path $projectsDir 'proj'
        $subDir = Join-Path $projectDir 'sess9/subagents'
        New-Item -ItemType Directory -Force -Path $subDir | Out-Null
        $line = Format-AssistantLine -Id 'msg-debug' -Timestamp '2026-01-01T00:00:00.000Z' -SessionId 'sess9' -IsSidechain $true
        Set-Content -LiteralPath (Join-Path $subDir 'agent-dbg.jsonl') -Value $line -NoNewline -Encoding utf8NoBOM

        $outFile = Join-Path $root 'out/usage.jsonl'
        $result = Invoke-Import -ProjectsDir $projectsDir -Project 'proj' -OutFile $outFile -WorkingDirectory $root -EnvVars @{ USAGE_IMPORT_DEBUG = '1' }
        $result.ExitCode | Should -Be 0

        $debugPath = Join-Path $root '.usage-import-debug-sess9-subagents-agent-dbg.jsonl'
        Test-Path -LiteralPath $debugPath | Should -BeTrue
    }
}
