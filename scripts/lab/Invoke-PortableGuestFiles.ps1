# Host-side file/configuration operations. This script never boots or runs an app.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][System.Management.Automation.Runspaces.PSSession]$Session,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$CycleId,
    [Parameter(Mandatory=$true)][ValidateSet('Stage','Upgrade','Remove','Restore','Logon','ClearLogon')][string]$Action,
    [PSCredential]$Credential
)
$ErrorActionPreference='Stop'
# A literal Direct block works in the restricted guest endpoint without executing a script file there.
Invoke-Command -Session $Session -ArgumentList $LabId,$CycleId,$Action,$Credential -ScriptBlock {
    param($labId,$cycleId,$action,$credential)
    $ErrorActionPreference='Stop'
    $ready=Get-Content -LiteralPath 'C:\LaqayLab\ready.json' -Raw | ConvertFrom-Json
    $computer=Get-CimInstance Win32_ComputerSystem
    if($ready.LabId -ne $labId -or $ready.Role -ne 'Primary' -or -not $ready.Ready -or $computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine' -or (Get-CimInstance Win32_OperatingSystem).Caption -notlike '*Windows 11 Enterprise*'){throw 'File operations require the owned disposable Windows guest.'}
    if($cycleId -notmatch '^[a-f0-9]{32}$'){throw 'Invalid cycle identity.'}
    $root='C:\LaqayLab\Portable\'+$cycleId
    if(-not ('LaqayPortableFiles' -as [type])){
        Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem,System.Web.Extensions
        Add-Type -Path (Join-Path $root 'PortablePackageFiles.cs') -ReferencedAssemblies @('System.Core.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll','System.Web.Extensions.dll')
    }
    [LaqayPortableFiles]::Child('C:\LaqayLab\Portable',$root)
    $statePath=Join-Path $root 'state.json'
    $app='C:\LaqayLab\App';$package=Join-Path $app ('Portable-'+$cycleId);$baseline=Join-Path $root 'BaselineApp'
    $exe=Join-Path $package 'laqay.exe'
    $oldZip=Join-Path $root 'old.zip';$newZip=Join-Path $root 'new.zip'
    $oldArchive='1ad8b8fc002ae1b259702ccb567b12f4d28f3a0a6011b843c9e23b6a73263fa7'
    $newArchive='ba02df3dccebc34543bfae93c3a80ff4195d6c6f143d775e45621463309f9c23'
    $oldExe='61b7051456e0a75a8002e8ddbeff493c68e37270d20a4a53020d90cea849d92b'
    $newExe='3e73ff0b35661c23064101049f481dadeceb41bc31db21a0dcba7ec1aaf9632f'
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    function Save-State {$state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding UTF8}
    function Assert-NoProcess {if(@(Get-Process laqay -ErrorAction SilentlyContinue).Count){throw 'An application is still running; refusing file or preference changes.'}}
    function Assert-NoStartup {
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
        try{if($key -and $key.GetValueNames() -contains 'Laqay'){throw 'A startup value remains.'}}finally{if($key){$key.Dispose()}}
    }
    function Read-Preference {
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay')
        $result=[ordered]@{KeyExisted=($null -ne $key);EnabledExisted=$false;EnabledValue=0}
        if($key){try{
            if($key.SubKeyCount -ne 0 -or @($key.GetValueNames() | Where-Object {$_ -ne 'Enabled'}).Count){throw 'Unexpected preference schema; preserving it.'}
            $result.EnabledExisted=$key.GetValueNames() -contains 'Enabled'
            if($result.EnabledExisted){
                if($key.GetValueKind('Enabled') -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $key.GetValue('Enabled') -notin @(0,1)){throw 'Unexpected Enabled preference.'}
                $result.EnabledValue=[int]$key.GetValue('Enabled')
            }
        }finally{$key.Dispose()}}
        [pscustomobject]$result
    }
    function Clear-Preference {
        $current=Read-Preference
        if($current.KeyExisted){
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Laqay',$true)
            try{$key.DeleteValue('Enabled',$false)}finally{$key.Dispose()}
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey('Software\Laqay',$false)
        }
    }
    $logonNames=@('DefaultUserName','DefaultDomainName','AutoAdminLogon')
    if($action -eq 'Stage'){
        if(Test-Path -LiteralPath $statePath){throw 'Refusing an existing portable state.'}
        Assert-NoProcess;Assert-NoStartup
        $preferences=Read-Preference
        $oldInventory=[LaqayPortableFiles]::Archive($oldZip,$oldArchive,$oldExe)
        $newInventory=[LaqayPortableFiles]::Archive($newZip,$newArchive,$newExe)
        $inventory=[LaqayPortableFiles]::Snapshot($app)
        $executables=@(Get-ChildItem -LiteralPath $app -Filter laqay.exe -Recurse -File)
        if($executables.Count -ne 1 -or [LaqayPortableFiles]::Hash($executables[0].FullName) -ne '64e277ca0abca403b1e4849852fbfa003ffd84332f73fa9c3c9f90aa2ca30ceb'){throw 'The development baseline differs from the approved guest fixture.'}
        $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon')
        $logon=@()
        try{
            if($key.GetValueNames() -contains 'DefaultPassword' -or $key.GetValueNames() -contains 'AutoLogonCount' -or $key.GetValueNames() -contains 'LaqayPortableCycle' -or $key.GetValue('AutoAdminLogon') -eq '1'){throw 'An existing logon configuration cannot be replaced.'}
            foreach($name in $logonNames){
                $exists=$key.GetValueNames() -contains $name
                if($exists -and $key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::String){throw 'Unexpected logon value kind.'}
                $logon+=@([pscustomobject]@{Name=$name;Existed=$exists;Value=$key.GetValue($name)})
            }
        }finally{$key.Dispose()}
        if(Test-Path -LiteralPath $baseline){throw 'A baseline backup already exists.'}
        $state=[pscustomobject]@{LabId=$labId;CycleId=$cycleId;UserSid=$sid;Executable=$exe;Stage='Preparing';
            OldExecutableSha256=$oldExe;NewExecutableSha256=$newExe;OldInventory=$oldInventory;NewInventory=$newInventory;
            BaselineInventory=$inventory;Preferences=$preferences;Logon=$logon;RemovalBootUtc=$null;Restored=$false}
        Save-State
        [IO.Directory]::Move($app,$baseline)
        [IO.Directory]::CreateDirectory($app) | Out-Null
        [LaqayPortableFiles]::Install($app,$package,$oldZip,$oldArchive,$oldExe)
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Laqay')
        try{$key.SetValue('Enabled',1,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$key.Dispose()}
        $state.Stage='Old';Save-State
    }else{
        $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if($state.LabId -ne $labId -or $state.CycleId -ne $cycleId -or $state.UserSid -ne $sid -or $state.Executable -ne $exe -or $state.OldExecutableSha256 -ne $oldExe -or $state.NewExecutableSha256 -ne $newExe){throw 'Portable backup ownership mismatch.'}
        if($action -in @('Logon','ClearLogon')){
            $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon',$true)
            try{
                $marker=$key.GetValue('LaqayPortableCycle')
                if($marker -and $marker -ne $cycleId){throw 'A different cycle owns temporary logon.'}
                if(-not $marker -and ($key.GetValueNames() -contains 'DefaultPassword' -or $key.GetValueNames() -contains 'AutoLogonCount' -or $key.GetValue('AutoAdminLogon') -eq '1')){throw 'Refusing unowned automatic logon.'}
                if($action -eq 'Logon'){
                    if(-not $credential -or $credential.UserName -notmatch '(^|\\)LaqayLab$'){throw 'The lab credential is required.'}
                    $key.SetValue('LaqayPortableCycle',$cycleId,[Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('DefaultUserName','LaqayLab',[Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('DefaultDomainName',$env:COMPUTERNAME,[Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('DefaultPassword',$credential.GetNetworkCredential().Password,[Microsoft.Win32.RegistryValueKind]::String)
                    $key.SetValue('AutoLogonCount',1,[Microsoft.Win32.RegistryValueKind]::DWord)
                    $key.SetValue('AutoAdminLogon','1',[Microsoft.Win32.RegistryValueKind]::String)
                }else{
                    if($marker){
                        $key.DeleteValue('DefaultPassword',$false);$key.DeleteValue('AutoLogonCount',$false)
                        foreach($item in $state.Logon){if($item.Existed){$key.SetValue($item.Name,[string]$item.Value,[Microsoft.Win32.RegistryValueKind]::String)}else{$key.DeleteValue($item.Name,$false)}}
                        $key.DeleteValue('LaqayPortableCycle',$false)
                    }
                    if($key.GetValueNames() -contains 'DefaultPassword' -or $key.GetValueNames() -contains 'AutoLogonCount' -or $key.GetValueNames() -contains 'LaqayPortableCycle'){throw 'Temporary logon cleanup is incomplete.'}
                    foreach($item in $state.Logon){if(($key.GetValueNames() -contains $item.Name) -ne $item.Existed -or ($item.Existed -and $key.GetValue($item.Name) -ne $item.Value)){throw 'The original logon values were not restored.'}}
                }
            }finally{$key.Dispose()}
        }else{
            Assert-NoProcess
            if($action -eq 'Restore'){
                # Restore only the exact startup command created by this cycle.
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$true)
                try{if($key -and $key.GetValueNames() -contains 'Laqay'){
                    if($key.GetValueKind('Laqay') -ne [Microsoft.Win32.RegistryValueKind]::String -or $key.GetValue('Laqay') -ne ('"'+$exe+'"')){throw 'An unowned startup command cannot be removed.'}
                    $key.DeleteValue('Laqay',$false)
                }}finally{if($key){$key.Dispose()}}
            }
            Assert-NoStartup
            if($action -eq 'Upgrade'){
                if($state.Stage -ne 'Old'){throw 'Upgrade requires the old package.'}
                [LaqayPortableFiles]::Remove($app,$package,$state.OldInventory)
                $state.Stage='BetweenVersions';Save-State
                [LaqayPortableFiles]::Install($app,$package,$newZip,$newArchive,$newExe)
                $state.Stage='New';Save-State
            }elseif($action -eq 'Remove'){
                if($state.Stage -ne 'New'){throw 'Removal requires the new package.'}
                [LaqayPortableFiles]::Remove($app,$package,$state.NewInventory)
                Clear-Preference
                $state.RemovalBootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
                $state.Stage='Removed';Save-State
            }elseif($action -eq 'Restore'){
                if(Test-Path -LiteralPath $baseline){
                    [LaqayPortableFiles]::Verify($baseline,$state.BaselineInventory)
                    if(Test-Path -LiteralPath $package){
                        $actual=[LaqayPortableFiles]::Snapshot($package)
                        if($actual -ceq $state.OldInventory){[LaqayPortableFiles]::Remove($app,$package,$state.OldInventory)}
                        elseif($actual -ceq $state.NewInventory){[LaqayPortableFiles]::Remove($app,$package,$state.NewInventory)}
                        else{throw 'Preserving a changed or partially installed package and its baseline backup.'}
                    }
                    [LaqayPortableFiles]::NoReparse($app)
                    if(Test-Path -LiteralPath $app){[IO.Directory]::Delete($app,$false)}
                    [IO.Directory]::Move($baseline,$app)
                }
                [LaqayPortableFiles]::Verify($app,$state.BaselineInventory)
                Clear-Preference
                if($state.Preferences.KeyExisted){
                    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Laqay')
                    try{if($state.Preferences.EnabledExisted){$key.SetValue('Enabled',[int]$state.Preferences.EnabledValue,[Microsoft.Win32.RegistryValueKind]::DWord)}}finally{$key.Dispose()}
                }
                if((Read-Preference | ConvertTo-Json -Compress) -cne ($state.Preferences | ConvertTo-Json -Compress)){throw 'Original preferences were not restored.'}
                foreach($archiveInput in @(@{Path=$oldZip;Hash=$oldArchive},@{Path=$newZip;Hash=$newArchive})){
                    if(Test-Path -LiteralPath $archiveInput.Path){[LaqayPortableFiles]::Child($root,$archiveInput.Path);if([LaqayPortableFiles]::Hash($archiveInput.Path) -ne $archiveInput.Hash){throw 'Preserving a changed package input.'};[IO.File]::Delete($archiveInput.Path)}
                }
                $state.Stage='Restored';$state.Restored=$true;Save-State
            }
        }
    }
    [pscustomobject]@{LabId=$labId;CycleId=$cycleId;Action=$action;Stage=$state.Stage;Restored=$state.Restored;Passed=$true}
}
