[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WorkspaceId,

    [string]$ReportId,

    [int]$LookbackHours = 24,

    [string]$ExportCsvPath,

    [string]$ExportJsonPath
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
| project TimeGenerated, RawData, _ResourceId
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
$severityMap = @{
    '0'  = 'Passed'
    '1'  = 'High'
    '2'  = 'Medium'
    '3'  = 'Low'
    '4'  = 'Information'
    '-1' = 'Information'
}

$parsed = foreach ($row in $rows) {
    $item = (@($header, $row.RawData) -join "`n") | ConvertFrom-Csv
    $item | Add-Member -Force -NotePropertyName IngestedAt -NotePropertyValue $row.TimeGenerated
    $item | Add-Member -Force -NotePropertyName ResourceId -NotePropertyValue $row._ResourceId
    $severityName = if ($severityMap.ContainsKey([string]$item.Severity)) {
        $severityMap[[string]$item.Severity]
    }
    else {
        "Severity $($item.Severity)"
    }
    $item | Add-Member -Force -NotePropertyName SeverityName -NotePropertyValue $severityName
    $item | Add-Member -Force -NotePropertyName Failed -NotePropertyValue (([int]$item.TargetScore -ge 0) -and ([int]$item.TargetScore -lt 100))
    $item
}

$latestReportId = if ($ReportId) {
    $ReportId
}
else {
    ($parsed | Sort-Object CollectedAt -Descending | Select-Object -First 1).ReportId
}

$latest = $parsed | Where-Object ReportId -eq $latestReportId

Write-Host "Report ID: $latestReportId"
Write-Host "Collected at: $(($latest | Select-Object -First 1).CollectedAt)"
Write-Host ''

Write-Host 'Findings by severity:'
$latest |
    Where-Object Failed |
    Group-Object SeverityName |
    Sort-Object @{ Expression = { switch ($_.Name) { 'High' { 1 } 'Medium' { 2 } 'Low' { 3 } default { 4 } } } } |
    ForEach-Object { [pscustomobject]@{ Severity = $_.Name; Count = $_.Count } } |
    Format-Table -AutoSize

Write-Host 'Top affected targets:'
$latest |
    Where-Object Failed |
    Group-Object Target |
    Sort-Object Count -Descending |
    Select-Object -First 15 |
    ForEach-Object { [pscustomobject]@{ Count = $_.Count; Target = $_.Name } } |
    Format-Table -AutoSize

Write-Host 'Failed high severity findings:'
$latest |
    Where-Object { $_.Failed -and $_.SeverityName -eq 'High' } |
    Sort-Object CheckId |
    Select-Object CheckId, DisplayName, Target, TargetScore, Message |
    Format-Table -AutoSize -Wrap

if ($ExportCsvPath) {
    $latest | Export-Csv -Path $ExportCsvPath -NoTypeInformation
    Write-Host "CSV exported to $ExportCsvPath"
}

if ($ExportJsonPath) {
    $latest | ConvertTo-Json -Depth 10 | Set-Content -Path $ExportJsonPath -Encoding utf8
    Write-Host "JSON exported to $ExportJsonPath"
}
