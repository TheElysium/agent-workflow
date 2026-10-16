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
