param(
    [ValidateRange(1, 30)]
    [int]$Seconds = 30,
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [ValidateSet('raw', 'hook')]
    [string]$InputBackend = 'raw',
    [switch]$InputOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$binary = Join-Path $projectRoot 'target/release/examples/paste_probe.exe'
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw 'Build the release examples before running this experiment.'
}
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($InputOnly) {
    $probeArguments = @('--input-only', "$Seconds")
} else {
    if ([string]::IsNullOrWhiteSpace($Destination)) { throw 'An approved destination is required.' }
    $destinationPath = (Resolve-Path -LiteralPath $Destination).Path
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container) -or $destinationPath.Contains('"')) {
        throw 'The approved destination must be an existing directory.'
    }
    # Double trailing backslashes before the quote in a literal Windows argument.
    $destinationArgument = '"' + [regex]::Replace($destinationPath, '(\\+)$', '$1$1') + '"'
    $probeArguments = @("$Seconds", $destinationArgument, $InputBackend)
}
[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
$runId = [guid]::NewGuid().ToString('N')
$stdout = Join-Path $outputPath "paste-probe-$runId.stdout.log"
$stderr = Join-Path $outputPath "paste-probe-$runId.stderr.log"
$probeProcess = Start-Process -FilePath $binary -ArgumentList $probeArguments `
    -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
# Retain the owned process handle, including on Windows PowerShell 5.1.
$null = $probeProcess.Handle
$probeClock = [System.Diagnostics.Stopwatch]::StartNew()
Write-Output "Experiment process $($probeProcess.Id) started; deadline: $Seconds seconds."
try {
    # Relay the observer's actual message-pump readiness before waiting for exit.
    # Count startup against the same watchdog rather than extending its deadline.
    $ready = $false
    while (-not $probeProcess.HasExited -and $probeClock.ElapsedMilliseconds -lt 5000) {
        $readyLine = Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue |
            Where-Object { $_.StartsWith('Ready.') } | Select-Object -First 1
        if ($readyLine) {
            Write-Output $readyLine
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw "The observer did not announce readiness. See $stdout and $stderr" }
    $remaining = [Math]::Max(1, (($Seconds + 5) * 1000) - [int]$probeClock.ElapsedMilliseconds)
    if (-not $probeProcess.WaitForExit($remaining)) {
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
