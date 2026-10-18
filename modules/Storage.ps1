# Support Diagnostic Toolkit - Storage inventory (read-only)
# Compatible with Windows PowerShell 5.1 and PowerShell 7 on Windows.

function Assert-LocalStorageComputer {
    param([string]$ComputerName)
    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        throw "Le nom de l'ordinateur ne peut pas etre vide."
    }
    if ($ComputerName -notin @('.', 'localhost', $env:COMPUTERNAME)) {
        throw "Mode distant non disponible dans cette version : $ComputerName."
    }
}

function Get-StorageInventory {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1,99)][int]$WarningPercent = 80,
        [ValidateRange(2,100)][int]$CriticalPercent = 90
    )

    Assert-LocalStorageComputer -ComputerName $ComputerName
    if ($CriticalPercent -le $WarningPercent) {
        throw 'CriticalPercent doit etre superieur a WarningPercent.'
    }

    # DriveType=3 means local disks; size and free space are returned in bytes.
    $volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop)

    # Physical media detection is best effort: it can be unavailable for USB,
    # RAID, virtual machines or some storage controllers.
    $physicalDisks = @()
    try {
        $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop)
    } catch {
        Write-Verbose "Informations sur les supports physiques indisponibles : $($_.Exception.Message)"
    }

    foreach ($volume in $volumes) {
        $sizeBytes = [double]$volume.Size
        $freeBytes = [double]$volume.FreeSpace
        $usedBytes = [math]::Max(0.0, ($sizeBytes - $freeBytes))
        $usedPercent = if ($sizeBytes -gt 0) {
            [math]::Round(($usedBytes / $sizeBytes) * 100, 1)
        } else { $null }

        $status = if ($null -eq $usedPercent) { 'Inconnu' }
                  elseif ($usedPercent -ge $CriticalPercent) { 'Critique' }
                  elseif ($usedPercent -ge $WarningPercent) { 'Attention' }
                  else { 'Normal' }

        # Do not guess a drive-letter-to-physical-disk mapping. A system may
        # have multiple partitions, Storage Spaces, or several physical disks.
        $mediaType = 'Indetermine'
        if ($physicalDisks.Count -eq 1 -and $volumes.Count -eq 1) {
            $candidate = [string]$physicalDisks[0].MediaType
            if ($candidate -in @('SSD', 'HDD', 'SCM')) { $mediaType = $candidate }
        }

        [PSCustomObject]@{
            ComputerName    = $env:COMPUTERNAME
            Drive           = $volume.DeviceID
            VolumeName      = $volume.VolumeName
            FileSystem      = $volume.FileSystem
            SizeGB          = [math]::Round($sizeBytes / 1GB, 2)
            UsedGB          = [math]::Round($usedBytes / 1GB, 2)
            FreeGB          = [math]::Round($freeBytes / 1GB, 2)
            UsedPercent     = $usedPercent
            Status          = $status
            MediaType       = $mediaType
            CollectedAt     = Get-Date
        }
    }
}

function Show-StorageInventory {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1,99)][int]$WarningPercent = 80,
        [ValidateRange(2,100)][int]$CriticalPercent = 90
    )

    $inventory = @(Get-StorageInventory -ComputerName $ComputerName -WarningPercent $WarningPercent -CriticalPercent $CriticalPercent)
    Write-Host "`n===== DIAGNOSTIC DU STOCKAGE =====" -ForegroundColor Cyan
    if ($inventory.Count -eq 0) {
        Write-Host 'Aucun lecteur local detecte.' -ForegroundColor Yellow
        return
    }
    $inventory | Format-Table Drive, VolumeName, FileSystem, SizeGB, UsedGB, FreeGB, UsedPercent, Status, MediaType -AutoSize | Out-Host
    Write-Host 'Note : Indetermine signifie que le type de support ne peut pas etre attribue avec certitude.' -ForegroundColor DarkGray
}

