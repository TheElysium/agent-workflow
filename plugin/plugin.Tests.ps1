#Requires -Version 7.5

BeforeAll {
    $script:PluginRoot = $PSScriptRoot
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:PluginManifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
    $script:MarketplacePath = Join-Path $script:RepoRoot '.claude-plugin/marketplace.json'
    $script:HooksPath = Join-Path $script:PluginRoot 'hooks/hooks.json'

    function Get-HookCommand {
        $config = Get-Content -LiteralPath $script:HooksPath -Raw | ConvertFrom-Json
        $commands = foreach ($hookEvent in $config.hooks.PSObject.Properties) {
            foreach ($entry in $hookEvent.Value) {
                foreach ($hook in $entry.hooks) { $hook.command }
            }
        }
        return @($commands)
    }

    $script:PluginVarPattern = '\$\{CLAUDE_PLUGIN_ROOT\}'

    function Get-PluginMarkdown {
        $files = Get-ChildItem -LiteralPath $script:PluginRoot -Filter '*.md' -Recurse -File
        return @($files | ForEach-Object {
                [PSCustomObject]@{
                    RelPath = [IO.Path]::GetRelativePath($script:PluginRoot, $_.FullName).Replace('\', '/')
                    Lines   = [string[]][IO.File]::ReadAllLines($_.FullName)
                }
            })
    }

    function Test-PluginVarAllowedPath {
        param([Parameter(Mandatory)][string]$RelPath)
        return ($RelPath -cmatch '^skills/[^/]+/SKILL\.md$') -or ($RelPath -cmatch '^agents/[^/]+\.md$')
    }

    function Find-MarkdownLine {
        param([Parameter(Mandatory)]$Files, [Parameter(Mandatory)][string]$Pattern)
        $hits = foreach ($file in $Files) {
            for ($i = 0; $i -lt $file.Lines.Count; $i++) {
                if ($file.Lines[$i] -cmatch $Pattern) { "$($file.RelPath):$($i + 1)" }
            }
        }
        return @($hits)
    }

    function Find-CwdRelativeScriptCall {
        param([Parameter(Mandatory)]$Files)
        return Find-MarkdownLine -Files $Files -Pattern '(?<!\$\{CLAUDE_PLUGIN_ROOT\}/)\bscripts/[\w-]+\.ps1'
    }

    function Find-MisplacedPluginVariable {
        param([Parameter(Mandatory)]$Files)
        $misplaced = @($Files | Where-Object { -not (Test-PluginVarAllowedPath -RelPath $_.RelPath) })
        return Find-MarkdownLine -Files $misplaced -Pattern $script:PluginVarPattern
    }

    function Find-UnquotedPluginVariable {
        param([Parameter(Mandatory)]$Files)
        $allowed = @($Files | Where-Object { Test-PluginVarAllowedPath -RelPath $_.RelPath })
        return Find-MarkdownLine -Files $allowed -Pattern ('(?<![\"`])' + $script:PluginVarPattern + '/')
    }

    function Find-AgentNameMismatch {
        param([Parameter(Mandatory)]$Files)
        $mismatches = foreach ($file in @($Files | Where-Object { $_.RelPath -cmatch '^agents/[^/]+\.md$' })) {
            $baseName = [IO.Path]::GetFileNameWithoutExtension($file.RelPath)
            $nameLine = $file.Lines | Where-Object { $_ -cmatch '^name:\s*\S' } | Select-Object -First 1
            $declared = if ($nameLine) { ($nameLine -creplace '^name:\s*', '').Trim() } else { $null }
            if ($declared -cne $baseName) { $file.RelPath }
        }
        return @($mismatches)
    }

    function Get-MarkdownSample {
        param([Parameter(Mandatory)][string]$RelPath, [Parameter(Mandatory)][string[]]$Lines)
        return [PSCustomObject]@{ RelPath = $RelPath; Lines = $Lines }
    }
}

Describe 'plugin manifests' {
    It 'plugin.json parses and is named agent-workflow' {
        $manifest = Get-Content -LiteralPath $script:PluginManifestPath -Raw | ConvertFrom-Json
        $manifest.name | Should -BeExactly 'agent-workflow'
    }

    It 'marketplace.json parses and has an owner name' {
        $marketplace = Get-Content -LiteralPath $script:MarketplacePath -Raw | ConvertFrom-Json
        $marketplace.owner.name | Should -Not -BeNullOrEmpty
    }

    It 'every marketplace plugin source resolves to a plugin with the same name' {
        $marketplace = Get-Content -LiteralPath $script:MarketplacePath -Raw | ConvertFrom-Json
        @($marketplace.plugins).Count | Should -BeGreaterThan 0
        foreach ($entry in $marketplace.plugins) {
            $sourceDir = Join-Path $script:RepoRoot $entry.source
            Test-Path -LiteralPath $sourceDir -PathType Container | Should -BeTrue
            $manifestPath = Join-Path $sourceDir '.claude-plugin/plugin.json'
            Test-Path -LiteralPath $manifestPath -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).name | Should -BeExactly $entry.name
        }
    }
}

