# This harness may attach a small scratch VHD only on a disposable hosted runner.
$ErrorActionPreference='Stop'
function Assert-StorageRunner([string]$actions,[string]$environment,[string]$os,[bool]$administrator){
    if($actions -cne 'true' -or $environment -cne 'github-hosted' -or $os -cne 'Windows' -or -not $administrator){throw 'Storage capacity testing requires an administrative GitHub-hosted Windows runner.'}
}
function Get-StoragePlan([string]$runnerTemp,[string]$token,[string]$letter){
    if($token -cnotmatch '^[a-f0-9]{32}$' -or $letter -cnotmatch '^[R-Z]$' -or $runnerTemp -notmatch '^[A-Za-z]:\\' -or $runnerTemp -match '["\r\n]'){throw 'Unexpected storage fixture identity or path.'}
    $temporary=[IO.Path]::GetFullPath($runnerTemp).TrimEnd('\')
    $scope=Join-Path $temporary ('Laqay.Storage.'+$token)
    $image=Join-Path $scope 'scratch.vhd'
    $label='LQST'+$token.Substring(0,8).ToUpperInvariant()
    [pscustomobject]@{Token=$token;Scope=$scope;Image=$image;Label=$label;Drive=($letter+':\');Letter=$letter;MaximumBytes=64MB;
        Data=($letter+':\LaqayStorageTest-'+$token);
        Commands=@(('create vdisk file="'+$image+'" maximum=64 type=expandable'),('select vdisk file="'+$image+'"'),'attach vdisk','create partition primary',('format fs=ntfs label='+$label+' quick'),('assign letter='+$letter),'exit')}
}
$administrator=([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Assert-StorageRunner $env:GITHUB_ACTIONS $env:RUNNER_ENVIRONMENT $env:RUNNER_OS $administrator
$letters=@([IO.DriveInfo]::GetDrives() | ForEach-Object {$_.Name.Substring(0,1)})
$letter=@('R','S','T','U','V','W','X','Y','Z' | Where-Object {$_ -notin $letters}) | Select-Object -First 1
if(-not $letter){throw 'No unused scratch drive letter is available.'}
$plan=Get-StoragePlan $env:RUNNER_TEMP ([guid]::NewGuid().ToString('N')) $letter
if(Test-Path -LiteralPath $plan.Scope){throw 'Refusing a reused storage fixture.'}
for($ancestor=Get-Item -LiteralPath $env:RUNNER_TEMP;$null -ne $ancestor;$ancestor=$ancestor.Parent){if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The runner temporary path contains a reparse point.'}}
$output=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../target'))
[IO.Directory]::CreateDirectory($output) | Out-Null
$reportPath=Join-Path $output 'storage-failure-report.json'
$report=[ordered]@{Schema=1;Token=$plan.Token;Image=$plan.Image;MaximumBytes=$plan.MaximumBytes;Drive=$plan.Drive;Label=$plan.Label;DiskNumber=$null;VolumeId=$null;VolumeBytes=$null;FileSystem=$null;ImageBytesAfter=$null;Prepared=$false;NativePassed=$false;Native=$null;Detached=$false;ImageRemoved=$false;ScopeRemoved=$false;Passed=$false;Error=$null;CleanupErrors=@()}
$created=$false;$oldRoot=$env:LAQAY_STORAGE_TEST_ROOT;$oldToken=$env:LAQAY_STORAGE_TEST_TOKEN
try{
    [IO.Directory]::CreateDirectory($plan.Scope) | Out-Null;$created=$true
    [IO.File]::WriteAllText((Join-Path $plan.Scope 'owner.txt'),$plan.Token)
    $commands=Join-Path $plan.Scope 'prepare.txt'
    [IO.File]::WriteAllLines($commands,[string[]]$plan.Commands,[Text.Encoding]::ASCII)
    & (Join-Path $env:SystemRoot 'System32/diskpart.exe') /s $commands *> (Join-Path $output 'storage-diskpart.log')
    if($LASTEXITCODE -ne 0){throw 'DiskPart did not prepare the scratch image.'}
    $image=Get-DiskImage -ImagePath $plan.Image
    $disk=$image | Get-Disk
    $volume=Get-Volume -DriveLetter $plan.Letter
    $partition=Get-Partition -DriveLetter $plan.Letter
    if(@($disk).Count -ne 1 -or @($partition).Count -ne 1 -or @($volume).Count -ne 1 -or -not $image.Attached -or $disk.IsSystem -or $disk.IsBoot -or $disk.Size -ne 64MB -or $partition.DiskNumber -ne $disk.Number -or $volume.FileSystem -ne 'NTFS' -or $volume.FileSystemLabel -cne $plan.Label){throw 'The scratch volume does not match the newly created image.'}
    if((Get-Item -LiteralPath $plan.Image).Length -gt 96MB){throw 'The scratch image exceeded its bounded size.'}
    [IO.Directory]::CreateDirectory($plan.Data) | Out-Null
    [IO.File]::WriteAllText((Join-Path $plan.Data 'owner.txt'),$plan.Token)
    $report.DiskNumber=$disk.Number;$report.VolumeId=$volume.UniqueId;$report.VolumeBytes=$volume.Size;$report.FileSystem=$volume.FileSystem
    $report.Prepared=$true
    $env:LAQAY_STORAGE_TEST_ROOT=$plan.Data;$env:LAQAY_STORAGE_TEST_TOKEN=$plan.Token
    $PSNativeCommandUseErrorActionPreference=$false
    $log=Join-Path $output 'storage-test-results.log'
    cargo test --locked --all-features --lib storage_tests::disk_full_cleans_failed_write_and_recovers -- --ignored --exact --nocapture 2>&1 | Tee-Object -FilePath $log
    if($LASTEXITCODE -ne 0){throw 'The real-capacity writer test failed.'}
    $report.ImageBytesAfter=(Get-Item -LiteralPath $plan.Image).Length
    if($report.ImageBytesAfter -gt 96MB){throw 'The scratch image exceeded its bounded size during the test.'}
    $matchesFound=[regex]::Matches([IO.File]::ReadAllText($log),'LAQAY_STORAGE_RESULT (\{[^\r\n]+\})')
    if($matchesFound.Count -ne 1){throw 'Missing unique native capacity-test evidence.'}
    $native=$matchesFound[0].Groups[1].Value | ConvertFrom-Json
    if($native.fill_error -notin @(39,112) -or $native.writer_error -notin @(39,112) -or $native.recovered -ne $true -or $native.original_preserved -ne $true -or $native.no_staging -ne $true -or $native.filled_bytes -gt 64MB){throw 'The native evidence did not prove capacity failure and recovery.'}
    $contents=@(Get-ChildItem -LiteralPath $plan.Data -Force)
    if($contents.Count -ne 1 -or $contents[0].Name -cne 'owner.txt' -or [IO.File]::ReadAllText($contents[0].FullName) -cne $plan.Token){throw 'The capacity test left unexpected staging or output.'}
    $report.Native=$native;$report.NativePassed=$true
}catch{$report.Error=$_.Exception.Message}finally{
    $env:LAQAY_STORAGE_TEST_ROOT=$oldRoot;$env:LAQAY_STORAGE_TEST_TOKEN=$oldToken
    if($created){try{
        if([IO.File]::ReadAllText((Join-Path $plan.Scope 'owner.txt')) -cne $plan.Token){throw 'The scratch fixture owner changed.'}
        if(Test-Path -LiteralPath $plan.Image){
            $image=Get-DiskImage -ImagePath $plan.Image
            if($image.Attached){Dismount-DiskImage -ImagePath $plan.Image}
            if((Get-DiskImage -ImagePath $plan.Image).Attached){throw 'The scratch image remained attached.'}
        }
        $report.Detached=$true
        foreach($item in @(Get-ChildItem -LiteralPath $plan.Scope -Force)){
            if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Name -notin @('owner.txt','prepare.txt','scratch.vhd')){throw 'Refusing unexpected scratch fixture contents.'}
        }
        if(Test-Path -LiteralPath $plan.Image){Remove-Item -LiteralPath $plan.Image}
        $report.ImageRemoved=-not (Test-Path -LiteralPath $plan.Image)
        foreach($name in @('prepare.txt','owner.txt')){$path=Join-Path $plan.Scope $name;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
        if([IO.Path]::GetFullPath($plan.Scope) -cne $plan.Scope -or [IO.Path]::GetFileName($plan.Scope) -cne ('Laqay.Storage.'+$plan.Token)){throw 'Unexpected scratch cleanup path.'}
        [IO.Directory]::Delete($plan.Scope)
        $report.ScopeRemoved=-not (Test-Path -LiteralPath $plan.Scope)
    }catch{$report.CleanupErrors+=@($_.Exception.Message)}}
    $report.Passed=$report.NativePassed -and -not $report.Error -and -not $report.CleanupErrors.Count -and $report.Detached -and $report.ImageRemoved -and $report.ScopeRemoved
    [IO.File]::WriteAllText($reportPath,($report | ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
}
if(-not $report.Passed){throw ('Storage validation or cleanup failed: '+$report.Error+' '+($report.CleanupErrors -join '; '))}
Write-Output 'Real disk-full writer failure and recovery passed; the scratch image was detached and removed.'
