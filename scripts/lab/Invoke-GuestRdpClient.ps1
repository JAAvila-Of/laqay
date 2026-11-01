[CmdletBinding()]
param(
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
if(-not ('LaqayGuestDesktop' -as [type])){& (Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly}
if($PrepareOnly){return}
if(-not $LabId -or -not $RunId -or $PSScriptRoot -ne ('C:\LaqayLab\Runs\'+$RunId)){throw 'Unexpected RDP client run identity.'}
$until=[DateTime]::UtcNow.AddSeconds(30)
while($true){try{[LaqayGuestDesktop]::Arm($LabId);break}catch{if([DateTime]::UtcNow -ge $until){throw};Start-Sleep -Milliseconds 500}}
[LaqayGuestDesktop]::RequireRole('Primary')
$path=Join-Path $PSScriptRoot 'peer-credential.xml'
$credential=$null
try{
    $credential=Import-Clixml -LiteralPath $path
    if($credential.UserName -notmatch '^(LQW11-[A-Z0-9]{8})\\LaqayLab$'){throw 'Unexpected RDP peer credential.'}
    $peer=$Matches[1]
    Remove-Item -LiteralPath $path
    [LaqayGuestDesktop]::RunRdpClient($LabId,$RunId,$peer,$credential.Password)
}finally{
    $credential=$null
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
}