Describe 'hooks.json' {
    It 'declares at least one hook command' {
        (Get-HookCommand).Count | Should -BeGreaterThan 0
    }

    It 'every ${CLAUDE_PLUGIN_ROOT} path exists under the plugin directory' {
        foreach ($command in Get-HookCommand) {
            $paths = [regex]::Matches($command, '\$\{CLAUDE_PLUGIN_ROOT\}/[^"\s]+') | ForEach-Object { $_.Value }
            @($paths).Count | Should -BeGreaterThan 0
            foreach ($path in $paths) {
                $resolved = $path.Replace('${CLAUDE_PLUGIN_ROOT}', $script:PluginRoot)
                Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue -Because $path
            }
        }
    }

    It 'every referenced .ps1 is double-quoted in the command' {
        foreach ($command in Get-HookCommand) {
            $command | Should -Match '"\$\{CLAUDE_PLUGIN_ROOT\}/[^"]+\.ps1"'
            $command | Should -Not -Match '(?<!")\$\{CLAUDE_PLUGIN_ROOT\}/\S+\.ps1'
        }
    }
}

Describe 'markdown guard functions' {
    It 'flags a cwd-relative script call with its file:line' {
        $sample = Get-MarkdownSample -RelPath 'skills/x/SKILL.md' -Lines @('ok', 'run `pwsh scripts/gates.ps1`')
        Find-CwdRelativeScriptCall -Files @($sample) | Should -Be @('skills/x/SKILL.md:2')
    }

    It 'accepts a script call prefixed by the plugin root variable' {
        $sample = Get-MarkdownSample -RelPath 'skills/x/SKILL.md' -Lines @('run "${CLAUDE_PLUGIN_ROOT}/scripts/gates.ps1"')
        Find-CwdRelativeScriptCall -Files @($sample) | Should -BeNullOrEmpty
    }

    It 'flags the plugin root variable outside SKILL.md and agents' {
        $bad = Get-MarkdownSample -RelPath 'skills/dev-workflow/gates.md' -Lines @('x', '"${CLAUDE_PLUGIN_ROOT}/a"')
        $good = Get-MarkdownSample -RelPath 'agents/bulk-reader.md' -Lines @('"${CLAUDE_PLUGIN_ROOT}/a"')
        Find-MisplacedPluginVariable -Files @($bad, $good) | Should -Be @('skills/dev-workflow/gates.md:2')
    }

    It 'flags an unquoted plugin root path and accepts quoted or backticked ones' {
        $lines = @('pwsh ${CLAUDE_PLUGIN_ROOT}/scripts/a.ps1', 'pwsh "${CLAUDE_PLUGIN_ROOT}/scripts/a.ps1"', 'pwsh `${CLAUDE_PLUGIN_ROOT}/scripts/a.ps1`')
        $sample = Get-MarkdownSample -RelPath 'skills/x/SKILL.md' -Lines $lines
        Find-UnquotedPluginVariable -Files @($sample) | Should -Be @('skills/x/SKILL.md:1')
    }

    It 'flags an agent whose frontmatter name differs from its file name or is missing' {
        $ok = Get-MarkdownSample -RelPath 'agents/a.md' -Lines @('---', 'name: a', '---')
        $wrong = Get-MarkdownSample -RelPath 'agents/b.md' -Lines @('---', 'name: c', '---')
        $missing = Get-MarkdownSample -RelPath 'agents/d.md' -Lines @('---', 'model: x', '---')
        Find-AgentNameMismatch -Files @($ok, $wrong, $missing) | Should -Be @('agents/b.md', 'agents/d.md')
    }
}

Describe 'shipped markdown invariants' {
    BeforeAll {
        $script:MarkdownFiles = Get-PluginMarkdown
    }

    It 'contains no cwd-relative scripts/*.ps1 call' {
        $offenders = Find-CwdRelativeScriptCall -Files $script:MarkdownFiles
        $offenders | Should -BeNullOrEmpty -Because ($offenders -join ', ')
    }

    It 'uses ${CLAUDE_PLUGIN_ROOT} only in SKILL.md and agent bodies' {
        $offenders = Find-MisplacedPluginVariable -Files $script:MarkdownFiles
        $offenders | Should -BeNullOrEmpty -Because ($offenders -join ', ')
    }

    It 'quotes or backticks every ${CLAUDE_PLUGIN_ROOT}/ path' {
        $offenders = Find-UnquotedPluginVariable -Files $script:MarkdownFiles
        $offenders | Should -BeNullOrEmpty -Because ($offenders -join ', ')
    }

    It 'keeps dev-workflow SKILL.md at most 9000 bytes' {
        $skill = Join-Path $script:PluginRoot 'skills/dev-workflow/SKILL.md'
        (Get-Item -LiteralPath $skill).Length | Should -BeLessOrEqual 9000
    }

    It 'names every agent after its file' {
        $offenders = Find-AgentNameMismatch -Files $script:MarkdownFiles
        $offenders | Should -BeNullOrEmpty -Because ($offenders -join ', ')
    }
}
