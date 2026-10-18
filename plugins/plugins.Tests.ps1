#Requires -Version 7.5

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $marketplace = Get-Content -LiteralPath (Join-Path $repoRoot '.claude-plugin/marketplace.json') -Raw | ConvertFrom-Json
    $expectedHooks = @{
        'agent-workflow' = @{ Events = @('SessionEnd'); Matchers = @{} }
        'shunt'          = @{ Events = @('PreToolUse'); Matchers = @{ PreToolUse = 'Read|Bash' } }
    }
    $skillRequired = @('agent-workflow')
    $script:PluginCases = @($marketplace.plugins | ForEach-Object {
            @{
                Name             = $_.name
                Source           = $_.source
                Description      = $_.description
                ExpectedEvents   = $expectedHooks[$_.name].Events
                ExpectedMatchers = $expectedHooks[$_.name].Matchers
                SkillRequired    = $skillRequired -contains $_.name
            }
        })
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MarketplacePath = Join-Path $script:RepoRoot '.claude-plugin/marketplace.json'

    function Get-HookCommand {
        param([Parameter(Mandatory)][string]$PluginRoot)
        $config = Get-Content -LiteralPath (Join-Path $PluginRoot 'hooks/hooks.json') -Raw | ConvertFrom-Json
        $commands = foreach ($hookEvent in $config.hooks.PSObject.Properties) {
            foreach ($entry in $hookEvent.Value) {
                foreach ($hook in $entry.hooks) { $hook.command }
            }
        }
        return @($commands)
    }

    $script:PluginVarPattern = '\$\{CLAUDE_PLUGIN_ROOT\}'

    function Get-PluginMarkdown {
        param([Parameter(Mandatory)][string]$PluginRoot)
        $files = Get-ChildItem -LiteralPath $PluginRoot -Filter '*.md' -Recurse -File
        return @($files | ForEach-Object {
                [PSCustomObject]@{
                    RelPath = [IO.Path]::GetRelativePath($PluginRoot, $_.FullName).Replace('\', '/')
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

Describe 'marketplace' {
    It 'marketplace.json parses and has an owner name' {
        $marketplace = Get-Content -LiteralPath $script:MarketplacePath -Raw | ConvertFrom-Json
        $marketplace.owner.name | Should -Not -BeNullOrEmpty
    }

    It 'lists agent-workflow and shunt' {
        $names = @((Get-Content -LiteralPath $script:MarketplacePath -Raw | ConvertFrom-Json).plugins | ForEach-Object { $_.name })
        $names | Should -Contain 'agent-workflow'
        $names | Should -Contain 'shunt'
    }
}

Describe 'plugin <Name>' -ForEach $script:PluginCases {
    BeforeAll {
        $script:PluginRoot = Join-Path $script:RepoRoot $Source
        $script:Manifest = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
    }

    Context 'manifest' {
        It 'source directory holds a plugin.json named after the marketplace entry' {
            Test-Path -LiteralPath $script:PluginRoot -PathType Container | Should -BeTrue
            Test-Path -LiteralPath $script:Manifest -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath $script:Manifest -Raw | ConvertFrom-Json).name | Should -BeExactly $Name
        }

        It 'plugin.json description matches the marketplace entry' {
            (Get-Content -LiteralPath $script:Manifest -Raw | ConvertFrom-Json).description | Should -BeExactly $Description
        }
    }

    Context 'hooks.json' {
        It 'declares at least one hook command' {
            (Get-HookCommand -PluginRoot $script:PluginRoot).Count | Should -BeGreaterThan 0
        }

        It 'declares exactly the expected hook events with their matchers' {
            $config = Get-Content -LiteralPath (Join-Path $script:PluginRoot 'hooks/hooks.json') -Raw | ConvertFrom-Json
            $events = @($config.hooks.PSObject.Properties.Name)
            $events | Should -BeExactly @($ExpectedEvents)
            foreach ($hookEvent in $ExpectedMatchers.Keys) {
                @($config.hooks.$hookEvent.matcher) | Should -BeExactly @($ExpectedMatchers[$hookEvent])
            }
        }

        It 'every ${CLAUDE_PLUGIN_ROOT} path exists under the plugin directory' {
            foreach ($command in Get-HookCommand -PluginRoot $script:PluginRoot) {
                $paths = [regex]::Matches($command, '\$\{CLAUDE_PLUGIN_ROOT\}/[^"\s]+') | ForEach-Object { $_.Value }
                @($paths).Count | Should -BeGreaterThan 0
                foreach ($path in $paths) {
                    $resolved = $path.Replace('${CLAUDE_PLUGIN_ROOT}', $script:PluginRoot)
                    Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue -Because $path
                }
            }
        }

        It 'every referenced .ps1 is double-quoted in the command' {
            foreach ($command in Get-HookCommand -PluginRoot $script:PluginRoot) {
                $command | Should -Match '"\$\{CLAUDE_PLUGIN_ROOT\}/[^"]+\.ps1"'
                $command | Should -Not -Match '(?<!")\$\{CLAUDE_PLUGIN_ROOT\}/\S+\.ps1'
            }
        }
    }

    Context 'shipped markdown invariants' {
        BeforeAll {
            $script:MarkdownFiles = Get-PluginMarkdown -PluginRoot $script:PluginRoot
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

        It 'keeps dev-workflow SKILL.md at most 9000 bytes (required where the plugin ships it)' {
            $skill = Join-Path $script:PluginRoot 'skills/dev-workflow/SKILL.md'
            if ($SkillRequired) {
                Test-Path -LiteralPath $skill -PathType Leaf | Should -BeTrue
            }
            if (Test-Path -LiteralPath $skill -PathType Leaf) {
                (Get-Item -LiteralPath $skill).Length | Should -BeLessOrEqual 9000
            }
        }

        It 'names every agent after its file' {
            $offenders = Find-AgentNameMismatch -Files $script:MarkdownFiles
            $offenders | Should -BeNullOrEmpty -Because ($offenders -join ', ')
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
