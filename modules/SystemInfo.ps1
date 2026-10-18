# Support Diagnostic Toolkit - Inventaire systeme (lecture seule)
# Compatible Windows PowerShell 5.1 et PowerShell 7 sous Windows.

function Get-SystemInfo {
    [CmdletBinding()]
    param(
        # Interface reservee au futur mode distant.
        [string]$ComputerName = $env:COMPUTERNAME
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        throw 'Le nom de l ordinateur ne peut pas etre vide.'
    }
    $localNames = @('.', 'localhost', $env:COMPUTERNAME)
    if ($ComputerName -notin $localNames) {
        throw "Mode distant non disponible dans cette version : $ComputerName."
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)

    $totalBytes = [double]$computer.TotalPhysicalMemory
    $freeBytes = [double]$os.FreePhysicalMemory * 1KB
    $totalGB = [math]::Round($totalBytes / 1GB, 2)
    $availableGB = [math]::Round($freeBytes / 1GB, 2)
    # 0.0 force la surcharge Double de Math.Max (evite le depassement Int32).
    $usedGB = [math]::Round([math]::Max(0.0, ($totalBytes - $freeBytes)) / 1GB, 2)
    $usedPercent = if ($totalBytes -gt 0) {
        [math]::Round(100 * ($totalBytes - $freeBytes) / $totalBytes, 1)
    } else { $null }

    $lastBoot = [datetime]$os.LastBootUpTime
    $now = Get-Date
    $uptime = $now - $lastBoot

    [PSCustomObject]@{
        ComputerName      = $computer.Name
        Manufacturer      = $computer.Manufacturer
        Model             = $computer.Model
        WindowsName       = $os.Caption
        WindowsVersion    = $os.Version
        WindowsBuild      = $os.BuildNumber
        Architecture      = $os.OSArchitecture
        Processor         = (($processors | ForEach-Object { $_.Name.Trim() }) -join ' ; ')
        PhysicalCores     = [int](($processors | Measure-Object -Property NumberOfCores -Sum).Sum)
        LogicalProcessors = [int](($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        TotalRAM_GB       = $totalGB
        AvailableRAM_GB   = $availableGB
        UsedRAM_GB        = $usedGB
        RAMUsedPercent    = $usedPercent
        LastBootTime      = $lastBoot
        Uptime            = ('{0} j {1} h {2} min' -f $uptime.Days, $uptime.Hours, $uptime.Minutes)
        CollectedAt       = $now
    }
}

function Show-SystemInfo {
    [CmdletBinding()]
    param([string]$ComputerName = $env:COMPUTERNAME)

    $info = Get-SystemInfo -ComputerName $ComputerName
    Write-Host "`n===== INFORMATIONS SYSTEME =====" -ForegroundColor Cyan
    $info | Format-List | Out-Host
}
