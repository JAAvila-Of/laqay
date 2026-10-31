param(
    [ValidateSet('Enabled', 'Startup')]
    [string]$Scenario = 'Enabled',
    [ValidateRange(10, 30)]
    [int]$Seconds = 30,
    [string]$OutputDirectory,
    [switch]$InspectOnly,
    [switch]$PrepareOnly,
    [switch]$Automated
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$helperSource = Join-Path $PSScriptRoot 'PreferencesWindow.cs'
$helperHash = (Get-FileHash -LiteralPath $helperSource -Algorithm SHA256).Hash
$helperRuntime = "$($PSVersionTable.PSEdition)-$($PSVersionTable.PSVersion.Major)"
$helperDirectory = Join-Path $projectRoot "target/preferences-probe/$helperRuntime"
$helperAssembly = Join-Path $helperDirectory "$helperHash.dll"
if ($PrepareOnly) {
    # C# compilation runs separately from any coordinated Rust runtime trial.
    [System.IO.Directory]::CreateDirectory($helperDirectory) | Out-Null
    if (-not (Test-Path -LiteralPath $helperAssembly -PathType Leaf)) {
        Add-Type -Path $helperSource -OutputAssembly $helperAssembly -OutputType Library
    }
    Write-Output "Prepared window helper: $helperAssembly"
    return
}
$preferencePath = 'Software\Laqay'
$startupPath = 'Software\Microsoft\Windows\CurrentVersion\Run'

function Read-Value([string]$Path, [string]$Name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path, $false)
    try {
        $exists = $null -ne $key -and $key.GetValueNames() -contains $Name
        return [pscustomobject]@{
            Path = $Path; Name = $Name; KeyExisted = ($null -ne $key); Exists = $exists
            Kind = $(if ($exists) { $key.GetValueKind($Name).ToString() } else { $null })
            Data = $(if ($exists) {
                $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            } else { $null })
        }
    } finally { if ($null -ne $key) { $key.Dispose() } }
}

function Restore-Value($Snapshot) {
    if ($Snapshot.Exists) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Snapshot.Path)
        try {
            $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse(
                [Microsoft.Win32.RegistryValueKind], $Snapshot.Kind)
            $key.SetValue($Snapshot.Name, $Snapshot.Data, $kind)
        } finally { $key.Dispose() }
    } else {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Snapshot.Path, $true)
        $removeEmptyPreferenceKey = $false
        if ($null -ne $key) {
            try {
                $key.DeleteValue($Snapshot.Name, $false)
                $removeEmptyPreferenceKey = -not $Snapshot.KeyExisted -and
                    $Snapshot.Path -eq $preferencePath -and
                    $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
            } finally { $key.Dispose() }
        }
        # Delete only a newly created, empty application key. Never delete Run.
        if ($removeEmptyPreferenceKey) {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($Snapshot.Path, $false)
        }
    }
}

function Same-Value($Left, $Right) {
    return ($Left | ConvertTo-Json -Depth 5 -Compress) -ceq
        ($Right | ConvertTo-Json -Depth 5 -Compress)
}

$before = @((Read-Value $preferencePath 'Enabled'), (Read-Value $startupPath 'Laqay'))
if ($InspectOnly) {
    $before | ConvertTo-Json -Depth 5
    return
}
if ($Automated -and $env:GITHUB_ACTIONS -ne 'true') {
    throw 'Automated normal-mode application checks require the isolated CI runner.'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw 'An output directory is required.' }
if ($before[0].Exists -and ($before[0].Kind -ne 'DWord' -or $before[0].Data -notin @(0, 1))) {
    throw 'This trial requires an absent Enabled value or a valid 0/1 DWORD.'
}
if ($Scenario -eq 'Startup' -and $before[1].Exists) {
    throw 'This startup trial requires automatic startup to be initially absent.'
}
# Refuse an existing session instance, without creating or holding its mutex.
try {
    $existing = [System.Threading.Mutex]::OpenExisting('Local\LaqayInstance')
} catch [System.Threading.WaitHandleCannotBeOpenedException] { $existing = $null }
if ($null -ne $existing) {
    $existing.Dispose()
    throw 'Close the existing Laqay instance before this trial.'
}

