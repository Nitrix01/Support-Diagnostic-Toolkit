# Support Diagnostic Toolkit - WindowsUpdate.ps1
# Windows PowerShell 5.1 / PowerShell 7 on Windows. Read-only local diagnostic.
Set-StrictMode -Version Latest

function Get-WindowsUpdateDiagnostic {
    [CmdletBinding()]
    param(
        [ValidateRange(1,8760)][int]$Hours = 168,
        [ValidateRange(1,500)][int]$MaxEvents = 100,
        [string]$ComputerName = $env:COMPUTERNAME
    )
    if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw 'ComputerName ne peut pas etre vide.' }
    if ($ComputerName -notin @('.', 'localhost', $env:COMPUTERNAME)) {
        throw "Mode distant non disponible dans cette version : $ComputerName"
    }
    $since = (Get-Date).AddHours(-$Hours)
    $warnings = [System.Collections.Generic.List[string]]::new()
    $events = @()
    try {
        $raw = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
            StartTime = $since
        } -MaxEvents $MaxEvents -ErrorAction Stop)
        $events = @($raw | ForEach-Object {
            [pscustomobject]@{
                TimeCreated = $_.TimeCreated
                EventId = $_.Id
                Level = $_.LevelDisplayName
                Message = $_.Message
                RecordId = $_.RecordId
            }
        })
    } catch {
        if ($_.Exception.Message -match 'No events were found|Aucun evenement|Aucun événement') {
            $events = @()
        } else {
            $warnings.Add("Lecture du journal WindowsUpdateClient impossible : $($_.Exception.Message)")
        }
    }

    $services = @()
    foreach ($name in @('wuauserv','BITS','UsoSvc')) {
        try {
            $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction Stop
            if ($null -ne $svc) {
                $services += [pscustomobject]@{
                    Name = $svc.Name
                    DisplayName = $svc.DisplayName
                    State = $svc.State
                    StartMode = $svc.StartMode
                }
            }
        } catch {
            $warnings.Add("Service $name inaccessible : $($_.Exception.Message)")
        }
    }

    $pendingChecks = @(
        @{ Name='WindowsUpdateRebootRequired'; Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' },
        @{ Name='ComponentBasedServicingRebootPending'; Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' }
    )
    $pendingIndicators = @()
    foreach ($check in $pendingChecks) {
        try {
            if (Test-Path -LiteralPath $check.Path -ErrorAction Stop) { $pendingIndicators += $check.Name }
        } catch {
            $warnings.Add("Verification de redemarrage impossible ($($check.Name)) : $($_.Exception.Message)")
        }
    }

    # Event 20 commonly reports installation failure; other IDs are context, not universal success/failure proof.
    $failedEvents = @($events | Where-Object { $_.EventId -eq 20 })
    $recommendations = [System.Collections.Generic.List[string]]::new()
    if ($failedEvents.Count -gt 0) {
        $recommendations.Add('Examiner les messages des evenements 20 et relever les codes erreur avant toute intervention.')
    }
    if ($pendingIndicators.Count -gt 0) {
        $recommendations.Add('Un indicateur de redemarrage en attente est present : confirmer avec l utilisateur avant de planifier un redemarrage.')
    }
    if ($warnings.Count -gt 0) {
        $recommendations.Add('Certaines donnees sont indisponibles : verifier les autorisations et les journaux.')
    }
    if ($recommendations.Count -eq 0) {
        $recommendations.Add('Aucune anomalie ciblee detectee dans les donnees consultees ; cela ne garantit pas que Windows Update fonctionne parfaitement.')
    }

    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        CollectedAt = Get-Date
        Hours = $Hours
        Events = $events
        EventCount = $events.Count
        FailedInstallationEvents = $failedEvents
        FailedInstallationCount = $failedEvents.Count
        Services = $services
        RebootPending = ($pendingIndicators.Count -gt 0)
        RebootIndicators = $pendingIndicators
        Warnings = @($warnings.ToArray())
        Recommendations = @($recommendations.ToArray())
    }
}

function Show-WindowsUpdateDiagnostic {
    [CmdletBinding()]
    param(
        [ValidateRange(1,8760)][int]$Hours = 168,
        [ValidateRange(1,500)][int]$MaxEvents = 100,
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1,100)][int]$Top = 15
    )
    $d = Get-WindowsUpdateDiagnostic -Hours $Hours -MaxEvents $MaxEvents -ComputerName $ComputerName
    Write-Host "`n===== DIAGNOSTIC WINDOWS UPDATE =====" -ForegroundColor Cyan
    Write-Host "PC : $($d.ComputerName) | Periode : $Hours h | Evenements : $($d.EventCount) | Echecs (ID 20) : $($d.FailedInstallationCount)"
    Write-Host "Redemarrage en attente (indicateurs verifies) : $($d.RebootPending)"
    if ($d.RebootIndicators.Count -gt 0) { Write-Host "Indicateurs : $($d.RebootIndicators -join ', ')" }
    Write-Host "`n--- Services ---" -ForegroundColor Cyan
    if ($d.Services.Count -gt 0) { $d.Services | Format-Table -AutoSize | Out-Host } else { Write-Host 'Aucun service recupere.' }
    Write-Host "`n--- Evenements recents ---" -ForegroundColor Cyan
    if ($d.EventCount -gt 0) { $d.Events | Select-Object -First $Top TimeCreated,EventId,Level,Message | Format-Table -Wrap | Out-Host } else { Write-Host 'Aucun evenement recupere sur la periode.' }
    if ($d.Warnings.Count -gt 0) {
        Write-Host "`n--- Avertissements ---" -ForegroundColor Yellow
        $d.Warnings | ForEach-Object { Write-Host "- $_" }
    }
    Write-Host "`n--- Pistes de verification ---" -ForegroundColor Cyan
    $d.Recommendations | ForEach-Object { Write-Host "- $_" }
}

function Export-WindowsUpdateDiagnostic {
    [CmdletBinding()]
    param(
        [ValidateRange(1,8760)][int]$Hours = 168,
        [ValidateRange(1,500)][int]$MaxEvents = 100,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Reports')
    )
    $d = Get-WindowsUpdateDiagnostic -Hours $Hours -MaxEvents $MaxEvents -ComputerName $ComputerName
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -Path $OutputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $file = Join-Path $OutputDirectory ('WindowsUpdate_{0}_{1}.csv' -f $d.ComputerName,(Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($d.EventCount -gt 0) {
        $d.Events | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8
    } else {
        'TimeCreated,EventId,Level,Message,RecordId' | Set-Content -LiteralPath $file -Encoding UTF8
    }
    Write-Host "Rapport CSV : $file" -ForegroundColor Green
    return $file
}
