# Support Diagnostic Toolkit - Services.ps1 V2
# Compatible Windows PowerShell 5.1 / PowerShell 7 sous Windows.
# Lecture seule. Analyse locale uniquement (mode distant a venir).

function Assert-LocalServiceComputer {
    param([string]$ComputerName = $env:COMPUTERNAME)
    if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw 'Le nom du PC ne peut pas etre vide.' }
    if ($ComputerName -notin @('.', 'localhost', $env:COMPUTERNAME)) {
        throw "Mode distant non disponible dans cette version : $ComputerName"
    }
}

function Get-WindowsServiceInventory {
    [CmdletBinding()]
    param(
        [ValidateSet('All', 'Running', 'Stopped', 'AutomaticStopped')]
        [string]$Filter = 'All'
    )
    $inventory = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.Name
            DisplayName = $_.DisplayName
            State       = $_.State
            StartMode   = $_.StartMode
            ProcessId   = $_.ProcessId
        }
    })
    switch ($Filter) {
        'Running' { $inventory = @($inventory | Where-Object State -eq 'Running') }
        'Stopped' { $inventory = @($inventory | Where-Object State -eq 'Stopped') }
        'AutomaticStopped' {
            $inventory = @($inventory | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Stopped' })
        }
    }
    $inventory | Sort-Object Name
}

function Export-WindowsServiceInventory {
    [CmdletBinding()]
    param(
        [ValidateSet('All', 'Running', 'Stopped', 'AutomaticStopped')]
        [string]$Filter = 'All',
        [string]$ReportDirectory = (Join-Path $PSScriptRoot '..\Reports')
    )
    $null = New-Item -ItemType Directory -Path $ReportDirectory -Force -ErrorAction Stop
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $ReportDirectory "Services-$Filter-$timestamp.csv"
    $inventory = @(Get-WindowsServiceInventory -Filter $Filter)
    if ($inventory.Count -eq 0) {
        Write-Warning 'Aucun service ne correspond au filtre. Aucun fichier CSV cree.'
        return
    }
    $inventory | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 -Delimiter ';' -ErrorAction Stop
    Write-Output $path
}

function Get-WindowsServiceDiagnostic {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 720)] [int]$Hours = 24,
        [ValidateRange(1, 5000)] [int]$MaxEvents = 300,
        [string]$ComputerName = $env:COMPUTERNAME
    )
    Assert-LocalServiceComputer -ComputerName $ComputerName
    $collectedAt = Get-Date
    $since = $collectedAt.AddHours(-$Hours)
    $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
    $eventIds = @(7000, 7001, 7009, 7023, 7031, 7034, 7043)
    $events = @()
    $eventWarning = $null
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Service Control Manager'
            Id = $eventIds
            StartTime = $since
        } -MaxEvents $MaxEvents -ErrorAction Stop)
    } catch {
        # Get-WinEvent utilise aussi une exception si aucun evenement ne correspond.
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or $_.Exception.Message -match 'No events were found|Aucun evenement|Aucun événement') {
            $events = @()
        } else {
            $eventWarning = "Lecture des journaux impossible ou incomplete : $($_.Exception.Message)"
        }
    }

    $eventRecords = @($events | ForEach-Object {
        $evt = $_
        $serviceName = $null
        # Dans ces evenements SCM, le premier parametre contient souvent le nom affiche du service.
        try {
            [xml]$xml = $evt.ToXml()
            $dataNodes = @($xml.Event.EventData.Data)
            if ($dataNodes.Count -gt 0) {
                $first = [string]$dataNodes[0].'#text'
                if ([string]::IsNullOrWhiteSpace($first)) { $first = [string]$dataNodes[0].InnerText }
                if (-not [string]::IsNullOrWhiteSpace($first)) { $serviceName = $first.Trim() }
            }
        } catch { }
        [PSCustomObject]@{
            TimeCreated = $evt.TimeCreated
            EventId = $evt.Id
            ServiceNameFromEvent = $serviceName
            Message = $evt.Message
            RecordId = $evt.RecordId
        }
    })

    $results = @($services | ForEach-Object {
        $service = $_
        $related = @($eventRecords | Where-Object {
            # Association stricte au nom technique ou au nom affiche, pas de sous-chaine.
            -not [string]::IsNullOrWhiteSpace($_.ServiceNameFromEvent) -and
            ($_.ServiceNameFromEvent -ieq $service.Name -or $_.ServiceNameFromEvent -ieq $service.DisplayName)
        })
        $stoppedAuto = ($service.StartMode -eq 'Auto' -and $service.State -eq 'Stopped')
        $hasEvents = ($related.Count -gt 0)
        $status = if ($hasEvents -and $service.State -eq 'Stopped') { 'Incident probable' }
                  elseif ($hasEvents) { 'Evenement recent' }
                  elseif ($stoppedAuto) { 'A verifier' }
                  else { 'Normal' }
        $recommendation = switch ($status) {
            'Incident probable' { 'Consulter les messages SCM, verifier les dependances et la configuration du service.' }
            'Evenement recent' { 'Verifier la recurrence et comparer les horaires aux symptomes signales.' }
            'A verifier' { 'Verifier si le service est a demarrage declenche ou volontairement inactif.' }
            default { '' }
        }
        [PSCustomObject]@{
            Name = $service.Name
            DisplayName = $service.DisplayName
            State = $service.State
            StartMode = $service.StartMode
            ProcessId = $service.ProcessId
            Status = $status
            RecentEventCount = $related.Count
            RecentEventIds = (($related | Select-Object -ExpandProperty EventId -Unique) -join ', ')
            LastEventTime = if ($hasEvents) { ($related | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated } else { $null }
            Recommendation = $recommendation
        }
    })

    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        CollectedAt = $collectedAt
        Hours = $Hours
        TotalServices = $services.Count
        AutomaticStoppedCount = @($results | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Stopped' }).Count
        RelatedEventCount = $eventRecords.Count
        EventReadWarning = $eventWarning
        Findings = @($results | Where-Object Status -ne 'Normal' | Sort-Object Status, Name)
        Services = $results
        Events = $eventRecords
    }
}

