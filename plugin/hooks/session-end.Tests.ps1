#Requires -Version 7.5

BeforeAll {
    $script:HookSource = Join-Path $PSScriptRoot 'session-end.ps1'
    $script:PwshCmd = (Get-Command pwsh).Source

    function Invoke-SessionEndHook {
        param(
            [Parameter(Mandatory)][string]$WorkingDirectory,
            [Parameter(Mandatory)][hashtable]$EnvVars
        )
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:PwshCmd
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($script:HookSource)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.EnvironmentVariables.Remove('USAGE_IMPORT_CMD')
        foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[$k] = $EnvVars[$k] }
        $proc = [Diagnostics.Process]::Start($psi)
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        [PSCustomObject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderrTask.GetAwaiter().GetResult() }
    }
}

Describe 'session-end default import command' {
    It 'resolves to the bundled usage-import-claude.ps1 and imports the project transcripts' {
        $worktree = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $worktree | Out-Null
        $worktree = (Resolve-Path -LiteralPath $worktree).Path
        $slug = [regex]::Replace($worktree, '[^A-Za-z0-9]', '-')
        $projects = Join-Path $TestDrive 'projects'
        $slugDir = Join-Path $projects $slug
        New-Item -ItemType Directory -Path $slugDir | Out-Null
        $line = '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","sessionId":"s1","message":{"id":"m1","model":"claude-test","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
        [IO.File]::WriteAllText((Join-Path $slugDir 's1.jsonl'), $line, [Text.UTF8Encoding]::new($false))

        $result = Invoke-SessionEndHook -WorkingDirectory $worktree -EnvVars @{ CLAUDE_PROJECTS_DIR = $projects }

        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $worktree '.usage/usage.jsonl') | Should -BeTrue
    }

    It 'ships the import script next to the hooks directory' {
        $pluginRoot = Split-Path -Parent $PSScriptRoot
        Test-Path -LiteralPath (Join-Path $pluginRoot 'scripts/usage-import-claude.ps1') -PathType Leaf | Should -BeTrue
    }
}
