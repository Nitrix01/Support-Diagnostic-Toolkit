# Support Diagnostic Toolkit - Network diagnostic V1
# Windows PowerShell 5.1 / PowerShell 7 - Read-only
# Remote computer names are reserved for a future version.

function Get-NetworkDiagnostic {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$TestHostName = 'www.microsoft.com',
        [string]$TestIPAddress = '1.1.1.1',
        [int]$TimeoutMilliseconds = 2500
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        throw 'ComputerName ne peut pas etre vide.'
    }
    if ($ComputerName -notin @('.', 'localhost', $env:COMPUTERNAME)) {
        throw "Mode distant non disponible dans cette version : $ComputerName"
    }
    if ($TimeoutMilliseconds -lt 500 -or $TimeoutMilliseconds -gt 30000) {
        throw 'TimeoutMilliseconds doit etre compris entre 500 et 30000.'
    }

    $alerts = [System.Collections.Generic.List[string]]::new()
    $recommendations = [System.Collections.Generic.List[string]]::new()

    $ipConfigs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
        $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up'
    })
    $interfaces = foreach ($cfg in $ipConfigs) {
        $adapter = $cfg.NetAdapter
        $ipv4 = @($cfg.IPv4Address | ForEach-Object { $_.IPAddress })
        $gateway = @(
        $cfg.IPv4DefaultGateway |
        Where-Object {
            $null -ne $_ -and
            $null -ne $_.PSObject.Properties['NextHop']
        } |
        ForEach-Object { $_.NextHop } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )   
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
        $ipInterface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $apipa = @($ipv4 | Where-Object { $_ -like '169.254.*' }).Count -gt 0
        if ($apipa) {
            $alerts.Add("Adresse APIPA detectee sur $($adapter.Name) : $($ipv4 -join ', ')")
            $recommendations.Add("Verifier DHCP, liaison reseau et VLAN pour $($adapter.Name).")
        }
        [pscustomobject]@{
            Interface       = $adapter.Name
            Description     = $adapter.InterfaceDescription
            Status          = $adapter.Status
            IPv4            = ($ipv4 -join ', ')
            PrefixLength    = (@($cfg.IPv4Address | ForEach-Object { $_.PrefixLength }) -join ', ')
            Gateway         = ($gateway -join ', ')
            DNSServers      = ($dns -join ', ')
            DHCPEnabled     = if ($ipInterface) { $ipInterface.Dhcp } else { 'Unknown' }
            APIPA           = $apipa
            InterfaceIndex  = $adapter.ifIndex
        }
    }
    if ($interfaces.Count -eq 0) {
        $alerts.Add('Aucune interface reseau active detectee.')
        $recommendations.Add('Verifier le Wi-Fi, le cable Ethernet et les adaptateurs reseau.')
    }

    $gatewayAddresses = @(
    $ipConfigs |
        ForEach-Object { $_.IPv4DefaultGateway } |
        Where-Object {
            $null -ne $_ -and
            $null -ne $_.PSObject.Properties['NextHop']
        } |
        ForEach-Object { $_.NextHop } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
    if ($interfaces.Count -gt 0 -and $gatewayAddresses.Count -eq 0) {
        $alerts.Add('Aucune passerelle IPv4 par defaut detectee sur les interfaces actives.')
        $recommendations.Add('Verifier la configuration IP et la presence attendue d une passerelle.')
    }

    $gatewayTests = foreach ($address in $gatewayAddresses) {
        $reachable = $false
        try { $reachable = [bool](Test-Connection -ComputerName $address -Count 1 -Quiet -ErrorAction Stop) } catch { }
        [pscustomobject]@{ Address = $address; PingResponded = $reachable }
    }

    $publicPing = $false
    try { $publicPing = [bool](Test-Connection -ComputerName $TestIPAddress -Count 1 -Quiet -ErrorAction Stop) } catch { }

    $resolvedAddresses = @()
    $dnsSucceeded = $false
    try {
        $resolvedAddresses = @(Resolve-DnsName -Name $TestHostName -Type A -ErrorAction Stop |
            Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique)
        $dnsSucceeded = $resolvedAddresses.Count -gt 0
    } catch { }
    if (-not $dnsSucceeded) {
        $alerts.Add("Resolution DNS impossible pour $TestHostName.")
        $recommendations.Add('Verifier les serveurs DNS configures et comparer la resolution avec un autre domaine.')
    }

    $httpsSucceeded = $false
    $httpsError = $null
    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $tcpClient.ConnectAsync($TestHostName, 443)
        if ($task.Wait($TimeoutMilliseconds)) {
            $httpsSucceeded = $tcpClient.Connected
        } else {
            $httpsError = 'Delai de connexion TCP depasse.'
        }
    } catch {
        $httpsError = $_.Exception.Message
    } finally {
        $tcpClient.Dispose()
    }
    if (-not $httpsSucceeded) {
        $alerts.Add("Connexion TCP au port 443 de $TestHostName impossible.")
        $recommendations.Add('Verifier proxy, pare-feu, VPN et filtrage reseau. Le test TCP ne garantit pas une navigation HTTPS fonctionnelle.')
    }

    [pscustomobject]@{
        ComputerName        = $env:COMPUTERNAME
        CollectedAt         = Get-Date
        Interfaces          = @($interfaces)
        GatewayTests        = @($gatewayTests)
        PublicPingTarget    = $TestIPAddress
        PublicPingResponded = $publicPing
        DNSTestName         = $TestHostName
        DNSResolved         = $dnsSucceeded
        DNSAddresses        = @($resolvedAddresses)
        TCP443Connected     = $httpsSucceeded
        TCP443Error         = $httpsError
        Alerts              = @($alerts.ToArray())
        Recommendations     = @($recommendations.ToArray() | Select-Object -Unique)
    }
}

function Show-NetworkDiagnostic {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$TestHostName = 'www.microsoft.com',
        [string]$TestIPAddress = '1.1.1.1'
    )
    $result = Get-NetworkDiagnostic -ComputerName $ComputerName -TestHostName $TestHostName -TestIPAddress $TestIPAddress
    Write-Host "`n===== DIAGNOSTIC RESEAU : $($result.ComputerName) =====" -ForegroundColor Cyan
    if ($result.Interfaces.Count -gt 0) {
        $result.Interfaces | Format-Table Interface, IPv4, PrefixLength, Gateway, DNSServers, DHCPEnabled, APIPA -Wrap -AutoSize | Out-Host
    }
    Write-Host "Ping IP publique ($($result.PublicPingTarget)) : $($result.PublicPingResponded)"
    Write-Host "Resolution DNS ($($result.DNSTestName)) : $($result.DNSResolved)"
    Write-Host "Connexion TCP 443 : $($result.TCP443Connected)"
    if ($result.GatewayTests.Count -gt 0) {
        Write-Host 'Passerelles (reponse ICMP) :'
        $result.GatewayTests | Format-Table -AutoSize | Out-Host
    }
    Write-Host 'NOTE : les tests ICMP peuvent etre bloques par des pare-feu.' -ForegroundColor DarkYellow
    if ($result.Alerts.Count -gt 0) {
        Write-Host "`nPoints a examiner :" -ForegroundColor Yellow
        foreach ($alert in $result.Alerts) { Write-Host " - $alert" }
    } else {
        Write-Host "`nAucune alerte detectee par ces tests de base." -ForegroundColor Green
    }
    if ($result.Recommendations.Count -gt 0) {
        Write-Host "`nPistes de verification :" -ForegroundColor Cyan
        foreach ($recommendation in $result.Recommendations) { Write-Host " - $recommendation" }
    }
}
