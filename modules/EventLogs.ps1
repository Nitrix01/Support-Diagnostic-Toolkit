# Support Diagnostic Toolkit - EventLogs.ps1
# Compatible Windows PowerShell 5.1 / PowerShell 7 on Windows.
# Read-only local event log diagnostics. Remote support will be added later.

function Get-EventLogDiagnostic {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1, 720)][int]$Hours = 24,
        [ValidateRange(1, 500)][int]$MaxEventsPerLog = 100,
        [ValidateRange(1, 50)][int]$Top = 10
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        throw 'Le nom de l ordinateur ne peut pas etre vide.'
    }
    if ($ComputerName -notin @('.', 'localhost', $env:COMPUTERNAME)) {
        throw "Mode distant non disponible dans cette version : $ComputerName."
    }

    $since = (Get-Date).AddHours(-$Hours)
    $collectedAt = Get-Date
    $events = @()
    $warnings = @()

    foreach ($logName in @('System', 'Application')) {
        try {
            $found = @(Get-WinEvent -FilterHashtable @{
                LogName = $logName
                Level = @(1, 2) # Critical, Error
                StartTime = $since
            } -MaxEvents $MaxEventsPerLog -ErrorAction Stop)

            foreach ($event in $found) {
                $message = [string]$event.Message
                if ($message.Length -gt 450) { $message = $message.Substring(0, 450) + '...' }
                $events += [PSCustomObject]@{
                    TimeCreated = $event.TimeCreated
                    LogName = $logName
                    Level = if ($event.Level -eq 1) { 'Critique' } else { 'Erreur' }
                    EventId = $event.Id
                    Provider = $event.ProviderName
                    Message = $message
                }
            }
        }
        catch {
            $details = $_.Exception.Message
            if ($details -match 'No events were found|Aucun evenement|Aucun .*v.nement') {
                continue
            }
            $warnings += "Journal $logName : $details"
        }
    }

    $events = @($events | Sort-Object TimeCreated -Descending)
    $topSources = @($events | Group-Object Provider, EventId | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object {
        [PSCustomObject]@{
            Count = $_.Count
            Provider = $_.Group[0].Provider
            EventId = $_.Group[0].EventId
            LogName = $_.Group[0].LogName
        }
    })

    $recommendations = @()
    if ($events.Count -eq 0 -and $warnings.Count -eq 0) {
        $recommendations += 'Aucune erreur critique ou erreur relevee dans les limites de cette recherche.'
    }
    if (@($events | Where-Object { $_.Provider -match 'Service Control Manager' }).Count -gt 0) {
        $recommendations += 'Examiner les evenements Service Control Manager et verifier les services concernes.'
    }
    if (@($events | Where-Object { $_.Provider -match 'Application Error|Windows Error Reporting' }).Count -gt 0) {
        $recommendations += 'Verifier les applications concernees, leur version et les circonstances des plantages.'
    }
    if (@($events | Where-Object { $_.Provider -match 'Disk|Ntfs|storahci|stornvme' }).Count -gt 0) {
        $recommendations += 'Examiner les erreurs de stockage et sauvegarder les donnees importantes si des defaillances sont suspectees.'
    }
    if ($events.Count -gt 0 -and $recommendations.Count -eq 0) {
        $recommendations += 'Correller les heures et identifiants des evenements avec le probleme signale par l utilisateur.'
    }
    if ($warnings.Count -gt 0) {
        $recommendations += 'Verifier les droits de lecture des journaux et les avertissements de collecte.'
    }

    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        CollectedAt = $collectedAt
        Hours = $Hours
        Since = $since
        MaxEventsPerLog = $MaxEventsPerLog
        TotalEvents = $events.Count
        CriticalCount = @($events | Where-Object { $_.Level -eq 'Critique' }).Count
        ErrorCount = @($events | Where-Object { $_.Level -eq 'Erreur' }).Count
        TopSources = $topSources
        Events = $events
        Warnings = @($warnings)
        Recommendations = @($recommendations)
    }
}

function Show-EventLogDiagnostic {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1, 720)][int]$Hours = 24,
        [ValidateRange(1, 500)][int]$MaxEventsPerLog = 100,
        [ValidateRange(1, 50)][int]$Top = 10
    )

    $result = Get-EventLogDiagnostic -ComputerName $ComputerName -Hours $Hours -MaxEventsPerLog $MaxEventsPerLog -Top $Top
    Write-Host "`n===== DIAGNOSTIC JOURNAUX WINDOWS =====" -ForegroundColor Cyan
    Write-Host "PC : $($result.ComputerName) | Periode : $Hours h | Evenements : $($result.TotalEvents)"
    Write-Host "Critiques : $($result.CriticalCount) | Erreurs : $($result.ErrorCount)"

    Write-Host "`n--- Sources / ID les plus frequents ---" -ForegroundColor Cyan
    if ($result.TopSources.Count -gt 0) {
        $result.TopSources | Format-Table -AutoSize | Out-Host
    } else { Write-Host 'Aucun evenement a afficher.' }

    Write-Host "`n--- Evenements recents (max. $Top) ---" -ForegroundColor Cyan
    if ($result.Events.Count -gt 0) {
        $result.Events | Select-Object -First $Top TimeCreated, LogName, Level, EventId, Provider | Format-Table -AutoSize | Out-Host
    } else { Write-Host 'Aucun evenement a afficher.' }

    if ($result.Warnings.Count -gt 0) {
        Write-Host "`n--- Avertissements de collecte ---" -ForegroundColor Yellow
        foreach ($warning in $result.Warnings) { Write-Host "- $warning" }
    }

    Write-Host "`n--- Pistes de verification ---" -ForegroundColor Cyan
    foreach ($recommendation in $result.Recommendations) { Write-Host "- $recommendation" }
}

function Export-EventLogDiagnostic {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1, 720)][int]$Hours = 24,
        [ValidateRange(1, 500)][int]$MaxEventsPerLog = 100,
        [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Reports')
    )

    $result = Get-EventLogDiagnostic -ComputerName $ComputerName -Hours $Hours -MaxEventsPerLog $MaxEventsPerLog
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
    }
    $file = Join-Path $OutputDirectory ("EventLogs_{0}_{1}.csv" -f $result.ComputerName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($result.Events.Count -gt 0) {
        $result.Events | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
    } else {
        'TimeCreated,LogName,Level,EventId,Provider,Message' | Set-Content -Path $file -Encoding UTF8
    }
    Write-Host "Rapport CSV enregistre : $file" -ForegroundColor Green
    return $file
}
