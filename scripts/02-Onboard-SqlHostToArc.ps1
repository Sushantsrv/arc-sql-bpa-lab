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

    [string]$Tags = 'Project=ArcSqlLab,Environment=Lab'
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    throw 'Run this script from an elevated PowerShell window on the target SQL Server host.'
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

Write-Host 'Connecting this server to Azure Arc.'
& $agentPath connect `
    --service-principal-id $ServicePrincipalId `
    --service-principal-secret $ServicePrincipalSecret `
    --resource-group $ResourceGroupName `
    --tenant-id $TenantId `
    --location $Location `
    --subscription-id $SubscriptionId `
    --cloud AzureCloud `
    --tags $Tags

Write-Host ''
Write-Host 'Azure Arc connection status:'
& $agentPath show

Write-Host ''
Write-Host 'If SQL Server is installed and prerequisites are met, Azure should automatically install the SQL extension and create SQL Server - Azure Arc resources within a few minutes.'
