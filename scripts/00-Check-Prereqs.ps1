[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found. Install it before continuing."
    }
}

Test-Command -Name 'az'

az account set --subscription $SubscriptionId | Out-Null
$account = az account show --query '{name:name, id:id, tenantId:tenantId, user:user.name}' -o json | ConvertFrom-Json

Write-Host "Azure CLI is signed in as $($account.user)"
Write-Host "Subscription: $($account.name) [$($account.id)]"
Write-Host "Tenant: $($account.tenantId)"

$requiredExtensions = @('connectedmachine')
foreach ($extension in $requiredExtensions) {
    $installed = az extension list --query "[?name=='$extension'].name" -o tsv
    if (-not $installed) {
        Write-Host "Installing Azure CLI extension: $extension"
        az extension add --name $extension --yes | Out-Null
    }
}

$providers = @(
    'Microsoft.HybridCompute',
    'Microsoft.AzureArcData',
    'Microsoft.GuestConfiguration'
)

Write-Host ''
Write-Host 'Provider registration state:'
foreach ($provider in $providers) {
    $state = az provider show --namespace $provider --query 'registrationState' -o tsv 2>$null
    if (-not $state) {
        $state = 'NotRegisteredOrUnavailable'
    }
    Write-Host "  $provider : $state"
}

Write-Host ''
Write-Host 'If any required provider is not Registered, run scripts\01-Prepare-AzureTenant.ps1.'
