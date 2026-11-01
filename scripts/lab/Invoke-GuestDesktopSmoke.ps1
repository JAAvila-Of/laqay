[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,System.Management,System.Web.Extensions,UIAutomationClient,UIAutomationTypes,WindowsBase
$references=@([Windows.Forms.Clipboard].Assembly.Location,[Drawing.Bitmap].Assembly.Location,
    [Management.ManagementObjectSearcher].Assembly.Location,[Web.Script.Serialization.JavaScriptSerializer].Assembly.Location,
    [Windows.Automation.AutomationElement].Assembly.Location,[Windows.Automation.ControlType].Assembly.Location,
    [Windows.Rect].Assembly.Location,[System.Diagnostics.Process].Assembly.Location,'System.Core.dll') | Select-Object -Unique
Add-Type -Path (Join-Path $PSScriptRoot 'GuestDesktopControls.cs') -ReferencedAssemblies $references
if($PrepareOnly){
    $rejected=$false
    try{[LaqayGuestDesktop]::ImageClipboard()}catch{$rejected=$true}
    if(-not $rejected){throw 'Unarmed input controls were accepted.'}
    $rejected=$false
    try{[LaqayGuestDesktop]::Arm('invalid-id')}catch{$rejected=$true}
    if(-not $rejected){throw 'An invalid guest identity was accepted.'}
    $rejected=$false
    try{[LaqayGuestDesktop]::Arm([guid]::NewGuid().ToString('N'))}catch{$rejected=$true}
    if(-not $rejected){throw 'An unowned lab identity was accepted.'}
    Write-Output 'Guest desktop helper compiled; unarmed input and invalid identity were rejected.'
    return
}
if(-not $LabId -or -not $RunId -or -not $ExpectedExecutableSha256){throw 'A lab identity, run identity, and executable SHA-256 are required.'}
$armLimit=[DateTime]::UtcNow.AddSeconds(30)
while($true){
    try{[LaqayGuestDesktop]::Arm($LabId);break}catch{
        if([DateTime]::UtcNow -ge $armLimit){throw}
        Start-Sleep -Milliseconds 500
    }
}
$root=[IO.Path]::GetFullPath((Join-Path 'C:/LaqayLab/Runs' $RunId))
if($PSScriptRoot -ne $root){throw 'The smoke runner must execute from its exact guest run directory.'}
$reportPath=Join-Path $root 'report.json'
if(Test-Path -LiteralPath $reportPath){throw 'Refusing to reuse an existing guest run report.'}
$report=[ordered]@{LabId=$LabId;RunId=$RunId;Passed=$false;Error=$null;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;
    ExecutableSha256=$ExpectedExecutableSha256;ApplicationPid=$null;ApplicationClosed=$false;ApplicationExitCode=$null;ForcedTermination=$false;
    Cases=@();CleanupErrors=@();PreferencesRestored=$false;StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
$shell=$null
$applicationStarted=$false
$preferencesTouched=$false
$preferencesExisted=$false
$enabledExisted=$false
$oldEnabled=$null
$oldEnabledKind=$null
function Save-Report { $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8 }
function Assert-True($condition,[string]$message){if(-not $condition){throw $message}}
function Wait-For([scriptblock]$condition,[string]$message,[int]$seconds=10){
    $limit=[DateTime]::UtcNow.AddSeconds($seconds)
    do{if(& $condition){return};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $limit)
    throw $message
}
function Run-Case([string]$name,[scriptblock]$body){
    $case=[ordered]@{Name=$name;Passed=$false;Error=$null;StartedUtc=[DateTime]::UtcNow.ToString('o');FinishedUtc=$null}
    try{& $body;$case.Passed=$true}catch{$case.Error=$_.Exception.Message;throw}finally{
        $case.FinishedUtc=[DateTime]::UtcNow.ToString('o');$report.Cases+=@([pscustomobject]$case);Save-Report
    }
}
function New-CaseFolder([string]$name){
    $path=Join-Path $root ('data/'+$name)
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}
function Find-Folder([string]$path){
    foreach($window in @($shell.Windows())){
        try{if($window.Document.Folder.Self.Path -eq $path){return $window}}catch{}
    }
    return $null
}
function Open-Folder([string]$path){
    $shell.Open($path)
    Wait-For { $null -ne (Find-Folder $path) } 'Guest Explorer did not expose the requested folder.'
    $window=Find-Folder $path
    [LaqayGuestDesktop]::Activate([IntPtr]$window.HWND)
    Start-Sleep -Milliseconds 250
    [LaqayGuestDesktop]::FocusFolder([IntPtr]$window.HWND)
    return $window
}
function Paste-Image($window,[string]$path,[int]$count){
    [LaqayGuestDesktop]::Activate([IntPtr]$window.HWND)
    [LaqayGuestDesktop]::FocusFolder([IntPtr]$window.HWND)
    [LaqayGuestDesktop]::ImageClipboard()
    [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(17,86))
    Wait-For { @(Get-ChildItem -LiteralPath $path -Filter '*.png').Count -eq $count } 'The expected image was not published in the active guest folder.'
}
function Check-Png([string]$path){
    Assert-True ([IO.Path]::GetFileName($path) -match '^Screenshot_\d{8}_\d{6}(_\d{3,})?\.png$') 'Unexpected screenshot filename.'
    $image=[Drawing.Bitmap]::new($path)
    try{
        Assert-True ($image.Width -eq 2 -and $image.Height -eq 2) 'Image dimensions changed.'
        Assert-True ($image.GetPixel(0,0).ToArgb() -eq [Drawing.Color]::Red.ToArgb()) 'Red pixel changed.'
        Assert-True ($image.GetPixel(1,0).ToArgb() -eq [Drawing.Color]::Lime.ToArgb()) 'Green pixel changed.'
        Assert-True ($image.GetPixel(0,1).ToArgb() -eq [Drawing.Color]::Blue.ToArgb()) 'Blue pixel changed.'
        Assert-True ($image.GetPixel(1,1).ToArgb() -eq [Drawing.Color]::White.ToArgb()) 'White pixel changed.'
    }finally{$image.Dispose()}
}
function Navigate-Tab([IntPtr]$window,[string]$path){
    [LaqayGuestDesktop]::Chord($window,[ushort[]]@(17,76))
    [LaqayGuestDesktop]::TextClipboard($path)
    [LaqayGuestDesktop]::Chord($window,[ushort[]]@(17,86))
    [LaqayGuestDesktop]::Chord($window,[ushort[]]@(13))
    Wait-For { $null -ne (Find-Folder $path) } 'The new guest tab did not navigate to its test folder.'
    Start-Sleep -Milliseconds 300
}
try{
    Save-Report
    $executables=@(Get-ChildItem -LiteralPath 'C:/LaqayLab/App' -Filter laqay.exe -File -Recurse)
    Assert-True ($executables.Count -eq 1) 'Expected one validated guest executable.'
    $executable=$executables[0].FullName
    Assert-True ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -eq $ExpectedExecutableSha256) 'Guest executable SHA-256 mismatch.'
    Assert-True (@(Get-Process -Name laqay -ErrorAction SilentlyContinue).Count -eq 0) 'An unrelated guest Laqay instance is already running.'
    Wait-For { @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $report.SessionId).Count -gt 0 } 'The interactive guest shell is not ready.' 30
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay')
    if($key){
        try{
            $preferencesExisted=$true
            $enabledExisted=$key.GetValueNames() -contains 'Enabled'
            if($enabledExisted){$oldEnabledKind=$key.GetValueKind('Enabled');$oldEnabled=$key.GetValue('Enabled',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
        }finally{$key.Dispose()}
    }
    $preferencesTouched=$true
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Laqay')
    try{$key.SetValue('Enabled',1,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$key.Dispose()}
    $report.ApplicationPid=[LaqayGuestDesktop]::StartApplication($executable)
    $applicationStarted=$true
    Save-Report
    Wait-For { [LaqayGuestDesktop]::ApplicationReady() } 'The actual Laqay tray application did not initialize.'
    $shell=New-Object -ComObject Shell.Application
    $images=New-CaseFolder 'images'
    $imageWindow=Open-Folder $images
    Run-Case 'ImagePaste' {
        Paste-Image $imageWindow $images 1
        $script:firstImage=(Get-ChildItem -LiteralPath $images -Filter '*.png')[0].FullName
        Check-Png $script:firstImage
        $script:firstHash=(Get-FileHash -LiteralPath $script:firstImage -Algorithm SHA256).Hash
    }
    Run-Case 'CollisionPreservation' {
        Paste-Image $imageWindow $images 2
        Assert-True ((Get-FileHash -LiteralPath $script:firstImage -Algorithm SHA256).Hash -eq $script:firstHash) 'An existing image was replaced.'
        foreach($file in @(Get-ChildItem -LiteralPath $images -Filter '*.png')){Check-Png $file.FullName}
    }
    Run-Case 'NativeFilePaste' {
        $sources=New-CaseFolder 'sources'
        $destination=New-CaseFolder 'file-destination'
        Set-Content -LiteralPath (Join-Path $sources 'one.txt') -Value 'Synthetic native paste fixture'
        [IO.File]::WriteAllBytes((Join-Path $sources 'two.bin'),[byte[]]@(0,1,127,255))
        $files=@(Get-ChildItem -LiteralPath $sources -File)
        $window=Open-Folder $destination
        [LaqayGuestDesktop]::FilesAndImageClipboard([string[]]@($files.FullName))
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(17,86))
        Wait-For { (Test-Path -LiteralPath (Join-Path $destination 'one.txt')) -and (Test-Path -LiteralPath (Join-Path $destination 'two.bin')) } 'Native multiple-file paste failed.'
        foreach($file in $files){Assert-True ((Get-FileHash -LiteralPath (Join-Path $destination $file.Name) -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) 'Native file contents changed.'}
        Start-Sleep -Milliseconds 500
        Assert-True (@(Get-ChildItem -LiteralPath $destination -Filter '*.png').Count -eq 0) 'File paste unexpectedly created an image.'
    }
    foreach($field in @('AddressBarText','SearchText')){
        Run-Case $field {
            $path=New-CaseFolder $field
            $window=Open-Folder $path
            $key=if($field -eq 'AddressBarText'){76}else{70}
            [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(17,$key))
            Start-Sleep -Milliseconds 200
            [LaqayGuestDesktop]::TextAndImageClipboard('LaqayEditableToken')
            [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(17,86))
            Wait-For { [LaqayGuestDesktop]::FocusedText([IntPtr]$window.HWND).Contains('LaqayEditableToken') } 'Native text paste did not reach the editable guest field.'
            Start-Sleep -Milliseconds 500
            Assert-True (@(Get-ChildItem -LiteralPath $path -Filter '*.png').Count -eq 0) 'An editable field caused an image write.'
            [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(27))
        }
    }
    Run-Case 'RenameText' {
        $path=New-CaseFolder 'rename'
        $file=Join-Path $path 'rename-source.txt'
        Set-Content -LiteralPath $file -Value 'Keep the original rename fixture'
        $hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        $window=Open-Folder $path
        $item=$window.Document.Folder.ParseName('rename-source.txt')
        $window.Document.SelectItem($item,29)
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(113))
        Start-Sleep -Milliseconds 200
        [LaqayGuestDesktop]::TextAndImageClipboard('LaqayRenameToken')
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(17,86))
        Wait-For { [LaqayGuestDesktop]::FocusedText([IntPtr]$window.HWND).Contains('LaqayRenameToken') } 'Text paste did not reach the rename field.'
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(27))
        Start-Sleep -Milliseconds 500
        Assert-True ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $hash) 'Cancelled rename altered the original file.'
        Assert-True (@(Get-ChildItem -LiteralPath $path -Filter '*.png').Count -eq 0) 'Rename caused an image write.'
    }
    $disabled=New-CaseFolder 'enabled'
    $enabledWindow=Open-Folder $disabled
    Run-Case 'DisabledImageDoesNotSave' {
        [LaqayGuestDesktop]::ToggleEnabled()
        [LaqayGuestDesktop]::ImageClipboard()
        [LaqayGuestDesktop]::Chord([IntPtr]$enabledWindow.HWND,[ushort[]]@(17,86))
        Start-Sleep -Milliseconds 1000
        Assert-True (@(Get-ChildItem -LiteralPath $disabled -Filter '*.png').Count -eq 0) 'Disabled application saved an image.'
    }
    Run-Case 'ReenabledImageSaves' {
        [LaqayGuestDesktop]::ToggleEnabled()
        Paste-Image $enabledWindow $disabled 1
        Check-Png (Get-ChildItem -LiteralPath $disabled -Filter '*.png')[0].FullName
    }
    Run-Case 'ActiveTabSelection' {
        $tabA=New-CaseFolder 'tab-a';$tabB=New-CaseFolder 'tab-b'
        $window=Open-Folder $tabA
        Paste-Image $window $tabA 1
        $original=(Get-ChildItem -LiteralPath $tabA -Filter '*.png')[0].FullName
        $hash=(Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(17,84))
        Start-Sleep -Milliseconds 400
        Navigate-Tab ([IntPtr]$window.HWND) $tabB
        $windowB=Find-Folder $tabB
        Assert-True ($windowB.HWND -eq $window.HWND) 'The second folder is not a tab of the same window.'
        Paste-Image $windowB $tabB 1
        $b=(Get-ChildItem -LiteralPath $tabB -Filter '*.png')[0].FullName
        $bHash=(Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(17,16,9))
        Start-Sleep -Milliseconds 300
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(17,76))
        Assert-True ([LaqayGuestDesktop]::FocusedText([IntPtr]$window.HWND) -eq $tabA) 'The original guest tab is not active.'
        [LaqayGuestDesktop]::Chord([IntPtr]$window.HWND,[ushort[]]@(27))
        Paste-Image $window $tabA 2
        Assert-True ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -eq $hash) 'The original tab image changed.'
        Assert-True (@(Get-ChildItem -LiteralPath $tabB -Filter '*.png').Count -eq 1 -and (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash -eq $bHash) 'Inactive tab received or lost output.'
        foreach($file in @(Get-ChildItem -LiteralPath $tabA,$tabB -Filter '*.png')){Check-Png $file.FullName}
    }
    Assert-True ($report.Cases.Count -eq 9) 'Not all required smoke cases executed.'
    $report.Passed=$true
}catch{$report.Error=$_.Exception.Message}finally{
    if($applicationStarted){
        try{$report.ApplicationClosed=[LaqayGuestDesktop]::CloseApplication();$report.ForcedTermination=[LaqayGuestDesktop]::WasApplicationForced;$report.ApplicationExitCode=[LaqayGuestDesktop]::ApplicationExitCode;if(-not $report.ApplicationClosed){$report.Passed=$false}}catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}
    }
    if($preferencesTouched){
        try{
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay',$true)
            $removeEmpty=$false
            if($key){try{
                if($enabledExisted){$key.SetValue('Enabled',$oldEnabled,$oldEnabledKind)}else{$key.DeleteValue('Enabled',$false)}
                $removeEmpty=-not $preferencesExisted -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
            }finally{$key.Dispose()}}
            if($removeEmpty){[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey('Software\Laqay',$false)}
            $report.PreferencesRestored=$true
        }catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}
    }
    try{[LaqayGuestDesktop]::CloseExplorerWindows()}catch{$report.CleanupErrors+=@($_.Exception.Message);$report.Passed=$false}
    if($shell){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    $report.FinishedUtc=[DateTime]::UtcNow.ToString('o')
    Save-Report
}
if(-not $report.Passed){exit 1}
