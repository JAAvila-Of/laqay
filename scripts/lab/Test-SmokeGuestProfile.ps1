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
foreach($profile in @('Windows11EnterpriseEvaluation','Windows10ProEsMx')){
    $complete=@(Get-BasicSmokeCases $profile | ForEach-Object {[pscustomobject]@{Name=$_;Passed=$true}})
    Assert-BasicSmokeCases $profile $complete
    Reject-Smoke {Assert-BasicSmokeCases $profile @($complete | Select-Object -Skip 1)}
    Reject-Smoke {Assert-BasicSmokeCases $profile @($complete+$complete[0])}
    $saved=$complete[1].Name;$complete[1].Name=$complete[0].Name
    Reject-Smoke {Assert-BasicSmokeCases $profile $complete};$complete[1].Name=$saved
    $complete[0].Passed=$false;Reject-Smoke {Assert-BasicSmokeCases $profile $complete};$complete[0].Passed=$true
    $saved=$complete[0];$complete[0]=$complete[1];$complete[1]=$saved
    Reject-Smoke {Assert-BasicSmokeCases $profile $complete}
}
Reject-Smoke {Assert-BasicSmokeCases Windows11EnterpriseEvaluation @($pro | ForEach-Object {[pscustomobject]@{Name=$_;Passed=$true}})}
Reject-Smoke {Assert-BasicSmokeCases Windows10ProEsMx @($w11 | ForEach-Object {[pscustomobject]@{Name=$_;Passed=$true}})}
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
$report.NotApplicableCases[0] | Add-Member NoteProperty RibbonTabsObserved 0
$report | Add-Member NoteProperty TabExclusionEvidence ([pscustomobject]@{AllTabItems=0;RibbonTabItems=0;FileTabCandidates=0;Items=@()})
Assert-SmokeProfileReport Windows10ProEsMx $report
$report.TabExclusionEvidence.AllTabItems=1;Reject-Smoke {Assert-SmokeProfileReport Windows10ProEsMx $report};$report.TabExclusionEvidence.AllTabItems=0
$report.TabExclusionEvidence.FileTabCandidates=1;Reject-Smoke {Assert-SmokeProfileReport Windows10ProEsMx $report};$report.TabExclusionEvidence.FileTabCandidates=0
$report.TabExclusionEvidence=[pscustomobject]@{AllTabItems=1;RibbonTabItems=1;FileTabCandidates=0;Items=@([pscustomobject]@{OwnedRibbon=$true;NativeAncestors=@('UIRibbonCommandBarDock')})}
$report.NotApplicableCases[0].RibbonTabsObserved=1
Assert-SmokeProfileReport Windows10ProEsMx $report
$report.TabExclusionEvidence.Items[0].OwnedRibbon=$false;Reject-Smoke {Assert-SmokeProfileReport Windows10ProEsMx $report};$report.TabExclusionEvidence.Items[0].OwnedRibbon=$true
$report.TabExclusionEvidence.Items[0].NativeAncestors=@('Unknown');Reject-Smoke {Assert-SmokeProfileReport Windows10ProEsMx $report}
$report.TabExclusionEvidence=[pscustomobject]@{AllTabItems=0;RibbonTabItems=0;FileTabCandidates=0;Items=@()};$report.NotApplicableCases[0].RibbonTabsObserved=0
$failed=[pscustomobject]@{GuestProfile='Windows10ProEsMx';Passed=$false;Error='The expected image was not published in the active guest folder.';NotApplicableCases=@()}
$preserved=$false
try{Assert-SmokeProfileReport Windows10ProEsMx $failed}catch{$preserved=$_.Exception.Message -ceq ('Guest validation failed: '+$failed.Error)}
Assert-Smoke $preserved 'An incomplete failed run hid its original failure behind missing platform or tab evidence.'
Reject-Smoke {[LaqayGuestDesktop]::FolderSemanticProbe([IntPtr]::Zero)}
Reject-Smoke {[LaqayGuestDesktop]::StartTrialApplication('unused','unused')}
Reject-Smoke {[LaqayGuestDesktop]::FocusedFieldState([IntPtr]::Zero)}
Reject-Smoke {[LaqayGuestDesktop]::FocusedEditableReady([IntPtr]::Zero)}
Reject-Smoke {[LaqayGuestDesktop]::FocusedEditableReady([IntPtr]::Zero,$true)}
Assert-Smoke ([LaqayGuestDesktop]::ProSearchFieldReady($true,$true,'RichEditBox')) 'The proven final Pro search editor was rejected.'
foreach($nativeClass in @('ModernSearchBox','Edit','Unknown','')){Assert-Smoke (-not [LaqayGuestDesktop]::ProSearchFieldReady($true,$true,$nativeClass)) 'A search wrapper or unknown input surface was accepted before the final editor.'}
Assert-Smoke (-not [LaqayGuestDesktop]::ProSearchFieldReady($false,$true,'RichEditBox')) 'The Pro-only editor rule was applied to another profile.'
Assert-Smoke (-not [LaqayGuestDesktop]::ProSearchFieldReady($true,$false,'RichEditBox')) 'A final search class bypassed the owned editable-field readiness proof.'
Assert-Smoke ([LaqayGuestDesktop]::EditableFieldReady($true,$true,$true,$true,$true,$true,$true,$true)) 'A complete writable guest input precondition was rejected.'
for($index=0;$index -lt 8;$index++){
    $scope=[object[]]@($true,$true,$true,$true,$true,$true,$true,$true);$scope[$index]=$false
    Assert-Smoke (-not [LaqayGuestDesktop].GetMethod('EditableFieldReady').Invoke($null,$scope)) 'Input was allowed before its owned writable field was ready.'
}
Reject-Smoke {[LaqayGuestDesktop]::ExplorerTabEvidence([IntPtr]::Zero)}
Assert-Smoke ([LaqayGuestDesktop]::OwnedRibbonAncestor('UIRibbonCommandBarDock',$true)) 'The exact owned native Ribbon dock was not identified.'
foreach($nativeClass in @('TabControl','ShellTabWindowClass','UIRibbonOther','')){Assert-Smoke (-not [LaqayGuestDesktop]::OwnedRibbonAncestor($nativeClass,$true)) 'An unknown native tab surface was classified as Ribbon.'}
Assert-Smoke (-not [LaqayGuestDesktop]::OwnedRibbonAncestor('UIRibbonCommandBarDock',$false)) 'An unowned Ribbon ancestor was accepted.'
Assert-Smoke ([LaqayGuestDesktop]::ForeignGuestFieldAllowed($true,$true,$true,$true,$true,$true,$true,$true)) 'The complete owned-field scope was rejected.'
for($index=0;$index -lt 8;$index++){
    $scope=[object[]]@($true,$true,$true,$true,$true,$true,$true,$true);$scope[$index]=$false
    Assert-Smoke (-not [LaqayGuestDesktop].GetMethod('ForeignGuestFieldAllowed').Invoke($null,$scope)) 'A foreign input field was accepted with incomplete ownership or editability evidence.'
}
$trialDirectory='C:\LaqayLab\Runs\'+('0'*32)+'\data\core-trial'
Assert-Smoke ([LaqayGuestDesktop]::CoreTrialArguments($trialDirectory) -ceq ('--trial 20 "'+$trialDirectory+'"')) 'The fixed core trial arguments changed.'
foreach($directory in @('relative','C:\Users\Fixture\core-trial',('C:\LaqayLab\Runs\'+('0'*32)+'\data\..\outside'),($trialDirectory+'" --unknown'))){Reject-Smoke {[LaqayGuestDesktop]::CoreTrialArguments($directory)}}
$flags=[Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
$buffer=[LaqayGuestDesktop].GetField('trialLog',$flags);$truncated=[LaqayGuestDesktop].GetField('trialLogTruncated',$flags)
$capture=[LaqayGuestDesktop].GetMethod('CaptureTrialLine',$flags)
$oldBuffer=$buffer.GetValue($null);$oldTruncated=$truncated.GetValue($null);$done=[Threading.ManualResetEvent]::new($false)
try{
    $buffer.SetValue($null,[Text.StringBuilder]::new());$truncated.SetValue($null,$false)
    $capture.Invoke($null,@('fixture',('x'*70000),$done)) | Out-Null
    $log=[LaqayGuestDesktop]::CoreTrialLog()
    Assert-Smoke ($log.Output.Length -eq 65536 -and $log.Truncated -and -not $done.WaitOne(0)) 'Core trial output was not bounded or signaled EOF early.'
    $capture.Invoke($null,@('fixture',$null,$done)) | Out-Null
    Assert-Smoke ($done.WaitOne(0)) 'Core trial EOF did not signal completion.'
}finally{$buffer.SetValue($null,$oldBuffer);$truncated.SetValue($null,$oldTruncated);$done.Dispose()}
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
if($env:RUST_WORK_JOB){throw 'Inert runtime entry checks must run outside a Rust runtime lease.'}
$runtimeOutput=Join-Path ([IO.Path]::GetTempPath()) ('Laqay.Unarmed.Runtime.'+[guid]::NewGuid().ToString('N'))
$runtime=Join-Path $PSScriptRoot 'Invoke-PortableRuntimePhase.ps1'
foreach($profile in @('Windows11EnterpriseEvaluation','Windows10ProEsMx')){
    $leaseRejected=$false
    try{& $runtime -GuestProfile $profile -LabId ('0'*32) -CycleId ('0'*32) -Phase Basic -ExpectedExecutableSha256 ('a'*64) -OutputDirectory $runtimeOutput}catch{$leaseRejected=$_.Exception.Message -ceq 'A RustWork runtime lease is required before any guest boot or application suite.'}
    Assert-Smoke $leaseRejected 'An explicit basic runtime profile did not reach the lease guard without guest operations.'
}
foreach($phase in @('Old','New','Enable','Verify','Absent','Removed','Adverse')){
    $modeRejected=$false
    try{& $runtime -GuestProfile Windows10ProEsMx -LabId ('0'*32) -CycleId ('0'*32) -Phase $phase -ExpectedExecutableSha256 ('a'*64) -OutputDirectory $runtimeOutput}catch{$modeRejected=$_.Exception.Message -ceq 'The Pro runtime profile supports only Boot and Basic without extensions.'}
    Assert-Smoke $modeRejected 'An unsupported Pro phase reached another runtime guard.'
}
Assert-Smoke (-not (Test-Path -LiteralPath $runtimeOutput)) 'An unarmed runtime entry created output.'
Write-Output 'Desktop profile identity, preserved Windows 11 cases and explicit Pro non-applicability passed without arming input.'
