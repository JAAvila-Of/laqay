param(
    [ValidateRange(1, 30)]
    [int]$Seconds = 30,
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$binary = Join-Path $projectRoot 'target/release/examples/paste_probe.exe'
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw 'Build the release examples before running this experiment.'
}
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
$destinationPath = (Resolve-Path -LiteralPath $Destination).Path
if (-not (Test-Path -LiteralPath $destinationPath -PathType Container) -or $destinationPath.Contains('"')) {
    throw 'The approved destination must be an existing directory.'
}
# Quote a literal Windows argument, doubling trailing backslashes before the quote.
$destinationArgument = '"' + [regex]::Replace($destinationPath, '(\\+)$', '$1$1') + '"'
[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
$runId = [guid]::NewGuid().ToString('N')
$stdout = Join-Path $outputPath "paste-probe-$runId.stdout.log"
$stderr = Join-Path $outputPath "paste-probe-$runId.stderr.log"
$probeProcess = Start-Process -FilePath $binary -ArgumentList @("$Seconds", $destinationArgument) `
    -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
# Retain the owned process handle, including on Windows PowerShell 5.1.
$null = $probeProcess.Handle
Write-Output "Experiment process $($probeProcess.Id) started; deadline: $Seconds seconds."
try {
    if (-not $probeProcess.WaitForExit(($Seconds + 5) * 1000)) {
        $probeProcess.Kill()
        $probeProcess.WaitForExit()
        throw 'The experiment exceeded its deadline; its owned process was terminated.'
    }
    if ($probeProcess.ExitCode -ne 0) {
        throw "The experiment failed with exit code $($probeProcess.ExitCode). See $stderr"
    }
    Write-Output "Experiment stopped. Output: $stdout; errors: $stderr"
} finally {
    if (-not $probeProcess.HasExited) {
        $probeProcess.Kill()
        $probeProcess.WaitForExit()
    }
    $probeProcess.Dispose()
}
