# Support Diagnostic Toolkit - Menu principal V2
# Diagnostics locaux et distants (WinRM). Aucune action corrective automatique.

$moduleDirectory = Join-Path $PSScriptRoot 'Modules'
$remotePath = Join-Path $PSScriptRoot 'Remote.ps1'
$moduleFiles = [ordered]@{
    SystemInfo    = 'SystemInfo.ps1'
    Services      = 'Services.ps1'
    Storage       = 'Storage.ps1'
    Network       = 'Network.ps1'
    Performance   = 'Performance.ps1'
    EventLogs     = 'EventLogs.ps1'
    WindowsUpdate = 'WindowsUpdate.ps1'
}
$diagnosticFunctions = @{
    SystemInfo    = 'Get-SystemInfo'
    Services      = 'Get-WindowsServiceDiagnostic'
    Storage       = 'Get-StorageDiagnostic'
    Network       = 'Get-NetworkDiagnostic'
    Performance   = 'Get-PerformanceDiagnostic'
    EventLogs     = 'Get-EventLogDiagnostic'
    WindowsUpdate = 'Get-WindowsUpdateDiagnostic'
}

# Charger les fonctions locales dans la portee du script principal.
# Les fichiers manquants seront signales lors du choix du diagnostic concerne.
foreach ($entry in $moduleFiles.GetEnumerator()) {
    $path = Join-Path $moduleDirectory $entry.Value
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { . $path }
        catch { Write-Host "Echec du chargement de $path : $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

function Assert-SDTLocalModule {
    param([Parameter(Mandatory)][string]$Module)
    $path = Join-Path $moduleDirectory $moduleFiles[$Module]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Module introuvable : $path"
    }
}

function Show-SDTResult {
    param([object[]]$Result)
    if ($null -eq $Result -or @($Result).Count -eq 0) {
        Write-Host 'Aucun resultat retourne.' -ForegroundColor Yellow
        return
    }
    $Result | Format-List * | Out-Host
}

function Show-SDTServiceResults {
    param(
        [ValidateSet('All','Running','Stopped','AutomaticStopped')]
        [string]$Filter = 'All'
    )
    Assert-SDTLocalModule -Module Services
    $services = @(Get-WindowsServiceInventory -Filter $Filter)
    Write-Host "`nServices trouves : $($services.Count)" -ForegroundColor Cyan
    if ($services.Count -gt 0) {
        $services | Format-Table Name,DisplayName,State,StartMode,ProcessId -AutoSize | Out-Host
    } else {
        Write-Host 'Aucun service ne correspond au filtre.' -ForegroundColor Yellow
    }
}

function Show-SDTLegacyServiceMenu {
    $back = $false
    while (-not $back) {
        Write-Host "`n--- Inventaire des services (local) ---" -ForegroundColor Cyan
        Write-Host '[1] Tous les services'
        Write-Host '[2] Services en cours d execution'
        Write-Host '[3] Services arretes'
        Write-Host '[4] Services automatiques arretes'
        Write-Host '[5] Exporter les services en CSV'
        Write-Host '[0] Retour'
        $choice = Read-Host 'Votre choix'
        try {
            switch ($choice) {
                '1' { Show-SDTServiceResults -Filter All }
                '2' { Show-SDTServiceResults -Filter Running }
                '3' { Show-SDTServiceResults -Filter Stopped }
                '4' { Show-SDTServiceResults -Filter AutomaticStopped }
                '5' {
                    Assert-SDTLocalModule -Module Services
                    $file = Export-WindowsServiceInventory -Filter All
                    if ($file) { Write-Host "Rapport CSV cree : $file" -ForegroundColor Green }
                }
                '0' { $back = $true }
                default { Write-Host 'Choix invalide.' -ForegroundColor Yellow }
            }
        } catch {
            Write-Host "Erreur : $($_.Exception.Message)" -ForegroundColor Red
        }
        if (-not $back) { $null = Read-Host 'Appuyez sur Entree pour continuer' }
    }
}

function Invoke-SDTLocalMenuDiagnostic {
    param([Parameter(Mandatory)][string]$Module)
    Assert-SDTLocalModule -Module $Module
    $functionName = $diagnosticFunctions[$Module]
    $command = Get-Command -Name $functionName -CommandType Function -ErrorAction Stop
    $params = @{}
    if ($Module -in @('Services','EventLogs','WindowsUpdate') -and $command.Parameters.ContainsKey('Hours')) {
        $params.Hours = 24
    }
    $result = & $functionName @params
    Show-SDTResult -Result @($result)
}

function Show-SDTDiagnosticMenu {
    param(
        [Parameter(Mandatory)][ValidateSet('Local','Remote')][string]$Mode,
        [string]$ComputerName,
        [pscredential]$Credential
    )
    $options = @{
        '1' = 'SystemInfo'
        '2' = 'Services'
        '3' = 'Storage'
        '4' = 'Network'
        '5' = 'Performance'
        '6' = 'EventLogs'
        '7' = 'WindowsUpdate'
    }
    $back = $false
    while (-not $back) {
        Write-Host "`n--- Diagnostics $Mode ---" -ForegroundColor Cyan
        if ($Mode -eq 'Remote') { Write-Host "Cible : $ComputerName" -ForegroundColor Cyan }
        Write-Host '[1] Informations systeme'
        Write-Host '[2] Diagnostic des services'
        Write-Host '[3] Diagnostic du stockage'
        Write-Host '[4] Diagnostic reseau'
        Write-Host '[5] Diagnostic des performances'
        Write-Host '[6] Journaux d evenements'
        Write-Host '[7] Windows Update'
        if ($Mode -eq 'Local') { Write-Host '[8] Inventaire / export des services (menu V1)' }
        Write-Host '[0] Retour'
        $choice = Read-Host 'Votre choix'
        if ($choice -eq '0') { $back = $true; continue }
        if ($Mode -eq 'Local' -and $choice -eq '8') {
            Show-SDTLegacyServiceMenu
            continue
        }
        if (-not $options.ContainsKey($choice)) {
            Write-Host 'Choix invalide.' -ForegroundColor Yellow
            continue
        }
        $module = $options[$choice]
        try {
            if ($Mode -eq 'Local') {
                Invoke-SDTLocalMenuDiagnostic -Module $module
            } else {
                $args = @{ ComputerName = $ComputerName; Module = $module; ErrorAction = 'Stop' }
                if ($null -ne $Credential) { $args.Credential = $Credential }
                $result = Invoke-SDTDiagnostic @args
                Show-SDTResult -Result @($result)
            }
        } catch {
            Write-Host "Erreur du diagnostic $module : $($_.Exception.Message)" -ForegroundColor Red
        }
        $null = Read-Host 'Appuyez sur Entree pour continuer'
    }
}

function Start-SDTRemoteMenu {
    if (-not (Test-Path -LiteralPath $remotePath -PathType Leaf)) {
        Write-Host "Remote.ps1 introuvable : $remotePath" -ForegroundColor Red
        return
    }
    try { . $remotePath } catch {
        Write-Host "Chargement de Remote.ps1 impossible : $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $target = (Read-Host 'Nom ou adresse IP du PC cible').Trim()
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host 'Aucune cible indiquee.' -ForegroundColor Yellow
        return
    }
    $credential = $null
    $askCredential = Read-Host 'Utiliser des identifiants distants ? (O/n)'
    if ($askCredential -notmatch '^(n|non)$') {
        $credential = Get-Credential -Message "Identifiants pour $target"
        if ($null -eq $credential) { Write-Host 'Authentification annulee.'; return }
    }
    $testArgs = @{ ComputerName = $target }
    if ($null -ne $credential) { $testArgs.Credential = $credential }
    try {
        $test = Test-SDTConnection @testArgs
        if (-not $test.Reachable) {
            Write-Host "Connexion impossible : $($test.Message)" -ForegroundColor Red
            return
        }
        Write-Host "Connexion distante validee : $target" -ForegroundColor Green
        Show-SDTDiagnosticMenu -Mode Remote -ComputerName $target -Credential $credential
    } catch {
        Write-Host "Erreur de connexion : $($_.Exception.Message)" -ForegroundColor Red
    }
}

$quit = $false
while (-not $quit) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host '       SUPPORT DIAGNOSTIC TOOLKIT' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '[1] Diagnostic local'
    Write-Host '[2] Diagnostic distant (WinRM)'
    Write-Host '[0] Quitter'
    $choice = Read-Host 'Choisissez une option'
    switch ($choice) {
        '1' { Show-SDTDiagnosticMenu -Mode Local }
        '2' { Start-SDTRemoteMenu }
        '0' { $quit = $true; Write-Host 'Fermeture du programme.' -ForegroundColor Cyan }
        default { Write-Host 'Choix invalide. Reessayez.' -ForegroundColor Yellow }
    }
}
