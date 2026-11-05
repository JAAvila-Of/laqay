$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SmokeGuestProfile.ps1')
if(-not ('LaqayGuestDesktop' -as [type])){& (Join-Path $PSScriptRoot 'Invoke-GuestDesktopSmoke.ps1') -PrepareOnly}
function Assert-Smoke($ok,[string]$message){if(-not $ok){throw $message}}
function Reject-Smoke([scriptblock]$action){$rejected=$false;try{& $action | Out-Null}catch{$rejected=$true};Assert-Smoke $rejected 'An unsupported or mismatched desktop profile was accepted.'}
$locale=[Text.StringBuilder]::new(85)
$native=[LaqayGuestDesktop].GetMethod('GetSystemDefaultLocaleName',[Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static)
Assert-Smoke ($native.Invoke($null,@($locale,85)) -gt 0 -and $null -ne [Globalization.CultureInfo]::GetCultureInfo($locale.ToString())) 'The Unicode-only system locale ABI failed.'
$w11=@(Get-BasicSmokeCases Windows11EnterpriseEvaluation);$pro=@(Get-BasicSmokeCases Windows10ProEsMx)
Assert-Smoke ($w11.Count -eq 13 -and $w11 -ccontains 'ActiveTabSelection' -and $pro.Count -eq 12 -and $pro -cnotcontains 'ActiveTabSelection' -and @(Compare-Object @($w11 | Where-Object {$_ -cne 'ActiveTabSelection'}) $pro).Count -eq 0) 'A platform case was lost or relabeled as passing.'
Reject-Smoke {Assert-SmokeProfileModes Windows10ProEsMx $true}
Reject-Smoke {Assert-SmokeProfileModes Unknown $false}
Assert-SmokeProfileModes Windows11EnterpriseEvaluation $true
$ready=[Collections.Generic.Dictionary[string,object]]::new()
foreach($pair in @(@('GuestProfile','Windows10ProEsMx'),@('Caption','Microsoft Windows 10 Pro'),@('Build','19045'),@('Edition','Professional'),@('Language','es-MX'))){$ready.Add($pair[0],$pair[1])}
[LaqayGuestDesktop]::ValidateDesktopProfile('Windows10ProEsMx',$ready,'Microsoft Windows 10 Pro','19045','Professional','es-MX')
foreach($values in @(@('Microsoft Windows 10 Home','19045','Professional','es-MX'),@('Microsoft Windows 10 Pro','19044','Professional','es-MX'),@('Microsoft Windows 10 Pro','19045','Core','es-MX'),@('Microsoft Windows 10 Pro','19045','Professional','en-US'))){
    Reject-Smoke {[LaqayGuestDesktop]::ValidateDesktopProfile('Windows10ProEsMx',$ready,$values[0],$values[1],$values[2],$values[3])}
}
foreach($field in @('GuestProfile','Caption','Build','Edition','Language')){
    $copy=[Collections.Generic.Dictionary[string,object]]::new($ready);$copy[$field]='wrong'
    Reject-Smoke {[LaqayGuestDesktop]::ValidateDesktopProfile('Windows10ProEsMx',$copy,'Microsoft Windows 10 Pro','19045','Professional','es-MX')}
}
$legacy=[Collections.Generic.Dictionary[string,object]]::new()
[LaqayGuestDesktop]::ValidateDesktopProfile('Windows11EnterpriseEvaluation',$legacy,'Microsoft Windows 11 Enterprise Evaluation','26300','EnterpriseEval','en-US')
Reject-Smoke {[LaqayGuestDesktop]::ValidateDesktopProfile('Windows11EnterpriseEvaluation',$ready,'Microsoft Windows 10 Pro','19045','Professional','es-MX')}
Reject-Smoke {[LaqayGuestDesktop]::GuestProfileEvidence()}
$report=[pscustomobject]@{GuestProfile='Windows10ProEsMx';Platform=[pscustomobject]@{Profile='Windows10ProEsMx';Caption='Microsoft Windows 10 Pro';Build='19045';Edition='Professional';Language='es-MX'};NotApplicableCases=@([pscustomobject]@{Name='ActiveTabSelection';Status='NotApplicable';Reason='Windows 10 Explorer has no native tabs.';ObservedTabs=0})}
Assert-SmokeProfileReport Windows10ProEsMx $report
$report.NotApplicableCases[0].ObservedTabs=1;Reject-Smoke {Assert-SmokeProfileReport Windows10ProEsMx $report};$report.NotApplicableCases[0].ObservedTabs=0
$report.NotApplicableCases[0].Status='Passed';Reject-Smoke {Assert-SmokeProfileReport Windows10ProEsMx $report};$report.NotApplicableCases[0].Status='NotApplicable'
Reject-Smoke {Assert-SmokeProfileReport Windows11EnterpriseEvaluation $report}
$report.NotApplicableCases=@();Reject-Smoke {Assert-SmokeProfileReport Windows10ProEsMx $report}
Assert-SmokeProfileReport Windows11EnterpriseEvaluation ([pscustomobject]@{GuestProfile='Windows11EnterpriseEvaluation';NotApplicableCases=@()})
# Actual entry points must reject unsupported Pro extensions before lease,
# elevation, guest filesystem, clipboard or desktop operations.
foreach($options in @(@{IncludeUnc=$true},@{IncludeLifecycle=$true},@{IncludeAdverse=$true},@{IncludeRealApplications=$true},@{StartupPhase='Enable'},@{PortablePhase='New'})){
    $rejected=$false
    try{& (Join-Path $PSScriptRoot 'Invoke-DesktopSmoke.ps1') -GuestProfile Windows10ProEsMx -PrepareOnly @options}catch{$rejected=$_.Exception.Message -ceq 'This guest profile supports only the explicit basic console Explorer suite.'}
    Assert-Smoke $rejected 'An unsupported Pro suite reached other runtime guards.'
}
Write-Output 'Desktop profile identity, preserved Windows 11 cases and explicit Pro non-applicability passed without arming input.'
