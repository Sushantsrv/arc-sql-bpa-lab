[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [string]$ResourceGroupName = 'rg-arc-sql-lab',

    [string]$Location = 'westus3',

    [string]$ServicePrincipalName = 'sp-arc-sql-onboarding-lab'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install Azure CLI and run az login before continuing.'
}

az account set --subscription $SubscriptionId | Out-Null

$providers = @(
    'Microsoft.HybridCompute',
    'Microsoft.AzureArcData',
    'Microsoft.GuestConfiguration'
)

foreach ($provider in $providers) {
    Write-Host "Registering provider: $provider"
    az provider register --namespace $provider | Out-Null
}

Write-Host "Creating or updating resource group: $ResourceGroupName"
az group create --name $ResourceGroupName --location $Location --tags Project=ArcSqlLab Environment=Lab | Out-Null

$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

Write-Host "Creating scoped onboarding service principal: $ServicePrincipalName"
$sp = az ad sp create-for-rbac `
    --name $ServicePrincipalName `
    --role 'Azure Connected Machine Onboarding' `
    --scopes $scope `
    -o json | ConvertFrom-Json

Write-Host ''
Write-Host 'Save this output securely. The password cannot be retrieved later.'
[pscustomobject]@{
    subscriptionId = $SubscriptionId
    resourceGroup  = $ResourceGroupName
    location       = $Location
    tenantId       = $sp.tenant
    appId          = $sp.appId
    password       = $sp.password
    scope          = $scope
} | ConvertTo-Json

Write-Host ''
Write-Host 'Provider registration can take several minutes. Re-run scripts\00-Check-Prereqs.ps1 to confirm registration state.'
