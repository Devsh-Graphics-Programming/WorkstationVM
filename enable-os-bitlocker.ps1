$ErrorActionPreference = "Stop"; $scriptArgs = $args

function ArgValue($name, $defaultValue = "") {
    for ($i = 0; $i -lt $scriptArgs.Count; $i++) {
        if ($scriptArgs[$i] -in @("-$name", "--$name")) { return $scriptArgs[$i + 1] }
    }
    return $defaultValue
}

function FullPath($path) {
    $path = [Environment]::ExpandEnvironmentVariables([string]$path)
    if ($path -match '^~[\\/](.*)$') { return (Join-Path $HOME $Matches[1]) }
    if ([IO.Path]::IsPathRooted($path)) { return $path }
    return (Join-Path $PSScriptRoot $path)
}

function Default($cfg, $name, $value) {
    if ($null -eq $cfg.$name) { $cfg | Add-Member -Force NoteProperty $name $value }
}

function Log($scope, $message) {
    Write-Host ("[{0}] {1}" -f $scope, $message)
}

function AssertAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from PowerShell as Administrator. VM security settings and DVD media changes require an elevated token."
    }
}

function SecureText($text) {
    $secure = [Security.SecureString]::new()
    foreach ($ch in ([string]$text).ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return $secure
}

function GuestCredential($cfg) {
    $path = Join-Path (FullPath $cfg.baseDir) "credentials.txt"
    if (-not (Test-Path -LiteralPath $path)) { throw "Credentials file '$path' was not found." }

    $content = Get-Content -LiteralPath $path
    $userLine = $content | Where-Object { $_ -match '^User:\s*(.+)$' } | Select-Object -First 1
    $passwordLine = $content | Where-Object { $_ -match '^Password:\s*(.+)$' } | Select-Object -First 1
    if (-not $userLine -or -not $passwordLine) { throw "Credentials file '$path' does not contain User and Password lines." }

    $user = [regex]::Match($userLine, '^User:\s*(.+)$').Groups[1].Value
    $password = [regex]::Match($passwordLine, '^Password:\s*(.+)$').Groups[1].Value
    [pscredential]::new($user, (SecureText $password))
}

function WaitForVmState($vmName, $state, $timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    do {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        if ($vm.State -eq $state) { return $vm }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    throw "VM '$vmName' did not reach state '$state' within $timeoutSeconds seconds."
}

function WaitForPowerShellDirect($cfg, $credential, $timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    do {
        try {
            Invoke-Command -VMName $cfg.vmName -Credential $credential -ScriptBlock { "ready" } -ErrorAction Stop | Out-Null
            return
        } catch {
            Start-Sleep -Seconds 5
        }
    } while ((Get-Date) -lt $deadline)
    throw "PowerShell Direct did not become ready for VM '$($cfg.vmName)' within $timeoutSeconds seconds."
}

function StopVmGracefully($cfg, $credential) {
    $vm = Get-VM -Name $cfg.vmName -ErrorAction Stop
    if ($vm.State -eq "Off") { return $false }

    Log "vm" "Shutting down VM '$($cfg.vmName)'"
    try {
        Invoke-Command -VMName $cfg.vmName -Credential $credential -ScriptBlock { Stop-Computer -Force } -ErrorAction Stop | Out-Null
    } catch {
        Stop-VM -Name $cfg.vmName -Shutdown -ErrorAction SilentlyContinue | Out-Null
    }
    WaitForVmState $cfg.vmName "Off" 300 | Out-Null
    return $true
}

function EnsureVmTpm($cfg, $credential) {
    $vm = Get-VM -Name $cfg.vmName -ErrorAction Stop
    if ($vm.Generation -ne 2) { throw "VM '$($cfg.vmName)' must be Generation 2 for vTPM-backed OS BitLocker." }

    $security = Get-VMSecurity -VMName $cfg.vmName -ErrorAction Stop
    if ($security.TpmEnabled) {
        Log "host" "vTPM is already enabled"
        return
    }

    $wasRunning = StopVmGracefully $cfg $credential
    Log "host" "Enabling local VM key protector"
    Set-VMKeyProtector -VMName $cfg.vmName -NewLocalKeyProtector
    Log "host" "Enabling vTPM"
    Enable-VMTPM -VMName $cfg.vmName

    if ($wasRunning) {
        Log "vm" "Starting VM '$($cfg.vmName)'"
        Start-VM -Name $cfg.vmName | Out-Null
        WaitForVmState $cfg.vmName "Running" 120 | Out-Null
        WaitForPowerShellDirect $cfg $credential 600
    }
}

function EnsureNoBootableDvd($vmName) {
    $drives = @(Get-VMDvdDrive -VMName $vmName -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) })
    foreach ($drive in $drives) {
        Log "host" "Ejecting VM DVD media from controller $($drive.ControllerNumber), location $($drive.ControllerLocation)"
        Set-VMDvdDrive -VMName $vmName -ControllerNumber $drive.ControllerNumber -ControllerLocation $drive.ControllerLocation -Path $null
    }
}

