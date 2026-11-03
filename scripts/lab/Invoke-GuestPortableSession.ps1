[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [ValidateSet('Old','New','Removed')][string]$Phase,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
if(-not ('LaqayGuestDesktop' -as [type])){& (Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly}
if($PrepareOnly){
    $types=$MyInvocation.MyCommand.ScriptBlock.Ast.FindAll({param($node) $node -is [Management.Automation.Language.TypeExpressionAst] -or $node -is [Management.Automation.Language.TypeConstraintAst]},$true)
    foreach($node in $types){if($node.TypeName.FullName -ne 'ordered' -and -not $node.TypeName.GetReflectionType()){throw ('Unresolved portable session type: '+$node.TypeName.FullName)}}
    return
}
if(-not $LabId -or -not $RunId -or -not $CycleId -or -not $Phase -or -not $ExpectedExecutableSha256){throw 'Portable session identities and executable hash are required.'}
$until=[DateTime]::UtcNow.AddSeconds(30)
while($true){try{[LaqayGuestDesktop]::Arm($LabId);break}catch{if([DateTime]::UtcNow -ge $until){throw};Start-Sleep -Milliseconds 500}}
[LaqayGuestDesktop]::RequireRole('Primary')
if([LaqayGuestDesktop]::SessionProtocol() -ne 0){throw 'A disposable Primary console session is required.'}
$root='C:\LaqayLab\Runs\'+$RunId
$cycleRoot='C:\LaqayLab\Portable\'+$CycleId
$executable='C:\LaqayLab\App\Portable-'+$CycleId+'\laqay.exe'
if($PSScriptRoot -ne $root -or (Test-Path -LiteralPath (Join-Path $root 'report.json'))){throw 'Unexpected or reused portable session directory.'}
$state=Get-Content -LiteralPath (Join-Path $cycleRoot 'state.json') -Raw | ConvertFrom-Json
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if($state.LabId -ne $LabId -or $state.CycleId -ne $CycleId -or $state.UserSid -ne $sid -or $state.Executable -ne $executable){throw 'Portable cycle ownership mismatch.'}
$report=[ordered]@{LabId=$LabId;RunId=$RunId;CycleId=$CycleId;Phase=$Phase;ExecutableSha256=$ExpectedExecutableSha256;
    Passed=$false;Error=$null;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;ApplicationStarted=$false;
    ApplicationPid=$null;ApplicationClosed=$true;ApplicationExitCode=0;ForcedTermination=$false;Cases=@();CleanupErrors=@();
    ObservationSeconds=0;BootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');FinishedUtc=$null}
$applicationStarted=$false;$shell=$null
function Assert-True($value,[string]$message){if(-not $value){throw $message}}
function Save-Report {$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'report.json') -Encoding UTF8}
function Wait-For([scriptblock]$condition,[string]$message,[int]$seconds=10){
    $deadline=[DateTime]::UtcNow.AddSeconds($seconds)
    do{if(& $condition){return};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
    throw $message
}
function Run-Case([string]$name,[scriptblock]$body){
    $case=[ordered]@{Name=$name;Passed=$false;Error=$null}
    try{& $body;$case.Passed=$true}catch{$case.Error=$_.Exception.Message;throw}finally{$report.Cases+=@([pscustomobject]$case);Save-Report}
}
function Assert-Startup([bool]$enabled){
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try{
        $exists=$key -and $key.GetValueNames() -contains 'Laqay'
        if($enabled){Assert-True ($exists -and $key.GetValueKind('Laqay') -eq [Microsoft.Win32.RegistryValueKind]::String -and $key.GetValue('Laqay') -eq ('"'+$executable+'"')) 'The portable startup path differs.'}
        else{Assert-True (-not $exists) 'The portable startup value remains.'}
    }finally{if($key){$key.Dispose()}}
}
function Assert-Enabled([int]$expected){
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay')
    try{Assert-True ($key -and $key.GetValueNames() -contains 'Enabled' -and $key.GetValueKind('Enabled') -eq [Microsoft.Win32.RegistryValueKind]::DWord -and $key.GetValue('Enabled') -eq $expected) 'The persisted Enabled preference differs.'}finally{if($key){$key.Dispose()}}
}
try{
    Save-Report
    Assert-True (@(Get-Process laqay -ErrorAction SilentlyContinue).Count -eq 0) 'A guest application is already running.'
    Assert-Startup $false
    Wait-For {@(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $report.SessionId).Count -gt 0} 'The guest shell is not ready.' 30
    if($Phase -eq 'Removed'){
        Assert-True ($state.Stage -eq 'Removed' -and [DateTime]::Parse($report.BootUtc).ToUniversalTime() -gt [DateTime]::Parse($state.RemovalBootUtc).ToUniversalTime()) 'Removal must be followed by a fresh guest boot.'
        Run-Case 'RemovedStaysAbsent' {
            $watch=[Diagnostics.Stopwatch]::StartNew()
            do{
                Assert-Startup $false
                Assert-True (-not (Test-Path -LiteralPath (Split-Path $executable))) 'The removed package returned.'
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay')
                try{Assert-True ($null -eq $key) 'Removed preferences returned.'}finally{if($key){$key.Dispose()}}
                Assert-True (@(Get-Process laqay -ErrorAction SilentlyContinue).Count -eq 0) 'Laqay started after package removal.'
                Start-Sleep -Milliseconds 500
            }while($watch.Elapsed.TotalSeconds -lt 180)
            $report.ObservationSeconds=[int][Math]::Floor($watch.Elapsed.TotalSeconds)
        }
    }else{
        $expectedStage=if($Phase -eq 'Old'){'Old'}else{'New'}
        $pin=if($Phase -eq 'Old'){$state.OldExecutableSha256}else{$state.NewExecutableSha256}
        Assert-True ($state.Stage -eq $expectedStage -and $pin -eq $ExpectedExecutableSha256 -and (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -eq $pin) 'Installed release identity differs.'
        if($Phase -eq 'New'){Assert-Enabled 0}
        $report.ApplicationPid=[LaqayGuestDesktop]::StartApplication($executable);$applicationStarted=$true;$report.ApplicationClosed=$false
        Wait-For {[LaqayGuestDesktop]::ApplicationReady()} 'The portable application did not initialize.'
        if($Phase -eq 'Old'){
            Run-Case 'OldDisabledPreference' {
                # The Explorer suite restores its Enabled=1 baseline before this phase.
                Assert-Enabled 1
                [LaqayGuestDesktop]::ToggleEnabled();Wait-For {try{Assert-Enabled 0;$true}catch{$false}} 'The old release did not save Disabled.'
            }
            Run-Case 'OldStartupRoundTrip' {
                [LaqayGuestDesktop]::ToggleStartup();Wait-For {try{Assert-Startup $true;$true}catch{$false}} 'Old startup registration failed.'
                [LaqayGuestDesktop]::ToggleStartup();Wait-For {try{Assert-Startup $false;$true}catch{$false}} 'Old startup removal failed.'
            }
        }else{
            $folder=Join-Path $root 'data';New-Item -ItemType Directory -Path $folder | Out-Null
            $shell=New-Object -ComObject Shell.Application;$shell.Open($folder);$script:window=$null
            Wait-For {foreach($candidate in @($shell.Windows())){try{if($candidate.Document.Folder.Self.Path -eq $folder){$script:window=$candidate;return $true}}catch{}};$false} 'The upgrade folder did not open.'
            [LaqayGuestDesktop]::Activate([IntPtr]$window.HWND)
            Wait-For {try{[LaqayGuestDesktop]::FocusFolder([IntPtr]$window.HWND);$true}catch{$false}} 'The upgrade folder view is not ready.'
            Run-Case 'UpgradePreservesDisabled' {
                Assert-Enabled 0
                [LaqayGuestDesktop]::ImageClipboard();[LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86))
                Start-Sleep -Seconds 2
                Assert-True (@(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) 'The upgraded release ignored Disabled.'
            }
            Run-Case 'UpgradeImagePaste' {
                [LaqayGuestDesktop]::ToggleEnabled();Wait-For {try{Assert-Enabled 1;$true}catch{$false}} 'The upgrade did not re-enable.'
                [LaqayGuestDesktop]::ImageClipboard();[LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[UInt16[]]@(17,86))
                Wait-For {@(Get-ChildItem -LiteralPath $folder -Filter '*.png').Count -eq 1} 'The upgraded release did not save a PNG.'
                $image=[Drawing.Bitmap]::new((Get-ChildItem -LiteralPath $folder -Filter '*.png')[0].FullName)
                try{
                    Assert-True ($image.Width -eq 2 -and $image.Height -eq 2) 'Upgrade image dimensions changed.'
                    $colors=@([Drawing.Color]::Red,[Drawing.Color]::Lime,[Drawing.Color]::Blue,[Drawing.Color]::White)
                    for($y=0;$y -lt 2;$y++){for($x=0;$x -lt 2;$x++){Assert-True ($image.GetPixel($x,$y).ToArgb() -eq $colors[$y*2+$x].ToArgb()) 'Upgrade image pixels changed.'}}
                }finally{$image.Dispose()}
            }
        }
    }
    $report.Passed=$true
}catch{$report.Error=$_.Exception.Message}finally{
    $report.ApplicationStarted=$applicationStarted
    if($applicationStarted){try{
        $report.ApplicationClosed=[LaqayGuestDesktop]::CloseApplication();$report.ApplicationExitCode=[LaqayGuestDesktop]::ApplicationExitCode;$report.ForcedTermination=[LaqayGuestDesktop]::WasApplicationForced
        if(-not $report.ApplicationClosed -or $report.ApplicationExitCode -ne 0 -or $report.ForcedTermination){$report.Passed=$false}
    }catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}}
    try{[LaqayGuestDesktop]::CloseExplorerWindows()}catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}
    if($shell){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    $report.FinishedUtc=[DateTime]::UtcNow.ToString('o');Save-Report
}
if(-not $report.Passed){exit 1}
