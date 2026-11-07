[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ShutdownEvidence.ps1')
if(-not ('LaqayGuestDesktop' -as [type])) { & (Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly | Out-Null }
if($PrepareOnly){Write-Output 'Shutdown driver compiled without arming desktop input or starting a trace.';return}
$root=Assert-ShutdownGuest $LabId $CycleId
$runRoot='C:\LaqayLab\Runs\'+$CycleId
if($PSScriptRoot -ine $runRoot -or -not (Test-Path -LiteralPath (Join-Path $root 'trace.json'))){throw 'The shutdown driver requires its prepared run and trace.'}
[LaqayGuestDesktop]::Arm($LabId)
[LaqayGuestDesktop]::RequireRole('Primary')
if([LaqayGuestDesktop]::SessionProtocol() -ne 0){throw 'Shutdown cases require the owned guest console.'}
$reportPath=Join-Path $root 'guest.json'
if(Test-Path -LiteralPath $reportPath){throw 'Refusing a reused shutdown driver.'}
$r=[ordered]@{LabId=$LabId;CycleId=$CycleId;Status='Initializing';Error=$null;ApplicationPid=0;CreatedUtc=$null;ParentPid=$PID;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;ExecutableSha256=$ExpectedExecutableSha256;Reference=$null;Provider=$null;PendingWaitProof=$null;PendingAtShutdown=$null;ShutdownRequestedUtc=$null;ShutdownCommand=$null;CleanupErrors=@()}
function Save {Write-ShutdownSnapshot $reportPath $r}
function Wait-Guest([scriptblock]$Check,[string]$Message,[int]$Seconds=15){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do{if(& $Check){return};Start-Sleep -Milliseconds 100}while($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw $Message
}
function Open-Target([string]$Path){
    $shell.Open($Path)
    $script:targetWindow=$null
    Wait-Guest {
        foreach($w in @($shell.Windows())){try{if($w.Document.Folder.Self.Path -ieq $Path){$script:targetWindow=$w;return $true}}catch{}}
        return $false
    } 'The owned Explorer target did not open.'
    [LaqayGuestDesktop]::Activate([IntPtr]$targetWindow.HWND)
    Wait-Guest {try{[LaqayGuestDesktop]::FocusFolder([IntPtr]$targetWindow.HWND);$true}catch{$false}} 'The owned folder did not acquire focus.'
    return $targetWindow
}
$started=$false;$requested=$false
try{
    Save
    $exe='C:\LaqayLab\App\laqay.exe'
    if((Get-FileHash -LiteralPath $exe).Hash -ine $ExpectedExecutableSha256 -or @(Get-Process laqay -ErrorAction SilentlyContinue).Count){throw 'A fresh exact application is required.'}
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay')
    $saved=[ordered]@{LabId=$LabId;CycleId=$CycleId;Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;KeyExisted=($null -ne $key);EnabledExisted=$false;Kind=$null;Value=$null}
    if($key){try{
        $saved.EnabledExisted=$key.GetValueNames() -contains 'Enabled'
        if($saved.EnabledExisted){$saved.Kind=[string]$key.GetValueKind('Enabled');$saved.Value=$key.GetValue('Enabled')}
    }finally{$key.Dispose()}}
    if($saved.EnabledExisted -and $saved.Kind -notin @('DWord','String')){throw 'Unsupported baseline preference type.'}
    Write-ShutdownSnapshot (Join-Path $root 'preferences-before.json') $saved
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Laqay')
    try{$key.SetValue('Enabled',1,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$key.Dispose()}
    $r.ApplicationPid=[LaqayGuestDesktop]::StartShutdownApplication($exe);$started=$true
    $app=Get-Process -Id $r.ApplicationPid
    try{$r.CreatedUtc=$app.StartTime.ToUniversalTime().ToString('o')}finally{$app.Dispose()}
    Save
    Wait-Guest {[LaqayGuestDesktop]::ApplicationReady()} 'The owned application did not become ready.'
    $shell=New-Object -ComObject Shell.Application
    $control=Join-Path $runRoot 'control';$pending=Join-Path $runRoot 'pending'
    New-Item -ItemType Directory -Path $control,$pending -ErrorAction Stop | Out-Null
    $window=Open-Target $control
    [LaqayGuestDesktop]::ImageClipboard()
    [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[uint16[]]@(17,86))
    Wait-Guest {@(Get-ChildItem -LiteralPath $control -Filter '*.png').Count -eq 1} 'The reference paste did not produce a PNG.'
    $file=@(Get-ChildItem -LiteralPath $control -Filter '*.png')[0]
    $image=[Drawing.Bitmap]::new($file.FullName)
    try{if($image.Width -ne 2 -or $image.Height -ne 2 -or $image.GetPixel(0,0).ToArgb() -ne [Drawing.Color]::Red.ToArgb()){throw 'The reference image differs.'}}finally{$image.Dispose()}
    $r.Reference=[pscustomobject]@{Passed=$true;Path=$file.FullName;Sha256=(Get-FileHash -LiteralPath $file.FullName).Hash}
    $window=Open-Target $pending
    [LaqayGuestDesktop]::BeginRenderedDelayedPng()
    [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[uint16[]]@(17,86))
    Wait-Guest {([LaqayGuestDesktop]::DelayedPngState()).Requested} 'The render request was not received.' 10
    $r.Provider=[LaqayGuestDesktop]::DelayedPngState();$r.Status='Pending';Save
    $proofPath=Join-Path $root 'pending-proof.json'
    Wait-Guest {Test-Path -LiteralPath $proofPath} 'The controller did not verify the native read dependency.' 20
    $proof=Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json
    if($proof.LabId -cne $LabId -or $proof.RunId -cne $CycleId -or -not $proof.Confirmed -or
        $proof.ApplicationPid -ne $r.ApplicationPid -or $proof.ProviderPid -ne $PID -or $proof.ProviderThreadId -ne $r.Provider.ProviderThreadId -or $proof.SessionId -ne $r.SessionId){throw 'The pending-read proof does not match this application and provider.'}
    $r.PendingWaitProof=$proof
    $held=[LaqayGuestDesktop]::DelayedPngState()
    if(-not $held.Requested -or $held.Released -or $held.Rendered -or $held.TimedOut -or -not $held.OwnerMatches -or $held.Error -or $held.PayloadBytes -le 0 -or $held.Sequence -ne $held.PublishedSequence){throw 'The image read is no longer retained.'}
    if(@(Get-ChildItem -LiteralPath $pending -Force).Count){throw 'The pending request already produced output.'}
    $r.PendingAtShutdown=$held;$r.ShutdownRequestedUtc=[DateTime]::UtcNow.ToString('o');$r.ShutdownCommand=Get-ShutdownArguments $CycleId;$r.Status='ShutdownRequested';Save
    $requested=$true
    $shutdownArguments=$r.ShutdownCommand
    & "$env:SystemRoot\System32\shutdown.exe" @shutdownArguments | Out-Null
    if($LASTEXITCODE -ne 0){$requested=$false;throw 'Windows refused the normal guest shutdown.'}
    # The controller observes power-off and collects kernel process events on
    # the next boot. Do not close the app or release its provider here.
    Start-Sleep -Seconds 90
    $requested=$false;throw 'Windows did not finish the requested shutdown.'
}catch{$requested=$false;$r.Error=$_.Exception.Message;$r.Status='Failed';Save;throw}
finally{
    if(-not $requested){
        try{[LaqayGuestDesktop]::EndDelayedPng()}catch{$r.CleanupErrors+=@($_.Exception.Message)}
        if($started){try{[LaqayGuestDesktop]::CloseApplication()|Out-Null}catch{$r.CleanupErrors+=@($_.Exception.Message)}}
        try{[LaqayGuestDesktop]::CloseExplorerWindows()}catch{$r.CleanupErrors+=@($_.Exception.Message)}
        Save
    }
}
