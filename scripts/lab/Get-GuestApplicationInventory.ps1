[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][Management.Automation.Runspaces.PSSession]$Session,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$LabId
)
$ErrorActionPreference='Stop'
# Read-only metadata, sent as a literal block because the guest remoting endpoint
# does not execute script files. No application or interactive task is started.
Invoke-Command -Session $Session -ArgumentList $LabId -ScriptBlock {
    param($labId)
    $ErrorActionPreference='Stop'
    if(-not (Test-Path -LiteralPath 'C:\LaqayLab\ready.json')){throw 'Unexpected inventory guest marker.'}
    $ready=Get-Content -LiteralPath 'C:\LaqayLab\ready.json' -Raw | ConvertFrom-Json
    if($ready.LabId -ne $labId -or $ready.Role -ne 'Primary' -or -not $ready.Ready){throw 'Unexpected inventory guest identity.'}
    $machine=Get-CimInstance Win32_ComputerSystem
    if($machine.Manufacturer -ne 'Microsoft Corporation' -or $machine.Model -ne 'Virtual Machine'){throw 'Unexpected inventory guest hardware.'}
    $os=Get-CimInstance Win32_OperatingSystem
    if(-not $os.Caption.Contains('Windows 11 Enterprise')){throw 'Unexpected inventory guest operating system.'}
    if(@(Get-Process laqay -ErrorAction SilentlyContinue).Count){throw 'The inventory requires no running Laqay instance.'}
    $errors=@();$executables=@();$packages=@();$provisioned=@()
    $known=@(
        @{Name='Notepad launcher';Path='C:\Windows\System32\notepad.exe'},
        @{Name='VS Code system';Path='C:\Program Files\Microsoft VS Code\Code.exe'},
        @{Name='VS Code user';Path='C:\Users\LaqayLab\AppData\Local\Programs\Microsoft VS Code\Code.exe'},
        @{Name='Windows Terminal alias';Path='C:\Users\LaqayLab\AppData\Local\Microsoft\WindowsApps\wt.exe'},
        @{Name='Edge x86';Path='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'},
        @{Name='Edge x64';Path='C:\Program Files\Microsoft\Edge\Application\msedge.exe'}
    )
    try{
        $jetbrains='C:\Program Files\JetBrains'
        if(Test-Path -LiteralPath $jetbrains){
            foreach($directory in @(Get-ChildItem -LiteralPath $jetbrains -Directory | Where-Object Name -Like '*Rider*')){
                if(($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A Rider directory is a reparse point.'}
                $known+=@{Name='Rider';Path=(Join-Path $directory.FullName 'bin\rider64.exe')}
            }
        }
    }catch{$errors+=@($_.Exception.Message)}
    foreach($candidate in $known){
        $entry=[ordered]@{Name=$candidate.Name;Path=$candidate.Path;Exists=$false;ReparsePoint=$false;FileVersion=$null;Length=$null;Sha256=$null;Error=$null}
        try{
            if(Test-Path -LiteralPath $candidate.Path -PathType Leaf){
                $file=Get-Item -LiteralPath $candidate.Path -Force
                $entry.Exists=$true;$entry.ReparsePoint=($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                # App execution aliases are reported without following their target.
                if(-not $entry.ReparsePoint){
                    $entry.FileVersion=$file.VersionInfo.FileVersion;$entry.Length=$file.Length
                    $entry.Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                }
            }
        }catch{$entry.Error=$_.Exception.Message;$errors+=@($entry.Error)}
        $executables+=@([pscustomobject]$entry)
    }
    try{
        $user=Get-LocalUser -Name LaqayLab
        $packages=@(Get-AppxPackage -User $user.SID.Value | Where-Object Name -in @('Microsoft.WindowsNotepad','Microsoft.WindowsTerminal') |
            Select-Object Name,Version,PackageFullName,InstallLocation,Status)
    }catch{$errors+=@('Registered packages: '+$_.Exception.Message)}
    try{
        $provisioned=@(Get-AppxProvisionedPackage -Online | Where-Object DisplayName -in @('Microsoft.WindowsNotepad','Microsoft.WindowsTerminal') |
            Select-Object DisplayName,Version,PackageName)
    }catch{$errors+=@('Provisioned packages: '+$_.Exception.Message)}
    $baseline=(Get-FileHash -LiteralPath 'C:\LaqayLab\App\laqay.exe' -Algorithm SHA256).Hash
    $remaining=@(Get-Process laqay -ErrorAction SilentlyContinue).Count
    [pscustomobject]@{LabId=$labId;Role='Primary';ReadOnly=$true;Complete=($errors.Count -eq 0 -and $remaining -eq 0);
        OsCaption=$os.Caption;OsVersion=$os.Version;OsBuild=$os.BuildNumber;BaselineSha256=$baseline;LaqayProcesses=$remaining;
        Executables=$executables;RegisteredPackages=$packages;ProvisionedPackages=$provisioned;Errors=$errors}
}
