# Support Diagnostic Toolkit - Report V1.1
# Windows PowerShell 5.1 / PowerShell 7. Local read-only diagnostics.
# Requires modules/SystemInfo.ps1 and modules/Storage.ps1.

function ConvertTo-SDTHtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-SDTProperty {
    param([AllowNull()][object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function ConvertTo-SDTReadableText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '-' }
    if ($Value -is [datetime]) { return $Value.ToString('dd/MM/yyyy HH:mm:ss') }
    if ($Value -is [bool]) { if ($Value) { return 'Oui' } else { return 'Non' } }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    return '[Donnees detaillees disponibles dans le JSON]'
}

function New-SDTKeyValueTable {
    param([AllowNull()][object]$Object, [string[]]$Properties)
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('<table class="details"><tbody>')
    foreach ($name in $Properties) {
        $value = Get-SDTProperty -Object $Object -Name $name
        if ($null -eq $value) { continue }
        $display = ConvertTo-SDTReadableText $value
        [void]$builder.AppendLine(('<tr><th scope="row">{0}</th><td>{1}</td></tr>' -f (ConvertTo-SDTHtmlText $name), (ConvertTo-SDTHtmlText $display)))
    }
    [void]$builder.AppendLine('</tbody></table>')
    return $builder.ToString()
}

function New-SDTStorageTable {
    param([object[]]$Volumes)
    if ($Volumes.Count -eq 0) { return '<p>Aucun volume retourne.</p>' }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('<div class="table-scroll"><table><thead><tr><th>Lecteur</th><th>Nom</th><th>Capacite (Gio)</th><th>Libre (Gio)</th><th>Utilise (%)</th><th>Statut du module</th></tr></thead><tbody>')
    foreach ($volume in $Volumes) {
        $fields = @('Drive','VolumeName','SizeGB','FreeGB','UsedPercent','Status')
        $cells = foreach ($field in $fields) {
            $value = Get-SDTProperty $volume $field
            '<td>{0}</td>' -f (ConvertTo-SDTHtmlText (ConvertTo-SDTReadableText $value))
        }
        [void]$builder.AppendLine(('<tr>{0}</tr>' -f ($cells -join '')))
    }
    [void]$builder.AppendLine('</tbody></table></div>')
    return $builder.ToString()
}

function New-SDTEventTable {
    param([object[]]$Events, [int]$MaxEvents = 10)
    if ($Events.Count -eq 0) { return '<p>Aucun evenement retourne.</p>' }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine(('<p class="muted">{0} evenement(s) collecte(s). Affichage des {1} premiers ; le JSON conserve la collecte complete.</p>' -f $Events.Count, [Math]::Min($Events.Count, $MaxEvents)))
    [void]$builder.AppendLine('<div class="table-scroll"><table><thead><tr><th>Date</th><th>ID</th><th>Niveau</th><th>Source</th><th>Message (extrait)</th></tr></thead><tbody>')
    foreach ($evt in @($Events | Select-Object -First $MaxEvents)) {
        $date = ConvertTo-SDTReadableText (Get-SDTProperty $evt 'TimeCreated')
        $id = ConvertTo-SDTReadableText (Get-SDTProperty $evt 'Id')
        $level = ConvertTo-SDTReadableText (Get-SDTProperty $evt 'LevelDisplayName')
        $provider = ConvertTo-SDTReadableText (Get-SDTProperty $evt 'ProviderName')
        $message = ConvertTo-SDTReadableText (Get-SDTProperty $evt 'Message')
        if ($message.Length -gt 240) { $message = $message.Substring(0,240) + '...' }
        $values = @($date,$id,$level,$provider,$message)
        $cells = foreach ($value in $values) { '<td>{0}</td>' -f (ConvertTo-SDTHtmlText $value) }
        [void]$builder.AppendLine(('<tr>{0}</tr>' -f ($cells -join '')))
    }
    [void]$builder.AppendLine('</tbody></table></div>')
    return $builder.ToString()
}

function New-SDTLocalReport {
    [CmdletBinding()]
    param(
        [string]$OutputDirectory = (Join-Path $PSScriptRoot 'reports'),
        [switch]$OpenHtml
    )

    $modules = @(
        @{ Path = (Join-Path $PSScriptRoot 'modules\SystemInfo.ps1'); Command = 'Get-SystemInfo' },
        @{ Path = (Join-Path $PSScriptRoot 'modules\Storage.ps1'); Command = 'Get-StorageDiagnostic' }
    )
    foreach ($module in $modules) {
        if (-not (Test-Path -LiteralPath $module.Path -PathType Leaf)) { throw "Module introuvable : $($module.Path)" }
        . $module.Path
        if (-not (Get-Command -Name $module.Command -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Fonction introuvable : $($module.Command)"
        }
    }

    $results = [ordered]@{}
    foreach ($diagnostic in @(
        @{ Name = 'SystemInfo'; Command = 'Get-SystemInfo' },
        @{ Name = 'Storage'; Command = 'Get-StorageDiagnostic' }
    )) {
        try {
            $data = @(& $diagnostic.Command -ErrorAction Stop)
            $results[$diagnostic.Name] = [ordered]@{ Status = 'Executed'; Data = $data; Error = $null }
        } catch {
            $results[$diagnostic.Name] = [ordered]@{ Status = 'Failed'; Data = @(); Error = $_.Exception.Message }
        }
    }

    $now = Get-Date
    $computerName = $env:COMPUTERNAME
    $safeName = $computerName -replace '[^a-zA-Z0-9._-]', '_'
    $runName = $now.ToString('yyyy-MM-dd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $runFolder = Join-Path (Join-Path $OutputDirectory $safeName) $runName
    New-Item -ItemType Directory -Path $runFolder -Force -ErrorAction Stop | Out-Null

    $report = [ordered]@{
        SchemaVersion = '1.1'
        Tool = 'Support Diagnostic Toolkit'
        Mode = 'Local'
        ComputerName = $computerName
        CollectedAt = $now.ToString('o')
        Diagnostics = $results
    }
    $jsonPath = Join-Path $runFolder 'diagnostic.json'
    $htmlPath = Join-Path $runFolder 'diagnostic.html'
    $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $jsonPath -Encoding UTF8 -ErrorAction Stop

    $sysEntry = $results['SystemInfo']
    $storageEntry = $results['Storage']
    $sys = if ($sysEntry.Status -eq 'Executed' -and $sysEntry.Data.Count -gt 0) { $sysEntry.Data[0] } else { $null }
    $storage = if ($storageEntry.Status -eq 'Executed' -and $storageEntry.Data.Count -gt 0) { $storageEntry.Data[0] } else { $null }

    $sysStatus = if ($sysEntry.Status -eq 'Executed') { 'Execute' } else { 'Echec' }
    $storageStatus = if ($storageEntry.Status -eq 'Executed') { 'Execute' } else { 'Echec' }
    $sysClass = if ($sysEntry.Status -eq 'Executed') { 'ok' } else { 'error' }
    $storageClass = if ($storageEntry.Status -eq 'Executed') { 'ok' } else { 'error' }
    $sysHtml = if ($null -ne $sys) {
        New-SDTKeyValueTable -Object $sys -Properties @('ComputerName','Manufacturer','Model','WindowsName','WindowsVersion','WindowsBuild','Architecture','Processor','PhysicalCores','LogicalProcessors','TotalRAM_GB','AvailableRAM_GB','UsedRAM_GB','RAMUsedPercent','LastBootTime','Uptime','CollectedAt')
    } elseif ($sysEntry.Status -eq 'Failed') {
        '<p class="error-text">{0}</p>' -f (ConvertTo-SDTHtmlText $sysEntry.Error)
    } else { '<p>Aucune donnee systeme retournee.</p>' }

    $storageHtml = ''
    if ($null -ne $storage) {
        $volumes = @(Get-SDTProperty $storage 'Volumes' | Where-Object { $null -ne $_ })
        $events = @(Get-SDTProperty $storage 'StorageEvents' | Where-Object { $null -ne $_ })
        $recommendations = @(Get-SDTProperty $storage 'Recommendations' | Where-Object { $null -ne $_ })
        $eventError = Get-SDTProperty $storage 'EventCollectionError'
        $storageHtml += '<h3>Volumes</h3>' + (New-SDTStorageTable -Volumes $volumes)
        if ($recommendations.Count -gt 0) {
            $storageHtml += '<h3>Recommandations du module</h3><ul>'
            foreach ($recommendation in $recommendations) {
                $storageHtml += '<li>' + (ConvertTo-SDTHtmlText $recommendation) + '</li>'
            }
            $storageHtml += '</ul>'
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$eventError)) {
            $storageHtml += '<p class="error-text">Collecte des evenements : ' + (ConvertTo-SDTHtmlText $eventError) + '</p>'
        }
        $storageHtml += '<details><summary>Evenements collectes (details)</summary>' + (New-SDTEventTable -Events $events -MaxEvents 10) + '</details>'
    } elseif ($storageEntry.Status -eq 'Failed') {
        $storageHtml = '<p class="error-text">{0}</p>' -f (ConvertTo-SDTHtmlText $storageEntry.Error)
    } else { $storageHtml = '<p>Aucune donnee de stockage retournee.</p>' }

    $summary = [System.Text.StringBuilder]::new()
    if ($null -ne $sys) {
        $ram = Get-SDTProperty $sys 'RAMUsedPercent'
        if ($null -ne $ram) {
            [void]$summary.AppendLine(('<div class="metric"><span>RAM utilisee</span><strong>{0} %</strong></div>' -f (ConvertTo-SDTHtmlText $ram)))
        }
    }
    if ($null -ne $storage) {
        foreach ($volume in @(Get-SDTProperty $storage 'Volumes')) {
            if ($null -eq $volume) { continue }
            $drive = Get-SDTProperty $volume 'Drive'
            $free = Get-SDTProperty $volume 'FreeGB'
            $used = Get-SDTProperty $volume 'UsedPercent'
            $status = Get-SDTProperty $volume 'Status'
            [void]$summary.AppendLine(('<div class="metric"><span>Disque {0} : {1} Gio libres</span><strong>{2} % utilises</strong><small>Statut du module : {3}</small></div>' -f (ConvertTo-SDTHtmlText $drive), (ConvertTo-SDTHtmlText $free), (ConvertTo-SDTHtmlText $used), (ConvertTo-SDTHtmlText $status)))
        }
    }
    if ($summary.Length -eq 0) { [void]$summary.AppendLine('<p>Aucune mesure de synthese disponible.</p>') }

    $html = @"
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rapport SDT - $(ConvertTo-SDTHtmlText $computerName)</title>
<style>
*{box-sizing:border-box}body{font-family:Segoe UI,Arial,sans-serif;background:#f3f5f9;color:#1e293b;margin:0;padding:28px;line-height:1.5}
main{max-width:1060px;margin:auto}header,section{background:white;padding:24px;margin:0 0 18px;border:1px solid #e2e8f0;border-radius:12px}
h1{font-size:26px;margin:0 0 5px}h2{font-size:20px;margin:0 0 14px}h3{font-size:16px;margin:20px 0 10px}
.muted,small{color:#64748b}.meta{margin:10px 0 0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
.metric{padding:14px;border:1px solid #e2e8f0;border-radius:9px;background:#fafbfe;display:flex;flex-direction:column;gap:4px}.metric strong{font-size:20px}
.pill{display:inline-block;font-size:12px;padding:3px 10px;border-radius:20px;margin-left:8px}.ok{background:#e0f2fe;color:#075985}.error{background:#fee2e2;color:#991b1b}.error-text{color:#991b1b}
table{width:100%;border-collapse:collapse;margin:10px 0 18px}th,td{border-bottom:1px solid #e2e8f0;padding:10px 12px;text-align:left;vertical-align:top;overflow-wrap:anywhere}
thead th{background:#f1f5f9;font-weight:600}.details th{width:32%;background:#f8fafc}.table-scroll{overflow-x:auto}details{border-top:1px solid #e2e8f0;padding-top:12px;margin-top:20px}
summary{cursor:pointer;font-weight:600}li{margin:5px 0}footer{font-size:12px;color:#64748b;padding:8px 4px}
@media print{body{padding:0;background:white}header,section{box-shadow:none;break-inside:avoid}details:not([open]){display:none}main{max-width:none}}
</style>
</head>
<body><main>
<header>
<h1>Support Diagnostic Toolkit</h1>
<p class="muted">Rapport de diagnostic local - version 1.1</p>
<p class="meta"><strong>Ordinateur :</strong> $(ConvertTo-SDTHtmlText $computerName) &nbsp; <strong>Date :</strong> $(ConvertTo-SDTHtmlText ($now.ToString('dd/MM/yyyy HH:mm:ss')))</p>
<p class="muted">Le statut "Execute" confirme uniquement l'execution du module, pas la bonne sante du PC.</p>
</header>
<section><h2>Synthese des mesures</h2><div class="grid">$($summary.ToString())</div></section>
<section><h2>Informations systeme <span class="pill $sysClass">$sysStatus</span></h2>$sysHtml</section>
<section><h2>Stockage <span class="pill $storageClass">$storageStatus</span></h2>$storageHtml</section>
<footer>Rapport genere en lecture seule. Les informations detaillees et les evenements collectes sont conserves dans diagnostic.json. Verifier les donnees sensibles avant tout partage.</footer>
</main></body></html>
"@
    # Write UTF-8 with BOM for consistent rendering in Windows PowerShell 5.1 and PowerShell 7.
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($htmlPath, $html, $utf8Bom)
    if ($OpenHtml) { Invoke-Item -LiteralPath $htmlPath }

    [pscustomobject]@{
        ComputerName = $computerName
        Folder = $runFolder
        HtmlPath = $htmlPath
        JsonPath = $jsonPath
        SystemInfo = $sysEntry.Status
        Storage = $storageEntry.Status
    }
}