function RecoveryFile($path, $vmName) {
    $resolved = FullPath $path
    $isDirectory = $false
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $isDirectory = $true
    } elseif ([string]::IsNullOrWhiteSpace([IO.Path]::GetExtension($resolved))) {
        $isDirectory = $true
    }

    if ($isDirectory) {
        New-Item -ItemType Directory -Force -Path $resolved | Out-Null
        return (Join-Path $resolved "$vmName-os-bitlocker-recovery-key.txt")
    }

    $parent = Split-Path -Parent $resolved
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    return $resolved
}

function SecureFileForCurrentUser($path) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $path /inheritance:r /grant:r "${user}:F" | Out-Null
}

function EnableGuestOsBitLocker($cfg, $credential) {
    Invoke-Command -VMName $cfg.vmName -Credential $credential -ScriptBlock {
        $mountPoint = "C:"

        function RefreshVolume {
            Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop
        }

        function ProtectorsOfType($volume, $type) {
            @($volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq $type })
        }

        $tpm = Get-Tpm -ErrorAction Stop
        if (-not $tpm.TpmPresent) { throw "Guest TPM is not present." }
        if (-not $tpm.TpmReady) { throw "Guest TPM is present but not ready." }

        $volume = RefreshVolume
        $recoveryPassword = ""
        $recoveryProtectorId = ""
        $createdRecoveryProtector = $false

        if ($volume.VolumeStatus -eq "FullyDecrypted") {
            Enable-BitLocker -MountPoint $mountPoint -UsedSpaceOnly -TpmProtector -SkipHardwareTest -WarningAction SilentlyContinue | Out-Null
            $volume = RefreshVolume
        }

        if ((ProtectorsOfType $volume "Tpm").Count -eq 0) {
            Add-BitLockerKeyProtector -MountPoint $mountPoint -TpmProtector -WarningAction SilentlyContinue | Out-Null
            $volume = RefreshVolume
        }

        if ((ProtectorsOfType $volume "RecoveryPassword").Count -eq 0) {
            Add-BitLockerKeyProtector -MountPoint $mountPoint -RecoveryPasswordProtector -WarningAction SilentlyContinue | Out-Null
            $volume = RefreshVolume
            $createdRecoveryProtector = $true
        }

        $recovery = ProtectorsOfType $volume "RecoveryPassword" | Select-Object -Last 1
        if ($recovery) {
            $recoveryPassword = [string]$recovery.RecoveryPassword
            $recoveryProtectorId = [string]$recovery.KeyProtectorId
        }

        if ([string]::IsNullOrWhiteSpace($recoveryPassword)) {
            throw "OS BitLocker recovery password could not be read. Refusing to continue without exporting it."
        }

        if ($volume.ProtectionStatus -ne "On") {
            Resume-BitLocker -MountPoint $mountPoint -ErrorAction SilentlyContinue | Out-Null
            & manage-bde.exe -protectors -enable $mountPoint | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "manage-bde failed to enable protectors for $mountPoint." }
            $volume = RefreshVolume
        }

        [pscustomobject]@{
            MountPoint = $volume.MountPoint
            ProtectionStatus = [string]$volume.ProtectionStatus
            VolumeStatus = [string]$volume.VolumeStatus
            EncryptionPercentage = [int]$volume.EncryptionPercentage
            LockStatus = [string]$volume.LockStatus
            RecoveryPassword = $recoveryPassword
            RecoveryProtectorId = $recoveryProtectorId
            CreatedRecoveryProtector = $createdRecoveryProtector
            TpmProtectorCount = (ProtectorsOfType $volume "Tpm").Count
            RecoveryProtectorCount = (ProtectorsOfType $volume "RecoveryPassword").Count
        }
    }
}

