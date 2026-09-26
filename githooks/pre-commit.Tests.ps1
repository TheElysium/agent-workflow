#Requires -Version 7.5

BeforeAll {
    $script:RealRepoRoot = Split-Path -Parent $PSScriptRoot
    $script:HookSource = Join-Path $script:RealRepoRoot 'githooks/pre-commit.ps1'
    $script:SettingsSource = Join-Path $script:RealRepoRoot 'PSScriptAnalyzerSettings.psd1'
    $script:GitCmd = (Get-Command git).Source
    $script:PwshCmd = (Get-Command pwsh).Source
    $script:TempDirs = [System.Collections.Generic.List[string]]::new()

    function Disable-CoreAutoCrlfForByteExactFixture {
        param([Parameter(Mandatory)][string]$RepoPath)
        & $script:GitCmd -C $RepoPath config core.autocrlf false
    }

    function Initialize-TestRepo {
        $repoPath = Join-Path ([IO.Path]::GetTempPath()) ("precommit-test-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $repoPath | Out-Null
        $script:TempDirs.Add($repoPath)
        New-Item -ItemType Directory -Path (Join-Path $repoPath 'githooks') | Out-Null
        Copy-Item -Path $script:HookSource -Destination (Join-Path $repoPath 'githooks/pre-commit.ps1')
        Copy-Item -Path $script:SettingsSource -Destination (Join-Path $repoPath 'PSScriptAnalyzerSettings.psd1')
        & $script:GitCmd -C $repoPath init -q
        & $script:GitCmd -C $repoPath config user.email 't@t.local'
        & $script:GitCmd -C $repoPath config user.name 't'
        Disable-CoreAutoCrlfForByteExactFixture -RepoPath $repoPath
        Set-Content -Path (Join-Path $repoPath 'seed.txt') -Value 'seed' -NoNewline -Encoding utf8NoBOM
        & $script:GitCmd -C $repoPath add seed.txt
        & $script:GitCmd -C $repoPath commit -q -m init
        return $repoPath
    }

    function Initialize-GitleaksStub {
        param([int]$ExitCode)
        $stubDir = Join-Path ([IO.Path]::GetTempPath()) ("gitleaks-stub-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $stubDir | Out-Null
        $script:TempDirs.Add($stubDir)
        if ($IsWindows) {
            Set-Content -Path (Join-Path $stubDir 'gitleaks.cmd') -Value "@exit /b $ExitCode" -Encoding ascii
        } else {
            $scriptPath = Join-Path $stubDir 'gitleaks'
            [IO.File]::WriteAllText($scriptPath, "#!/bin/sh`nexit $ExitCode`n")
            & chmod +x $scriptPath
        }
        return $stubDir
    }

    function Get-PassingPathEnv {
        $stub = Initialize-GitleaksStub -ExitCode 0
        return "$stub$([IO.Path]::PathSeparator)$env:PATH"
    }

    function Get-MinimalPathEnv {
        $gitDir = Split-Path -Parent $script:GitCmd
        $pwshDir = Split-Path -Parent $script:PwshCmd
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add($gitDir)
        if ($pwshDir -ne $gitDir) { $parts.Add($pwshDir) }
        if ($IsWindows) { $parts.Add((Join-Path $env:WINDIR 'System32')) }
        return ($parts -join [IO.Path]::PathSeparator)
    }

    function Test-CommandResolvable {
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$PathEnv)
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:PwshCmd
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-Command')
        $psi.ArgumentList.Add("if (Get-Command $Name -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }")
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['PATH'] = $PathEnv
        $proc = [Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        return ($proc.ExitCode -eq 0)
    }

    function Invoke-Hook {
        param(
            [Parameter(Mandatory)][string]$RepoPath,
            [string]$PathEnv = $env:PATH,
            [string]$AnalyzerModule,
            [string]$ForceError
        )
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:PwshCmd
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add((Join-Path $RepoPath 'githooks/pre-commit.ps1'))
        $psi.WorkingDirectory = $RepoPath
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['PATH'] = $PathEnv
        if ($AnalyzerModule) { $psi.EnvironmentVariables['PRECOMMIT_ANALYZER_MODULE'] = $AnalyzerModule }
        if ($ForceError) { $psi.EnvironmentVariables['PRECOMMIT_FORCE_ERROR'] = $ForceError }
        $proc = [Diagnostics.Process]::Start($psi)
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Output   = $stdout + $stderr
        }
    }
}

AfterAll {
    foreach ($d in $script:TempDirs) {
        Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'pre-commit hook' {
    Context 'gitleaks (non-skippable SAST)' {
        It 'blocks when gitleaks is not installed' {
            $minimalPath = Get-MinimalPathEnv
            Test-CommandResolvable -Name 'gitleaks' -PathEnv $minimalPath | Should -BeFalse
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'clean.txt') -Value 'clean' -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add clean.txt
            $result = Invoke-Hook -RepoPath $repo -PathEnv $minimalPath
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'gitleaks not installed'
        }

        It 'passes when gitleaks exits 0' {
            $repo = Initialize-TestRepo
            $stub = Initialize-GitleaksStub -ExitCode 0
            Set-Content -Path (Join-Path $repo 'clean.txt') -Value 'clean' -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add clean.txt
            $result = Invoke-Hook -RepoPath $repo -PathEnv "$stub$([IO.Path]::PathSeparator)$env:PATH"
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'gitleaks: ok'
        }

        It 'blocks when gitleaks exits 1 (secrets found)' {
            $repo = Initialize-TestRepo
            $stub = Initialize-GitleaksStub -ExitCode 1
            $tok = 'ghp_0123456789abcdefghij01234' + '56789'
            Set-Content -Path (Join-Path $repo 'leak.txt') -Value "token: $tok" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add leak.txt
            $result = Invoke-Hook -RepoPath $repo -PathEnv "$stub$([IO.Path]::PathSeparator)$env:PATH"
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'gitleaks found secrets in staged changes'
        }

        It 'fails closed when gitleaks exits <ExitCode>' -ForEach @(
            @{ ExitCode = 2 }
            @{ ExitCode = 126 }
        ) {
            $repo = Initialize-TestRepo
            $stub = Initialize-GitleaksStub -ExitCode $ExitCode
            Set-Content -Path (Join-Path $repo 'clean.txt') -Value 'clean' -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add clean.txt
            $result = Invoke-Hook -RepoPath $repo -PathEnv "$stub$([IO.Path]::PathSeparator)$env:PATH"
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match "gitleaks exited $ExitCode"
        }
    }

    Context 'accented characters (English-only docs rule)' {
        It 'blocks a staged file with accented content' {
            $repo = Initialize-TestRepo
            $accent = [char]0x00E9
            $content = "caf$accent test"
            Set-Content -Path (Join-Path $repo 'accented.md') -Value $content -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add accented.md
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'accented characters'
        }

        It 'blocks when staged content is accented but the worktree was cleaned' {
            $repo = Initialize-TestRepo
            $accent = [char]0x00E9
            $content = "caf$accent test"
            $file = Join-Path $repo 'accented.md'
            Set-Content -Path $file -Value $content -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add accented.md
            Set-Content -Path $file -Value 'now clean' -NoNewline -Encoding utf8NoBOM
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'accented characters'
        }

        It 'does not self-block when the hook source itself is staged' {
            $repo = Initialize-TestRepo
            Copy-Item -Path (Join-Path $repo 'githooks/pre-commit.ps1') -Destination (Join-Path $repo 'copied-hook.ps1')
            & $script:GitCmd -C $repo add copied-hook.ps1
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 0
        }

        It 'blocks accented content at range edge U+<CodePointHex>' -ForEach @(
            @{ CodePointHex = '00C0'; CodePoint = 0x00C0 }
            @{ CodePointHex = '00D6'; CodePoint = 0x00D6 }
            @{ CodePointHex = '00D8'; CodePoint = 0x00D8 }
            @{ CodePointHex = '00F6'; CodePoint = 0x00F6 }
            @{ CodePointHex = '00F8'; CodePoint = 0x00F8 }
            @{ CodePointHex = '00FF'; CodePoint = 0x00FF }
            @{ CodePointHex = '0152'; CodePoint = 0x0152 }
            @{ CodePointHex = '0153'; CodePoint = 0x0153 }
            @{ CodePointHex = '00C9'; CodePoint = 0x00C9 }
        ) {
            $repo = Initialize-TestRepo
            $char = [string][char]$CodePoint
            $file = "accent-$CodePointHex.md"
            Set-Content -Path (Join-Path $repo $file) -Value "x${char}x" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add $file
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'accented characters'
        }

        It 'does not block excluded code point U+<CodePointHex>' -ForEach @(
            @{ CodePointHex = '00D7'; CodePoint = 0x00D7 }
            @{ CodePointHex = '00F7'; CodePoint = 0x00F7 }
            @{ CodePointHex = '0178'; CodePoint = 0x0178 }
        ) {
            $repo = Initialize-TestRepo
            $char = [string][char]$CodePoint
            $file = "excluded-$CodePointHex.md"
            Set-Content -Path (Join-Path $repo $file) -Value "x${char}x" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add $file
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 0
        }

        It 'checks accented content in <Extension> files' -ForEach @(
            @{ Extension = 'ps1' }
            @{ Extension = 'psd1' }
        ) {
            $repo = Initialize-TestRepo
            $accent = [char]0x00E9
            $file = "accented.$Extension"
            Set-Content -Path (Join-Path $repo $file) -Value "# caf$accent" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add $file
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'accented characters'
        }

        It 'does not check accented content in .sh files' {
            $repo = Initialize-TestRepo
            $accent = [char]0x00E9
            Set-Content -Path (Join-Path $repo 'accented.sh') -Value "# caf$accent" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add accented.sh
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 0
        }
    }

    Context 'unexpected errors (fail-closed)' {
        It 'still prints commit blocked and exits 1 on an uncaught exception' {
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'clean.txt') -Value 'clean' -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add clean.txt
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv) -ForceError 'synthetic failure for test coverage'
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'FAIL: unexpected error'
            $result.Output | Should -Match 'synthetic failure for test coverage'
            $result.Output | Should -Match 'commit blocked'
        }
    }

    Context 'staged blob read failures (fail-closed)' {
        It 'blocks and reports a failure when the staged blob cannot be read' {
            $repo = Initialize-TestRepo
            $file = 'corrupt.md'
            Set-Content -Path (Join-Path $repo $file) -Value 'plain text' -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add $file
            $blobHash = (& $script:GitCmd -C $repo rev-parse ":$file").Trim()
            $objectPath = Join-Path $repo ".git/objects/$($blobHash.Substring(0, 2))/$($blobHash.Substring(2))"
            Remove-Item -Path $objectPath -Force
            Set-Content -Path (Join-Path $repo 'ok.json') -Value '{"ok": true}' -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add ok.json
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match '(?m)^pre-commit: FAIL: git cat-file blob failed for corrupt\.md'
            $result.Output | Should -Match '(?m)^pre-commit: json: ok \(ok\.json\)\r?$'
            $result.Output | Should -Match 'commit blocked'
            $result.Output | Should -Not -Match 'unexpected error'
        }
    }

    Context 'JSON validity' {
        It 'blocks invalid JSON' {
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'bad.json') -Value '{"bad": }' -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add bad.json
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'invalid JSON'
        }

        It 'passes valid JSON' {
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'ok.json') -Value '{"good": true}' -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add ok.json
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'json: ok'
        }
    }

    Context 'PSScriptAnalyzer on staged PowerShell files' {
        It 'blocks a staged .ps1 with an analyzer finding' {
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'bad.ps1') -Value "Write-Host 'test'" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add bad.ps1
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -MatchExactly 'FAIL: psscriptanalyzer bad\.ps1'
        }

        It 'blocks a staged .ps1 with a parse error' {
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'broken.ps1') -Value 'if ($x) {' -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add broken.ps1
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -MatchExactly 'FAIL: psscriptanalyzer broken\.ps1'
        }

        It 'passes a clean staged .ps1' {
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'good.ps1') -Value "Write-Output 'ok'" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add good.ps1
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 0
        }

        It 'blocks with a clear message when the analyzer module is absent (test seam)' {
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'good.ps1') -Value "Write-Output 'ok'" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add good.ps1
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv) -AnalyzerModule 'NoSuchModulePrecommitTest'
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'PSScriptAnalyzer not installed'
        }

        It 'does not check a staged .PS1 (uppercase extension not matched, case-sensitive by spec)' {
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'BAD.PS1') -Value "Write-Host 'test'" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add BAD.PS1
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 0
        }
    }

    Context 'CLAUDE.md must import root AGENTS.md' {
        It 'CLAUDE.md "<Desc>" -> exit <ExitCode>' -ForEach @(
            @{ Desc = '@AGENTS.md with trailing LF'; Content = "@AGENTS.md`n"; ExitCode = 0 }
            @{ Desc = '@AGENTS.md without trailing newline'; Content = '@AGENTS.md'; ExitCode = 0 }
            @{ Desc = 'inline content'; Content = "# inline workflow`n"; ExitCode = 1 }
            @{ Desc = 'import of another file'; Content = "@OTHER.md`n"; ExitCode = 1 }
            @{ Desc = 'extra blank line after import'; Content = "@AGENTS.md`n`n"; ExitCode = 1 }
            @{ Desc = 'junk after blank line'; Content = "@AGENTS.md`n`nx"; ExitCode = 1 }
            @{ Desc = 'CRLF line ending'; Content = "@AGENTS.md`r`n"; ExitCode = 1 }
        ) {
            $repo = Initialize-TestRepo
            [IO.File]::WriteAllBytes((Join-Path $repo 'CLAUDE.md'), [Text.Encoding]::UTF8.GetBytes($Content))
            & $script:GitCmd -C $repo add CLAUDE.md
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be $ExitCode
        }

        It 'blocks a staged deletion of CLAUDE.md' {
            $repo = Initialize-TestRepo
            Set-Content -Path (Join-Path $repo 'CLAUDE.md') -Value "@AGENTS.md`n" -NoNewline -Encoding utf8NoBOM
            & $script:GitCmd -C $repo add CLAUDE.md
            & $script:GitCmd -C $repo commit -q -m 'add claude'
            & $script:GitCmd -C $repo rm -q CLAUDE.md
            $result = Invoke-Hook -RepoPath $repo -PathEnv (Get-PassingPathEnv)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'CLAUDE.md cannot be deleted'
        }
    }
}
