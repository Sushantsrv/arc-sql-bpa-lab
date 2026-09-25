[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Windows', 'Linux')]
    [string]$OsType = 'Windows',

    [string]$VmName = 'arcsql-win01',

    [Parameter(Mandatory)]
    [string]$IsoPath,

    [string]$VmRoot = 'C:\HyperV\ArcSqlLab',

    [uint64]$MemoryStartupBytes = 8GB,

    [uint64]$VhdSizeBytes = 120GB,

    [int]$ProcessorCount = 4,

    [string]$SwitchName,

    [switch]$Start
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    throw 'Run this script from an elevated PowerShell window.'
}

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell cmdlets are not available. Run scripts\05-Enable-HyperV.ps1 as Administrator, restart if prompted, and try again.'
}

if (-not (Test-Path -LiteralPath $IsoPath)) {
    throw "ISO path does not exist: $IsoPath"
}

if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "A VM named '$VmName' already exists."
}

if (-not $SwitchName) {
    $defaultSwitch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($defaultSwitch) {
        $SwitchName = $defaultSwitch.Name
    }
    else {
        $firstSwitch = Get-VMSwitch | Select-Object -First 1
        if ($firstSwitch) {
            $SwitchName = $firstSwitch.Name
        }
    }
}

if (-not $SwitchName) {
    throw 'No Hyper-V virtual switch was found. Create one in Hyper-V Manager or pass -SwitchName.'
}

$vmPath = Join-Path $VmRoot $VmName
$vhdPath = Join-Path $vmPath "$VmName.vhdx"

if ($PSCmdlet.ShouldProcess($VmName, "Create Hyper-V $OsType SQL host VM")) {
    New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

    $vm = New-VM `
        -Name $VmName `
        -Generation 2 `
        -MemoryStartupBytes $MemoryStartupBytes `
        -NewVHDPath $vhdPath `
        -NewVHDSizeBytes $VhdSizeBytes `
        -Path $VmRoot `
        -SwitchName $SwitchName

    Set-VMProcessor -VMName $VmName -Count $ProcessorCount
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true -MinimumBytes 2GB -StartupBytes $MemoryStartupBytes -MaximumBytes $MemoryStartupBytes

    $dvd = Add-VMDvdDrive -VMName $VmName -Path $IsoPath -PassThru
    Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd

    if ($OsType -eq 'Linux') {
        Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
    }
    else {
        Set-VMFirmware -VMName $VmName -SecureBootTemplate MicrosoftWindows
    }

    Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface' -ErrorAction SilentlyContinue

    if ($Start) {
        Start-VM -Name $VmName
    }

    Write-Host ''
    Write-Host "Created VM: $VmName"
    Write-Host "OS type: $OsType"
    Write-Host "VM path: $vmPath"
    Write-Host "VHD path: $vhdPath"
    Write-Host "Switch: $SwitchName"
    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host '1. Connect to the VM console in Hyper-V Manager and install the operating system from the ISO.'
    Write-Host '2. Install SQL Server 2017 or later. SQL Server Developer edition is fine for lab use.'
    Write-Host '3. Copy arc-sql-lab to the guest or download it there.'
    Write-Host '4. Run sql\Check-SqlArcPrereqs.sql in SQL Server.'
    Write-Host '5. Run scripts\02-Onboard-SqlHostToArc.ps1 from an elevated PowerShell session in the guest.'
}
