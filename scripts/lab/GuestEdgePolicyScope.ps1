# This literal block runs only through the owned guest's administrative session.
$GuestEdgePolicyScope = {
    param($action,$labId,$runId,$runRoot)
    $ErrorActionPreference='Stop'
    if($action -notin @('Prepare','Restore') -or $labId -notmatch '^[a-f0-9]{32}$' -or $runId -notmatch '^[a-f0-9]{32}$' -or $runRoot -cne ('C:\LaqayLab\Runs\'+$runId)){throw 'Unexpected Edge policy scope or action.'}
    $ready=Get-Content -LiteralPath 'C:/LaqayLab/ready.json' -Raw | ConvertFrom-Json
    $hardware=Get-CimInstance Win32_ComputerSystem
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=[Security.Principal.WindowsPrincipal]::new($identity)
    $account=Get-LocalUser -Name LaqayLab
    if($ready.LabId -ne $labId -or $ready.Role -ne 'Primary' -or -not $ready.Ready -or $hardware.Manufacturer -ne 'Microsoft Corporation' -or $hardware.Model -ne 'Virtual Machine' -or $identity.User.Value -ne $account.SID.Value -or -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Edge policies require the owned Primary guest administrative user.'}
    if(-not (Test-Path -LiteralPath $runRoot -PathType Container)){throw 'Missing owned guest run.'}
    for($directory=Get-Item -LiteralPath $runRoot;$null -ne $directory;$directory=$directory.Parent){if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A policy scope ancestor is a reparse point.'}}
    $path='SOFTWARE\Policies\Microsoft\Edge'
    $allowedKeys=@('SOFTWARE','SOFTWARE\Policies','SOFTWARE\Policies\Microsoft',$path)
    $names=@('StartupBoostEnabled','BackgroundModeEnabled')
    $journal=Join-Path $runRoot 'edge-policy-scope.json'
    if((Test-Path -LiteralPath $journal) -and ((Get-Item -LiteralPath $journal).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The policy scope journal is a reparse point.'}
    if($action -eq 'Prepare'){
        if(Test-Path -LiteralPath $journal){throw 'Refusing a reused Edge policy scope.'}
        $values=@(foreach($name in $names){
            $machine=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path)
            try{if($machine -and $null -ne $machine.GetValue($name) -and ($machine.GetValueKind($name) -ne 'DWord' -or [int]$machine.GetValue($name) -ne 0)){throw 'A machine Edge background policy conflicts with the test.'}}finally{if($machine){$machine.Dispose()}}
            $user=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
            try{
                $exists=$user -and $null -ne $user.GetValue($name)
                if($exists -and $user.GetValueKind($name) -ne 'DWord'){throw 'Unexpected Edge policy value type.'}
                [pscustomobject]@{Name=$name;Existed=[bool]$exists;Kind='DWord';Value=$(if($exists){[int]$user.GetValue($name)}else{0})}
            }finally{if($user){$user.Dispose()}}
        })
        $created=@(foreach($keyPath in $allowedKeys){$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($keyPath);try{if(-not $key){$keyPath}}finally{if($key){$key.Dispose()}}})
        $scope=[pscustomobject]@{Schema=1;LabId=$labId;RunId=$runId;UserSid=$identity.User.Value;Prepared=$false;Restored=$false;Values=$values;CreatedKeys=$created;VerifiedValues=@()}
        $scope | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $journal -Encoding UTF8
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path)
        try{foreach($name in $names){$key.SetValue($name,0,[Microsoft.Win32.RegistryValueKind]::DWord)};foreach($name in $names){if($key.GetValueKind($name) -ne 'DWord' -or [int]$key.GetValue($name) -ne 0){throw 'Temporary Edge policy readback failed.'}}}finally{if($key){$key.Dispose()}}
        $scope.Prepared=$true
    }else{
        if(-not (Test-Path -LiteralPath $journal)){return [pscustomobject]@{Prepared=$false;Restored=$true;NothingToRestore=$true}}
        $scope=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
        if($scope.Schema -ne 1 -or $scope.LabId -ne $labId -or $scope.RunId -ne $runId -or $scope.UserSid -ne $identity.User.Value -or @($scope.Values).Count -ne 2 -or @(Compare-Object @($scope.Values.Name) $names).Count -or @($scope.CreatedKeys | Where-Object {$_ -notin $allowedKeys}).Count){throw 'Unexpected Edge policy restoration identity.'}
        foreach($value in $scope.Values){if($value.Existed -isnot [bool] -or $value.Kind -ne 'DWord'){throw 'Unexpected Edge policy restoration value.'}}
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path,$true)
        try{
            if(-not $key -and @($scope.Values | Where-Object Existed).Count){throw 'The original Edge policy key disappeared.'}
            if($key){foreach($value in $scope.Values){if($value.Existed){$key.SetValue($value.Name,[int]$value.Value,[Microsoft.Win32.RegistryValueKind]::DWord)}else{$key.DeleteValue($value.Name,$false)}}}
        }finally{if($key){$key.Dispose()}}
        $verified=@(foreach($value in $scope.Values){
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
            try{
                $actual=$(if($key){$key.GetValue($value.Name)}else{$null})
                $exists=$null -ne $actual
                if($exists -ne $value.Existed -or ($exists -and ($key.GetValueKind($value.Name) -ne 'DWord' -or [int]$actual -ne [int]$value.Value))){throw 'An Edge policy did not restore its original value/type.'}
                [pscustomobject]@{Name=$value.Name;Existed=$exists;Kind='DWord';Value=$(if($exists){[int]$actual}else{0})}
            }finally{if($key){$key.Dispose()}}
        })
        foreach($keyPath in @($scope.CreatedKeys | Sort-Object Length -Descending)){
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($keyPath)
            try{if($key -and ($key.ValueCount -or $key.SubKeyCount)){throw 'A temporary policy key contains unexpected entries.'}}finally{if($key){$key.Dispose()}}
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($keyPath,$false)
        }
        $scope.VerifiedValues=$verified;$scope.Restored=$true
    }
    $scope | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $journal -Encoding UTF8
    $scope
}