function Export-StorageInventory {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Reports'),
        [ValidateRange(1,99)][int]$WarningPercent = 80,
        [ValidateRange(2,100)][int]$CriticalPercent = 90
    )

    $inventory = @(Get-StorageInventory -ComputerName $ComputerName -WarningPercent $WarningPercent -CriticalPercent $CriticalPercent)
    if ($inventory.Count -eq 0) {
        Write-Warning 'Aucun lecteur a exporter.'
        return
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
    }
    $filename = 'Storage_{0}_{1}.csv' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss')
    $path = Join-Path $OutputDirectory $filename
    $inventory | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    Write-Host "Rapport CSV cree : $path" -ForegroundColor Green
    return $path
}

# Diagnostic complementaire : alertes de capacite et evenements de stockage.
# Les evenements sont au niveau du PC et ne sont pas attribues a un lecteur
# sans verification du message et de la configuration du stockage.
function Get-StorageDiagnostic {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1,99)][int]$WarningPercent = 80,
        [ValidateRange(2,100)][int]$CriticalPercent = 90,
        [ValidateRange(1,30)][int]$LookbackDays = 7
    )
    Assert-LocalStorageComputer -ComputerName $ComputerName
    $volumes = @(Get-StorageInventory -ComputerName $ComputerName -WarningPercent $WarningPercent -CriticalPercent $CriticalPercent)
    $recommendations = foreach ($volume in $volumes) {
        if ($volume.Status -eq 'Critique') {
            "[$($volume.Drive)] Espace critique ($($volume.FreeGB) Gio libres). Verifier les fichiers volumineux, temporaires et besoins applicatifs avant tout nettoyage."
        } elseif ($volume.Status -eq 'Attention') {
            "[$($volume.Drive)] Espace a surveiller ($($volume.FreeGB) Gio libres). Examiner l'evolution de l'occupation."
        }
    }
    $events = @()
    $eventError = $null
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Id = @(7,51,55,129,153,157)
            StartTime = (Get-Date).AddDays(-$LookbackDays)
        } -MaxEvents 100 -ErrorAction Stop | Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message)
    } catch {
        # Get-WinEvent peut signaler l'absence d'evenements correspondants.
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            $eventError = $_.Exception.Message
        }
    }
    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        Volumes = $volumes
        StorageEvents = $events
        EventCollectionError = $eventError
        Recommendations = @($recommendations)
        CollectedAt = Get-Date
    }
}

function Show-StorageDiagnostic {
    [CmdletBinding()]
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateRange(1,99)][int]$WarningPercent = 80,
        [ValidateRange(2,100)][int]$CriticalPercent = 90,
        [ValidateRange(1,30)][int]$LookbackDays = 7
    )
    $result = Get-StorageDiagnostic -ComputerName $ComputerName -WarningPercent $WarningPercent -CriticalPercent $CriticalPercent -LookbackDays $LookbackDays
    Write-Host "`n===== DIAGNOSTIC DU STOCKAGE =====" -ForegroundColor Cyan
    $result.Volumes | Format-Table Drive, VolumeName, SizeGB, FreeGB, UsedPercent, Status -AutoSize | Out-Host
    Write-Host "`nEvenements de stockage potentiellement pertinents (derniers $LookbackDays jours) : $(@($result.StorageEvents).Count)"
    if ($result.EventCollectionError) { Write-Warning "Lecture des evenements incomplete : $($result.EventCollectionError)" }
    if (@($result.StorageEvents).Count -gt 0) {
        $result.StorageEvents | Select-Object TimeCreated, Id, ProviderName, LevelDisplayName | Format-Table -AutoSize | Out-Host
        Write-Host 'Ces evenements doivent etre examines : ils ne prouvent pas a eux seuls une panne de disque.' -ForegroundColor Yellow
    }
    Write-Host "`nPistes de verification :" -ForegroundColor Cyan
    if (@($result.Recommendations).Count -eq 0) { Write-Host 'Aucune alerte de capacite selon les seuils choisis.' }
    else { $result.Recommendations | ForEach-Object { Write-Host "- $_" } }
}
