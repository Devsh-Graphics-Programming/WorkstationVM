@{
    VMUser = "work"
    Password = ""
    SwitchName = "Default Switch"
    ImageCacheRoot = "~/VMs/_image-cache"
    ProvisioningProfile = "Full"
    MemoryStartupGB = 16
    VhdSizeGB = 100
    CpuCount = 4
    CreateCleanCheckpoint = $true
    CleanCheckpointName = "clean-ready-no-creds-no-vpn"
    WorkAppUrls = @(
        "https://teams.microsoft.com/v2/",
        "https://outlook.office.com/mail/"
    )
}
