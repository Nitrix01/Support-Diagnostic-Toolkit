# Support Diagnostic Toolkit - Menu principal V1 (lecture seule)
$servicePath = Join-Path $PSScriptRoot 'Modules\Services.ps1'
$systemPath  = Join-Path $PSScriptRoot 'Modules\SystemInfo.ps1'

foreach ($path in @($servicePath, $systemPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "Module introuvable : $path" -ForegroundColor Red
        return
    }
    try {
        . $path
    } catch {
        Write-Host "Echec du chargement de $path : $($_.Exception.Message)" -ForegroundColor Red
        return
    }
}

function Show-ServiceResults {
    param(
        [ValidateSet('All', 'Running', 'Stopped', 'AutomaticStopped')]
        [string]$Filter = 'All'
    )
    $services = @(Get-WindowsServiceInventory -Filter $Filter)
    Write-Host "`nServices trouves : $($services.Count)" -ForegroundColor Cyan
    if ($services.Count -gt 0) {
        $services | Format-Table Name, DisplayName, State, StartMode, ProcessId -AutoSize | Out-Host
    } else {
        Write-Host 'Aucun service ne correspond au filtre.' -ForegroundColor Yellow
    }
}

$quit = $false
while (-not $quit) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host '       SUPPORT DIAGNOSTIC TOOLKIT' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '[1] Afficher tous les services'
    Write-Host '[2] Services en cours d execution'
    Write-Host '[3] Services arretes'
    Write-Host '[4] Services automatiques arretes'
    Write-Host '[5] Exporter les services en CSV'
    Write-Host '[6] Informations systeme (PC local)'
    Write-Host '[0] Quitter'

    $choice = Read-Host 'Choisissez une option'
    try {
        switch ($choice) {
            '1' { Show-ServiceResults -Filter All }
            '2' { Show-ServiceResults -Filter Running }
            '3' { Show-ServiceResults -Filter Stopped }
            '4' { Show-ServiceResults -Filter AutomaticStopped }
            '5' {
                $file = Export-WindowsServiceInventory -Filter All
                if ($file) { Write-Host "`nRapport CSV cree : $file" -ForegroundColor Green }
            }
            '6' { Show-SystemInfo }
            '0' {
                $quit = $true
                Write-Host 'Fermeture du programme.' -ForegroundColor Cyan
            }
            default { Write-Host 'Choix invalide. Reessayez.' -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "Erreur pendant le diagnostic : $($_.Exception.Message)" -ForegroundColor Red
    }
    if (-not $quit) { $null = Read-Host 'Appuyez sur Entree pour revenir au menu' }
}
