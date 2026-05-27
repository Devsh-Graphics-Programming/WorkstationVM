# WorkstationVM

Minimal Windows 11 Hyper-V workstation VM setup.

The script can download the Windows ISO automatically. You can also download the ISO yourself and set `windowsIsoPath` in `config\windows.json` before running the script.

## Requirements

- Windows host with Hyper-V support.
- Virtualization enabled in BIOS/UEFI.
- Internet access for Windows ISO download, unless `windowsIsoPath` points to an existing local ISO.

## What It Does

- Downloads a Windows 11 ISO if `windowsIsoPath` is empty.
- Creates a bootable unattended Windows install ISO with built-in Windows APIs.
- Creates a Generation 2 Hyper-V VM.
- Sets the VMConnect display size from `displayWidth` and `displayHeight`, or from the host primary display when they are empty.
- Enables Hyper-V Enhanced Session transport for VMConnect.
- Installs Windows with an unattended local admin account.
- Installs VS Code, Git, WireGuard and Tor Browser on first login through `winget`.
- Adds desktop shortcuts for VS Code, Git Bash, WireGuard and Tor Browser.
- Enables the RDP server during first login.
- Tunes the guest RDP/DWM frame interval and power plan for smoother interactive sessions.
- Waits until the guest finishes bootstrap and is ready to use.

## Important Settings

- Network uses Hyper-V `Default Switch`, which is NAT.
- Do not change the VM to an external or bridged switch unless that is intentional.
- Keep VPN profiles, work accounts and work browser sessions inside the VM.
- Host traffic is separate from VM traffic. The VM gets its own NATed network path.
- Hyper-V Enhanced Session is enabled for local VMConnect use.
- Secure Boot and TPM are enabled.
- Dynamic memory and automatic checkpoints are disabled.
- No checkpoints are created by default.

## Prepare Host

Run once from PowerShell **as Administrator**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass; .\prepare-host.ps1
```

This validates BIOS/UEFI virtualization setup, enables Hyper-V, enables Hyper-V Enhanced Session Mode and adds the current user to `Hyper-V Administrators`.

After it finishes, close the Administrator PowerShell window. Open a new PowerShell session **without Administrator privileges**.

## Run

Run from normal PowerShell **without Administrator privileges**:

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

## Changing VM Settings

`config\windows.json` is used when the VM is created. After the VM exists, you can change normal Hyper-V settings without recreating it.

Use Hyper-V Manager for changes like CPU count, memory, display size or disk expansion. Some changes require the VM to be shut down first. Keep `recreate` set to `false` unless replacing the VM and its disk is intentional.

## Default Software

The first-login bootstrap installs these tools inside the VM by default:

- VS Code
- Git
- WireGuard
- Tor Browser

It also enables the RDP server, Remote Desktop firewall rules and RDP access for the workstation user.
Remote Desktop frame pacing is tuned during bootstrap so VMConnect Enhanced Session and RDP do not use the default 30 FPS cap. The target is stable 60 FPS for remote sessions.

## Display Performance

The bootstrap tunes the VM for stable 60 FPS VMConnect Enhanced Session and RDP use instead of the default 30 FPS behavior.

Higher refresh rates are not expected through the standard Hyper-V VMConnect or RDP path without GPU passthrough. GPU passthrough is intentionally not configured by this setup because it is hardware-specific and changes how the host and VM share the GPU.

## Optional Debloat

After the VM is installed, you can optionally use tools such as [undergroundwires/privacy.sexy](https://github.com/undergroundwires/privacy.sexy) to review and apply Windows privacy or debloat tweaks.

This is not part of the bootstrap. Review any selected tweaks before applying them because debloat tools can disable Windows features that some workflows need.

## Windows Activation

This setup does not automate Windows activation. Activate the VM after installation with a valid Windows license, product key or organization-provided activation method.

Unofficial activation tools are outside the scope of this setup. They bypass official licensing and can create audit or compliance risk for business use.

## VPN

If a customer provides a VPN profile or config, import and enable it inside this VM only. Do not enable customer VPN profiles on the host.

The default Hyper-V network uses NAT, so host traffic and VM traffic stay on separate network paths.

## RDP

The VM enables the RDP server, Remote Desktop firewall rules and RDP access for the workstation user during first login.

If you want to use RDP as the main UI, consider checking out [Upinel/BetterRDP](https://github.com/Upinel/BetterRDP) and applying its `.reg` file **on the host, not inside the VM**. It tunes the RDP experience by enabling GPU/RemoteFX policies, 60 FPS capture/DWM settings, AVC444/hardware encode preference, image quality, latency and bandwidth-related registry settings. This is optional and is not vendored here.
