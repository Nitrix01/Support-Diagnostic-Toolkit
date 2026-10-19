# Support Diagnostic Toolkit - Report V1
# Windows PowerShell 5.1 / PowerShell 7 - Local, read-only diagnostics
# Produces HTML and JSON reports from SystemInfo and Storage.


function ConvertTo-SDTHtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-SDTDisplayValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    if ($Value -is [System.Collections.IDictionary]) {
        return (($Value.Keys | ForEach-Object { '{0}: {1}' -f $_, $Value[$_] }) -join '; ')
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return ((@($Value) | ForEach-Object { [string]$_ }) -join ', ')
    }
    return [string]$Value
}

function ConvertTo-SDTHtmlTable {
    param([AllowNull()][object]$Data)
    if ($null -eq $Data) { return '<p>Aucune donnee retournee.</p>' }

    $items = @($Data)
    if ($items.Count -eq 0) { return '<p>Aucune donnee retournee.</p>' }

    $html = [System.Text.StringBuilder]::new()
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        [void]$html.AppendLine('<table><tbody>')
        if ($item -is [System.Collections.IDictionary]) {
            $names = @($item.Keys)
            foreach ($name in $names) {
                $value = ConvertTo-SDTDisplayValue -Value $item[$name]
                [void]$html.AppendLine(('<tr><th>{0}</th><td>{1}</td></tr>' -f (ConvertTo-SDTHtmlText $name), (ConvertTo-SDTHtmlText $value)))
            }
        } else {
            foreach ($property in $item.PSObject.Properties) {
                if ($property.MemberType -notin @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) { continue }
                try { $value = ConvertTo-SDTDisplayValue -Value $property.Value }
                catch { $value = '[Lecture impossible]' }
                [void]$html.AppendLine(('<tr><th>{0}</th><td>{1}</td></tr>' -f (ConvertTo-SDTHtmlText $property.Name), (ConvertTo-SDTHtmlText $value)))
            }
        }
        [void]$html.AppendLine('</tbody></table>')
    }
    return $html.ToString()
}

function New-SDTLocalReport {
    [CmdletBinding()]
    param(
        [string]$OutputDirectory = (Join-Path $PSScriptRoot 'reports'),
        [switch]$OpenHtml
    )

    $modulePaths = @{
        SystemInfo = Join-Path $PSScriptRoot 'modules\SystemInfo.ps1'
        Storage    = Join-Path $PSScriptRoot 'modules\Storage.ps1'
    }

    foreach ($moduleName in @('SystemInfo', 'Storage')) {
        $path = $modulePaths[$moduleName]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Module introuvable : $path"
        }
        . $path
    }

    foreach ($commandName in @('Get-SystemInfo', 'Get-StorageDiagnostic')) {
        if (-not (Get-Command -Name $commandName -CommandType Function -ErrorAction SilentlyContinue)) {
            throw "Fonction introuvable apres chargement : $commandName"
        }
    }

    $results = [ordered]@{}
    foreach ($diagnostic in @(
        @{ Name = 'SystemInfo'; Command = 'Get-SystemInfo' },
        @{ Name = 'Storage'; Command = 'Get-StorageDiagnostic' }
    )) {
        $name = $diagnostic.Name
        try {
            $data = @(& $diagnostic.Command -ErrorAction Stop)
            $results[$name] = [ordered]@{
                Status = 'Executed'
                Data   = $data
                Error  = $null
            }
        } catch {
            $results[$name] = [ordered]@{
                Status = 'Failed'
                Data   = @()
                Error  = $_.Exception.Message
            }
        }
    }

    $now = Get-Date
    $computerName = $env:COMPUTERNAME
    $safeComputerName = $computerName -replace '[^a-zA-Z0-9._-]', '_'
    $runFolder = Join-Path (Join-Path $OutputDirectory $safeComputerName) ($now.ToString('yyyy-MM-dd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $runFolder -Force -ErrorAction Stop | Out-Null

    $report = [ordered]@{
        SchemaVersion = '1.0'
        Tool          = 'Support Diagnostic Toolkit'
        Mode          = 'Local'
        ComputerName  = $computerName
        CollectedAt   = $now.ToString('o')
        Diagnostics   = $results
    }

    $jsonPath = Join-Path $runFolder 'diagnostic.json'
    $htmlPath = Join-Path $runFolder 'diagnostic.html'
    $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $jsonPath -Encoding UTF8 -ErrorAction Stop

    $sections = [System.Text.StringBuilder]::new()
    foreach ($name in @('SystemInfo', 'Storage')) {
        $entry = $results[$name]
        $state = if ($entry.Status -eq 'Executed') { 'Execute' } else { 'Echec' }
        $stateClass = if ($entry.Status -eq 'Executed') { 'done' } else { 'failed' }
        [void]$sections.AppendLine(('<section><h2>{0} <span class="{1}">{2}</span></h2>' -f (ConvertTo-SDTHtmlText $name), $stateClass, $state))
        if ($entry.Status -eq 'Failed') {
            [void]$sections.AppendLine(('<p class="error">{0}</p>' -f (ConvertTo-SDTHtmlText $entry.Error)))
        } else {
            [void]$sections.AppendLine((ConvertTo-SDTHtmlTable -Data $entry.Data))
        }
        [void]$sections.AppendLine('</section>')
    }

    $html = @"
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rapport SDT - $(ConvertTo-SDTHtmlText $computerName)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#f4f6fa;color:#1e293b;margin:0;padding:28px}
main{max-width:1050px;margin:auto}header,section{background:#fff;padding:24px;margin-bottom:18px;border-radius:12px;box-shadow:0 2px 8px #0000000d}
h1{margin-top:0;font-size:26px}h2{font-size:19px}p{line-height:1.5}
table{border-collapse:collapse;width:100%;margin:12px 0 20px;table-layout:fixed}th,td{border-bottom:1px solid #e2e8f0;padding:10px;text-align:left;vertical-align:top;overflow-wrap:anywhere}
th{width:28%;background:#f8fafc}.done,.failed{font-size:12px;padding:4px 9px;border-radius:12px;margin-left:10px}
.done{background:#e0f2fe;color:#075985}.failed{background:#fee2e2;color:#991b1b}.error{color:#991b1b}
small{color:#64748b}
</style>
</head>
<body><main>
<header><h1>Support Diagnostic Toolkit</h1><p>Rapport de diagnostic local</p>
<p><strong>Ordinateur :</strong> $(ConvertTo-SDTHtmlText $computerName)<br>
<strong>Date :</strong> $(ConvertTo-SDTHtmlText ($now.ToString('dd/MM/yyyy HH:mm:ss')))</p>
<small>Le statut « Execute » signifie que le module a retourne un resultat sans erreur bloquante ; il ne signifie pas que le poste est sain.</small>
</header>
$($sections.ToString())
</main></body></html>
"@
    $html | Set-Content -LiteralPath $htmlPath -Encoding UTF8 -ErrorAction Stop

    if ($OpenHtml) { Invoke-Item -LiteralPath $htmlPath }

    [pscustomobject]@{
        ComputerName = $computerName
        Folder       = $runFolder
        HtmlPath     = $htmlPath
        JsonPath     = $jsonPath
        SystemInfo   = $results['SystemInfo'].Status
        Storage      = $results['Storage'].Status
    }
}
