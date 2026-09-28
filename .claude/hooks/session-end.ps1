#Requires -Version 7.5

function Get-ProjectSlug {
    param([Parameter(Mandatory)][string]$Worktree)
    return [regex]::Replace($Worktree, '[^A-Za-z0-9]', '-')
}

$ErrorActionPreference = 'Stop'

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture

    $worktree = (Get-Location).Path

    $importCmd = $env:USAGE_IMPORT_CMD
    if ([string]::IsNullOrEmpty($importCmd)) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $importCmd = Join-Path $repoRoot 'scripts' 'usage-import-claude.ps1'
    }

    $projects = $env:CLAUDE_PROJECTS_DIR
    if ([string]::IsNullOrEmpty($projects)) {
        $projects = Join-Path $HOME '.claude' 'projects'
    }

    if ((Test-Path -LiteralPath $projects -PathType Container) -and (Test-Path -LiteralPath $importCmd -PathType Leaf)) {
        $slug = Get-ProjectSlug -Worktree $worktree
        $slugPath = Join-Path $projects $slug

        if (Test-Path -LiteralPath $slugPath -PathType Container) {
            $outPath = Join-Path $worktree '.usage' 'usage.jsonl'
            try {
                & pwsh -NoProfile -File $importCmd --dir $projects --project $slug --out $outPath 2>$null
            } catch {
                $null = $_
            }
        }
    }
} catch {
    $null = $_
}

exit 0
