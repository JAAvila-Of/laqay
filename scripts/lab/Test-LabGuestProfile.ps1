$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'LabGuestProfile.ps1')
. (Join-Path $PSScriptRoot 'Assert-LabIsoImage.ps1')
function Assert-Profile($ok,[string]$message){if(-not $ok){throw $message}}
function Reject-Profile([scriptblock]$action){$rejected=$false;try{& $action | Out-Null}catch{$rejected=$true};Assert-Profile $rejected 'An invalid profile or image was accepted.'}
$entry=Join-Path $PSScriptRoot 'Invoke-DesktopTestLab.ps1'
$id=[guid]::NewGuid().ToString('N')
$plan=& $entry -LabId $id -Action Plan | ConvertFrom-Json
Assert-Profile ($plan.GuestProfile -ceq 'Windows11EnterpriseEvaluation' -and $plan.ImageIndex -eq 1 -and $plan.Language -ceq 'en-US') 'The default Windows 11 plan changed.'
$plan=& $entry -LabId $id -Action Plan -GuestProfile Windows10ProEsMx | ConvertFrom-Json
Assert-Profile ($plan.WindowsVersion -ceq 'Windows 10 Pro' -and $plan.ImageIndex -eq 4 -and $plan.Language -ceq 'es-MX' -and -not $plan.Internet -and -not $plan.HostDesktopControl -and -not $plan.HostReboot) 'The opt-in Pro plan is not isolated and explicit.'
Assert-Profile (-not (Test-Path -LiteralPath $plan.Root)) 'Planning created resources.'
Reject-Profile {Get-LabGuestProfile 'Windows10Home'}
$profile=Get-LabGuestProfile Windows10ProEsMx
$image=[pscustomobject]@{ImageIndex=4;ImageName='Windows 10 Pro';EditionId='Professional';Architecture='x64';Languages=@('es-MX');Version='10.0.19041.2965'}
Assert-LabInstallImage $profile $image
foreach($mutation in @(@('ImageIndex',1),@('ImageName','Windows 10 Home'),@('EditionId','Core'),@('Architecture','x86'),@('Languages',@('en-US')),@('Version','10.0.22621.1'))){
    $bad=$image.PSObject.Copy();$bad.($mutation[0])=$mutation[1];Reject-Profile {Assert-LabInstallImage $profile $bad}
}
Assert-LabGuestSystem $profile 'Microsoft Windows 10 Pro' 19045 Professional es-MX
Reject-Profile {Assert-LabGuestSystem $profile 'Microsoft Windows 10 Home' 19045 Professional es-MX}
Reject-Profile {Assert-LabGuestSystem $profile 'Microsoft Windows 10 Pro' 19041 Professional es-MX}
Reject-Profile {Assert-LabGuestSystem $profile 'Microsoft Windows 10 Pro' 19045 Enterprise es-MX}
$xml=Convert-LabUnattendProfile (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Autounattend.xml.template') -Raw) $profile
$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
Assert-Profile ($xml.SelectSingleNode('//u:InstallFrom/u:MetaData/u:Value',$ns).InnerText -ceq '4') 'Unattended setup would install Home.'
$setupKey=$xml.SelectSingleNode('//u:component[@name="Microsoft-Windows-Setup"]/u:UserData/u:ProductKey',$ns)
Assert-Profile ($setupKey.SelectSingleNode('u:Key',$ns).InnerText -ceq 'VK7JG-NPHTM-C97JM-9MPGT-3V66T' -and $setupKey.SelectSingleNode('u:WillShowUI',$ns).InnerText -ceq 'Never') 'Retail Pro setup lost its explicit non-activating edition key.'
Assert-Profile ($xml.SelectNodes('//u:component[@name="Microsoft-Windows-Shell-Setup"]/u:ProductKey',$ns).Count -eq 0) 'A product key was passed to Windows activation.'
Reject-Profile {Convert-LabUnattendProfile $xml.OuterXml $profile}
$defaultXml=Convert-LabUnattendProfile (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Autounattend.xml.template') -Raw) (Get-LabGuestProfile Windows11EnterpriseEvaluation)
Assert-Profile ($defaultXml.SelectNodes('//u:ProductKey',$ns).Count -eq 0) 'The default evaluation profile acquired a setup key.'
foreach($node in $xml.SelectNodes('//u:SystemLocale | //u:UILanguage | //u:UserLocale',$ns)){Assert-Profile ($node.InnerText -ceq 'es-MX') 'Unattended setup retained another language.'}
Assert-Profile ($xml.SelectSingleNode('//u:WillWipeDisk',$ns).InnerText -ceq 'true' -and $xml.SelectSingleNode('//u:InstallTo/u:DiskID',$ns).InnerText -ceq '0') 'The owned guest disk target changed.'
# Exercise the actual mount verifier through inert adapters, including cleanup
# on a metadata failure and refusal to detach someone else's existing mount.
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('Laqay.Profile.'+$id)
$script:attached=$false;$script:mounts=0;$script:unmounts=0;$script:badImage=$false
function Get-DiskImage {param($ImagePath,$ErrorAction);[pscustomobject]@{Attached=$script:attached}}
function Mount-DiskImage {param($ImagePath,$StorageType,$Access,[switch]$NoDriveLetter,[switch]$PassThru,$ErrorAction);Assert-Profile ($StorageType -ceq 'ISO' -and $Access -ceq 'ReadOnly' -and $NoDriveLetter) 'The ISO mount is not read-only without a drive letter.';$script:attached=$true;$script:mounts++;[pscustomobject]@{ImagePath=$ImagePath;Attached=$true}}
function Get-Volume {param([Parameter(ValueFromPipeline)]$disk);process{[pscustomobject]@{Path=$temporary}}}
function Get-WindowsImage {param($ImagePath,$Index,$ErrorAction);if($script:badImage){throw 'Synthetic metadata failure'};$image}
function Dismount-DiskImage {param($ImagePath,$ErrorAction);$script:attached=$false;$script:unmounts++}
try {
    [IO.Directory]::CreateDirectory((Join-Path $temporary 'sources')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $temporary 'sources/install.wim'),'inert')
    Assert-LabIsoImage 'C:\synthetic.iso' $profile | Out-Null
    Assert-Profile ($script:mounts -eq 1 -and $script:unmounts -eq 1 -and -not $script:attached) 'Successful ISO inspection leaked its mount.'
    $script:badImage=$true
    Reject-Profile {Assert-LabIsoImage 'C:\synthetic.iso' $profile}
    Assert-Profile ($script:mounts -eq 2 -and $script:unmounts -eq 2 -and -not $script:attached) 'Failed inspection leaked its mount.'
    $script:attached=$true
    Reject-Profile {Assert-LabIsoImage 'C:\synthetic.iso' $profile}
    Assert-Profile ($script:mounts -eq 2 -and $script:unmounts -eq 2 -and $script:attached) 'An existing foreign mount was touched.'
} finally {
    $resolved=[IO.Path]::GetFullPath($temporary)
    if($resolved -cne $temporary -or [IO.Path]::GetFileName($resolved) -cne ('Laqay.Profile.'+$id)){throw 'Unexpected inert fixture cleanup path.'}
    Remove-Item -LiteralPath (Join-Path $resolved 'sources/install.wim')
    [IO.Directory]::Delete((Join-Path $resolved 'sources'));[IO.Directory]::Delete($resolved)
}
Write-Output 'Explicit Pro selection, language, guest identity and ISO inspection ownership passed without mounting media.'
