function Assert-LabIsoImage([string]$iso,$profile) {
    # Called only by explicitly elevated provisioning, after hash/path checks.
    # Never take ownership of an ISO that someone else already mounted.
    if((Get-DiskImage -ImagePath $iso -ErrorAction Stop).Attached){throw 'Refusing an already mounted installation ISO.'}
    $mounted=$false
    try {
        $disk=Mount-DiskImage -ImagePath $iso -StorageType ISO -Access ReadOnly -NoDriveLetter -PassThru -ErrorAction Stop
        $mounted=$true
        if($disk.ImagePath -ine $iso -or -not $disk.Attached){throw 'Unexpected mounted ISO identity.'}
        $volumes=@($disk | Get-Volume -ErrorAction Stop)
        if($volumes.Count -ne 1 -or -not $volumes[0].Path){throw 'Expected one installation ISO volume.'}
        $sources=Join-Path $volumes[0].Path 'sources'
        $images=@(foreach($name in @('install.wim','install.esd')){$path=Join-Path $sources $name;if(Test-Path -LiteralPath $path -PathType Leaf){$path}})
        if($images.Count -ne 1){throw 'Expected one installation image container.'}
        $image=Get-WindowsImage -ImagePath $images[0] -Index $profile.ImageIndex -ErrorAction Stop
        Assert-LabInstallImage $profile $image
        return $image
    } finally {
        if($mounted){Dismount-DiskImage -ImagePath $iso -ErrorAction Stop | Out-Null;if((Get-DiskImage -ImagePath $iso -ErrorAction Stop).Attached){throw 'The owned installation ISO remains mounted.'}}
    }
}
