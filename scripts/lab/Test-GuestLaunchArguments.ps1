# Capture the actual remoting argument expressions without contacting a guest.
$ErrorActionPreference='Stop'
function Test-LaunchArguments([string]$source,[int]$count,[int[]]$booleanIndices){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $source),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Cannot test a launch script with parser errors.'}
    $commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Command' -and $node.Extent.Text -match '-ArgumentList[^\r\n]*\[bool\]'},$true))
    if($commands.Count -ne 1){throw 'Expected exactly one guest launch argument expression.'}
    # The mock captures binding only. It never invokes the supplied remote body.
    function Invoke-Command {param($Session,[object[]]$ArgumentList,[scriptblock]$ScriptBlock) return ,$ArgumentList}
    $session='fixture';$sessions=@{Primary='fixture'};$role='Primary'
    $LabId='lab';$RunId='run';$ExpectedExecutableSha256='sha';$guestRoot='root';$taskName='task';$StartupPhase='Explorer';$CycleId='cycle';$GuestProfile='Windows11EnterpriseEvaluation'
    foreach($unc in @($false,$true)){foreach($lifecycle in @($false,$true)){foreach($consent in @($false,$true)){
        [switch]$IncludeUnc=$unc;[switch]$IncludeLifecycle=$lifecycle;[switch]$AllowGuestRdpFileConsent=$consent
        foreach($adverse in @($false,$true)){foreach($real in @($false,$true)){foreach($terminal in @($false,$true)){foreach($PortablePhase in @('','Old','New','Removed')){
            [switch]$IncludeAdverse=$adverse
            [switch]$IncludeRealApplications=$real
            [switch]$IncludeWindowsTerminal=$terminal
            # This is trusted repository source, evaluated only against the local mock.
            $arguments=& ([scriptblock]::Create($commands[0].Extent.Text))
            if($arguments.Count -ne $count){throw ('Guest launch argument count changed in '+$source)}
            $expected=if($count -eq 14){@($unc,$lifecycle,$adverse,$real,$terminal)}else{@($consent)}
            for($index=0;$index -lt $booleanIndices.Count;$index++){
                $value=$arguments[$booleanIndices[$index]]
                if($value -isnot [bool] -or $value -ne $expected[$index]){throw ('Guest launch switch changed type/value in '+$source)}
            }
            if($count -eq 14 -and $arguments[13] -cne $GuestProfile){throw 'The explicit guest profile changed during argument binding.'}
            if($count -eq 14 -and $arguments[9] -cne $PortablePhase){throw 'The portable phase changed during argument binding.'}
        }}}}
    }}}
}
Test-LaunchArguments 'Invoke-DesktopSmoke.ps1' 14 @(7,8,10,11,12)
Test-LaunchArguments 'Invoke-RdpSmoke.ps1' 7 @(6)
# Evaluate the actual task-action selection against an inert scheduler mock.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-DesktopSmoke.ps1'),[ref]$tokens,[ref]$errors)
$selection=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match '^if\(\$includeWindowsTerminal\)' -and $node.Extent.Text.Contains('New-ScheduledTaskAction')},$true))
if($selection.Count -ne 1){throw 'The actual Terminal task action selection is ambiguous.'}
function New-ScheduledTaskAction {param([string]$Execute,[string]$Argument) [pscustomobject]@{Execute=$Execute;Argument=$Argument}}
$runRoot='C:\LaqayLab\Runs\0123456789abcdef0123456789abcdef'
$taskArguments='-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "'+$runRoot+'\Launch.ps1"'
foreach($includeWindowsTerminal in @($false,$true)){
    & ([scriptblock]::Create($selection[0].Extent.Text+'; $action')) | ForEach-Object {
        if($includeWindowsTerminal){
            if($_.Execute -cne (Join-Path $env:WINDIR 'System32\conhost.exe') -or $_.Argument -cne ('-ForceNoHandoff --headless -- "'+(Join-Path $PSHOME 'powershell.exe')+'" '+$taskArguments)){throw 'The Terminal driver did not select its explicit headless console host.'}
        }elseif($_.Execute -cne (Join-Path $PSHOME 'powershell.exe') -or $_.Argument -cne $taskArguments){throw 'The existing task launch changed without Terminal opt-in.'}
    }
}
Write-Output 'Actual desktop/RDP launch expressions preserve Boolean switches and portable phases without remoting.'
