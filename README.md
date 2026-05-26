# WorkstationVM

Minimal Windows 11 Hyper-V workstation VM setup.

## Requirements

- Windows host with Hyper-V support.
- Virtualization enabled in BIOS/UEFI.
- Internet access for Windows ISO and tool install.

`prepare-host.ps1` checks BIOS/UEFI virtualization and stops with a clear error if it is disabled.

## Prepare Host

Run once from PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\prepare-host.ps1
```

This enables Hyper-V, adds the current user to `Hyper-V Administrators` and installs Windows ADK Deployment Tools if needed.

If Hyper-V was just enabled, restart Windows.
If only group membership changed, sign out and back in.

## Run

Run from normal PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\create-workstation-vm.ps1 --config config\windows.json
```

Edit `config\windows.json` first if you want a different VM name, RAM, CPU count, disk size or install path.
By default, an existing VM or disk is not deleted. Set `recreate` to `true` only when you intentionally want to replace it.

The generated login is written to:

```text
$HOME\VMs\WorkstationWindows11\credentials.txt
```

Check the VM:

```powershell
.\check-workstation-vm.ps1 --config config\windows.json
```

## RDP

The VM enables the RDP server, Remote Desktop firewall rules and RDP access for the workstation user during first login.

If you want to use RDP as the main UI, consider checking out [Upinel/BetterRDP](https://github.com/Upinel/BetterRDP) and applying its `.reg` file. It tunes the RDP experience by enabling GPU/RemoteFX policies, 60 FPS capture/DWM settings, AVC444/hardware encode preference, image quality, latency and bandwidth-related registry settings. This is optional and is not vendored here.

## What It Does

- Downloads a Windows 11 ISO if `windowsIsoPath` is empty.
- Creates a Generation 2 Hyper-V VM.
- Installs Windows with an unattended local admin account.
- Installs VS Code, Git and WireGuard on first login through `winget`.
- Enables the RDP server during first login.
- Creates a `clean-ready` checkpoint before work credentials or VPN profiles are added.

## Important Settings

- Network uses Hyper-V `Default Switch`, which is NAT.
- Do not change the VM to an external or bridged switch unless that is intentional.
- Keep VPN profiles, work accounts and work browser sessions inside the VM.
- Host traffic is separate from VM traffic. The VM gets its own NATed network path.
- Secure Boot and TPM are enabled.
- Dynamic memory and automatic checkpoints are disabled.
