# Support Diagnostic Toolkit - Performance.ps1
# Windows PowerShell 5.1 / PowerShell 7 on Windows
# Read-only, local diagnostic. Remote support intentionally not implemented yet.

function Get-PerformanceDiagnostic {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1, 30)][int]$SampleSeconds = 2,
        [ValidateRange(1, 30)][int]$Top = 5,
        [ValidateRange(1, 100)][int]$MemoryWarningPercent = 85,
        [ValidateRange(1, 100)][int]$CpuWarningPercent = 85
    )

    $localNames = @('.', 'localhost', $env:COMPUTERNAME)
    if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw 'ComputerName ne peut pas etre vide.' }
    if ($ComputerName -notin $localNames) { throw "Mode distant non disponible dans cette version : $ComputerName" }
    if ($env:OS -ne 'Windows_NT') { throw 'Ce module est destine a Windows.' }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $totalMemoryBytes = [double]$computer.TotalPhysicalMemory
    $availableMemoryBytes = [double]$os.FreePhysicalMemory * 1KB
    $memoryUsedPercent = if ($totalMemoryBytes -gt 0) {
        [math]::Round((1 - $availableMemoryBytes / $totalMemoryBytes) * 100, 1)
    } else { $null }

    # Sample total CPU via the Windows performance counter. This is system-wide usage,
    # not the sum of lifetime process CPU times.
    $cpuPercent = $null
    $cpuNote = $null
    try {
        $cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        if ($null -ne $cpu) { $cpuPercent = [math]::Round([double]$cpu.PercentProcessorTime, 1) }
        else { $cpuNote = 'Compteur CPU global indisponible.' }
    } catch {
        $cpuNote = "Compteur CPU global indisponible : $($_.Exception.Message)"
    }

    # Two samples allow estimating recent per-process CPU consumption, rather than
    # incorrectly presenting cumulative CPU time as current CPU percentage.
    $first = @(Get-Process -ErrorAction Stop | Where-Object { $null -ne $_.CPU } | Select-Object Id, ProcessName, CPU)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $SampleSeconds
    $second = @(Get-Process -ErrorAction Stop | Where-Object { $null -ne $_.CPU } | Select-Object Id, ProcessName, CPU, WorkingSet64)
    $timer.Stop()

    $logicalCpus = [int]$computer.NumberOfLogicalProcessors
    if ($logicalCpus -lt 1) { $logicalCpus = 1 }
    $previous = @{}
    foreach ($p in $first) { $previous[[int]$p.Id] = [double]$p.CPU }
    $elapsed = [math]::Max($timer.Elapsed.TotalSeconds, 0.001)
    $processes = @(
        foreach ($p in $second) {
            $recentCpu = $null
            if ($previous.ContainsKey([int]$p.Id)) {
                $delta = [double]$p.CPU - $previous[[int]$p.Id]
                if ($delta -ge 0) {
                    $recentCpu = [math]::Round([math]::Min(100.0, 100.0 * $delta / ($elapsed * $logicalCpus)), 1)
                }
            }
            [PSCustomObject]@{
                Name = $p.ProcessName
                Id = [int]$p.Id
                CpuPercent = $recentCpu
                RAM_MB = [math]::Round([double]$p.WorkingSet64 / 1MB, 1)
            }
        }
    )

    $topCpu = @($processes | Where-Object { $null -ne $_.CpuPercent } | Sort-Object CpuPercent -Descending | Select-Object -First $Top)
    $topMemory = @($processes | Sort-Object RAM_MB -Descending | Select-Object -First $Top)
    $alerts = [System.Collections.Generic.List[string]]::new()
    $recommendations = [System.Collections.Generic.List[string]]::new()

    if ($null -ne $cpuPercent -and $cpuPercent -ge $CpuWarningPercent) {
        $alerts.Add("CPU eleve : $cpuPercent % (seuil : $CpuWarningPercent %).")
        $recommendations.Add('Verifier les processus les plus actifs et refaire une mesure sur une duree plus longue.')
    }
    if ($null -ne $memoryUsedPercent -and $memoryUsedPercent -ge $MemoryWarningPercent) {
        $alerts.Add("RAM utilisee : $memoryUsedPercent % (seuil : $MemoryWarningPercent %).")
        $recommendations.Add('Examiner les applications ouvertes, les processus gourmands et la memoire disponible.')
    }
    if ($null -eq $cpuPercent) {
        $recommendations.Add('Mesure CPU globale indisponible : verifier les compteurs de performances Windows.')
    }
    if ($alerts.Count -eq 0) {
        $recommendations.Add('Aucune saturation CPU/RAM detectee a cet instant ; une mesure ponctuelle ne suffit pas a exclure un ralentissement intermittent.')
    }

    [PSCustomObject]@{
        ComputerName = $computer.Name
        CollectedAt = Get-Date
        SampleSeconds = $SampleSeconds
        CpuPercent = $cpuPercent
        CpuNote = $cpuNote
        LogicalProcessors = $logicalCpus
        TotalRAM_GB = [math]::Round($totalMemoryBytes / 1GB, 2)
        AvailableRAM_GB = [math]::Round($availableMemoryBytes / 1GB, 2)
        RAMUsedPercent = $memoryUsedPercent
        TopCPU = $topCpu
        TopMemory = $topMemory
        Alerts = @($alerts.ToArray())
        Recommendations = @($recommendations.ToArray())
    }
}

function Show-PerformanceDiagnostic {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1, 30)][int]$SampleSeconds = 2,
        [ValidateRange(1, 30)][int]$Top = 5
    )
    $result = Get-PerformanceDiagnostic -ComputerName $ComputerName -SampleSeconds $SampleSeconds -Top $Top
    Write-Host "`n===== DIAGNOSTIC PERFORMANCES =====" -ForegroundColor Cyan
    $result | Select-Object ComputerName, CollectedAt, CpuPercent, TotalRAM_GB, AvailableRAM_GB, RAMUsedPercent | Format-List | Out-Host
    if ($result.CpuNote) { Write-Host $result.CpuNote -ForegroundColor Yellow }
    Write-Host '--- Processus : CPU recent (estimation) ---' -ForegroundColor Cyan
    $result.TopCPU | Format-Table Name, Id, CpuPercent, RAM_MB -AutoSize | Out-Host
    Write-Host '--- Processus : RAM ---' -ForegroundColor Cyan
    $result.TopMemory | Format-Table Name, Id, RAM_MB, CpuPercent -AutoSize | Out-Host
    Write-Host '--- Alertes ---' -ForegroundColor Cyan
    if ($result.Alerts.Count) { $result.Alerts | ForEach-Object { Write-Host "- $_" -ForegroundColor Yellow } }
    else { Write-Host 'Aucune alerte selon les seuils configures.' -ForegroundColor Green }
    Write-Host '--- Pistes de verification ---' -ForegroundColor Cyan
    $result.Recommendations | ForEach-Object { Write-Host "- $_" }
    return $result
}
