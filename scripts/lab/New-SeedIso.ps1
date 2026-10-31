param(
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][ValidatePattern('^[A-Z0-9]{1,16}$')][string]$VolumeLabel
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Destination) { throw 'Refusing to overwrite an existing ISO.' }
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
if (-not ('LaqayLabIsoStream' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class LaqayLabIsoStream {
    public static void Save(object value, string path) {
        var input = (IStream)value;
        IntPtr count = Marshal.AllocHGlobal(4);
        try {
            using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                var buffer = new byte[1024 * 1024];
                for (;;) {
                    input.Read(buffer, buffer.Length, count);
                    int read = Marshal.ReadInt32(count);
                    if (read < 0 || read > buffer.Length) throw new IOException("Invalid ISO stream length.");
                    if (read == 0) break;
                    output.Write(buffer, 0, read);
                }
                output.Flush(true);
            }
        } finally { Marshal.FreeHGlobal(count); }
    }
}
'@
}
$image = $result = $stream = $null
try {
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3
    $image.VolumeName = $VolumeLabel
    $image.Root.AddTree($source, $false)
    $result = $image.CreateResultImage()
    $stream = $result.ImageStream
    [LaqayLabIsoStream]::Save($stream, [IO.Path]::GetFullPath($Destination))
} finally {
    foreach ($value in @($stream, $result, $image)) {
        if ($null -ne $value -and [Runtime.InteropServices.Marshal]::IsComObject($value)) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($value)
        }
    }
}
