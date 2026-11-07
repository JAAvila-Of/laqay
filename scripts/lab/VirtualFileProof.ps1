# Pure report validation; no guest, clipboard, input, or filesystem operations.
function Assert-VirtualFileProof([object[]]$proofs,[int]$applicationPid){
    if($proofs.Count -ne 2 -or $proofs[0].LaqayEnabled -cne $false -or $proofs[1].LaqayEnabled -cne $true){throw 'Virtual-file disabled/enabled references are incomplete.'}
    $bytes=[Text.Encoding]::UTF8.GetBytes("Laqay virtual file fixture.`r`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
    foreach($proof in $proofs){
        $before=$proof.Before;$after=$proof.After
        if($proof.Error -or -not $proof.ProviderClosed -or -not $proof.OnlyExpectedFile -or $proof.FileSha256 -cne $hash -or -not $proof.Input.Foreground -or -not $proof.Input.FocusWithinWindow){throw 'Virtual-file result, target focus, or provider cleanup did not pass.'}
        foreach($state in @($before,$after)){
            if(-not $state.Current -or $state.OwnerPid -le 0 -or $state.OwnerPid -ne $state.SourcePid -or $state.SourcePid -eq $applicationPid -or $state.SourceThread -le 0 -or $state.Expired -or $state.Error -or -not $state.HasPng -or -not $state.HasDescriptor -or -not $state.HasContents -or $state.HasFileDrop -or $state.FileName -cne 'virtual-fixture.txt' -or $state.Length -ne $bytes.Length -or $state.Sha256 -cne $hash){throw 'The virtual-file source is not the complete live OLE fixture.'}
        }
        if($after.OwnerPid -ne $before.OwnerPid -or $after.SourceThread -ne $before.SourceThread -or $after.ContentReads -le $before.ContentReads){throw 'The same OLE provider did not supply file contents during native paste.'}
    }
}

function Assert-SustainedLargePngProof($proof,[int]$applicationPid){
    if(-not $proof -or $proof.Error -or $proof.Dimension -ne 4096 -or $proof.RequiredCount -ne 12 -or $proof.MinimumMilliseconds -ne 30000 -or $proof.BudgetMilliseconds -ne 120000 -or $proof.ElapsedMilliseconds -lt 30000 -or $proof.ElapsedMilliseconds -gt 120000 -or @($proof.Completed).Count -ne 12){throw 'The sustained large-PNG sample is incomplete or outside its declared bounds.'}
    $names=@{};$index=0
    foreach($frame in $proof.Completed){
        $index++
        if($frame.Width -ne 4096 -or $frame.Height -ne 4096 -or @($frame.CornerPixels).Count -ne 4 -or $frame.CornerPixels[0] -ne 0 -or $frame.CornerPixels[1] -ne 1090453504 -or $frame.CornerPixels[2] -ne -2147418368 -or $frame.CornerPixels[3] -ne -16776961){throw 'A sustained PNG does not preserve decoded dimensions and corner alpha/channels.'}
        if($frame.Index -ne $index -or -not $frame.Responsive -or -not $frame.Input.Foreground -or -not $frame.Input.FocusWithinWindow -or -not $frame.Input.ItemsViewFocused -or $frame.File -cnotmatch '^Screenshot_\d{8}_\d{6}(_\d{3,})?\.png$' -or $names.ContainsKey($frame.File) -or $frame.Sha256 -cnotmatch '^[A-F0-9]{64}$' -or $frame.ElapsedMilliseconds -lt 0){throw 'A sustained PNG frame lacks unique output, focus, or responsiveness evidence.'}
        $names[$frame.File]=$true;$sample=$frame.Resources
        if($sample.Pid -ne $applicationPid -or $sample.WorkingSetBytes -le 0 -or $sample.PrivateBytes -le 0 -or $sample.Handles -le 0 -or $sample.Threads -le 0){throw 'A sustained PNG sample does not belong to the running application.'}
    }
}