function WaitForGuestOsBitLocker($cfg, $credential, $timeoutSeconds) {
    $lastText = ""
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    do {
        $state = Invoke-Command -VMName $cfg.vmName -Credential $credential -ScriptBlock {
            $volume = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
            [pscustomobject]@{
                ProtectionStatus = [string]$volume.ProtectionStatus
                VolumeStatus = [string]$volume.VolumeStatus
                EncryptionPercentage = [int]$volume.EncryptionPercentage
            }
        }
        $text = "C: protection=$($state.ProtectionStatus) status=$($state.VolumeStatus) encrypted=$($state.EncryptionPercentage)%"
        if ($text -ne $lastText) {
            Log "guest" $text
            $lastText = $text
        }
        if ($state.ProtectionStatus -eq "On" -and $state.VolumeStatus -eq "FullyEncrypted") { return $state }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    throw "OS BitLocker did not reach Protection=On and FullyEncrypted within $timeoutSeconds seconds."
}

$configPath = ArgValue "config" "config\windows.json"
$recoveryKeyPath = ArgValue "recovery-key-path"
$waitTimeoutSeconds = [int](ArgValue "wait-timeout-seconds" "14400")
if ([string]::IsNullOrWhiteSpace($recoveryKeyPath)) {
    throw "Usage: .\enable-os-bitlocker.ps1 --config config\windows.json --recovery-key-path <secure-host-directory-or-file>"
}

$cfg = Get-Content -Raw (FullPath $configPath) | ConvertFrom-Json
@{
    vmName = "WorkstationW11"
    user = "work"
    baseDir = "~/VMs/WorkstationWindows11"
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }

AssertAdministrator
$credential = GuestCredential $cfg
$recoveryFile = RecoveryFile $recoveryKeyPath $cfg.vmName

Log "host" "Preparing OS BitLocker for VM '$($cfg.vmName)'"
EnsureNoBootableDvd $cfg.vmName
EnsureVmTpm $cfg $credential
WaitForPowerShellDirect $cfg $credential 300

$state = EnableGuestOsBitLocker $cfg $credential
$createdText = if ($state.CreatedRecoveryProtector) { "created" } else { "existing" }
$recoveryText = @(
    "VM: $($cfg.vmName)",
    "Volume: $($state.MountPoint)",
    "CreatedUtc: $((Get-Date).ToUniversalTime().ToString('s'))Z",
    "RecoveryProtector: $($state.RecoveryProtectorId)",
    "RecoveryPassword: $($state.RecoveryPassword)"
)
Set-Content -LiteralPath $recoveryFile -Value $recoveryText -Encoding ascii
SecureFileForCurrentUser $recoveryFile
Log "host" "Recovery key exported to $recoveryFile ($createdText protector)"

$final = WaitForGuestOsBitLocker $cfg $credential $waitTimeoutSeconds
if ($final.ProtectionStatus -ne "On") { throw "OS BitLocker protection is not on." }
if ($final.VolumeStatus -ne "FullyEncrypted") { throw "OS BitLocker is not fully encrypted." }

Write-Host ""
Write-Host "READY: OS BitLocker is enabled for VM '$($cfg.vmName)'."
