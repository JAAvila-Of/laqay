[CmdletBinding()]
param(
    [Parameter(Mandatory)][UInt64]$FreeMemoryBytes,
    [Parameter(Mandatory)][UInt64]$FreeDiskBytes,
    [Parameter(Mandatory)][ValidateRange(0,2)][int]$RunningGuestCount,
    [ValidateSet(1,2)][int]$MaximumRunningGuests=1
)
$ErrorActionPreference='Stop'
if($RunningGuestCount -ge $MaximumRunningGuests){throw 'The explicit lab concurrency limit has been reached.'}
$required=3GB+4GB*($MaximumRunningGuests-$RunningGuestCount)
if($FreeMemoryBytes -lt $required){throw 'Insufficient host memory for the remaining lab capacity and a 3 GiB reserve.'}
if($FreeDiskBytes -lt 40GB){throw 'Insufficient host disk headroom.'}
[pscustomobject]@{Allowed=$true;MaximumRunningGuests=$MaximumRunningGuests;GuestMemoryBytes=4GB;
    HostMemoryReserveBytes=3GB;RequiredFreeMemoryBytes=$required;HostDiskReserveBytes=40GB}
