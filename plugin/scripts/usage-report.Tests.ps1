#Requires -Version 7.5

BeforeAll {
    $script:RealRepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:RealRepoRoot 'scripts/usage-report.ps1'
    $script:PwshCmd = (Get-Command pwsh).Source

    function Invoke-Report {
        param([Parameter(Mandatory)][string]$File)
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:PwshCmd
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($script:ScriptPath)
        $psi.ArgumentList.Add('--file')
        $psi.ArgumentList.Add($File)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $script:RealRepoRoot
        $proc = [Diagnostics.Process]::Start($psi)
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [PSCustomObject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }
}

Describe 'usage-report subagent cache totals' {
    It 'reports cache_read and cache_write on the subagent line like the primary line' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $file = Join-Path $root 'usage.jsonl'

        $primaryRecord = [ordered]@{
            ts          = '2026-01-01T00:00:00Z'
            harness     = 'claude'
            session     = 'sess1'
            msg         = 'msg-primary'
            role        = 'primary'
            model       = 'claude-test'
            tokens_in   = 100
            tokens_out  = 200
            cache_read  = 10
            cache_write = 20
        }
        $subagentRecord = [ordered]@{
            ts          = '2026-01-01T00:00:01Z'
            harness     = 'claude'
            session     = 'sess1'
            msg         = 'msg-subagent'
            role        = 'subagent'
            model       = 'claude-test'
            tokens_in   = 5
            tokens_out  = 7
            cache_read  = 3
            cache_write = 4
        }
        $lines = @(
            ($primaryRecord | ConvertTo-Json -Compress),
            ($subagentRecord | ConvertTo-Json -Compress)
        )
        [IO.File]::WriteAllText($file, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))

        $result = Invoke-Report -File $file
        $result.ExitCode | Should -Be 0

        $outLines = @($result.Stdout -split "`n")
        $primaryLine = $outLines | Where-Object { $_.StartsWith('primary:', [StringComparison]::Ordinal) }
        $subagentLine = $outLines | Where-Object { $_.StartsWith('subagent:', [StringComparison]::Ordinal) }

        $primaryLine | Should -Be 'primary: 100 in / 200 out   (cache_read 10, cache_write 20)'
        $subagentLine | Should -Be 'subagent: 5 in / 7 out   (cache_read 3, cache_write 4)'
    }
}
