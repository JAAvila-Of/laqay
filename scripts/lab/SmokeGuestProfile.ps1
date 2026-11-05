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
function Assert-BasicSmokeCases([string]$profile,$cases) {
    $expected=@(Get-BasicSmokeCases $profile)
    $observed=@($cases)
    if($observed.Count -ne $expected.Count){throw 'Not all required smoke cases executed.'}
    for($index=0;$index -lt $expected.Count;$index++){
        if($observed[$index].Name -cne $expected[$index] -or $observed[$index].Passed -ne $true){throw 'A required smoke case is missing, reordered, duplicated or unsuccessful.'}
    }
}
function Assert-SmokeProfileReport([string]$profile,$report) {
    if($report.Passed -eq $false){throw ('Guest validation failed: '+$report.Error)}
    if($report.GuestProfile -cne $profile){throw 'The guest result has another platform profile.'}
    $na=@($report.NotApplicableCases)
    if($profile -ceq 'Windows10ProEsMx'){
        $p=$report.Platform
        if($p.Profile -cne $profile -or $p.Caption -cne 'Microsoft Windows 10 Pro' -or $p.Build -cne '19045' -or $p.Edition -cne 'Professional' -or $p.Language -ine 'es-MX' -or $na.Count -ne 1 -or $na[0].Name -cne 'ActiveTabSelection' -or $na[0].Status -cne 'NotApplicable' -or $na[0].ObservedTabs -ne 0 -or -not $na[0].Reason -or $na[0].Passed -eq $true){throw 'The Pro platform or explicit non-applicable tab evidence is incomplete.'}
        $tabs=$report.TabExclusionEvidence
        if($null -eq $tabs -or $tabs.FileTabCandidates -ne 0 -or $tabs.RibbonTabItems -lt 0 -or $tabs.AllTabItems -ne $tabs.RibbonTabItems -or $na[0].RibbonTabsObserved -ne $tabs.RibbonTabItems -or @($tabs.Items).Count -ne $tabs.AllTabItems -or @($tabs.Items | Where-Object {-not $_.OwnedRibbon -or $_.NativeAncestors -cnotcontains 'UIRibbonCommandBarDock'}).Count){throw 'The Pro file-tab exclusion does not account for every observed tab item.'}
    }elseif($na.Count){throw 'The Windows 11 suite cannot omit its tab case.'}
}
