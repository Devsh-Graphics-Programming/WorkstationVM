function New-AnswerIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [string]$VolumeName = "AUTOUNATTEND",
        [string]$OverlayDir = "",
        [string]$BootImagePath = ""
    )

    if (-not ("WorkstationIsoWriter" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

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
    void Stat(out System.Runtime.InteropServices.ComTypes.STATSTG pstatstg, int grfStatFlag);
    void Clone(out IStreamNative ppstm);
}

public static class WorkstationIsoWriter
{
    private const uint STGM_READ = 0x00000000;
    private const uint STGM_SHARE_DENY_WRITE = 0x00000020;

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateStreamOnFileEx(
        string fileName,
        uint mode,
        uint attributes,
        bool create,
        IStreamNative template,
        out IStreamNative stream);

    private static object Get(object target, string name)
    {
        return target.GetType().InvokeMember(name, BindingFlags.GetProperty, null, target, null);
    }

    private static void Set(object target, string name, object value)
    {
        target.GetType().InvokeMember(name, BindingFlags.SetProperty, null, target, new object[] { value });
    }

    private static object Call(object target, string name, params object[] args)
    {
        return target.GetType().InvokeMember(name, BindingFlags.InvokeMethod, null, target, args);
    }

    public static void Write(string sourceDir, string overlayDir, string outputPath, string volumeName, string bootImagePath)
    {
        Type imageType = Type.GetTypeFromProgID("IMAPI2FS.MsftFileSystemImage", true);
        object image = Activator.CreateInstance(imageType);
        Set(image, "FileSystemsToCreate", String.IsNullOrWhiteSpace(bootImagePath) ? 3 : 4);
        Set(image, "FreeMediaBlocks", 25000000);
        Set(image, "VolumeName", volumeName);
        object root = Get(image, "Root");
        Call(root, "AddTree", sourceDir, false);
        if (!String.IsNullOrWhiteSpace(overlayDir))
        {
            Call(root, "AddTree", overlayDir, false);
        }

        if (!String.IsNullOrWhiteSpace(bootImagePath))
        {
            Type bootType = Type.GetTypeFromProgID("IMAPI2FS.BootOptions", true);
            object boot = Activator.CreateInstance(bootType);
            Set(boot, "Manufacturer", "Microsoft");
            Set(boot, "PlatformId", 0xef);
            Set(boot, "Emulation", 0);

            IStreamNative bootStream;
            SHCreateStreamOnFileEx(bootImagePath, STGM_READ | STGM_SHARE_DENY_WRITE, 0, false, null, out bootStream);
            Call(boot, "AssignBootImage", bootStream);
            Set(image, "BootImageOptions", boot);
        }

        object result = Call(image, "CreateResultImage");
        object imageStream = Get(result, "ImageStream");
        IntPtr unknown = Marshal.GetIUnknownForObject(imageStream);
        try
        {
            IStreamNative stream = (IStreamNative)Marshal.GetTypedObjectForIUnknown(unknown, typeof(IStreamNative));
            System.Runtime.InteropServices.ComTypes.STATSTG stat;
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
    $overlay = if ([string]::IsNullOrWhiteSpace($OverlayDir)) { "" } else { (Resolve-Path -LiteralPath $OverlayDir).Path }
    $bootImage = if ([string]::IsNullOrWhiteSpace($BootImagePath)) { "" } else { (Resolve-Path -LiteralPath $BootImagePath).Path }
    $iso = [IO.Path]::GetFullPath($IsoPath)
    $parent = [IO.Path]::GetDirectoryName($iso)
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    [WorkstationIsoWriter]::Write($source, $overlay, $iso, $VolumeName, $bootImage)
    if (-not (Test-Path -LiteralPath $iso)) { throw "ISO creation failed: $iso" }
    return $iso
}

function New-InstallIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [Parameter(Mandatory = $true)][string]$BootImagePath,
        [string]$OverlayDir = "",
        [string]$VolumeName = "WORKSTATION"
    )

    New-AnswerIso -SourceDir $SourceDir -IsoPath $IsoPath -BootImagePath $BootImagePath -OverlayDir $OverlayDir -VolumeName $VolumeName
}
