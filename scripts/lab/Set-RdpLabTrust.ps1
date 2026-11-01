[CmdletBinding()]
param(
    [ValidateSet('ExportPeer','PreparePrimary','Cleanup')][string]$Action,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$LabId,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [string]$CertificatePath,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
if($PrepareOnly){return}
if(-not $Action -or -not $LabId -or -not $RunId){throw 'An action and lab/run identities are required.'}
if($env:RUST_WORK_JOB){throw 'Certificate and guest name configuration run outside the Rust runtime lease.'}
if(-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An explicitly authorized administrator process is required.'}
$root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA ('LaqayTestLab/'+$LabId)))
$manifest=Get-Content -LiteralPath (Join-Path $root 'lab.json') -Raw | ConvertFrom-Json
if($manifest.Kind -ne 'LaqayDesktopTestLab' -or $manifest.LabId -ne $LabId -or $manifest.Root -ne $root){throw 'Invalid lab ownership.'}
$role=if($Action -eq 'ExportPeer'){'Peer'}else{'Primary'}
$entries=@($manifest.VMs | Where-Object Role -eq $role)
if($entries.Count -ne 1){throw 'Exactly one owned role is required.'}
$entry=$entries[0];$vm=Get-VM -Id ([guid]$entry.Id)
$disk=Join-Path $root ('vms/'+$role+'/system.vhdx')
$drives=@(Get-VMHardDiskDrive -VM $vm)
if($vm.State -ne 'Running' -or $vm.Name -ne $entry.Name -or $vm.Notes -ne ('Laqay disposable desktop lab '+$LabId) -or $entry.DiskPath -ne $disk -or $drives.Count -ne 1 -or $drives[0].Path -ne $disk){throw 'Unexpected guest ownership, state, or disk.'}
$credential=Import-Clixml -LiteralPath (Join-Path (Split-Path $disk) 'credential.xml')
$certificate=$null
if($Action -eq 'ExportPeer'){
    if(-not $CertificatePath -or -not [IO.Path]::IsPathRooted($CertificatePath) -or (Test-Path -LiteralPath $CertificatePath)){throw 'A new absolute certificate evidence path is required.'}
}elseif($Action -eq 'PreparePrimary'){
    $certificate=Get-Content -LiteralPath $CertificatePath -Raw | ConvertFrom-Json
    if($certificate.LabId -ne $LabId -or $certificate.RunId -ne $RunId -or $certificate.PeerName -notmatch '^LQW11-[A-Z0-9]{8}$'){throw 'Unexpected public certificate evidence.'}
}
$result=Invoke-Command -VMId $vm.Id -Credential $credential -ArgumentList $Action,$LabId,$RunId,$role,$certificate -ScriptBlock {
    param($action,$labId,$runId,$role,$certificate)
    $ErrorActionPreference='Stop'
    $ready=Get-Content -LiteralPath 'C:/LaqayLab/ready.json' -Raw | ConvertFrom-Json
    $computer=Get-CimInstance Win32_ComputerSystem
    $expected=if($role -eq 'Primary'){'10.77.166.10'}else{'10.77.166.11'}
    $adapters=@(Get-NetAdapter -Physical)
    if($ready.LabId -ne $labId -or $ready.Role -ne $role -or -not $ready.Ready -or $computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine' -or (Get-CimInstance Win32_OperatingSystem).Caption -notlike '*Windows 11 Enterprise*' -or $adapters.Count -ne 1){throw 'Refusing configuration outside the isolated guest.'}
    if(@(Get-NetIPAddress -InterfaceIndex $adapters[0].ifIndex -AddressFamily IPv4 | Where-Object {$_.IPAddress -eq $expected -and $_.PrefixLength -eq 24}).Count -ne 1 -or @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count){throw 'Guest address or isolation changed.'}
    if($action -eq 'ExportPeer'){
        $settings=Get-CimInstance -Namespace root/cimv2/terminalservices -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-tcp'"
        if($settings.UserAuthenticationRequired -ne 1 -or $settings.SecurityLayer -notin @(1,2)){throw 'The peer must already require NLA and negotiate TLS.'}
        $until=[DateTime]::UtcNow.AddSeconds(30)
        do{
            $certificates=@(Get-ChildItem -LiteralPath 'Cert:\LocalMachine\Remote Desktop' | Where-Object {$_.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -eq $env:COMPUTERNAME -and $_.NotBefore -le (Get-Date) -and $_.NotAfter -gt (Get-Date)})
            if($certificates.Count){break};Start-Sleep -Seconds 1
        }while([DateTime]::UtcNow -lt $until)
        if($certificates.Count -ne 1){throw 'Expected one valid existing self-signed RDP certificate.'}
        $cert=$certificates[0]
        if($cert.Subject -ne $cert.Issuer){throw 'The temporary lab expects the existing self-signed peer certificate.'}
        $configured=([string]$settings.SSLCertificateSHA1Hash).Replace(' ','')
        if($configured -and $configured -notmatch '^0{40}$' -and $configured -ne $cert.Thumbprint){throw 'The RDP listener uses a different certificate.'}
        return [pscustomobject]@{LabId=$labId;RunId=$runId;PeerName=$env:COMPUTERNAME;Thumbprint=$cert.Thumbprint;PublicCertificate=[Convert]::ToBase64String($cert.RawData);NlaRequired=$true;SecurityLayer=$settings.SecurityLayer}
    }
    $stateRoot='C:\LaqayLab\RdpTrust'
    $statePath=Join-Path $stateRoot ($runId+'.json')
    if((Test-Path -LiteralPath $stateRoot) -and ((Get-Item -LiteralPath $stateRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected trust state reparse point.'}
    if((Test-Path -LiteralPath $statePath) -and ((Get-Item -LiteralPath $statePath).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected trust record reparse point.'}
    $hosts=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts'
    if((Get-Item -LiteralPath $hosts).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected guest hosts reparse point.'}
    function Hash-Bytes([byte[]]$bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}}
    function Save-State {$state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8}
    $store=[Security.Cryptography.X509Certificates.X509Store]::new('Root',[Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try{
        if($action -eq 'PreparePrimary'){
            if(Test-Path -LiteralPath $statePath){throw 'Refusing to replace an existing trust state.'}
            New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
            $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($certificate.PublicCertificate))
            if($cert.HasPrivateKey -or $cert.Thumbprint -ne $certificate.Thumbprint -or $cert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ne $certificate.PeerName -or $cert.Subject -ne $cert.Issuer -or $cert.NotBefore -gt (Get-Date) -or $cert.NotAfter -le (Get-Date)){throw 'Invalid temporary peer certificate.'}
            $original=[IO.File]::ReadAllBytes($hosts)
            $text=[Text.Encoding]::UTF8.GetString($original)
            if($text -match ('(?i)\b'+[regex]::Escape($certificate.PeerName)+'\b')){throw 'The peer name already appears in the guest hosts file.'}
            $suffix=[Text.Encoding]::ASCII.GetBytes("`r`n10.77.166.11 "+$certificate.PeerName+' # Laqay lab '+$runId+"`r`n")
            $prepared=[byte[]]($original+$suffix)
            $existing=@($store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint)
            if($existing.Count -gt 1 -or ($existing.Count -eq 1 -and [Convert]::ToBase64String($existing[0].RawData) -ne $certificate.PublicCertificate)){throw 'Ambiguous preexisting trust.'}
            $state=[ordered]@{LabId=$labId;RunId=$runId;PeerName=$certificate.PeerName;Thumbprint=$cert.Thumbprint;PublicCertificate=$certificate.PublicCertificate;
                OriginalHosts=[Convert]::ToBase64String($original);OriginalHash=(Hash-Bytes $original);PreparedHash=(Hash-Bytes $prepared);OriginalWriteUtc=(Get-Item -LiteralPath $hosts).LastWriteTimeUtc.ToString('o');
                TrustAdded=($existing.Count -eq 0);Prepared=$false;Restored=$false}
            Save-State
            [IO.File]::WriteAllBytes($hosts,$prepared)
            if($state.TrustAdded){$store.Add($cert)}
            Clear-DnsClientCache
            $addresses=@([Net.Dns]::GetHostAddresses($certificate.PeerName) | ForEach-Object IPAddressToString)
            if($addresses.Count -ne 1 -or $addresses[0] -ne '10.77.166.11' -or @($store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint).Count -ne 1){throw 'Temporary guest name or trust verification failed.'}
            $state.Prepared=$true;Save-State
            return [pscustomobject]@{LabId=$labId;RunId=$runId;Prepared=$true;PeerName=$state.PeerName;Thumbprint=$state.Thumbprint}
        }
        if(-not (Test-Path -LiteralPath $statePath)){return [pscustomobject]@{LabId=$labId;RunId=$runId;Restored=$true;NothingChanged=$true}}
        $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if($state.LabId -ne $labId -or $state.RunId -ne $runId -or $state.PeerName -notmatch '^LQW11-[A-Z0-9]{8}$'){throw 'Unexpected trust cleanup ownership.'}
        $current=Hash-Bytes ([IO.File]::ReadAllBytes($hosts))
        if($current -eq $state.PreparedHash){
            $original=[Convert]::FromBase64String($state.OriginalHosts)
            if((Hash-Bytes $original) -ne $state.OriginalHash){throw 'Original guest hosts evidence changed.'}
            [IO.File]::WriteAllBytes($hosts,$original)
            [IO.File]::SetLastWriteTimeUtc($hosts,[DateTime]::Parse($state.OriginalWriteUtc,$null,[Globalization.DateTimeStyles]::RoundtripKind))
        }elseif($current -ne $state.OriginalHash){throw 'Guest hosts changed unexpectedly; refusing to overwrite them.'}
        if($state.TrustAdded){
            foreach($cert in @($store.Certificates | Where-Object Thumbprint -eq $state.Thumbprint)){
                if([Convert]::ToBase64String($cert.RawData) -ne $state.PublicCertificate){throw 'Unexpected certificate at the owned thumbprint.'}
                $store.Remove($cert)
            }
            if(@($store.Certificates | Where-Object Thumbprint -eq $state.Thumbprint).Count){throw 'Temporary certificate remains trusted.'}
        }
        Clear-DnsClientCache
        if((Hash-Bytes ([IO.File]::ReadAllBytes($hosts))) -ne $state.OriginalHash){throw 'Guest hosts were not restored.'}
        $state.Restored=$true;Save-State
        [pscustomobject]@{LabId=$labId;RunId=$runId;Restored=$true;HostsRestored=$true;OwnedTrustRemoved=$true}
    }finally{$store.Close()}
}
if($Action -eq 'ExportPeer'){$result | Select-Object LabId,RunId,PeerName,Thumbprint,PublicCertificate,NlaRequired,SecurityLayer | ConvertTo-Json | Set-Content -LiteralPath $CertificatePath -Encoding UTF8}
$result
