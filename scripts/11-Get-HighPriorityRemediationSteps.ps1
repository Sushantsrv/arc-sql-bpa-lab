[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WorkspaceId,

    [string]$ReportId,

    [int]$LookbackHours = 24,

    [string]$OutputMarkdownPath
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install Azure CLI and run az login before continuing.'
}

if (-not (az extension list --query "[?name=='log-analytics'].name" -o tsv)) {
    az extension add --name log-analytics --yes | Out-Null
}

$filter = if ($ReportId) {
    "RawData has '$ReportId'"
}
else {
    "TimeGenerated > ago(${LookbackHours}h)"
}

$query = @"
SqlAssessment_CL
| where $filter
| project RawData
"@

$rows = az monitor log-analytics query `
    --workspace $WorkspaceId `
    --analytics-query $query `
    --timespan "PT${LookbackHours}H" `
    -o json | ConvertFrom-Json

if (-not $rows) {
    Write-Warning 'No SQL best practices assessment rows were found.'
    return
}

$header = 'CollectedAt,ReportId,CheckId,DisplayName,Description,HelpLink,Severity,Target,TargetScore,Message,Tags,InstanceName'
$parsed = foreach ($row in $rows) {
    (@($header, $row.RawData) -join "`n") | ConvertFrom-Csv
}

$latestReportId = if ($ReportId) {
    $ReportId
}
else {
    ($parsed | Sort-Object CollectedAt -Descending | Select-Object -First 1).ReportId
}

$high = $parsed |
    Where-Object { $_.ReportId -eq $latestReportId -and $_.Severity -eq 1 -and [int]$_.TargetScore -ge 0 -and [int]$_.TargetScore -lt 100 } |
    Sort-Object CheckId

$steps = @{
    AgentSvcStoped = @(
        'Open PowerShell as Administrator on the SQL host.',
        'Run: Set-Service -Name SQLSERVERAGENT -StartupType Automatic',
        'Run: Start-Service -Name SQLSERVERAGENT'
    )
    BrowserSvcStoped = @(
        'Only enable SQL Browser if named instances or dynamic ports require it.',
        'Open PowerShell as Administrator on the SQL host.',
        'Run: Set-Service -Name SQLBrowser -StartupType Automatic',
        'Run: Start-Service -Name SQLBrowser'
    )
    MaxMemorySystem = @(
        'Set max server memory below physical RAM, leaving memory for Windows and agents.',
        "Run in sqlcmd: EXEC sp_configure 'show advanced options', 1; RECONFIGURE;",
        "Run in sqlcmd: EXEC sp_configure 'max server memory (MB)', <target_mb>; RECONFIGURE;"
    )
    BackupCompression = @(
        "Run in sqlcmd: EXEC sp_configure 'backup compression default', 1; RECONFIGURE;"
    )
    DisallowResultsTriggers = @(
        "Run in sqlcmd: EXEC sp_configure 'disallow results from triggers', 1; RECONFIGURE;"
    )
    PlansUseRatio = @(
        "Run in sqlcmd: EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;",
        'Do not clear the plan cache during business hours unless you accept recompilation impact.'
    )
    PlansUseRatioNotOptimal = @(
        'Review workload impact before clearing plan cache.',
        'If approved for a maintenance window, run in sqlcmd: DBCC FREESYSTEMCACHE(''SQL Plans'');'
    )
    InstantFileInitialization = @(
        'Grant the SQL Server Database Engine service account the "Perform volume maintenance tasks" user right.',
        'For the default instance virtual account, grant it to: NT Service\MSSQLSERVER',
        'Restart the SQL Server service after changing the user right.'
    )
    NtfsBlockSizeNotFormatted = @(
        'Move SQL data/log/tempdb files to a volume formatted with 64 KB allocation units.',
        'Changing allocation unit size on an existing volume requires backup, reformat, restore or moving files to a new volume.'
    )
    PageFileAutoManagedAllDrives = @(
        'Open System Properties as Administrator.',
        'Go to Advanced > Performance > Settings > Advanced > Virtual memory.',
        'Enable "Automatically manage paging file size for all drives" unless your enterprise standard requires a manually sized page file.'
    )
    ErrorLogAge = @(
        "Run in sqlcmd: EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'NumErrorLogs', REG_DWORD, 14;",
        'Cycle error logs during maintenance or wait for normal retention to accumulate enough history.'
    )
    TempDBFilesInitialSize = @(
        'Pre-size tempdb data files to fit the normal workload and use consistent growth settings.',
        "Example: ALTER DATABASE tempdb MODIFY FILE (NAME = N'tempdev', SIZE = 1024MB, FILEGROWTH = 256MB);",
        'Restart SQL Server if file layout changes require it.'
    )
    DeprecatedFeatures = @(
        'Use the BPA message to identify deprecated features.',
        'Replace deprecated system views/functions/types in application code or database objects.',
        'Common examples: replace syslogins, avoid text/ntext/image, qualify modern syntax such as table hints WITH (...).'
    )
    ShowAdvancedOptions = @(
        "Run in sqlcmd: EXEC sp_configure 'show advanced options', 0; RECONFIGURE;"
    )
}

$lines = @(
    '# SQL Server BPA high-priority remediation plan'
    ''
    ('Report ID: `{0}`' -f $latestReportId)
    ''
)

foreach ($finding in $high) {
    $lines += ('## {0}: {1}' -f $finding.CheckId, $finding.DisplayName)
    $lines += ''
    $lines += ('- Target: `{0}`' -f $finding.Target)
    $lines += ('- Score: `{0}`' -f $finding.TargetScore)
    $lines += ('- BPA message: {0}' -f $finding.Message)
    $lines += ''
    $lines += 'Recommended steps:'
    if ($steps.ContainsKey($finding.CheckId)) {
        foreach ($step in $steps[$finding.CheckId]) {
            $lines += ('- {0}' -f $step)
        }
    }
    else {
        $lines += '- Review the BPA message and Microsoft guidance link from the assessment output.'
        $lines += '- Validate the change in a non-production environment before applying it to production.'
    }
    $lines += ''
}

if ($OutputMarkdownPath) {
    $lines | Set-Content -Path $OutputMarkdownPath -Encoding utf8
    Write-Host "Remediation plan written to $OutputMarkdownPath"
}
else {
    $lines
}
