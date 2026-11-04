# Only the disposable hosted runner may create and withdraw this owned SMB share.
$ErrorActionPreference='Stop'
function Assert-ShareRunner([string]$actions,[string]$environment,[string]$os,[bool]$administrator){
    if($actions -cne 'true' -or $environment -cne 'github-hosted' -or $os -cne 'Windows' -or -not $administrator){throw 'Share withdrawal testing requires an administrative GitHub-hosted Windows runner.'}
}
function Get-SharePlan([string]$runnerTemp,[string]$token){
    if($token -cnotmatch '^[a-f0-9]{32}$' -or $runnerTemp -notmatch '^[A-Za-z]:\\' -or $runnerTemp -match '["\r\n]'){throw 'Unexpected share fixture identity or path.'}
    $scope=Join-Path ([IO.Path]::GetFullPath($runnerTemp).TrimEnd('\')) ('Laqay.Share.'+$token)
    $name='LaqayShare-'+$token
    [pscustomobject]@{Token=$token;Scope=$scope;Data=(Join-Path $scope 'data');Control=(Join-Path $scope 'control');Name=$name;Unc=('\\127.0.0.1\'+$name)}
}
function Write-ShareMarker([string]$path,[string]$token){
    $temporary=$path+'.tmp'
    if([IO.File]::Exists($path) -or [IO.File]::Exists($temporary)){throw 'Refusing a reused controller marker.'}
    [IO.File]::WriteAllText($temporary,$token)
    [IO.File]::Move($temporary,$path)
}
function Assert-OwnShare($plan){
    $share=Get-SmbShare -Name $plan.Name -ErrorAction Stop
    if(@($share).Count -ne 1 -or $share.Path -cne $plan.Data -or $share.Description -cne ('Laqay isolated share '+$plan.Token) -or -not $share.Temporary){throw 'The SMB share does not match the owned fixture.'}
}
$administrator=([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Assert-ShareRunner $env:GITHUB_ACTIONS $env:RUNNER_ENVIRONMENT $env:RUNNER_OS $administrator
$plan=Get-SharePlan $env:RUNNER_TEMP ([guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $plan.Scope){throw 'Refusing a reused share fixture.'}
for($ancestor=Get-Item -LiteralPath $env:RUNNER_TEMP;$null -ne $ancestor;$ancestor=$ancestor.Parent){if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A share fixture ancestor is a reparse point.'}}
if((Get-Service LanmanServer).Status -ne 'Running'){throw 'The hosted runner SMB server must already be running.'}
if(Get-SmbShare -Name $plan.Name -ErrorAction SilentlyContinue){throw 'Refusing an existing SMB share name.'}
$output=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../target'))
[IO.Directory]::CreateDirectory($output) | Out-Null
$report=[ordered]@{Schema=1;Token=$plan.Token;Name=$plan.Name;Unc=$plan.Unc;Data=$plan.Data;Control=$plan.Control;Prepared=$false;Connection=@();Staged=$null;OriginalHash=$null;Withdrawn=$false;UnavailableError=$null;Failure=$null;Restored=$false;Native=$null;NativeExit=$null;Forced=$false;NativePassed=$false;ControllerRemovedStaging=0;ShareRemoved=$false;ScopeRemoved=$false;Passed=$false;Error=$null;CleanupErrors=@()}
$child=$null;$stdout=$null;$stderr=$null;$created=$false
$account=[Security.Principal.WindowsIdentity]::GetCurrent().Name
function New-OwnShare {
    if(Get-SmbShare -Name $plan.Name -ErrorAction SilentlyContinue){throw 'Refusing to replace an existing share.'}
    New-SmbShare -Name $plan.Name -Path $plan.Data -Description ('Laqay isolated share '+$plan.Token) -FullAccess $account -Temporary -CachingMode None | Out-Null
    Assert-OwnShare $plan
}
function Wait-SharePhase([string]$name){
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    $path=Join-Path $plan.Control $name
    do{
        if([IO.File]::Exists($path)){return ([IO.File]::ReadAllText($path) | ConvertFrom-Json)}
        if($child.HasExited){throw ('The owned native test exited before phase '+$name)}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    throw ('Timed out waiting for phase '+$name)
}
try{
    $PSNativeCommandUseErrorActionPreference=$false
    $build=Join-Path $output 'share-build.log'
    cargo test --locked --all-features --lib --no-run --message-format=json 2>&1 | Tee-Object -FilePath $build
    if($LASTEXITCODE -ne 0){throw 'The native share fixture did not build.'}
    $executables=@(foreach($line in Get-Content -LiteralPath $build){try{$entry=$line | ConvertFrom-Json;if($entry.reason -eq 'compiler-artifact' -and $entry.profile.test -and $entry.target.name -eq 'laqay' -and $entry.executable){[string]$entry.executable}}catch{}})
    if($executables.Count -ne 1){throw 'The library test executable is ambiguous.'}
    $executable=[IO.Path]::GetFullPath($executables[0])
    if(-not $executable.StartsWith($output+'\debug\deps\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($executable) -cne '.exe' -or -not (Test-Path -LiteralPath $executable -PathType Leaf)){throw 'Unexpected native test executable.'}
    [IO.Directory]::CreateDirectory($plan.Control) | Out-Null
    [IO.Directory]::CreateDirectory($plan.Data) | Out-Null;$created=$true
    $acl=Get-Acl -LiteralPath $plan.Data
    $inheritance=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
    $acl.SetAccessRule($rule);Set-Acl -LiteralPath $plan.Data -AclObject $acl
    foreach($directory in @($plan.Scope,$plan.Control,$plan.Data)){[IO.File]::WriteAllText((Join-Path $directory 'owner.txt'),$plan.Token)}
    New-OwnShare;$report.Prepared=$true
    $access=@(Get-SmbShareAccess -Name $plan.Name)
    if(@($access | Where-Object {$_.AccessControlType -ne 'Allow' -or $_.AccessRight -ne 'Full' -or $_.AccountName -ine $account}).Count -or $access.Count -ne 1){throw 'Unexpected share access permissions.'}
    $info=[Diagnostics.ProcessStartInfo]::new($executable)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.WorkingDirectory=$output;$info.Arguments='--exact storage_tests::share_withdrawal_before_publication_recovers --ignored --nocapture'
    $info.Environment['LAQAY_SHARE_TEST_ROOT']=$plan.Unc
    $info.Environment['LAQAY_SHARE_TEST_CONTROL']=$plan.Control
    $info.Environment['LAQAY_SHARE_TEST_TOKEN']=$plan.Token
    $child=[Diagnostics.Process]::Start($info);$ownedHandle=$child.Handle
    $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
    $staged=Wait-SharePhase 'staged.json';$report.Staged=$staged
    if($staged.pid -ne $child.Id -or $staged.staging -cnotmatch ('^\.laqay-'+$child.Id+'-[0-9]+\.tmp$') -or $staged.original -cne 'Screenshot_20261104_010203.png' -or $staged.target -cne 'Screenshot_20261104_010204.png'){throw 'The staged native request has an unexpected identity.'}
    $original=Join-Path $plan.Data $staged.original
    $stagePath=Join-Path $plan.Data $staged.staging
    if((Get-Item -LiteralPath $stagePath).Length -ne $staged.payload_bytes){throw 'The native PNG staging data is incomplete.'}
    $report.OriginalHash=(Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash
    $connections=@(Get-SmbConnection | Where-Object {$_.ShareName -ceq $plan.Name})
    if(-not $connections.Count -or @($connections | Where-Object {$_.ServerName -notin @('127.0.0.1','localhost',$env:COMPUTERNAME)}).Count){throw 'No matching loopback SMB connection was observed.'}
    $report.Connection=@($connections | Select-Object ServerName,ShareName,Dialect)
    Assert-OwnShare $plan
    Remove-SmbShare -Name $plan.Name -Force -Confirm:$false
    if(Get-SmbShare -Name $plan.Name -ErrorAction SilentlyContinue){throw 'The owned share survived withdrawal.'}
    try{[IO.File]::ReadAllText((Join-Path $plan.Unc 'owner.txt')) | Out-Null;throw 'The withdrawn UNC path is still readable.'}
    catch [IO.IOException]{$report.UnavailableError=$_.Exception.GetBaseException().HResult -band 0xFFFF}
    if($report.UnavailableError -notin @(53,64,67,1203,1231,1232,2250)){throw 'The UNC probe did not confirm a network-path failure.'}
    $report.Withdrawn=$true
    Write-ShareMarker (Join-Path $plan.Control 'withdrawn.txt') $plan.Token
    $failure=Wait-SharePhase 'failed.json';$report.Failure=$failure
    if($failure.pid -ne $child.Id -or $failure.error -notin @(53,64,67,1203,1231,1232,2250)){throw 'The native publication did not fail on the withdrawn resource.'}
    if(@(Get-ChildItem -LiteralPath $plan.Data -Filter '*.png').Count -ne 1 -or (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -cne $report.OriginalHash){throw 'Withdrawal published unexpected PNG output or changed the original.'}
    New-OwnShare
    $deadline=[DateTime]::UtcNow.AddSeconds(15);$available=$false
    do{try{$available=[IO.File]::ReadAllText((Join-Path $plan.Unc 'owner.txt')) -ceq $plan.Token}catch{};if(-not $available){Start-Sleep -Milliseconds 100}}while(-not $available -and [DateTime]::UtcNow -lt $deadline)
    if(-not $available){throw 'The restored share did not expose its original owner.'}
    $report.Restored=$true
    Write-ShareMarker (Join-Path $plan.Control 'restored.txt') $plan.Token
    if(-not $child.WaitForExit(30000) -or $child.ExitCode -ne 0){throw 'The native recovery test did not exit normally.'}
    $text=$stdout.GetAwaiter().GetResult()
    $proof=[regex]::Matches($text,'LAQAY_SHARE_RESULT (\{[^\r\n]+\})')
    if($proof.Count -ne 1){throw 'Missing unique native share evidence.'}
    $native=$proof[0].Groups[1].Value | ConvertFrom-Json
    if($native.writer_error -ne $failure.error -or $native.no_incomplete_png -ne $true -or $native.original_preserved -ne $true -or $native.new_image_recovered -ne $true -or $native.staging_after_reconnect -notin @(0,1)){throw 'The native result did not prove safe failure and fresh-image recovery.'}
    $residue=@(Get-ChildItem -LiteralPath $plan.Data -Force | Where-Object Name -ne 'owner.txt')
    if($residue.Count -ne $native.staging_after_reconnect -or @($residue | Where-Object {$_.Name -cne $staged.staging -or $_.Length -ne $staged.payload_bytes}).Count){throw 'Unexpected post-recovery residue.'}
    $report.Native=$native;$report.NativePassed=$true
}catch{$report.Error=$_.Exception.Message}finally{
    if($child){try{
        if(-not $child.HasExited){$abort=Join-Path $plan.Control 'abort.txt';if(-not [IO.File]::Exists($abort)){Write-ShareMarker $abort $plan.Token};if(-not $child.WaitForExit(5000)){$report.Forced=$true;$child.Kill($true);if(-not $child.WaitForExit(5000)){throw 'The exact native test survived cleanup.'}}}
        $report.NativeExit=$child.ExitCode
        if($stdout){[IO.File]::WriteAllText((Join-Path $output 'share-test-results.log'),$stdout.GetAwaiter().GetResult())}
        if($stderr){[IO.File]::WriteAllText((Join-Path $output 'share-test-stderr.log'),$stderr.GetAwaiter().GetResult())}
        $child.Dispose()
    }catch{$report.CleanupErrors+=@($_.Exception.Message)}}
    if($created){try{
        if(Get-SmbShare -Name $plan.Name -ErrorAction SilentlyContinue){Assert-OwnShare $plan;Remove-SmbShare -Name $plan.Name -Force -Confirm:$false}
        $report.ShareRemoved=-not [bool](Get-SmbShare -Name $plan.Name -ErrorAction SilentlyContinue)
        if(-not $report.ShareRemoved){throw 'The owned share remains registered.'}
    }catch{$report.CleanupErrors+=@($_.Exception.Message)}}
    if($created -and $report.ShareRemoved){try{
        if([IO.File]::ReadAllText((Join-Path $plan.Scope 'owner.txt')) -cne $plan.Token){throw 'The share scope owner changed.'}
        foreach($directory in @($plan.Data,$plan.Control)){
            foreach($file in @(Get-ChildItem -LiteralPath $directory -Force)){
                $valid=if($directory -ceq $plan.Data){$file.Name -in @('owner.txt','Screenshot_20261104_010203.png','Screenshot_20261104_010204.png') -or ($report.Staged -and $file.Name -ceq $report.Staged.staging)}else{$file.Name -in @('owner.txt','staged.json','failed.json','withdrawn.txt','restored.txt','abort.txt')}
                if(-not $valid -or $file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Refusing unexpected share fixture contents.'}
                if($file.Name -like '.laqay-*.tmp'){$report.ControllerRemovedStaging++}
                Remove-Item -LiteralPath $file.FullName
            }
            [IO.Directory]::Delete($directory)
        }
        Remove-Item -LiteralPath (Join-Path $plan.Scope 'owner.txt')
        if([IO.Path]::GetFullPath($plan.Scope) -cne $plan.Scope -or [IO.Path]::GetFileName($plan.Scope) -cne ('Laqay.Share.'+$plan.Token)){throw 'Unexpected share cleanup path.'}
        [IO.Directory]::Delete($plan.Scope);$report.ScopeRemoved=-not (Test-Path -LiteralPath $plan.Scope)
    }catch{$report.CleanupErrors+=@($_.Exception.Message)}}
    $report.Passed=$report.NativePassed -and $report.NativeExit -eq 0 -and -not $report.Forced -and $report.Withdrawn -and $report.Restored -and $report.ShareRemoved -and $report.ScopeRemoved -and -not $report.Error -and -not $report.CleanupErrors.Count
    [IO.File]::WriteAllText((Join-Path $output 'share-failure-report.json'),($report | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
if(-not $report.Passed){throw ('Share withdrawal validation or cleanup failed: '+$report.Error+' '+($report.CleanupErrors -join '; '))}
Write-Output 'Real SMB withdrawal and fresh-image recovery passed; share and fixture removed. Controller staging cleanup is recorded separately.'
