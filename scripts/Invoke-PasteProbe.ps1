param(
    [ValidateRange(1, 30)]
    [int]$Seconds = 30,
    [string]$Destination,
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [ValidateSet('raw', 'hook')]
    [string]$InputBackend = 'raw',
    [switch]$InputOnly,
    [switch]$Tray,
    [switch]$CheckSecondInstance
)

$ErrorActionPreference = 'Stop'
if ($CheckSecondInstance -and (-not $Tray -or $Seconds -lt 10)) {
    throw 'The second-instance check requires a tray trial of at least ten seconds.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$binary = Join-Path $projectRoot $(if ($Tray) { 'target/release/laqay.exe' } else { 'target/release/examples/paste_probe.exe' })
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw 'Build the release binaries and examples before running this experiment.'
}
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($InputOnly) {
    if ($Tray) { throw 'Tray trials require an approved destination.' }
    $probeArguments = @('--input-only', "$Seconds")
} else {
    if ([string]::IsNullOrWhiteSpace($Destination)) { throw 'An approved destination is required.' }
    $destinationPath = (Resolve-Path -LiteralPath $Destination).Path
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container) -or $destinationPath.Contains('"')) {
        throw 'The approved destination must be an existing directory.'
    }
    # Double trailing backslashes before the quote in a literal Windows argument.
    $destinationArgument = '"' + [regex]::Replace($destinationPath, '(\\+)$', '$1$1') + '"'
    if ($Tray) {
        if ($PSBoundParameters.ContainsKey('InputBackend')) { throw 'Tray trials use the dedicated hook observer.' }
        $probeArguments = @('--trial', "$Seconds", $destinationArgument)
    } else {
        $probeArguments = @("$Seconds", $destinationArgument, $InputBackend)
    }
}
[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
$runId = [guid]::NewGuid().ToString('N')
$logPrefix = if ($Tray) { 'tray-trial' } else { 'paste-probe' }
$stdout = Join-Path $outputPath "$logPrefix-$runId.stdout.log"
$stderr = Join-Path $outputPath "$logPrefix-$runId.stderr.log"
$probeProcess = Start-Process -FilePath $binary -ArgumentList $probeArguments `
    -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
# Retain the owned process handle, including on Windows PowerShell 5.1.
$null = $probeProcess.Handle
$probeClock = [System.Diagnostics.Stopwatch]::StartNew()
$secondProcess = $null
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
    if ($CheckSecondInstance) {
        if ($probeProcess.HasExited) { throw 'The first instance exited before the duplicate check.' }
        $secondStdout = Join-Path $outputPath "$logPrefix-$runId.second.stdout.log"
        $secondStderr = Join-Path $outputPath "$logPrefix-$runId.second.stderr.log"
        $secondProcess = Start-Process -FilePath $binary -ArgumentList $probeArguments `
            -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $secondStdout -RedirectStandardError $secondStderr
        $null = $secondProcess.Handle
        if (-not $secondProcess.WaitForExit(3000)) {
            throw 'The second instance did not exit within three seconds.'
        }
        # Complete redirected output before checking that the duplicate never
        # reached the engine's starting/readiness diagnostics.
        $secondProcess.WaitForExit()
        if ($secondProcess.ExitCode -ne 0) { throw 'The second instance failed.' }
        if ((Get-Item -LiteralPath $secondStdout).Length -ne 0 -or
            (Get-Item -LiteralPath $secondStderr).Length -ne 0) {
            throw 'The second instance produced unexpected engine output or errors.'
        }
        if ($probeProcess.HasExited) { throw 'The first instance stopped during the duplicate check.' }
        Write-Output "Second instance $($secondProcess.Id) exited with code 0 and no engine output; first instance $($probeProcess.Id) remains active."
    }
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
    if ($null -ne $secondProcess) {
        if (-not $secondProcess.HasExited) {
            $secondProcess.Kill()
            $secondProcess.WaitForExit()
        }
        $secondProcess.Dispose()
    }
    if (-not $probeProcess.HasExited) {
        $probeProcess.Kill()
        $probeProcess.WaitForExit()
    }
    $probeProcess.Dispose()
}
