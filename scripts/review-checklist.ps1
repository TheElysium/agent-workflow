#Requires -Version 7.5

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.NewLine = "`n"
[Console]::Error.NewLine = "`n"
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture
$ErrorActionPreference = 'Stop'

$script:LockFileNames = [Collections.Generic.HashSet[string]]::new(
    [string[]]@('package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'bun.lockb', 'go.sum', 'Cargo.lock', 'poetry.lock', 'Pipfile.lock', 'composer.lock'),
    [StringComparer]::Ordinal)

function Get-PathBasename {
    param([Parameter(Mandatory)][string]$Path)
    $index = $Path.LastIndexOf('/')
    if ($index -lt 0) { return $Path }
    return $Path.Substring($index + 1)
}

function Test-ExcludedPath {
    param([Parameter(Mandatory)][string]$Path)
    $name = Get-PathBasename -Path $Path
    if ($script:LockFileNames.Contains($name)) { return $true }
    if ($name.EndsWith('.min.js', [StringComparison]::Ordinal)) { return $true }
    if ($name.EndsWith('.min.css', [StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-FileType {
    param([Parameter(Mandatory)][string]$Path)
    $dotIndex = $Path.LastIndexOf('.')
    $extension = if ($dotIndex -lt 0) { $Path } else { $Path.Substring($dotIndex + 1) }
    switch -CaseSensitive ($extension) {
        'sh' { return 'shell' }
        'bash' { return 'shell' }
        'ts' { return 'typescript' }
        'js' { return 'javascript' }
        'mjs' { return 'javascript' }
        'cjs' { return 'javascript' }
        'go' { return 'go' }
        'py' { return 'python' }
        'rb' { return 'ruby' }
        'rs' { return 'rust' }
        'java' { return 'java' }
        'c' { return 'c' }
        'h' { return 'c' }
        'cpp' { return 'cpp' }
        'hpp' { return 'cpp' }
        'cc' { return 'cpp' }
        'cs' { return 'csharp' }
        'sql' { return 'sql' }
        'yml' { return 'yaml' }
        'yaml' { return 'yaml' }
        'toml' { return 'toml' }
        'json' { return 'json' }
        'md' { return 'markdown' }
        'mdx' { return 'markdown' }
        'html' { return 'html' }
        'htm' { return 'html' }
        'css' { return 'css' }
        'scss' { return 'css' }
        default { return 'other' }
    }
}

function Get-LineCount {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '?' }
    try {
        $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
        $bytes = [IO.File]::ReadAllBytes($resolvedPath)
    } catch {
        return '?'
    }
    return [string](($bytes -eq 10).Count)
}

function Get-NumstatCount {
    param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Path)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($diffArgs in @(
            @('-c', 'core.quotepath=false', 'diff', '-M', '--numstat', '--', ":(literal)$Src", ":(literal)$Path"),
            @('-c', 'core.quotepath=false', 'diff', '--cached', '-M', '--numstat', '--', ":(literal)$Src", ":(literal)$Path")
        )) {
        $output = & git @diffArgs 2>$null
        if ($output) { foreach ($line in @($output)) { $lines.Add($line) } }
    }
    if ($lines.Count -eq 0) { return @('?', '?') }
    $add = 0
    $del = 0
    $isBinary = $false
    foreach ($line in $lines) {
        $fields = $line -split "`t", 3
        if ($fields[0] -eq '-' -and $fields[1] -eq '-') {
            $isBinary = $true
        } else {
            $add += [int]$fields[0]
            $del += [int]$fields[1]
        }
    }
    $addText = if ($add -eq 0 -and $isBinary) { '?' } else { [string]$add }
    $delText = if ($del -eq 0 -and $isBinary) { '?' } else { [string]$del }
    return @($addText, $delText)
}

function Write-ChecklistEntry {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Adds,
        [Parameter(Mandatory)][string]$Dels,
        [Parameter(Mandatory)][string]$Path
    )
    if (Test-ExcludedPath -Path $Path) { return }
    $fileType = Get-FileType -Path $Path
    [Console]::Out.WriteLine("[$Status] $Adds $Dels $fileType $Path")
}

function Get-GitStatusRecord {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($arg in @('-c', 'core.quotepath=false', 'status', '--porcelain', '-z', '-uall')) { $psi.ArgumentList.Add($arg) }
    $psi.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $proc = [Diagnostics.Process]::Start($psi)
    $memoryStream = [IO.MemoryStream]::new()
    $proc.StandardOutput.BaseStream.CopyTo($memoryStream)
    $proc.WaitForExit()
    $bytes = $memoryStream.ToArray()
    if ($bytes.Length -eq 0) { return @() }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $parts = $text -split "`0"
    if ($parts.Length -gt 0 -and $parts[$parts.Length - 1] -eq '') {
        $parts = $parts[0..($parts.Length - 2)]
    }
    return $parts
}

& git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('review-checklist.ps1: not inside a git repository')
    exit 1
}

$records = @(Get-GitStatusRecord)
$index = 0
while ($index -lt $records.Length) {
    $record = $records[$index]
    $index++
    $xy = $record.Substring(0, 2)
    $path = $record.Substring(3)
    if ($xy[0] -ceq 'R' -or $xy[0] -ceq 'C') {
        if ($index -ge $records.Length) { continue }
        $src = $records[$index]
        $index++
        $counts = Get-NumstatCount -Src $src -Path $path
        Write-ChecklistEntry -Status $xy -Adds "+$($counts[0])" -Dels "-$($counts[1])" -Path $src
        Write-ChecklistEntry -Status $xy -Adds "+$($counts[0])" -Dels "-$($counts[1])" -Path $path
    } elseif ($xy.StartsWith('??', [StringComparison]::Ordinal)) {
        Write-ChecklistEntry -Status $xy -Adds "+$(Get-LineCount -Path $path)" -Dels '-0' -Path $path
    } else {
        $counts = Get-NumstatCount -Src $path -Path $path
        Write-ChecklistEntry -Status $xy -Adds "+$($counts[0])" -Dels "-$($counts[1])" -Path $path
    }
}

exit 0
