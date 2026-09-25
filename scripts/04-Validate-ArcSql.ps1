[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [string]$ResourceGroupName = 'rg-arc-sql-lab'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install Azure CLI and run az login before continuing.'
}

az account set --subscription $SubscriptionId | Out-Null

Write-Host 'Arc-enabled machines:'
az connectedmachine list --resource-group $ResourceGroupName --query '[].{name:name, status:status, osName:osName, location:location}' -o table

Write-Host ''
Write-Host 'SQL extension state on Arc machines:'
$machines = az connectedmachine list --resource-group $ResourceGroupName --query '[].name' -o tsv
foreach ($machine in $machines) {
    $extension = az connectedmachine extension show `
        --resource-group $ResourceGroupName `
        --machine-name $machine `
        --name 'WindowsAgent.SqlServer' `
        --query '{machine:machineName, name:name, provisioningState:provisioningState, type:type}' `
        -o table 2>$null

    if ($extension) {
        $extension
    }
    else {
        Write-Host "$machine : WindowsAgent.SqlServer extension not found"
    }
}

Write-Host ''
Write-Host 'AzureArcData resources:'
az resource list `
    --resource-group $ResourceGroupName `
    --query "[?starts_with(type, 'Microsoft.AzureArcData/')].{name:name,type:type,location:location}" `
    -o table
