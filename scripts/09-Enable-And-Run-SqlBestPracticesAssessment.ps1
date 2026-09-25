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

    [string]$WorkspaceName = 'loganalyticsarc-bpa',

    [string]$WorkspaceResourceGroupName = $ResourceGroupName,

    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')]
    [string]$ScheduleDayOfWeek = 'Sunday',

    [ValidatePattern('^\d{2}:\d{2}$')]
    [string]$ScheduleStartTime = '00:00',

    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'

function Invoke-AzRestJson {
    param(
        [Parameter(Mandatory)][ValidateSet('get', 'put', 'post', 'patch', 'delete')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [object]$Body
    )

    if ($PSBoundParameters.ContainsKey('Body')) {
        $bodyPath = Join-Path $env:TEMP ([Guid]::NewGuid().ToString() + '.json')
        try {
            $Body | ConvertTo-Json -Depth 100 | Set-Content -Path $bodyPath -Encoding utf8
            az rest --method $Method --url $Url --headers 'Content-Type=application/json' --body "@$bodyPath"
        }
        finally {
            Remove-Item $bodyPath -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        az rest --method $Method --url $Url
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install Azure CLI and run az login before continuing.'
}

az account set --subscription $SubscriptionId | Out-Null

$providers = @(
    'Microsoft.HybridCompute',
    'Microsoft.AzureArcData',
    'Microsoft.Insights',
    'Microsoft.OperationalInsights'
)
foreach ($provider in $providers) {
    $state = az provider show --namespace $provider --query registrationState -o tsv 2>$null
    if ($state -ne 'Registered') {
        Write-Host "Registering resource provider: $provider"
        az provider register --namespace $provider | Out-Null
    }
}

$workspace = az monitor log-analytics workspace show `
    --subscription $SubscriptionId `
    --resource-group $WorkspaceResourceGroupName `
    --workspace-name $WorkspaceName `
    -o json 2>$null

if (-not $workspace) {
    Write-Host "Creating Log Analytics workspace: $WorkspaceName"
    az monitor log-analytics workspace create `
        --subscription $SubscriptionId `
        --resource-group $WorkspaceResourceGroupName `
        --workspace-name $WorkspaceName `
        --location $Location | Out-Null
    $workspace = az monitor log-analytics workspace show `
        --subscription $SubscriptionId `
        --resource-group $WorkspaceResourceGroupName `
        --workspace-name $WorkspaceName `
        -o json
}

$workspaceObject = $workspace | ConvertFrom-Json
$workspaceId = $workspaceObject.id
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$extensionId = "$scope/providers/Microsoft.HybridCompute/machines/$MachineName/extensions/WindowsAgent.SqlServer"

$extension = az resource show --subscription $SubscriptionId --ids $extensionId -o json 2>$null
if (-not $extension) {
    throw "WindowsAgent.SqlServer extension was not found on Arc machine '$MachineName'. Install Arc for SQL first."
}

$extensionObject = $extension | ConvertFrom-Json
$licenseType = [string]$extensionObject.properties.settings.LicenseType
if ($licenseType -eq 'LicenseOnly') {
    throw 'Best practices assessment requires PAYG or Paid licensing on the SQL extension, not LicenseOnly.'
}

Write-Host 'Deploying Azure Monitor resources required by SQL best practices assessment.'
$policy = az policy definition show --name 'f36de009-cacb-47b3-b936-9c4c9120d064' -o json | ConvertFrom-Json
$templatePath = Join-Path $env:TEMP 'sql-bpa-template.json'
$paramsPath = Join-Path $env:TEMP 'sql-bpa-params.json'

try {
    $policy.policyRule.then.details.deployment.properties.template |
        ConvertTo-Json -Depth 100 |
        Set-Content -Path $templatePath -Encoding utf8

    @{
        '$schema'       = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion  = '1.0.0.0'
        parameters      = @{
            agentName           = @{ value = 'WindowsAgent.SqlServer' }
            existingSettings    = @{ value = $extensionObject.properties.settings }
            extensionName       = @{ value = "$MachineName/WindowsAgent.SqlServer" }
            isEnabled           = @{ value = $true }
            laWorkspaceId       = @{ value = $workspaceId }
            laWorkspaceLocation = @{ value = $workspaceObject.location }
            vmLocation          = @{ value = $Location }
        }
    } | ConvertTo-Json -Depth 100 | Set-Content -Path $paramsPath -Encoding utf8

    az deployment group create `
        --subscription $SubscriptionId `
        --resource-group $ResourceGroupName `
        --name "Enable-SQL-BPA-$MachineName" `
        --template-file $templatePath `
        --parameters "@$paramsPath" | Out-Null
}
finally {
    Remove-Item $templatePath, $paramsPath -Force -ErrorAction SilentlyContinue
}

$extensionObject = az resource show --subscription $SubscriptionId --ids $extensionId -o json | ConvertFrom-Json
$settings = $extensionObject.properties.settings
$epoch = [int][double]::Parse((Get-Date -UFormat %s))
$settings | Add-Member -Force -NotePropertyName AssessmentSettings -NotePropertyValue ([pscustomobject]@{
    Enable              = $true
    ResourceNamePrefix  = $MachineName
    RunImmediately      = [bool]$RunNow
    WorkspaceLocation   = $workspaceObject.location
    WorkspaceResourceId = $workspaceId
    schedule            = [pscustomobject]@{
        Enable            = $true
        StartDate         = $null
        WeeklyInterval    = 1
        dayOfWeek         = $ScheduleDayOfWeek
        monthlyOccurrence = $null
        startTime         = $ScheduleStartTime
    }
    settingsSaveTime    = $epoch
})

$body = @{
    location   = $Location
    properties = @{
        publisher               = 'Microsoft.AzureData'
        type                    = 'WindowsAgent.SqlServer'
        typeHandlerVersion      = $extensionObject.properties.typeHandlerVersion
        autoUpgradeMinorVersion = $extensionObject.properties.autoUpgradeMinorVersion
        enableAutomaticUpgrade  = $extensionObject.properties.enableAutomaticUpgrade
        settings                = $settings
    }
}

Invoke-AzRestJson `
    -Method put `
    -Url "https://management.azure.com${extensionId}?api-version=2019-12-12" `
    -Body $body | Out-Null

Write-Host "SQL best practices assessment is enabled for $MachineName."
Write-Host "Schedule: every $ScheduleDayOfWeek at $ScheduleStartTime local machine time."
if ($RunNow) {
    Write-Host 'An on-demand assessment run was requested. Results can take several minutes to two hours to appear in Log Analytics.'
}
