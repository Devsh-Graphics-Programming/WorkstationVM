# WorkstationVM

Minimal Windows 11 Hyper-V workstation VM setup.

The script can download the Windows ISO automatically. You can also download the ISO yourself and set `windowsIsoPath` in `config\windows.json` before running the script.

## Requirements

- Windows host with Hyper-V support.
- Virtualization enabled in BIOS/UEFI.
- Internet access for Windows ISO download, unless `windowsIsoPath` points to an existing local ISO.

## Prepare Host

Run once from PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass; .\prepare-host.ps1
```

This validates BIOS/UEFI virtualization setup, enables Hyper-V and adds the current user to `Hyper-V Administrators`.

After it finishes, close the Administrator PowerShell window. Open a new PowerShell session without Administrator privileges.

## Run

Run from normal PowerShell without Administrator privileges:

```powershell
Set-ExecutionPolicy -Scope Process Bypass; .\create-workstation-vm.ps1 --config config\windows.json
```

Edit `config\windows.json` first if you want a different VM name, RAM, CPU count, disk size or install path.
By default, an existing VM or disk is not deleted. Set `recreate` to `true` only when you intentionally want to replace it.

The generated login is written to:

```text
$HOME\VMs\WorkstationWindows11\credentials.txt
```

The file contains the VM username and password. Hyper-V Manager may reconnect to the active local session without asking, but use this login for RDP, PowerShell Direct or manual sign-in when needed.
Print it from PowerShell with:

```powershell
Get-Content -LiteralPath "$HOME\VMs\WorkstationWindows11\credentials.txt"
```

When the script finishes successfully, the VM is ready to use and the output looks like this:

![Ready VM output](misc/vmready.png)

Open Hyper-V Manager, then double-click the VM to open the interactive VM window:

![Hyper-V Manager VM window](misc/hypervmanager.png)

Check the VM:

```powershell
.\check-workstation-vm.ps1 --config config\windows.json
```

## Default Software

The first-login bootstrap installs these tools inside the VM by default:

- VS Code
- Git
- WireGuard

It also enables the RDP server, Remote Desktop firewall rules and RDP access for the workstation user.

## VPN

If a customer provides a VPN profile or config, import and enable it inside this VM only. Do not enable customer VPN profiles on the host.

The default Hyper-V network uses NAT, so host traffic and VM traffic stay on separate network paths.

## RDP

The VM enables the RDP server, Remote Desktop firewall rules and RDP access for the workstation user during first login.

If you want to use RDP as the main UI, consider checking out [Upinel/BetterRDP](https://github.com/Upinel/BetterRDP) and applying its `.reg` file. It tunes the RDP experience by enabling GPU/RemoteFX policies, 60 FPS capture/DWM settings, AVC444/hardware encode preference, image quality, latency and bandwidth-related registry settings. This is optional and is not vendored here.

## What It Does

- Downloads a Windows 11 ISO if `windowsIsoPath` is empty.
- Creates a bootable unattended Windows install ISO with built-in Windows APIs.
- Creates a Generation 2 Hyper-V VM.
- Installs Windows with an unattended local admin account.
- Installs VS Code, Git and WireGuard on first login through `winget`.
- Enables the RDP server during first login.
- Waits until the guest finishes bootstrap and is ready to use.

## Important Settings

- Network uses Hyper-V `Default Switch`, which is NAT.
- Do not change the VM to an external or bridged switch unless that is intentional.
- Keep VPN profiles, work accounts and work browser sessions inside the VM.
- Host traffic is separate from VM traffic. The VM gets its own NATed network path.
- Secure Boot and TPM are enabled.
- Dynamic memory and automatic checkpoints are disabled.
- No checkpoints are created by default.
