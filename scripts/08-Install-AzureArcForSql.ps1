[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory)]
    [string]$ServicePrincipalSecret,

    [ValidateSet('PAYG', 'Paid')]
    [string]$LicenseType = 'Paid',

    [string[]]$ExcludedSqlInstances = @(),

    [string]$Tags = 'Project=ArcSqlBpa,Environment=Lab'
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    throw 'Run this script from an elevated PowerShell window on the SQL host.'
}

$agentPath = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
if (-not (Test-Path $agentPath)) {
    $installer = Join-Path $env:TEMP 'AzureConnectedMachineAgent.msi'
    Write-Host 'Downloading Azure Connected Machine Agent.'
    Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile $installer

    Write-Host 'Installing Azure Connected Machine Agent.'
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$installer`" /qn /l*v `"$env:TEMP\azcmagent-install.log`"" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Azure Connected Machine Agent installation failed with exit code $($process.ExitCode). See $env:TEMP\azcmagent-install.log."
    }
}

$agent = & $agentPath show 2>$null
$agentText = $agent | Out-String
if ($LASTEXITCODE -ne 0 -or $agentText -notmatch 'Connected') {
    Write-Host 'Connecting this machine to Azure Arc.'
    & $agentPath connect `
        --service-principal-id $ServicePrincipalId `
        --service-principal-secret $ServicePrincipalSecret `
        --resource-group $ResourceGroupName `
        --tenant-id $TenantId `
        --location $Location `
        --subscription-id $SubscriptionId `
        --cloud AzureCloud `
        --tags $Tags
}
else {
    Write-Host 'Azure Connected Machine Agent is already connected.'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required to install the SQL extension. Install Azure CLI and authenticate with az login.'
}

az account set --subscription $SubscriptionId | Out-Null
$machineName = (& $agentPath show --property resourceName).Trim()
if (-not $machineName) {
    $machineName = $env:COMPUTERNAME
}

$settings = @{
    SqlManagement        = @{ IsEnabled = $true }
    LicenseType          = $LicenseType
    ExcludedSqlInstances = $ExcludedSqlInstances
} | ConvertTo-Json -Compress

$existing = az connectedmachine extension show `
    --resource-group $ResourceGroupName `
    --machine-name $machineName `
    --name 'WindowsAgent.SqlServer' `
    -o json 2>$null

if ($existing) {
    Write-Host "Updating WindowsAgent.SqlServer extension on $machineName."
    az connectedmachine extension update `
        --resource-group $ResourceGroupName `
        --machine-name $machineName `
        --name 'WindowsAgent.SqlServer' `
        --settings $settings | Out-Null
}
else {
    Write-Host "Installing WindowsAgent.SqlServer extension on $machineName."
    az connectedmachine extension create `
        --resource-group $ResourceGroupName `
        --machine-name $machineName `
        --location $Location `
        --name 'WindowsAgent.SqlServer' `
        --type 'WindowsAgent.SqlServer' `
        --publisher 'Microsoft.AzureData' `
        --settings $settings | Out-Null
}

Write-Host 'Azure Arc for SQL is installed. SQL Server - Azure Arc resources can take several minutes to appear.'
