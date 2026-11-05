# Pure profile and identity checks; loading this file performs no system changes.
function Get-LabGuestProfile([string]$name='Windows11EnterpriseEvaluation') {
    switch -CaseSensitive ($name) {
        'Windows11EnterpriseEvaluation' { return [pscustomobject]@{Name=$name;Caption='Windows 11 Enterprise Evaluation';Prefix='LQW11-';Language='en-US';InputLocale='0409:00000409';ImageIndex=1;ImageName='Windows 11 Enterprise Evaluation';Edition='EnterpriseEval';MinimumBuild=22000;MaximumBuild=99999;InstalledBuild=0} }
        'Windows10ProEsMx' { return [pscustomobject]@{Name=$name;Caption='Windows 10 Pro';Prefix='LQW10-';Language='es-MX';InputLocale='080a:0000080a';ImageIndex=4;ImageName='Windows 10 Pro';Edition='Professional';MinimumBuild=19041;MaximumBuild=19045;InstalledBuild=19045} }
        default { throw 'Unsupported explicit lab guest profile.' }
    }
}
function Assert-LabInstallImage($profile,$image) {
    $version=[version]$image.Version
    if($image.ImageIndex -ne $profile.ImageIndex -or $image.ImageName -cne $profile.ImageName -or $image.EditionId -cne $profile.Edition -or $image.Architecture.ToString() -notin @('9','x64','amd64') -or @($image.Languages).Count -ne 1 -or @($image.Languages)[0] -ine $profile.Language -or $version.Major -ne 10 -or $version.Minor -ne 0 -or $version.Build -lt $profile.MinimumBuild -or $version.Build -gt $profile.MaximumBuild){throw 'Installation image does not match the explicit lab profile.'}
}
function Assert-LabGuestSystem($profile,[string]$caption,[int]$build,[string]$edition,[string]$language) {
    $captionMatches=if($profile.Name -ceq 'Windows10ProEsMx'){$caption -ceq 'Microsoft Windows 10 Pro'}else{$caption -like '*Windows 11 Enterprise*'}
    if(-not $captionMatches -or $build -lt $profile.MinimumBuild -or $build -gt $profile.MaximumBuild -or ($profile.InstalledBuild -and $build -ne $profile.InstalledBuild) -or $edition -cne $profile.Edition -or $language -ine $profile.Language){throw 'Installed guest does not match its declared lab profile.'}
}
function Convert-LabUnattendProfile([string]$answer,$profile) {
    $xml=[xml]$answer
    $ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
    foreach($node in $xml.SelectNodes('//u:SetupUILanguage/u:UILanguage | //u:SystemLocale | //u:UILanguage | //u:UserLocale',$ns)){$node.InnerText=$profile.Language}
    foreach($node in $xml.SelectNodes('//u:InputLocale',$ns)){$node.InnerText=$profile.InputLocale}
    $xml.SelectSingleNode('//u:InstallFrom/u:MetaData/u:Value',$ns).InnerText=[string]$profile.ImageIndex
    if($profile.Name -ceq 'Windows10ProEsMx'){
        # Public generic Pro setup key: selects the edition, grants no license,
        # and is never passed to activation or read from the host.
        $userData=$xml.SelectSingleNode('//u:component[@name="Microsoft-Windows-Setup"]/u:UserData',$ns)
        if($userData.SelectSingleNode('u:ProductKey',$ns)){throw 'Refusing to replace a pre-existing installation key.'}
        $key=$xml.CreateElement('ProductKey',$ns.LookupNamespace('u'))
        $value=$xml.CreateElement('Key',$ns.LookupNamespace('u'));$value.InnerText='VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        $display=$xml.CreateElement('WillShowUI',$ns.LookupNamespace('u'));$display.InnerText='Never'
        [void]$key.AppendChild($value);[void]$key.AppendChild($display);[void]$userData.AppendChild($key)
    }
    return $xml
}
