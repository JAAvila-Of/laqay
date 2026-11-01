[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [ValidateSet('Enable','Verify','Absent','Cleanup')][string]$Phase,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
if(-not ('LaqayGuestDesktop' -as [type])){& (Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly}
if($PrepareOnly){
    $types=$MyInvocation.MyCommand.ScriptBlock.Ast.FindAll({param($node) $node -is [Management.Automation.Language.TypeExpressionAst] -or $node -is [Management.Automation.Language.TypeConstraintAst]},$true)
    foreach($node in $types){if($node.TypeName.FullName -ne 'ordered' -and -not $node.TypeName.GetReflectionType()){throw ('Unresolved startup type: '+$node.TypeName.FullName)}}
    foreach($operation in @({[LaqayGuestDesktop]::ToggleStartup()},{[LaqayGuestDesktop]::AdoptStartupApplication('C:\LaqayLab\App\laqay.exe',[DateTime]::UtcNow)})){
        $rejected=$false;try{& $operation}catch{$rejected=$true}
        if(-not $rejected){throw 'Unarmed startup control was accepted.'}
    }
    Write-Output 'Startup helper types resolved; unarmed startup control and adoption were rejected.'
    return
}
if(-not $LabId -or -not $RunId -or -not $CycleId -or -not $Phase -or -not $ExpectedExecutableSha256){throw 'Startup phase, identities, and executable hash are required.'}
$limit=[DateTime]::UtcNow.AddSeconds(30)
while($true){try{[LaqayGuestDesktop]::Arm($LabId);break}catch{if([DateTime]::UtcNow -ge $limit){throw};Start-Sleep -Milliseconds 500}}
$root='C:\LaqayLab\Runs\'+$RunId
if($PSScriptRoot -ne $root -or (Test-Path -LiteralPath (Join-Path $root 'report.json'))){throw 'Unexpected or reused startup run directory.'}
$cycleRoot='C:\LaqayLab\Startup\'+$CycleId
$statePath=Join-Path $cycleRoot 'state.json'
$state=$null;$applicationStarted=$false;$shell=$null
$report=[ordered]@{LabId=$LabId;RunId=$RunId;CycleId=$CycleId;Phase=$Phase;Passed=$false;Error=$null;
    SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;ExecutableSha256=$ExpectedExecutableSha256;
    ApplicationPid=$null;ApplicationStarted=$false;ApplicationClosed=$true;ApplicationExitCode=0;ForcedTermination=$false;
    SettingsRestored=$false;Cases=@();CleanupErrors=@();BootUtc=$null;ApplicationStartUtc=$null;ParentProcessId=$null;
    ObservationSeconds=0;StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
function Save-Report {$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'report.json') -Encoding UTF8}
function Save-State {$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8}
function Assert-True($value,[string]$message){if(-not $value){throw $message}}
function Wait-For([scriptblock]$condition,[string]$message,[int]$seconds=10){
    $until=[DateTime]::UtcNow.AddSeconds($seconds)
    do{if(& $condition){return};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $until)
    throw $message
}
function Run-Case([string]$name,[scriptblock]$body){
    $case=[ordered]@{Name=$name;Passed=$false;Error=$null}
    try{& $body;$case.Passed=$true}catch{$case.Error=$_.Exception.Message;throw}finally{$report.Cases+=@([pscustomobject]$case);Save-Report}
}
function Assert-RunValue([bool]$enabled){
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try{
        $exists=$key -and $key.GetValueNames() -contains 'Laqay'
        if($enabled){Assert-True ($exists -and $key.GetValueKind('Laqay') -eq [Microsoft.Win32.RegistryValueKind]::String -and $key.GetValue('Laqay') -eq ('"'+$executable+'"')) 'Startup registration is not the exact quoted executable.'}
        else{Assert-True (-not $exists) 'The startup Run value still exists.'}
    }finally{if($key){$key.Dispose()}}
}
function Restore-Settings {
    if(-not $state){$report.SettingsRestored=$true;return}
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$true)
    try{
        if($key -and $key.GetValueNames() -contains 'Laqay'){
            Assert-True ($key.GetValueKind('Laqay') -eq [Microsoft.Win32.RegistryValueKind]::String -and $key.GetValue('Laqay') -eq ('"'+$state.Executable+'"')) 'Refusing to remove an unexpected startup command.'
            $key.DeleteValue('Laqay',$false)
        }
    }finally{if($key){$key.Dispose()}}
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay',$true)
    if($state.EnabledExisted -and -not $key){$key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Laqay')}
    if($key){try{
        if($state.EnabledExisted){$key.SetValue('Enabled',[int]$state.EnabledValue,[Microsoft.Win32.RegistryValueKind]::DWord)}else{$key.DeleteValue('Enabled',$false)}
        $removeEmpty=-not $state.SettingsKeyExisted -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
    }finally{$key.Dispose()}
    if($removeEmpty){[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey('Software\Laqay',$false)}}
    Assert-RunValue $false
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay')
    try{
        $exists=$key -and $key.GetValueNames() -contains 'Enabled'
        Assert-True ([bool]$exists -eq [bool]$state.EnabledExisted) 'Enabled existence was not restored.'
        if($exists){Assert-True ($key.GetValueKind('Enabled') -eq [Microsoft.Win32.RegistryValueKind]::DWord -and $key.GetValue('Enabled') -eq $state.EnabledValue) 'Enabled value was not restored.'}
    }finally{if($key){$key.Dispose()}}
    $state.Restored=$true;Save-State;$report.SettingsRestored=$true
}
try{
    Save-Report
    $executables=@(Get-ChildItem -LiteralPath 'C:/LaqayLab/App' -Filter laqay.exe -File -Recurse)
    Assert-True ($executables.Count -eq 1) 'Expected one validated guest executable.'
    $executable=$executables[0].FullName
    Assert-True ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -eq $ExpectedExecutableSha256) 'Guest executable hash mismatch.'
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $report.BootUtc=$boot.ToString('o')
    Wait-For {@(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $report.SessionId).Count -gt 0} 'The guest shell is not ready.' 30
    if($Phase -eq 'Enable'){
        Assert-True (-not (Test-Path -LiteralPath $cycleRoot)) 'Refusing to reuse an existing startup cycle.'
        Assert-True (@(Get-Process laqay -ErrorAction SilentlyContinue).Count -eq 0) 'A guest application is already running.'
        Assert-RunValue $false
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay')
        $keyExisted=$null -ne $key;$enabledExisted=$false;$oldEnabled=0
        if($key){try{
            $enabledExisted=$key.GetValueNames() -contains 'Enabled'
            if($enabledExisted){Assert-True ($key.GetValueKind('Enabled') -eq [Microsoft.Win32.RegistryValueKind]::DWord) 'Unexpected original Enabled type.';$oldEnabled=$key.GetValue('Enabled')}
        }finally{$key.Dispose()}}
        New-Item -ItemType Directory -Path $cycleRoot | Out-Null
        $state=[pscustomobject]@{LabId=$LabId;CycleId=$CycleId;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;
            Executable=$executable;Sha256=$ExpectedExecutableSha256;EnabledBootUtc=$boot.ToString('o');VerifiedBootUtc=$null;
            SettingsKeyExisted=$keyExisted;EnabledExisted=$enabledExisted;EnabledValue=$oldEnabled;Restored=$false;Stage='Preparing'}
        Save-State
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Laqay')
        try{$key.SetValue('Enabled',1,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$key.Dispose()}
        Run-Case 'StartupRegistered' {
            $report.ApplicationPid=[LaqayGuestDesktop]::StartApplication($executable);$script:applicationStarted=$true;$report.ApplicationClosed=$false
            Wait-For {[LaqayGuestDesktop]::ApplicationReady()} 'The startup setup application did not initialize.'
            [LaqayGuestDesktop]::ToggleStartup();Assert-RunValue $true
            $state.Stage='Enabled';Save-State
        }
    }else{
        if(Test-Path -LiteralPath $statePath){$state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json}
        if($Phase -ne 'Cleanup'){Assert-True ($null -ne $state) 'Startup cycle state is missing.'}
        if($state){Assert-True ($state.LabId -eq $LabId -and $state.CycleId -eq $CycleId -and $state.UserSid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -and $state.Executable -eq $executable -and $state.Sha256 -eq $ExpectedExecutableSha256) 'Startup state ownership mismatch.'}
        if($Phase -eq 'Verify'){
            Assert-True ($state.Stage -eq 'Enabled' -and -not $state.Restored -and $boot -gt [DateTime]::Parse($state.EnabledBootUtc).ToUniversalTime()) 'A fresh enabled guest boot is required.'
            Assert-RunValue $true
            Run-Case 'LaunchedAtLogin' {
                Wait-For {@(Get-Process laqay -ErrorAction SilentlyContinue).Count -gt 0} 'Windows did not launch the Run entry within 180 seconds.' 180
                $report.ApplicationPid=[LaqayGuestDesktop]::AdoptStartupApplication($executable,$boot);$script:applicationStarted=$true;$report.ApplicationClosed=$false
                $process=Get-Process -Id $report.ApplicationPid
                $report.ApplicationStartUtc=$process.StartTime.ToUniversalTime().ToString('o')
                $native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$report.ApplicationPid)
                $report.ParentProcessId=$native.ParentProcessId
                Assert-True ($native.CommandLine.Trim() -eq ('"'+$executable+'"') -or $native.CommandLine.Trim() -eq $executable) 'Unexpected startup process arguments.'
                Wait-For {[LaqayGuestDesktop]::ApplicationReady()} 'The startup tray window did not initialize.'
            }
            Run-Case 'StartupImagePaste' {
                $folder=Join-Path $root 'data';New-Item -ItemType Directory -Path $folder | Out-Null
                $shell=New-Object -ComObject Shell.Application;$shell.Open($folder)
                $script:window=$null
                Wait-For {foreach($candidate in @($shell.Windows())){try{if($candidate.Document.Folder.Self.Path -eq $folder){$script:window=$candidate;return $true}}catch{}};$false} 'The startup image folder did not open.'
                [LaqayGuestDesktop]::Activate([IntPtr]$window.HWND)
                Wait-For {try{[LaqayGuestDesktop]::FocusFolder([IntPtr]$window.HWND);$true}catch{$false}} 'The startup folder view is not ready.'
                [LaqayGuestDesktop]::ImageClipboard()
                [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[System.UInt16[]]@(17,86))
                Wait-For {@(Get-ChildItem -LiteralPath $folder -Filter '*.png').Count -eq 1} 'The application launched by Windows did not save an image.'
                $image=[Drawing.Bitmap]::new((Get-ChildItem -LiteralPath $folder -Filter '*.png')[0].FullName)
                try{
                    Assert-True ($image.Width -eq 2 -and $image.Height -eq 2) 'Startup image dimensions changed.'
                    $colors=@([Drawing.Color]::Red,[Drawing.Color]::Lime,[Drawing.Color]::Blue,[Drawing.Color]::White)
                    for($y=0;$y -lt 2;$y++){for($x=0;$x -lt 2;$x++){Assert-True ($image.GetPixel($x,$y).ToArgb() -eq $colors[$y*2+$x].ToArgb()) 'Startup image pixels changed.'}}
                }finally{$image.Dispose()}
            }
            Run-Case 'StartupDisabled' {[LaqayGuestDesktop]::ToggleStartup();Assert-RunValue $false;$state.Stage='Disabled';$state.VerifiedBootUtc=$boot.ToString('o');Save-State}
        }elseif($Phase -eq 'Absent'){
            Assert-True ($state.Stage -eq 'Disabled' -and -not $state.Restored -and $boot -gt [DateTime]::Parse($state.VerifiedBootUtc).ToUniversalTime()) 'A fresh disabled guest boot is required.'
            Run-Case 'NoStartupWithinObservationWindow' {
                Assert-RunValue $false
                $watch=[Diagnostics.Stopwatch]::StartNew()
                while($watch.Elapsed.TotalSeconds -lt 180){Assert-True (@(Get-Process laqay -ErrorAction SilentlyContinue).Count -eq 0) 'The disabled application started after guest logon.';Start-Sleep -Milliseconds 500}
                $report.ObservationSeconds=[int][Math]::Floor($watch.Elapsed.TotalSeconds)
                Assert-RunValue $false
            }
            Run-Case 'SettingsRestored' {Restore-Settings}
        }else{Run-Case 'SettingsRestored' {Restore-Settings}}
    }
    $report.Passed=$true
}catch{$report.Error=$_.Exception.Message}finally{
    $report.ApplicationStarted=$applicationStarted
    if($applicationStarted){try{
        $report.ApplicationClosed=[LaqayGuestDesktop]::CloseApplication();$report.ApplicationExitCode=[LaqayGuestDesktop]::ApplicationExitCode;$report.ForcedTermination=[LaqayGuestDesktop]::WasApplicationForced
        if(-not $report.ApplicationClosed){$report.Passed=$false}
    }catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}}
    if(-not $report.Passed -and $state){try{Restore-Settings}catch{$report.CleanupErrors+=@($_.Exception.Message)}}
    try{[LaqayGuestDesktop]::CloseExplorerWindows()}catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}
    if($shell){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    if($state -and $state.Restored){$report.SettingsRestored=$true}
    if($state){$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'startup-state.json') -Encoding UTF8}
    $report.FinishedUtc=[DateTime]::UtcNow.ToString('o');Save-Report
}
if(-not $report.Passed){exit 1}
