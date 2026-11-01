param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
      [Parameter(Mandatory)][ValidateSet('Primary','Peer')][string]$Role)
$ErrorActionPreference = 'Stop'
$root = 'C:/LaqayLab'
$marker = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'guest.json') -Raw | ConvertFrom-Json
if ($marker.LabId -ne $LabId -or $marker.Role -ne $Role -or $PSScriptRoot -ne 'C:\LaqayLab') {
    throw 'This initializer runs only inside its disposable lab guest.'
}
$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine') {
    throw 'A Hyper-V guest is required.'
}
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -notlike '*Windows 11 Enterprise*') { throw 'Unexpected evaluation image; do not claim Windows 11 coverage.' }
$adapters = @(Get-NetAdapter -Physical)
if ($adapters.Count -ne 1) { throw 'Exactly one private lab adapter is required.' }
$address = if ($Role -eq 'Primary') { '10.77.166.10' } else { '10.77.166.11' }
Set-NetIPInterface -InterfaceIndex $adapters[0].ifIndex -AddressFamily IPv4 -Dhcp Disabled
New-NetIPAddress -InterfaceIndex $adapters[0].ifIndex -IPAddress $address -PrefixLength 24 | Out-Null
$profile = @(Get-NetConnectionProfile -InterfaceIndex $adapters[0].ifIndex)
if ($profile.Count -ne 1) { throw 'The private lab network profile is not ready.' }
$profile | Set-NetConnectionProfile -NetworkCategory Private
Set-ItemProperty -LiteralPath 'HKLM:/SYSTEM/CurrentControlSet/Control/Terminal Server' -Name fDenyTSConnections -Value 0
Set-Service -Name TermService -StartupType Automatic
Start-Service -Name TermService
foreach ($port in @(3389,445)) {
    New-NetFirewallRule -Name "LaqayLab-$LabId-$port" -DisplayName "Laqay lab $port" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress '10.77.166.0/24' -Profile Private | Out-Null
}
New-Item -ItemType Directory -Path (Join-Path $root 'Share') -Force | Out-Null
$shareAcl=Get-Acl -LiteralPath (Join-Path $root 'Share')
$shareAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(($env:COMPUTERNAME+'\LaqayLab'),'Modify','ContainerInherit,ObjectInherit','None','Allow'))
Set-Acl -LiteralPath (Join-Path $root 'Share') -AclObject $shareAcl
Expand-Archive -LiteralPath (Join-Path $root 'Laqay.zip') -DestinationPath (Join-Path $root 'App')
New-SmbShare -Name LaqayLab -Path (Join-Path $root 'Share') -FullAccess "$env:COMPUTERNAME\LaqayLab" | Out-Null
[ordered]@{ LabId=$LabId; Role=$Role; ComputerName=$env:COMPUTERNAME; Caption=$os.Caption;
    Version=$os.Version; Build=$os.BuildNumber; Architecture=$os.OSArchitecture;
    Ready=$true; TestsExecuted=$false; Address=$address; InitializedUtc=[DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'ready.json') -Encoding UTF8
