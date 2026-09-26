#Requires -Version 7.5

[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
[Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture

$gatesFileName = '.gates.yml'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -Path $repoRoot

$gatesFile = Join-Path $repoRoot $gatesFileName
if (-not (Test-Path -Path $gatesFile -PathType Leaf)) {
    [Console]::Error.WriteLine("FAIL: $gatesFileName not found in $((Get-Location).Path)")
    exit 1
}

function Get-GateExitCode {
    param([Parameter(Mandatory)][string]$Command)
    $wrappedCommand = @(
        '$global:LASTEXITCODE = 0'
        $Command
        'if ($?) { exit 0 }'
        'if ($LASTEXITCODE) { exit $LASTEXITCODE }'
        'exit 1'
    ) -join [Environment]::NewLine
    $pwshPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-Command')
    $psi.ArgumentList.Add($wrappedCommand)
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    return $proc.ExitCode
}

$hasFailure = $false
foreach ($line in Get-Content -Path $gatesFile) {
    if ($line -match '^\s*$') { continue }
    if ($line -match '^\s*#') { continue }

    $colonIndex = $line.IndexOf(':')
    if ($colonIndex -lt 0) {
        $key = $line
        $cmd = ''
    } else {
        $key = $line.Substring(0, $colonIndex)
        $cmd = $line.Substring($colonIndex + 1).Trim()
    }

    if ([string]::Equals($key, 'stack', [StringComparison]::Ordinal)) { continue }

    if ($cmd.Length -eq 0) {
        Write-Output "${key}: FAIL (empty command)"
        $hasFailure = $true
        continue
    }

    $rc = Get-GateExitCode -Command $cmd
    if ($rc -eq 0) {
        Write-Output "${key}: PASS"
    } else {
        Write-Output "${key}: FAIL (exit $rc)"
        $hasFailure = $true
    }
}

if ($hasFailure) {
    Write-Output 'gates: FAIL (see above)'
    exit 1
}
Write-Output 'gates: PASS (all)'
exit 0
