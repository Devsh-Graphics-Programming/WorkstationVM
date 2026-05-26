function New-AnswerIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [string]$VolumeName = "AUTOUNATTEND"
    )

    if (-not ("WorkstationIsoWriter" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

[ComImport]
[Guid("0000000C-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IStreamNative
{
    void Read([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=1)] byte[] pv, int cb, IntPtr pcbRead);
    void Write([In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=1)] byte[] pv, int cb, IntPtr pcbWritten);
    void Seek(long dlibMove, int dwOrigin, IntPtr plibNewPosition);
    void SetSize(long libNewSize);
    void CopyTo(IStreamNative pstm, long cb, IntPtr pcbRead, IntPtr pcbWritten);
    void Commit(int grfCommitFlags);
    void Revert();
    void LockRegion(long libOffset, long cb, int dwLockType);
    void UnlockRegion(long libOffset, long cb, int dwLockType);
    void Stat(out STATSTG pstatstg, int grfStatFlag);
    void Clone(out IStreamNative ppstm);
}

public static class WorkstationIsoWriter
{
    public static void Write(string sourceDir, string outputPath, string volumeName)
    {
        Type imageType = Type.GetTypeFromProgID("IMAPI2FS.MsftFileSystemImage", true);
        dynamic image = Activator.CreateInstance(imageType);
        image.FileSystemsToCreate = 3;
        image.VolumeName = volumeName;
        image.Root.AddTree(sourceDir, false);

        dynamic result = image.CreateResultImage();
        object imageStream = result.ImageStream;
        IntPtr unknown = Marshal.GetIUnknownForObject(imageStream);
        try
        {
            IStreamNative stream = (IStreamNative)Marshal.GetTypedObjectForIUnknown(unknown, typeof(IStreamNative));
            STATSTG stat;
            stream.Stat(out stat, 1);
            stream.Seek(0, 0, IntPtr.Zero);

            byte[] buffer = new byte[32768];
            IntPtr bytesRead = Marshal.AllocHGlobal(4);
            try
            {
                using (FileStream file = File.Open(outputPath, FileMode.Create, FileAccess.Write))
                {
                    long remaining = stat.cbSize;
                    while (remaining > 0)
                    {
                        int count = (int)Math.Min(buffer.Length, remaining);
                        stream.Read(buffer, count, bytesRead);
                        int actual = Marshal.ReadInt32(bytesRead);
                        if (actual <= 0) break;
                        file.Write(buffer, 0, actual);
                        remaining -= actual;
                    }
                }
            }
            finally
            {
                Marshal.FreeHGlobal(bytesRead);
            }
        }
        finally
        {
            Marshal.Release(unknown);
        }
    }
}
'@
    }

    $source = (Resolve-Path -LiteralPath $SourceDir).Path
    $iso = [IO.Path]::GetFullPath($IsoPath)
    $parent = [IO.Path]::GetDirectoryName($iso)
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    [WorkstationIsoWriter]::Write($source, $iso, $VolumeName)
    if (-not (Test-Path -LiteralPath $iso)) { throw "ISO creation failed: $iso" }
    return $iso
}
