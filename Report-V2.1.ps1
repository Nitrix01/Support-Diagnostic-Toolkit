# Support Diagnostic Toolkit - Report V2
# Windows PowerShell 5.1 / PowerShell 7 (Windows). Read-only collection.
# Place at project root, alongside Remote.ps1 and modules/.

function ConvertTo-SDTReportHtml {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-SDTReportProperty {
    param([AllowNull()][object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function ConvertTo-SDTReportValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '-' }
    if ($Value -is [datetime]) { return $Value.ToString('dd/MM/yyyy HH:mm:ss') }
    if ($Value -is [bool]) { if ($Value) { return 'Oui' }; return 'Non' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    if ($Value -is [array]) { return "{0} element(s)" -f $Value.Count }
    return '[Objet detaille ci-dessous]'
}

function New-SDTReportTable {
    param([object[]]$Rows, [int]$MaxRows = 12)
    $items = @($Rows | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return '<p class="muted">Aucune donnee retournee.</p>' }
    $first = $items[0]
    if ($first -is [string] -or $first -is [ValueType]) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('<ul>')
        foreach ($item in @($items | Select-Object -First $MaxRows)) {
            [void]$sb.AppendLine('<li>' + (ConvertTo-SDTReportHtml (ConvertTo-SDTReportValue $item)) + '</li>')
        }
        [void]$sb.AppendLine('</ul>')
        if ($items.Count -gt $MaxRows) { [void]$sb.AppendLine('<p class="muted">Liste limitee dans le HTML ; voir le JSON.</p>') }
        return $sb.ToString()
    }
    $columns = @($first.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty','Property','AliasProperty','ScriptProperty') } | Select-Object -ExpandProperty Name)
    if ($first -is [System.Collections.IDictionary]) { $columns = @($first.Keys) }
    if ($columns.Count -eq 0) { return '<p class="muted">Objet non tabulaire ; voir le JSON.</p>' }
    # Avoid excessively wide tables and nested objects.
    $columns = @($columns | Select-Object -First 8)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<div class="table-scroll"><table><thead><tr>')
    foreach ($col in $columns) { [void]$sb.AppendLine('<th>' + (ConvertTo-SDTReportHtml $col) + '</th>') }
    [void]$sb.AppendLine('</tr></thead><tbody>')
    foreach ($item in @($items | Select-Object -First $MaxRows)) {
        [void]$sb.AppendLine('<tr>')
        foreach ($col in $columns) {
            $value = Get-SDTReportProperty $item $col
            $display = ConvertTo-SDTReportValue $value
            if ($display.Length -gt 220) { $display = $display.Substring(0,220) + '...' }
            [void]$sb.AppendLine('<td>' + (ConvertTo-SDTReportHtml $display) + '</td>')
        }
        [void]$sb.AppendLine('</tr>')
    }
    [void]$sb.AppendLine('</tbody></table></div>')
    if ($items.Count -gt $MaxRows) {
        [void]$sb.AppendLine(('<p class="muted">{0} elements collectes ; {1} affiches. Donnees completes dans le JSON.</p>' -f $items.Count,$MaxRows))
    }
    return $sb.ToString()
}

function New-SDTReportModuleHtml {
    param([string]$Name, [object]$Entry)
    $title = @{
        SystemInfo='Informations systeme'; Services='Services Windows'; Storage='Stockage';
        Network='Reseau'; Performance='Performances'; EventLogs='Journaux Windows';
        WindowsUpdate='Windows Update'
    }[$Name]
    $status = Get-SDTReportProperty $Entry 'Status'
    $class = if ($status -eq 'Executed') { 'ok' } else { 'error' }
    $label = if ($status -eq 'Executed') { 'Execute' } else { 'Echec' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine(('<section><h2>{0} <span class="pill {1}">{2}</span></h2>' -f (ConvertTo-SDTReportHtml $title),$class,$label))
    if ($status -ne 'Executed') {
        [void]$sb.AppendLine('<p class="error-text">' + (ConvertTo-SDTReportHtml (Get-SDTReportProperty $Entry 'Error')) + '</p></section>')
        return $sb.ToString()
    }
    $data = @(Get-SDTReportProperty $Entry 'Data')
    if ($data.Count -eq 0) { [void]$sb.AppendLine('<p class="muted">Aucun objet retourne.</p></section>'); return $sb.ToString() }
    $obj = $data[0]
    $names = @($obj.PSObject.Properties | Select-Object -ExpandProperty Name)
    $simple = [ordered]@{}
    $nested = [ordered]@{}
    foreach ($name in $names) {
        # Remoting adds PSComputerName, RunspaceId and PSShowComputerName; not useful here.
        if ($name -in @('PSComputerName','RunspaceId','PSShowComputerName')) { continue }
        $value = Get-SDTReportProperty $obj $name
        if ($null -eq $value -or $value -is [string] -or $value -is [ValueType]) {
            $simple[$name] = ConvertTo-SDTReportValue $value
        } else {
            $nested[$name] = $value
        }
    }
    if ($simple.Count -gt 0) {
        [void]$sb.AppendLine('<table class="details"><tbody>')
        foreach ($name in $simple.Keys) {
            [void]$sb.AppendLine(('<tr><th scope="row">{0}</th><td>{1}</td></tr>' -f (ConvertTo-SDTReportHtml $name),(ConvertTo-SDTReportHtml $simple[$name])))
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    # Promote short, actionable lists and inventory tables. Large event lists are collapsed.
    foreach ($name in $nested.Keys) {
        $value = $nested[$name]
        $rows = @($value | Where-Object { $null -ne $_ })
        if ($rows.Count -eq 0) { continue }
        $isLong = $name -match 'Event|Services|Findings|TopCPU|TopMemory|Interfaces|Volumes|GatewayTests|TopSources|FailedInstallation'
        $limit = if ($name -match 'Event') { 10 } elseif ($name -eq 'Services') { 20 } else { 12 }
        $content = '<h3>' + (ConvertTo-SDTReportHtml $name) + '</h3>' + (New-SDTReportTable -Rows $rows -MaxRows $limit)
        if ($isLong -and $name -match 'Event|Services') {
            [void]$sb.AppendLine('<details><summary>' + (ConvertTo-SDTReportHtml $name) + ' (' + $rows.Count + ')</summary>' + $content + '</details>')
        } else {
            [void]$sb.AppendLine($content)
        }
    }
    [void]$sb.AppendLine('</section>')
    return $sb.ToString()
}

function New-SDTReport {
    [CmdletBinding()]
    param(
        [ValidateSet('Local','Remote')][string]$Mode = 'Local',
        [string]$ComputerName,
        [pscredential]$Credential,
        [ValidateRange(1,168)][int]$Hours = 24,
        [string]$OutputDirectory = (Join-Path $PSScriptRoot 'reports'),
        [switch]$OpenHtml
    )
    $names = @('SystemInfo','Services','Storage','Network','Performance','EventLogs','WindowsUpdate')
    $commands = @{
        SystemInfo='Get-SystemInfo'; Services='Get-WindowsServiceDiagnostic';
        Storage='Get-StorageDiagnostic'; Network='Get-NetworkDiagnostic';
        Performance='Get-PerformanceDiagnostic'; EventLogs='Get-EventLogDiagnostic';
        WindowsUpdate='Get-WindowsUpdateDiagnostic'
    }
    if ($Mode -eq 'Remote') {
        if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw 'En mode Remote, -ComputerName est obligatoire.' }
        $remotePath = Join-Path $PSScriptRoot 'Remote.ps1'
        if (-not (Test-Path -LiteralPath $remotePath -PathType Leaf)) { throw "Remote.ps1 introuvable : $remotePath" }
        . $remotePath
        if (-not (Get-Command Invoke-SDTDiagnostic -CommandType Function -ErrorAction SilentlyContinue)) { throw 'Fonction Invoke-SDTDiagnostic introuvable.' }
        if (-not $PSBoundParameters.ContainsKey('Credential')) { $Credential = Get-Credential -Message "Identifiants du PC distant $ComputerName" }
        if ($null -eq $Credential) { throw 'Authentification distante annulee.' }
    } else {
        $ComputerName = $env:COMPUTERNAME
        foreach ($name in $names) {
            $path = Join-Path $PSScriptRoot (Join-Path 'modules' ($name + '.ps1'))
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Module introuvable : $path" }
            . $path
            if (-not (Get-Command $commands[$name] -CommandType Function -ErrorAction SilentlyContinue)) { throw "Fonction introuvable : $($commands[$name])" }
        }
    }
    $results = [ordered]@{}
    foreach ($name in $names) {
        Write-Host "Diagnostic $name ($Mode)..." -ForegroundColor Cyan
        try {
            if ($Mode -eq 'Remote') {
                $items = @(Invoke-SDTDiagnostic -ComputerName $ComputerName -Credential $Credential -Module $name -Hours $Hours -ErrorAction Stop)
            } else {
                $invokeParams = @{ ErrorAction = 'Stop' }
                if ($name -in @('Services','EventLogs','WindowsUpdate')) {
                    $command = Get-Command $commands[$name] -CommandType Function -ErrorAction Stop
                    if ($command.Parameters.ContainsKey('Hours')) { $invokeParams.Hours = $Hours }
                }
                $items = @(& $commands[$name] @invokeParams)
            }
            if ($items.Count -eq 0) { throw 'Le diagnostic n a retourne aucun objet.' }
            $results[$name] = [ordered]@{ Status='Executed'; Data=$items; Error=$null }
        } catch {
            $results[$name] = [ordered]@{ Status='Failed'; Data=@(); Error=$_.Exception.Message }
            Write-Warning "Echec $name : $($_.Exception.Message)"
        }
    }
    # Separate the connection target (IP/DNS) from the actual Windows computer name.
    $connectionTarget = $ComputerName
    $reportComputerName = $ComputerName
    $systemEntry = $results['SystemInfo']
    if ($systemEntry.Status -eq 'Executed' -and @($systemEntry.Data).Count -gt 0) {
        $detectedName = Get-SDTReportProperty $systemEntry.Data[0] 'ComputerName'
        if (-not [string]::IsNullOrWhiteSpace([string]$detectedName)) {
            $reportComputerName = ([string]$detectedName).Trim()
        }
    }
    $now = Get-Date
    $safeName = $reportComputerName -replace '[^a-zA-Z0-9._-]','_'
    $folderName = $now.ToString('yyyy-MM-dd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $folder = Join-Path (Join-Path $OutputDirectory $safeName) $folderName
    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
    $jsonPath = Join-Path $folder 'diagnostic.json'
    $htmlPath = Join-Path $folder 'diagnostic.html'
    $report = [ordered]@{
        SchemaVersion='2.0'; Tool='Support Diagnostic Toolkit'; Mode=$Mode
        ComputerName=$reportComputerName; ConnectionTarget=$connectionTarget; CollectedAt=$now.ToString('o'); Hours=$Hours; Diagnostics=$results
    }
    $json = ConvertTo-Json -InputObject $report -Depth 40
    $utf8 = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($jsonPath, $json, $utf8)

    $executed = @($names | Where-Object { $results[$_].Status -eq 'Executed' }).Count
    $failed = $names.Count - $executed
    $metrics = [System.Text.StringBuilder]::new()
    [void]$metrics.AppendLine(('<div class="metric"><span>Diagnostics executes</span><strong>{0} / 7</strong></div>' -f $executed))
    [void]$metrics.AppendLine(('<div class="metric"><span>Diagnostics en echec</span><strong>{0}</strong></div>' -f $failed))
    $sysEntry = $results['SystemInfo']
    if ($sysEntry.Status -eq 'Executed') {
        $sys = $sysEntry.Data[0]
        $ram = Get-SDTReportProperty $sys 'RAMUsedPercent'
        if ($null -ne $ram) { [void]$metrics.AppendLine(('<div class="metric"><span>RAM utilisee</span><strong>{0} %</strong></div>' -f (ConvertTo-SDTReportHtml $ram))) }
    }
    $storageEntry = $results['Storage']
    if ($storageEntry.Status -eq 'Executed') {
        $storage = $storageEntry.Data[0]
        foreach ($volume in @(Get-SDTReportProperty $storage 'Volumes')) {
            if ($null -eq $volume) { continue }
            $drive = Get-SDTReportProperty $volume 'Drive'
            $free = Get-SDTReportProperty $volume 'FreeGB'
            $used = Get-SDTReportProperty $volume 'UsedPercent'
            $state = Get-SDTReportProperty $volume 'Status'
            [void]$metrics.AppendLine(('<div class="metric"><span>Disque {0} : {1} Gio libres</span><strong>{2} % utilises</strong><small>Etat du volume : {3}</small></div>' -f (ConvertTo-SDTReportHtml $drive),(ConvertTo-SDTReportHtml $free),(ConvertTo-SDTReportHtml $used),(ConvertTo-SDTReportHtml $state)))
        }
    }
    $sections = [System.Text.StringBuilder]::new()
    foreach ($name in $names) { [void]$sections.AppendLine((New-SDTReportModuleHtml -Name $name -Entry $results[$name])) }
    $safeComputer = ConvertTo-SDTReportHtml $reportComputerName
    $safeMode = ConvertTo-SDTReportHtml $Mode
    $date = ConvertTo-SDTReportHtml $now.ToString('dd/MM/yyyy HH:mm:ss')
    $html = @"
<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Rapport SDT - $safeComputer</title>
<style>
*{box-sizing:border-box}body{font-family:Segoe UI,Arial,sans-serif;background:#f3f5f9;color:#1e293b;margin:0;padding:28px;line-height:1.5}
main{max-width:1100px;margin:auto}header,section{background:#fff;padding:24px;margin:0 0 18px;border:1px solid #e2e8f0;border-radius:12px}
h1{font-size:26px;margin:0 0 5px}h2{font-size:20px;margin:0 0 14px}h3{font-size:15px;margin:18px 0 9px}
.muted,small{color:#64748b}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(195px,1fr));gap:12px}
.metric{padding:14px;border:1px solid #e2e8f0;border-radius:9px;background:#fafbfe;display:flex;flex-direction:column;gap:4px}.metric strong{font-size:20px}
.pill{display:inline-block;font-size:12px;padding:3px 10px;border-radius:20px;margin-left:8px}.ok{background:#e0f2fe;color:#075985}.error{background:#fee2e2;color:#991b1b}.error-text{color:#991b1b}
table{width:100%;border-collapse:collapse;margin:10px 0 18px}th,td{border-bottom:1px solid #e2e8f0;padding:9px 11px;text-align:left;vertical-align:top;overflow-wrap:anywhere}
thead th{background:#f1f5f9}.details th{width:34%;background:#f8fafc}.table-scroll{overflow-x:auto}details{border-top:1px solid #e2e8f0;padding-top:12px;margin-top:16px}
summary{cursor:pointer;font-weight:600}footer{font-size:12px;color:#64748b;padding:8px 4px}
@media print{body{padding:0;background:#fff}header,section{break-inside:auto}details:not([open]){display:none}main{max-width:none}}
</style></head><body><main>
<header><h1>Support Diagnostic Toolkit</h1><p class="muted">Rapport de diagnostic - version 2.0</p>
<p><strong>Ordinateur :</strong> $safeComputer &nbsp; <strong>Mode :</strong> $safeMode &nbsp; <strong>Date :</strong> $date</p>
<p class="muted">Execute = le module a retourne un resultat. Cela ne garantit pas que le poste est sain. Echec = diagnostic incomplet.</p></header>
<section><h2>Synthese des mesures</h2><div class="grid">$($metrics.ToString())</div></section>
$($sections.ToString())
<footer>Collecte en lecture seule. Le JSON conserve les donnees detaillees. Les journaux et noms de processus peuvent contenir des informations sensibles : verifier avant partage.</footer>
</main></body></html>
"@
    [System.IO.File]::WriteAllText($htmlPath, $html, $utf8)
    if ($OpenHtml) { Invoke-Item -LiteralPath $htmlPath }
    [pscustomobject]@{
        ComputerName=$reportComputerName; ConnectionTarget=$connectionTarget; Mode=$Mode; Folder=$folder; HtmlPath=$htmlPath;
        JsonPath=$jsonPath; Executed=$executed; Failed=$failed
    }
}

# Keep the V1.1 command name for backward compatibility.
function New-SDTLocalReport {
    [CmdletBinding()]
    param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'reports'), [switch]$OpenHtml)
    New-SDTReport -Mode Local -OutputDirectory $OutputDirectory -OpenHtml:$OpenHtml
}