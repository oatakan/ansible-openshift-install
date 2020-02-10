Param(
    [Parameter(Mandatory=$true)]
    [string]$SubnetFile,
    [Parameter(Mandatory=$false)]
    [string]$OVSNetworkName="external",
    [Parameter(Mandatory=$false)]
    [int]$OVSCmdTimeout=30
)

$ErrorActionPreference = "Stop"

function Set-StaticIPAddress {
    $IP = $currentIPAddress
    $MaskBits = 24
    $Gateway = $currentGW
    $Dns = $currentDNS
    $IPType = "IPv4"

    $primaryIfIndex = (Get-NetRoute -DestinationPrefix "0.0.0.0/0").ifIndex
    $mainInterface = Get-NetAdapter -InterfaceIndex $primaryIfIndex

    # Remove any existing IP, gateway from our ipv4 adapter
    If (($mainInterface | Get-NetIPConfiguration).IPv4Address.IPAddress) {
     $mainInterface | Remove-NetIPAddress -AddressFamily $IPType -Confirm:$false
    }
    If (($mainInterface | Get-NetIPConfiguration).Ipv4DefaultGateway) {
     $mainInterface | Remove-NetRoute -AddressFamily $IPType -Confirm:$false
    }
     # Configure the IP address and default gateway
    $mainInterface | New-NetIPAddress -AddressFamily $IPType -IPAddress $IP -PrefixLength $MaskBits -DefaultGateway $Gateway
    # Configure the DNS client server IP addresses
    $mainInterface | Set-DnsClientServerAddress -ServerAddresses $Dns
}

function Get-NetworkInfo {
    if(!(Test-Path $SubnetFile)) {
        Throw "The subnet file $SubnetFile doesn't exist"
    }
    $subnet = Get-Content $SubnetFile -Raw | ConvertFrom-Json
    if(!($subnet -is [string])) {
        Throw "The content from file $SubnetFile is not a string: $subnet"
    }
    $splitSubnet = $subnet.Split('/')
    if($splitSubnet.Count -ne 2) {
        Throw "The subnet format from file is incorrect: $subnet"
    }
    $net = $splitSubnet[0].Split('.')
    $gateway = "{0}.{1}.{2}.{3}" -f @($net[0], $net[1], $net[2], "1")
    return @{
        "subnet" = $subnet
        "gateway" = $gateway
    }
}

function New-OVSNetwork {
    $primaryIfIndex = (Get-NetRoute -DestinationPrefix "0.0.0.0/0").ifIndex
    $mainInterface = Get-NetAdapter -InterfaceIndex $primaryIfIndex
    [array]$networks = Get-HnsNetwork | Where-Object {
        ($_.Name -eq $OVSNetworkName) -and ($_.Type -eq "Transparent")
    }
    if($networks) {
        if($networks.Count -gt 1) {
            # If we reach this, something weird happened
            Throw "More than one OVS network was found"
        }
        $adapterName = $networks[0].NetworkAdapterName
        # Clean up existing network to refresh its subnet and gateway values
        $networks | Remove-HnsNetwork
    } else {
        $adapterName = $mainInterface.InterfaceAlias
    }
    $netInfo = Get-NetworkInfo
    $net = New-HnsNetwork -Name $OVSNetworkName -Type "Transparent" -AdapterName $adapterName `
                          -AddressPrefix $netInfo["subnet"] -Gateway $netInfo["gateway"]
    # Check if the virtual adapter is present post HNS network creation
    $virtualAdapterName = "vEthernet ($($net.NetworkAdapterName))"
    $adapter = Get-NetAdapter -Name $virtualAdapterName -ErrorAction SilentlyContinue
    if(!$adapter) {
        Throw "The virtual adapter $virtualAdapterName doesn't exist post HNS network creation"
    }
    return $net
}


try {
    Import-Module HostNetworkingService
    Import-Module HNSHelper -DisableNameChecking
    Import-Module OVS -DisableNameChecking

    $primaryIfIndex = (Get-NetRoute -DestinationPrefix "0.0.0.0/0").ifIndex
    $currentIPAddress = Get-NetAdapter -InterfaceIndex $primaryIfIndex | Get-NetIPAddress -AddressFamily ipV4 | Select-Object -ExpandProperty IPAddress
    $currentGW = Get-NetAdapter -InterfaceIndex $primaryIfIndex | Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Select-Object -ExpandProperty "NextHop"
    $currentDNS = Get-DnsClientServerAddress -InterfaceIndex $primaryIfIndex | Select-Object -First 1 -ExpandProperty "ServerAddresses"

    $net = New-OVSNetwork
    Set-Service "ovs-vswitchd" -StartupType Disabled
    Stop-Service "ovs-vswitchd" -Force -ErrorAction SilentlyContinue
    Disable-OVSOnHNSNetwork $net.ID
    $bridgeName = "vEthernet ($($net.NetworkAdapterName))"
    ovs-vsctl.exe --timeout $OVSCmdTimeout --if-exists --no-wait del-br "$bridgeName"
    if($LASTEXITCODE) {
        Throw "Failed to cleanup existing OVS bridge"
    }
    ovs-vsctl.exe --timeout $OVSCmdTimeout --no-wait --may-exist add-br "$bridgeName"
    if($LASTEXITCODE) {
        Throw "Failed to add the OVS bridge"
    }
    ovs-vsctl.exe --timeout $OVSCmdTimeout --no-wait --may-exist add-port "$bridgeName" "$($net.NetworkAdapterName)"
    if($LASTEXITCODE) {
        Throw "Failed to add the HNS interface to OVS bridge"
    }
    Enable-OVSOnHNSNetwork $net.ID

    Set-StaticIPAddress

    Set-Service "ovs-vswitchd" -StartupType Automatic
    Start-Service "ovs-vswitchd"
    Write-Output "The SDN network setup is ready"
} catch {
    Write-Output $_.ScriptStackTrace
    exit 1
}
exit 0