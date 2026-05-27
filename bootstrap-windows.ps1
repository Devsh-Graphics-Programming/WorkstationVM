$ErrorActionPreference = "Continue"

$root = "C:\WorkstationVM"
$log = Join-Path $root "bootstrap.log"
New-Item -ItemType Directory -Force -Path $root | Out-Null
Start-Transcript -Path $log -Append | Out-Null

function EnableRemoteDesktop {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Type DWord -Value 0
    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    Set-NetFirewallRule -Name "RemoteDesktop-UserMode-In-TCP", "RemoteDesktop-UserMode-In-UDP" -Enabled True -ErrorAction SilentlyContinue

    try {
        $group = ([Security.Principal.SecurityIdentifier]"S-1-5-32-555").Translate([Security.Principal.NTAccount]).Value.Split("\")[-1]
        Add-LocalGroupMember -Group $group -Member $env:USERNAME -ErrorAction SilentlyContinue
    } catch {
        Write-Output "Remote Desktop user setup failed: $_"
    }
}

function TuneRemoteDesktop {
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations" -Name DWMFRAMEINTERVAL -PropertyType DWord -Value 15 -Force | Out-Null

    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name InteractiveDelay -PropertyType DWord -Value 0 -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name AVC444ModePreferred -PropertyType DWord -Value 1 -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name SystemResponsiveness -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name NetworkThrottlingIndex -PropertyType DWord -Value 0xffffffff -Force | Out-Null
}

function TunePowerPlan {
    powercfg /setactive SCHEME_MIN | Out-Null
}

function Shortcut($name, $target) {
    if (-not (Test-Path -LiteralPath $target)) { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "$name.lnk"))
    $shortcut.TargetPath = $target
    $shortcut.Save()
}

EnableRemoteDesktop
TuneRemoteDesktop
TunePowerPlan

$media = Get-PSDrive -PSProvider FileSystem |
    Where-Object { Test-Path (Join-Path $_.Root "packages.txt") } |
    Select-Object -First 1

$packages = @()
if ($media) {
    $packages = Get-Content -LiteralPath (Join-Path $media.Root "packages.txt") |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

for ($i = 0; $i -lt 60; $i++) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) { break }
    Start-Sleep -Seconds 10
}

if (-not $winget) {
    "winget.exe was not found." | Out-File -FilePath $log -Append
    Stop-Transcript | Out-Null
    exit 1
}

foreach ($package in $packages) {
    & winget.exe install --id $package --exact --source winget --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Output "Install failed: $package ($LASTEXITCODE)"
    }
}

Shortcut "VS Code" "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
Shortcut "Git Bash" "C:\Program Files\Git\git-bash.exe"
Shortcut "WireGuard" "C:\Program Files\WireGuard\wireguard.exe"
Shortcut "Tor Browser" "$(Join-Path ([Environment]::GetFolderPath("Desktop")) "Tor Browser\Browser\firefox.exe")"

"Done" | Set-Content -LiteralPath (Join-Path $root "bootstrap.done")
Stop-Transcript | Out-Null
