# WorkstationVM

Minimal Windows 11 Hyper-V workstation VM setup.

## Requirements

- Windows host with Hyper-V enabled.
- PowerShell running as Administrator.
- Virtualization enabled in BIOS/UEFI.
- Internet access for Windows ISO and first-login tool install.
- `oscdimg.exe` from Windows ADK Deployment Tools available in `PATH`.

## Run

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\create-workstation-vm.ps1 --config config\windows11.json
```

The generated login is written to:

```text
$HOME\VMs\WorkstationWindows11\credentials.txt
```

Check the VM:

```powershell
.\check-workstation-vm.ps1 --config config\windows11.json
```

## What It Does

- Downloads a Windows 11 ISO if `windowsIsoPath` is empty.
- Creates a Generation 2 Hyper-V VM.
- Installs Windows with an unattended local admin account.
- Installs VS Code, Git and WireGuard on first login through `winget`.
- Creates a `clean-ready` checkpoint before work credentials or VPN profiles are added.

## Important Settings

- Network uses Hyper-V `Default Switch`, which is NAT.
- Do not change the VM to an external or bridged switch unless that is intentional.
- Keep VPN profiles, work accounts and work browser sessions inside the VM.
- Host traffic is separate from VM traffic. The VM gets its own NATed network path.
- Secure Boot and TPM are enabled.
- Dynamic memory and automatic checkpoints are disabled.
