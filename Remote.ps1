# Support Diagnostic Toolkit - Remote.ps1
# V1 - PowerShell Remoting (WinRM), lecture seule des diagnostics.
# Windows PowerShell 5.1 / PowerShell 7 sur Windows.

function Test-SDTConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComputerName,
        [pscredential]$Credential
    )

    $result = [ordered]@{
        ComputerName = $ComputerName
        Reachable = $false
        Message = $null
        CheckedAt = Get-Date
    }
    try {
        $params = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
        if ($PSBoundParameters.ContainsKey('Credential')) { $params.Credential = $Credential }
        $session = New-PSSession @params
        try {
            $null = Invoke-Command -Session $session -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            $result.Reachable = $true
            $result.Message = 'Session PowerShell distante operationnelle.'
        }
        finally { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    catch {
        $result.Message = $_.Exception.Message
    }
    [pscustomobject]$result
}

function Invoke-SDTDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComputerName,
        [Parameter(Mandatory)][ValidateSet('SystemInfo','Services','Storage','Network','Performance','EventLogs','WindowsUpdate')]
        [string]$Module,
        [pscredential]$Credential,
        [ValidateRange(1,168)][int]$Hours = 24
    )

    $moduleFiles = @{
        SystemInfo = 'SystemInfo.ps1'
        Services = 'Services.ps1'
        Storage = 'Storage.ps1'
        Network = 'Network.ps1'
        Performance = 'Performance.ps1'
        EventLogs = 'EventLogs.ps1'
        WindowsUpdate = 'WindowsUpdate.ps1'
    }
    $functionNames = @{
        SystemInfo = 'Get-SystemInfo'
        Services = 'Get-WindowsServiceDiagnostic'
        Storage = 'Get-StorageDiagnostic'
        Network = 'Get-NetworkDiagnostic'
        Performance = 'Get-PerformanceDiagnostic'
        EventLogs = 'Get-EventLogDiagnostic'
        WindowsUpdate = 'Get-WindowsUpdateDiagnostic'
    }

    $path = Join-Path $PSScriptRoot (Join-Path 'Modules' $moduleFiles[$Module])
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Module introuvable : $path. Placez Remote.ps1 a la racine du projet."
    }
    $source = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $functionName = $functionNames[$Module]

    $sessionParams = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('Credential')) { $sessionParams.Credential = $Credential }
    $session = $null
    try {
        $session = New-PSSession @sessionParams
        $output = Invoke-Command -Session $session -ArgumentList $source,$functionName,$Module,$Hours -ErrorAction Stop -ScriptBlock {
            param($moduleSource,$diagnosticFunction,$moduleName,$hours)
            # Charger le module dans la portee de cette invocation, sans ecrire de fichier distant.
            . ([scriptblock]::Create($moduleSource))
            $command = Get-Command -Name $diagnosticFunction -CommandType Function -ErrorAction Stop
            $args = @{}
            if ($moduleName -in @('Services','EventLogs','WindowsUpdate')) {
                if ($command.Parameters.ContainsKey('Hours')) { $args.Hours = $hours }
            }
            & $diagnosticFunction @args
        }
        return $output
    }
    catch {
        throw "Diagnostic '$Module' impossible sur '$ComputerName' : $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
}
