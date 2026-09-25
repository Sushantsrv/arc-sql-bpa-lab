[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    throw 'Run this script from an elevated PowerShell window.'
}

$feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($feature.State -eq 'Enabled') {
    Write-Host 'Hyper-V is already enabled.'
}
else {
    if ($PSCmdlet.ShouldProcess('Local computer', 'Enable Hyper-V')) {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
        Write-Host 'Hyper-V was enabled. Restart Windows before creating VMs.'
    }
}

$tools = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell
if ($tools.State -ne 'Enabled') {
    if ($PSCmdlet.ShouldProcess('Local computer', 'Enable Hyper-V PowerShell management tools')) {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -All -NoRestart
        Write-Host 'Hyper-V PowerShell management tools were enabled.'
    }
}
