[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SetupPath,

    [string]$InstanceName = 'MSSQLSERVER',

    [string[]]$SqlSysAdminAccounts = @("$env:USERDOMAIN\$env:USERNAME"),

    [string]$ProductKey,

    [switch]$UseEvaluation,

    [string]$InstallSqlDataDir = 'C:\SQLData',

    [string]$SqlUserDbDir = 'C:\SQLData\Data',

    [string]$SqlUserDbLogDir = 'C:\SQLData\Log',

    [string]$SqlTempDbDir = 'C:\SQLData\TempDB',

    [string]$SqlTempDbLogDir = 'C:\SQLData\TempDBLog',

    [int]$TempDbFileCount = 8,

    [int]$TempDbFileSizeMb = 1024,

    [int]$TempDbFileGrowthMb = 256
)

$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell window.'
    }
}

function Assert-Windows11ProOrAbove {
    $os = Get-CimInstance Win32_OperatingSystem
    $caption = [string]$os.Caption
    if ($caption -notmatch 'Windows 1[1-9]' -and $caption -notmatch 'Windows Server') {
        throw "Unsupported OS: $caption. Use Windows 11 Pro/Enterprise/Education or Windows Server."
    }

    if ($caption -match 'Windows 11 Home') {
        throw 'Windows 11 Home is not supported. Use Windows 11 Pro or above.'
    }
}

Assert-Administrator
Assert-Windows11ProOrAbove

if (-not (Test-Path $SetupPath)) {
    throw "SetupPath was not found: $SetupPath"
}

$setupExe = if ((Get-Item $SetupPath).PSIsContainer) {
    Join-Path $SetupPath 'setup.exe'
}
else {
    $SetupPath
}

if (-not (Test-Path $setupExe)) {
    throw "SQL Server setup.exe was not found at: $setupExe"
}

if (-not $ProductKey -and -not $UseEvaluation) {
    throw 'Enterprise edition installation requires licensed Enterprise media or -ProductKey. For a temporary lab, pass -UseEvaluation with evaluation media.'
}

@($InstallSqlDataDir, $SqlUserDbDir, $SqlUserDbLogDir, $SqlTempDbDir, $SqlTempDbLogDir) |
    ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }

$features = 'SQLENGINE'
$sysAdmins = '"' + ($SqlSysAdminAccounts -join '" "') + '"'
$sqlServiceAccount = if ($InstanceName -eq 'MSSQLSERVER') { 'NT Service\MSSQLSERVER' } else { "NT Service\MSSQL`$$InstanceName" }
$agentServiceAccount = if ($InstanceName -eq 'MSSQLSERVER') { 'NT Service\SQLSERVERAGENT' } else { "NT Service\SQLAgent`$$InstanceName" }

$arguments = @(
    '/Q',
    '/ACTION=Install',
    "/FEATURES=$features",
    "/INSTANCENAME=$InstanceName",
    '/SQLSVCSTARTUPTYPE=Automatic',
    '/AGTSVCSTARTUPTYPE=Automatic',
    "/SQLSVCACCOUNT=`"$sqlServiceAccount`"",
    "/AGTSVCACCOUNT=`"$agentServiceAccount`"",
    "/SQLSYSADMINACCOUNTS=$sysAdmins",
    "/INSTALLSQLDATADIR=`"$InstallSqlDataDir`"",
    "/SQLUSERDBDIR=`"$SqlUserDbDir`"",
    "/SQLUSERDBLOGDIR=`"$SqlUserDbLogDir`"",
    "/SQLTEMPDBDIR=`"$SqlTempDbDir`"",
    "/SQLTEMPDBLOGDIR=`"$SqlTempDbLogDir`"",
    "/SQLTEMPDBFILECOUNT=$TempDbFileCount",
    "/SQLTEMPDBFILESIZE=$TempDbFileSizeMb",
    "/SQLTEMPDBFILEGROWTH=$TempDbFileGrowthMb",
    '/TCPENABLED=1',
    '/NPENABLED=0',
    '/BROWSERSVCSTARTUPTYPE=Automatic',
    '/IACCEPTSQLSERVERLICENSETERMS'
)

if ($ProductKey) {
    $arguments += "/PID=$ProductKey"
}

Write-Host "Installing SQL Server instance '$InstanceName' from $setupExe"
$process = Start-Process -FilePath $setupExe -ArgumentList $arguments -Wait -PassThru
if ($process.ExitCode -notin @(0, 3010)) {
    throw "SQL Server setup failed with exit code $($process.ExitCode). Review SQL setup logs under C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log."
}

Write-Host 'SQL Server setup completed.'
if ($process.ExitCode -eq 3010) {
    Write-Warning 'SQL Server setup requested a restart.'
}