function Show-WindowsServiceDiagnostic {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 720)] [int]$Hours = 24,
        [ValidateRange(1, 5000)] [int]$MaxEvents = 300,
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1, 100)] [int]$Top = 20
    )
    $diagnostic = Get-WindowsServiceDiagnostic -Hours $Hours -MaxEvents $MaxEvents -ComputerName $ComputerName
    Write-Host "`n===== DIAGNOSTIC SERVICES WINDOWS =====" -ForegroundColor Cyan
    Write-Host "PC : $($diagnostic.ComputerName) | Periode : $Hours h"
    Write-Host "Services : $($diagnostic.TotalServices) | Auto arretes : $($diagnostic.AutomaticStoppedCount) | Evenements SCM : $($diagnostic.RelatedEventCount)"
    if ($diagnostic.EventReadWarning) { Write-Warning $diagnostic.EventReadWarning }
    Write-Host "`n--- Services a examiner (max. $Top) ---" -ForegroundColor Yellow
    if (@($diagnostic.Findings).Count -eq 0) {
        Write-Host 'Aucun signalement selon les criteres de cette analyse.'
    } else {
        $diagnostic.Findings | Select-Object -First $Top Name, State, StartMode, Status, RecentEventCount, RecentEventIds |
            Format-Table -AutoSize | Out-Host
    }
    Write-Host "`nNote : un service automatique arrete n'est pas necessairement en panne."
    Write-Host 'Les evenements non associes restent disponibles dans la propriete Events.'
    # Utiliser Get-WindowsServiceDiagnostic pour recuperer l'objet complet.
}

function Export-WindowsServiceDiagnostic {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 720)] [int]$Hours = 24,
        [ValidateRange(1, 5000)] [int]$MaxEvents = 300,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$ReportDirectory = (Join-Path $PSScriptRoot '..\Reports')
    )
    $diagnostic = Get-WindowsServiceDiagnostic -Hours $Hours -MaxEvents $MaxEvents -ComputerName $ComputerName
    $null = New-Item -ItemType Directory -Path $ReportDirectory -Force -ErrorAction Stop
    $path = Join-Path $ReportDirectory ("Services-Diagnostic-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $diagnostic.Services | Export-Csv -Path $path -NoTypeInformation -Delimiter ';' -Encoding UTF8 -ErrorAction Stop
    return $path
}
