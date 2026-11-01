[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [Parameter(Mandatory)][ValidateSet('Primary','Peer')][string]$Role
)
$ErrorActionPreference='Stop'
if($PSScriptRoot -ne 'C:\LaqayLab'){throw 'Firewall configuration is restricted to the owned guest directory.'}
$marker=Get-Content -LiteralPath 'C:/LaqayLab/guest.json' -Raw | ConvertFrom-Json
$computer=Get-CimInstance Win32_ComputerSystem
if($marker.LabId -ne $LabId -or $marker.Role -ne $Role -or $computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine' -or (Get-CimInstance Win32_OperatingSystem).Caption -notlike '*Windows 11 Enterprise*'){throw 'Guest firewall identity mismatch.'}
if(-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An administrator inside the owned guest is required.'}
$adapters=@(Get-NetAdapter -Physical)
if($adapters.Count -ne 1){throw 'Exactly one private lab adapter is required.'}
$address=if($Role -eq 'Primary'){'10.77.166.10'}else{'10.77.166.11'}
$addresses=@(Get-NetIPAddress -InterfaceIndex $adapters[0].ifIndex -AddressFamily IPv4 | Where-Object {$_.IPAddress -eq $address -and $_.PrefixLength -eq 24})
if($addresses.Count -ne 1 -or @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count){throw 'The guest network is not the isolated lab subnet.'}
function Test-Subnet($values){$items=@($values);return $items.Count -eq 1 -and $items[0] -in @('10.77.166.0/24','10.77.166.0/255.255.255.0')}
$results=@()
foreach($port in @(3389,445)){
    $name='LaqayLab-'+$LabId+'-'+$port
    $existing=@(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)
    if($existing.Count -gt 1){throw 'Ambiguous owned firewall rule.'}
    $before='Absent'
    if($existing.Count -eq 1){
        $rule=$existing[0]
        $ports=$rule | Get-NetFirewallPortFilter
        $scope=$rule | Get-NetFirewallAddressFilter
        $interfaces=$rule | Get-NetFirewallInterfaceFilter
        if($rule.DisplayName -ne ('Laqay lab '+$port) -or $rule.Direction.ToString() -ne 'Inbound' -or $rule.Action.ToString() -ne 'Allow' -or $rule.Enabled.ToString() -ne 'True' -or $rule.Profile.ToString() -notin @('Private','Any') -or $ports.Protocol.ToString() -notin @('TCP','6') -or @($ports.LocalPort).Count -ne 1 -or @($ports.LocalPort)[0] -ne $port.ToString() -or -not (Test-Subnet $scope.RemoteAddress) -or @($scope.LocalAddress).Count -ne 1 -or @($scope.LocalAddress)[0] -notin @('Any',$address) -or @($interfaces.InterfaceAlias).Count -ne 1 -or @($interfaces.InterfaceAlias)[0] -notin @('Any',$adapters[0].Name)){throw 'Refusing to change an unexpected firewall rule.'}
        $before=$rule.Profile.ToString()
        Set-NetFirewallRule -Name $name -Profile Any -InterfaceAlias $adapters[0].Name -LocalAddress $address -RemoteAddress '10.77.166.0/24'
    }else{
        New-NetFirewallRule -Name $name -DisplayName ('Laqay lab '+$port) -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -Profile Any -InterfaceAlias $adapters[0].Name -LocalAddress $address -RemoteAddress '10.77.166.0/24' | Out-Null
    }
    $rule=Get-NetFirewallRule -Name $name
    $scope=$rule | Get-NetFirewallAddressFilter
    $interfaces=$rule | Get-NetFirewallInterfaceFilter
    if($rule.Profile.ToString() -ne 'Any' -or @($scope.LocalAddress).Count -ne 1 -or @($scope.LocalAddress)[0] -ne $address -or -not (Test-Subnet $scope.RemoteAddress) -or @($interfaces.InterfaceAlias).Count -ne 1 -or @($interfaces.InterfaceAlias)[0] -ne $adapters[0].Name){throw 'Guest firewall scope verification failed.'}
    $results+=@([pscustomobject]@{Port=$port;PreviousProfile=$before;Profile='Any';InterfaceAlias=$adapters[0].Name;LocalAddress=$address;RemoteAddress='10.77.166.0/24'})
}
[pscustomobject]@{LabId=$LabId;Role=$Role;Configured=$true;Rules=$results}