$binary = (Resolve-Path -LiteralPath (Join-Path $projectRoot 'target/release/laqay.exe')).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
$runId = [guid]::NewGuid().ToString('N')
$reportPath = Join-Path $outputPath "preferences-$runId.json"
$backupPath = Join-Path $outputPath "preferences-$runId.before.json"
$before | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8

# Load the separately compiled helper without running another compiler under
# the Rust runtime lease.
if (-not (Test-Path -LiteralPath $helperAssembly -PathType Leaf)) {
    throw 'Prepare the window helper with -PrepareOnly before the runtime trial.'
}
Add-Type -Path $helperAssembly

$ownedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$report = [ordered]@{
    Scenario = $Scenario; Seconds = $Seconds; Before = $before
    ObservedChange = $false; Restarted = $false; StartupRemoved = $false
    Passed = $false; Restored = $false; ForcedTermination = $false; Error = $null
    Automated = [bool]$Automated; ApplicationRoundTrip = $false
}
$clock = [System.Diagnostics.Stopwatch]::StartNew()

function Start-OwnedApp {
    if ($clock.Elapsed.TotalSeconds -ge $Seconds - 3) { throw 'Insufficient time for another launch.' }
    $index = $ownedProcesses.Count + 1
    $process = Start-Process -FilePath $binary -WorkingDirectory $projectRoot `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $outputPath "preferences-$runId.$index.stdout.log") `
        -RedirectStandardError (Join-Path $outputPath "preferences-$runId.$index.stderr.log")
    $ownedProcesses.Add($process)
    $null = $process.Handle
    $launchTime = $clock.Elapsed.TotalSeconds
    while (-not $process.HasExited -and
        $clock.Elapsed.TotalSeconds -lt [Math]::Min($Seconds, $launchTime + 5)) {
        if ([LaqayPreferencesWindow]::Find([uint32]$process.Id) -ne [IntPtr]::Zero) {
            if (-not $process.WaitForInputIdle(5000)) { throw 'The owned application did not become idle.' }
            return $process
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'The owned tray window did not appear.'
}

try {
    $initialEnabled = -not $before[0].Exists -or $before[0].Data -eq 1
    $desired = [int](-not $initialEnabled)
    $process = Start-OwnedApp
    Write-Output "Ready. Normal-mode preferences trial; process $($process.Id); scenario $Scenario; deadline $Seconds seconds."
    if ($Automated) {
        $command = if ($Scenario -eq 'Enabled') { 1001 } else { 1002 }
        if (-not [LaqayPreferencesWindow]::Command([uint32]$process.Id, $command)) {
            throw 'The owned application did not complete the first command.'
        }
    }
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
        if ($Scenario -eq 'Enabled') {
            $value = Read-Value $preferencePath 'Enabled'
            if ($value.Exists -and $value.Kind -eq 'DWord' -and $value.Data -eq $desired) {
                $report.ObservedChange = $true
                if ($Automated -and -not $report.Restarted -and -not $process.HasExited) {
                    if (-not [LaqayPreferencesWindow]::Command([uint32]$process.Id, 1003)) {
                        throw 'The first application did not accept Exit.'
                    }
                    if (-not $process.WaitForExit(4000)) { throw 'The first application did not exit.' }
                }
            }
            if ($process.HasExited) {
                if ($process.ExitCode -ne 0) { throw 'The application failed before restart.' }
                if (-not $report.ObservedChange) { throw 'Enabled was not changed before exit.' }
                if ($report.Restarted) { break }
                $process = Start-OwnedApp
                $report.Restarted = $true
                $report.LoadedValueOnRestart = Read-Value $preferencePath 'Enabled'
                Write-Output "Restarted as process $($process.Id). Expected Enabled=$desired; confirm the tray state."
                if ($Automated) {
                    if (-not [LaqayPreferencesWindow]::Command([uint32]$process.Id, 1001)) {
                        throw 'The restarted application did not accept Enabled.'
                    }
                    $roundTrip = Read-Value $preferencePath 'Enabled'
                    if (-not $roundTrip.Exists -or $roundTrip.Data -ne [int]$initialEnabled) {
                        throw 'The application did not restore its persisted Enabled state.'
                    }
                    $report.ApplicationRoundTrip = $true
                    if (-not [LaqayPreferencesWindow]::Command([uint32]$process.Id, 1003)) {
                        throw 'The restarted application did not accept Exit.'
                    }
                }
            }
        } else {
            $value = Read-Value $startupPath 'Laqay'
            if ($value.Exists) {
                if ($value.Kind -ne 'String' -or $value.Data -cne ('"' + $binary + '"')) {
                    throw 'The Run value is not the expected quoted executable.'
                }
                $report.ObservedChange = $true
                $report.StartupCommand = $value.Data
                if ($Automated -and -not $report.ApplicationRoundTrip) {
                    if (-not [LaqayPreferencesWindow]::Command([uint32]$process.Id, 1002)) {
                        throw 'The application did not accept disabling startup.'
                    }
                    $report.ApplicationRoundTrip = $true
                }
            } elseif ($report.ObservedChange) {
                $report.StartupRemoved = $true
                break
            }
            if ($process.HasExited) { throw 'The application exited before both startup changes.' }
        }
        Start-Sleep -Milliseconds 100
    }
    if ($Scenario -eq 'Enabled') {
        if (-not $report.Restarted -or -not $report.LoadedValueOnRestart.Exists -or
            $report.LoadedValueOnRestart.Data -ne $desired) { throw 'The persistence check was not completed.' }
    } elseif (-not $report.StartupRemoved) { throw 'The startup add/remove check was not completed.' }
    if ($Automated -and -not $report.ApplicationRoundTrip) { throw 'The application round trip was not completed.' }
    $report.Passed = $true
} catch {
    $report.Error = $_.Exception.Message
} finally {
    # End only owned processes before restoring settings, including error paths.
    $report.ProcessIds = @($ownedProcesses | ForEach-Object { $_.Id })
    $report.Processes = @()
    $cleanupErrors = @()
    foreach ($process in $ownedProcesses) {
        try {
            if (-not $process.HasExited) {
                $null = [LaqayPreferencesWindow]::Close([uint32]$process.Id)
                if (-not $process.WaitForExit(4000)) {
                    $process.Kill()
                    $process.WaitForExit()
                    $report.ForcedTermination = $true
                    $report.Passed = $false
                }
            }
            if ($process.ExitCode -ne 0) { $report.Passed = $false }
        } catch {
            $cleanupErrors += $_.Exception.Message
            $report.Passed = $false
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit()
                    $report.ForcedTermination = $true
                }
            } catch { $cleanupErrors += $_.Exception.Message }
        } finally {
            $exited = $process.HasExited
            $report.Processes += [pscustomobject]@{
                Id = $process.Id; Exited = $exited
                ExitCode = $(if ($exited) { $process.ExitCode } else { $null })
            }
            $process.Dispose()
        }
    }
    $report.CleanupErrors = $cleanupErrors
    # Each value is restored independently so a failure does not skip the other.
    $restoreErrors = @()
    foreach ($snapshot in $before) {
        try { Restore-Value $snapshot } catch { $restoreErrors += $_.Exception.Message }
    }
    $report.After = @((Read-Value $preferencePath 'Enabled'), (Read-Value $startupPath 'Laqay'))
    $report.Restored = $restoreErrors.Count -eq 0 -and
        (Same-Value $before[0] $report.After[0]) -and (Same-Value $before[1] $report.After[1])
    $report.RestoreErrors = $restoreErrors
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
Write-Output "Trial stopped. Passed=$($report.Passed); restored=$($report.Restored); report: $reportPath"
if (-not $report.Passed -or -not $report.Restored) { throw 'The trial or restoration failed; inspect the report and backup.' }
