# Explicit platform contract for the console Explorer suite only.
function Assert-SmokeProfileModes([string]$profile,[bool]$extended) {
    if($profile -cnotin @('Windows11EnterpriseEvaluation','Windows10ProEsMx') -or ($profile -ceq 'Windows10ProEsMx' -and $extended)){throw 'This guest profile supports only the explicit basic console Explorer suite.'}
}
function Get-BasicSmokeCases([string]$profile) {
    Assert-SmokeProfileModes $profile $false
    $names=@('ImagePaste','CollisionPreservation','NativeFilePaste','AddressBarText','SearchText','RenameText','DisabledImageDoesNotSave','ReenabledImageSaves','ActiveTabSelection','UnicodePathImagePaste','ClipboardPreservedAfterImagePaste','ActiveWindowSelection','DeniedWriteRecovery')
    if($profile -ceq 'Windows10ProEsMx'){$names=@($names | Where-Object {$_ -cne 'ActiveTabSelection'})}
    return $names
}
function Assert-SmokeProfileReport([string]$profile,$report) {
    if($report.Passed -eq $false){throw ('Guest validation failed: '+$report.Error)}
    if($report.GuestProfile -cne $profile){throw 'The guest result has another platform profile.'}
    $na=@($report.NotApplicableCases)
    if($profile -ceq 'Windows10ProEsMx'){
        $p=$report.Platform
        if($p.Profile -cne $profile -or $p.Caption -cne 'Microsoft Windows 10 Pro' -or $p.Build -cne '19045' -or $p.Edition -cne 'Professional' -or $p.Language -ine 'es-MX' -or $na.Count -ne 1 -or $na[0].Name -cne 'ActiveTabSelection' -or $na[0].Status -cne 'NotApplicable' -or $na[0].ObservedTabs -ne 0 -or -not $na[0].Reason -or $na[0].Passed -eq $true){throw 'The Pro platform or explicit non-applicable tab evidence is incomplete.'}
    }elseif($na.Count){throw 'The Windows 11 suite cannot omit its tab case.'}
}
