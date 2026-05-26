@{
    ProvisioningProfile = "Smoke"
    MemoryStartupGB = 4
    VhdSizeGB = 64
    CpuCount = 2
    CreateCleanCheckpoint = $false
    MaintenanceSshHost = "192.168.250.10"
    UbuntuStaticAddress = "192.168.250.10/24"
    UbuntuGateway = "192.168.250.1"
    UbuntuDnsServers = @("1.1.1.1", "8.8.8.8")
    WorkAppUrls = @()
}
