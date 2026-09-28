#Requires -Version 7.5

[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture

$script:HasFailure = $false
$script:EmDash = [char]0x2014

function Write-PreCommitLine {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Out.WriteLine("pre-commit: $Message")
}

function Add-PreCommitFailure {
    param([Parameter(Mandatory)][string]$Message)
    $script:HasFailure = $true
    Write-PreCommitLine "FAIL: $Message"
}

function Get-StagedFileList {
    param([string]$DiffFilter = 'ACMR')
    $raw = & git diff --cached --name-only "--diff-filter=$DiffFilter" -z 2>$null
    if (-not $raw) { return @() }
    return @($raw -split "`0" | Where-Object { $_.Length -gt 0 })
}

function Test-StagedBlobPresent {
    param([Parameter(Mandatory)][string]$Path)
    & git cat-file -e ":$Path" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-StagedBlobContent {
    param([Parameter(Mandatory)][string]$Path)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($arg in @('cat-file', 'blob', ":$Path")) { $psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [Diagnostics.Process]::Start($psi)
    $memoryStream = [IO.MemoryStream]::new()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardOutput.BaseStream.CopyTo($memoryStream)
    $proc.WaitForExit()
    $stderrText = $stderrTask.GetAwaiter().GetResult()
    if ($proc.ExitCode -ne 0) {
        Add-PreCommitFailure "git cat-file blob failed for $Path $script:EmDash $($stderrText.Trim())"
        return $null
    }
    return , $memoryStream.ToArray()
}

function Test-BytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return $false }
    }
    return $true
}

function Get-PreCommitAnalyzerModuleName {
    if ($env:PRECOMMIT_ANALYZER_MODULE) { return $env:PRECOMMIT_ANALYZER_MODULE }
    return 'PSScriptAnalyzer'
}

function Test-PreCommitAnalyzer {
    param([string[]]$Files, [string]$RepoRoot)
    if ($Files.Count -eq 0) { return }
    $moduleName = Get-PreCommitAnalyzerModuleName
    $requiredVersion = '1.25.0'
    if (-not (Get-Module -ListAvailable -Name $moduleName | Where-Object { $_.Version -eq $requiredVersion })) {
        Add-PreCommitFailure 'PSScriptAnalyzer not installed'
        return
    }
    Import-Module $moduleName -RequiredVersion $requiredVersion -ErrorAction Stop
    $settingsPath = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'
    foreach ($file in $Files) {
        $bytes = Get-StagedBlobContent $file
        if ($null -eq $bytes) { continue }
        $content = [Text.Encoding]::UTF8.GetString($bytes)
        $params = @{ ScriptDefinition = $content }
        if (Test-Path $settingsPath) { $params['Settings'] = $settingsPath }
        $findings = Invoke-ScriptAnalyzer @params
        if ($findings) {
            Add-PreCommitFailure "psscriptanalyzer $file"
        } else {
            Write-PreCommitLine "psscriptanalyzer: ok ($file)"
        }
    }
}

function Test-PreCommitSecretScan {
    if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
        Add-PreCommitFailure "gitleaks not installed $script:EmDash SAST is non-skippable"
        return
    }
    & gitleaks protect --staged --redact *> $null
    $rc = $LASTEXITCODE
    switch ($rc) {
        0 { Write-PreCommitLine 'gitleaks: ok' }
        1 { Add-PreCommitFailure 'gitleaks found secrets in staged changes' }
        default { Add-PreCommitFailure "gitleaks exited $rc" }
    }
}

function Get-PreCommitAccentPattern {
    $codePointRanges = @(
        , @(0x00C0, 0x00D6)
        , @(0x00D8, 0x00F6)
        , @(0x00F8, 0x00FF)
    )
    $ligatureCodePoints = @(0x0152, 0x0153)
    $classBody = ($codePointRanges | ForEach-Object {
        [string][char]$_[0] + '-' + [string][char]$_[1]
    }) -join ''
    $classBody += ($ligatureCodePoints | ForEach-Object { [string][char]$_ }) -join ''
    return "[$classBody]"
}

function Test-PreCommitAccentCheck {
    param([string[]]$Files)
    if ($Files.Count -eq 0) { return }
    $accentPattern = Get-PreCommitAccentPattern
    $allClean = $true
    foreach ($file in $Files) {
        $bytes = Get-StagedBlobContent $file
        if ($null -eq $bytes) { $allClean = $false; continue }
        $content = [Text.Encoding]::UTF8.GetString($bytes)
        if ($content -cmatch $accentPattern) {
            Add-PreCommitFailure "accented characters (docs must be plain English) in: $file"
            $allClean = $false
        }
    }
    if ($allClean) { Write-PreCommitLine 'accents: ok' }
}

function Test-PreCommitJson {
    param([string[]]$Files)
    foreach ($file in $Files) {
        $bytes = Get-StagedBlobContent $file
        if ($null -eq $bytes) { continue }
        $content = [Text.Encoding]::UTF8.GetString($bytes)
        $isValid = $false
        try {
            $isValid = Test-Json -Json $content -ErrorAction Stop
        } catch {
            $isValid = $false
        }
        if ($isValid) {
            Write-PreCommitLine "json: ok ($file)"
        } else {
            Add-PreCommitFailure "invalid JSON: $file"
        }
    }
}

function Test-PreCommitClaudeMd {
    if (Test-StagedBlobPresent 'CLAUDE.md') {
        $bytes = Get-StagedBlobContent 'CLAUDE.md'
        if ($null -eq $bytes) { return }
        $noNewline = [Text.Encoding]::UTF8.GetBytes('@AGENTS.md')
        $withNewline = [Text.Encoding]::UTF8.GetBytes("@AGENTS.md`n")
        $isValid = (Test-BytesEqual $bytes $noNewline) -or (Test-BytesEqual $bytes $withNewline)
        if ($isValid) {
            Write-PreCommitLine 'agents-sync: ok'
        } else {
            Add-PreCommitFailure 'CLAUDE.md must be exactly one line: @AGENTS.md'
        }
        return
    }
    $deleted = Get-StagedFileList -DiffFilter 'D'
    if ($deleted -contains 'CLAUDE.md') {
        Add-PreCommitFailure 'CLAUDE.md cannot be deleted'
    }
}

$ErrorActionPreference = 'Stop'

try {
    if ($env:PRECOMMIT_FORCE_ERROR) {
        throw $env:PRECOMMIT_FORCE_ERROR
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $stagedFiles = Get-StagedFileList

    $psFiles = @($stagedFiles | Where-Object { $_ -cmatch '\.(ps1|psd1)$' })
    Test-PreCommitAnalyzer -Files $psFiles -RepoRoot $repoRoot

    Test-PreCommitSecretScan

    $accentExtensions = @('md', 'ps1', 'psd1', 'json', 'jsonc', 'yml', 'yaml', 'txt', 'ts')
    $accentPatternExt = '\.(' + ($accentExtensions -join '|') + ')$'
    $textFiles = @($stagedFiles | Where-Object { $_ -cmatch $accentPatternExt })
    Test-PreCommitAccentCheck -Files $textFiles

    $jsonFiles = @($stagedFiles | Where-Object { $_ -cmatch '\.json$' })
    Test-PreCommitJson -Files $jsonFiles

    Test-PreCommitClaudeMd
} catch {
    Add-PreCommitFailure "unexpected error $script:EmDash $($_.Exception.Message)"
}

if ($script:HasFailure) {
    Write-PreCommitLine "commit blocked $script:EmDash fix the failures above"
    exit 1
}
Write-PreCommitLine 'all checks passed'
exit 0
