[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$MachineName,

    [Parameter(Mandatory)]
    [string]$Location,

    [ValidateSet('PAYG', 'Paid', 'LicenseOnly')]
    [string]$LicenseType = 'LicenseOnly',

    [string[]]$ExcludedSqlInstances = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install Azure CLI and run az login before continuing.'
}

az account set --subscription $SubscriptionId | Out-Null

$extension = az connectedmachine extension show `
    --resource-group $ResourceGroupName `
    --machine-name $MachineName `
    --name 'WindowsAgent.SqlServer' `
    -o json 2>$null

if ($extension) {
    Write-Host "WindowsAgent.SqlServer extension already exists on $MachineName."
    return
}

$settings = @{
    SqlManagement        = @{ IsEnabled = $true }
    LicenseType          = $LicenseType
    ExcludedSqlInstances = $ExcludedSqlInstances
} | ConvertTo-Json -Compress

Write-Host "Installing Azure extension for SQL Server on Arc machine: $MachineName"
az connectedmachine extension create `
    --machine-name $MachineName `
    --location $Location `
    --name 'WindowsAgent.SqlServer' `
    --resource-group $ResourceGroupName `
    --type 'WindowsAgent.SqlServer' `
    --publisher 'Microsoft.AzureData' `
    --settings $settings

Write-Host ''
Write-Host 'The extension continuously discovers installed SQL Server instances and registers them as SQL Server - Azure Arc resources.'
