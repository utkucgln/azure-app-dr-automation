<#
.SYNOPSIS
  Restores a Logic App (Consumption) from a DR backup JSON to a target
  subscription, resource group, and region.

.DESCRIPTION
  Given a backup JSON produced by Backup-LogicAppsToDR.ps1, this script:
  1. Downloads the backup blob from the DR Storage account (or reads a local file).
  2. Re-creates all API connection resources (Microsoft.Web/connections) in the
     target resource group and region, updating subscription/location references.
  3. Deploys the Logic App (Microsoft.Logic/workflows) with the original workflow
     definition, wiring it to the newly created API connections.
  4. Optionally renames the restored Logic App (default: original name).

  The script uses ARM REST API (az rest) for deployment so that all resource
  properties are preserved exactly as they were in the backup.

.PARAMETER BackupSource
  Either a local file path to the backup JSON, OR a blob name in the DR
  Storage account (e.g. "ME-MngEnvMCAP.../logic-rss-demo/20260306-110804.json").

.PARAMETER SourceStorageAccount
  Name of the DR Storage account that holds backup blobs. Required when
  BackupSource is a blob path (not a local file).

.PARAMETER SourceStorageContainer
  Blob container name in the DR Storage account. Default: "config-docs".

.PARAMETER SourceStorageSubscription
  Subscription ID or name for the DR Storage account. Required when
  BackupSource is a blob path.

.PARAMETER TargetSubscriptionId
  Subscription where the Logic App will be restored.

.PARAMETER TargetResourceGroup
  Resource group where the Logic App will be restored.

.PARAMETER TargetLocation
  Azure region for the restored resources (e.g. "westeurope", "eastus").

.PARAMETER NewLogicAppName
  Optional new name for the restored Logic App. Defaults to the original name.

.PARAMETER SkipConnections
  Skip re-creating API connections. Use when connections already exist in the
  target resource group.

.NOTES
  References:
  - Microsoft.Logic/workflows ARM template:
    https://learn.microsoft.com/azure/templates/microsoft.logic/workflows
  - Microsoft.Web/connections ARM template:
    https://learn.microsoft.com/azure/templates/microsoft.web/connections
  - Managed connector APIs by region:
    https://learn.microsoft.com/connectors/connector-reference/connector-reference-logicapps-connectors
  - az rest:
    https://learn.microsoft.com/cli/azure/reference-index?view=azure-cli-latest#az-rest
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]  [string]$BackupSource,
  [Parameter(Mandatory=$false)] [string]$SourceStorageAccount,
  [Parameter(Mandatory=$false)] [string]$SourceStorageContainer = "config-docs",
  [Parameter(Mandatory=$false)] [string]$SourceStorageSubscription,
  [Parameter(Mandatory=$true)]  [string]$TargetSubscriptionId,
  [Parameter(Mandatory=$true)]  [string]$TargetResourceGroup,
  [Parameter(Mandatory=$true)]  [string]$TargetLocation,
  [Parameter(Mandatory=$false)] [string]$NewLogicAppName,
  [switch]$SkipConnections
)

# -- Helpers -------------------------------------------------------------------

function Update-SubscriptionInResourceId {
  param(
    [string]$ResourceId,
    [string]$NewSubscriptionId
  )
  if (-not $ResourceId) { return $ResourceId }
  $ResourceId -replace '/subscriptions/[^/]+/', "/subscriptions/$NewSubscriptionId/"
}

function Update-ResourceGroupInResourceId {
  param(
    [string]$ResourceId,
    [string]$NewResourceGroup
  )
  if (-not $ResourceId) { return $ResourceId }
  $ResourceId -replace '/resourceGroups/[^/]+/', "/resourceGroups/$NewResourceGroup/"
}

function Update-LocationInManagedApiId {
  param(
    [string]$ApiId,
    [string]$NewLocation
  )
  if (-not $ApiId) { return $ApiId }
  $ApiId -replace '/locations/[^/]+/', "/locations/$NewLocation/"
}

function Extract-RawJsonValue {
  <#
  .SYNOPSIS
    Extracts a raw JSON object value for a given property name from a JSON string.
    This preserves array structures that PS 5.1 ConvertFrom-Json would flatten
    (e.g. runAfter: {"Set_Feed_URL": ["Succeeded"]} stays as an array).
  #>
  param(
    [Parameter(Mandatory=$true)][string]$JsonString,
    [Parameter(Mandatory=$true)][string]$PropertyName
  )
  $pattern = '"' + [regex]::Escape($PropertyName) + '"\s*:\s*'
  $match = [regex]::Match($JsonString, $pattern)
  if (-not $match.Success) { return $null }

  $startIdx = $match.Index + $match.Length
  while ($startIdx -lt $JsonString.Length -and [char]::IsWhiteSpace($JsonString[$startIdx])) { $startIdx++ }
  if ($JsonString[$startIdx] -ne '{') { return $null }

  $depth = 0
  $inString = $false
  $escape = $false
  for ($i = $startIdx; $i -lt $JsonString.Length; $i++) {
    $c = $JsonString[$i]
    if ($escape) { $escape = $false; continue }
    if ($c -eq [char]'\' -and $inString) { $escape = $true; continue }
    if ($c -eq [char]'"') { $inString = -not $inString; continue }
    if ($inString) { continue }
    if ($c -eq [char]'{') { $depth++ }
    elseif ($c -eq [char]'}') {
      $depth--
      if ($depth -eq 0) { return $JsonString.Substring($startIdx, $i - $startIdx + 1) }
    }
  }
  return $null
}

# -- Main ----------------------------------------------------------------------

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop | Out-Null

# -- Step 1: Load backup JSON -------------------------------------------------

Write-Host "`n[1/4] Loading backup JSON..." -ForegroundColor Cyan

if (Test-Path $BackupSource -ErrorAction SilentlyContinue) {
  Write-Host "  Reading local file: $BackupSource" -ForegroundColor DarkGray
  $backupJson = Get-Content $BackupSource -Raw -ErrorAction Stop
}
else {
  if (-not $SourceStorageAccount -or -not $SourceStorageSubscription) {
    throw "BackupSource is not a local file. You must provide -SourceStorageAccount and -SourceStorageSubscription."
  }
  Write-Host "  Downloading from blob: $SourceStorageAccount/$SourceStorageContainer/$BackupSource" -ForegroundColor DarkGray

  Set-AzContext -Subscription $SourceStorageSubscription -ErrorAction Stop | Out-Null
  $ctx = New-AzStorageContext -StorageAccountName $SourceStorageAccount -UseConnectedAccount
  $tempFile = Join-Path $env:TEMP ("restore-" + [guid]::NewGuid() + ".json")
  Get-AzStorageBlobContent -Context $ctx -Container $SourceStorageContainer -Blob $BackupSource -Destination $tempFile -Force | Out-Null
  $backupJson = Get-Content $tempFile -Raw -ErrorAction Stop
}

$backup = $backupJson | ConvertFrom-Json -ErrorAction Stop

$originalName = $backup.name
$restoreName  = if ($NewLogicAppName) { $NewLogicAppName } else { "$originalName-dr" }
$originalSubId = $backup.subscriptionId

Write-Host "  Original Logic App : $originalName" -ForegroundColor Green
Write-Host "  Original region    : $($backup.location)" -ForegroundColor Green
Write-Host "  Restore as         : $restoreName" -ForegroundColor Green
Write-Host "  Target region      : $TargetLocation" -ForegroundColor Green
Write-Host "  Target RG          : $TargetResourceGroup" -ForegroundColor Green

# Resolve target subscription ID
Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop | Out-Null
$resolvedSubId = (Get-AzContext).Subscription.Id

# -- Step 2: Re-create API connections -----------------------------------------

Write-Host "`n[2/4] Restoring API connections..." -ForegroundColor Cyan

$connectionMap = @{}

if ($backup.apiConnections) {
  $apiConns = @($backup.apiConnections)

  if ($SkipConnections) {
    Write-Host "  -SkipConnections specified. Assuming connections already exist." -ForegroundColor Yellow
    foreach ($conn in $apiConns) {
      if (-not $conn.connectionKey) { continue }
      $newConnId = "/subscriptions/$resolvedSubId/resourceGroups/$TargetResourceGroup/providers/Microsoft.Web/connections/$($conn.connectionName)"
      $connectionMap[$conn.connectionKey] = @{
        connectionId   = $newConnId
        connectionName = $conn.connectionName
        id             = Update-LocationInManagedApiId -ApiId $conn.apiId -NewLocation $TargetLocation
      }
      Write-Host "    Mapped: $($conn.connectionKey) -> $($conn.connectionName) (existing)" -ForegroundColor DarkGray
    }
  }
  else {
    foreach ($conn in $apiConns) {
      if (-not $conn.connectionKey) { continue }
      if ($conn.error) {
        Write-Warning "  Skipping connection '$($conn.connectionKey)' -- backup had error: $($conn.error)"
        continue
      }

      $connName = $conn.connectionName
      $managedApiName = ($conn.apiId -split '/')[-1]
      $newApiId = "/subscriptions/$resolvedSubId/providers/Microsoft.Web/locations/$TargetLocation/managedApis/$managedApiName"

      Write-Host "  Creating connection: $connName ($managedApiName) in $TargetLocation ..." -ForegroundColor Yellow

      $connResourceId = "/subscriptions/$resolvedSubId/resourceGroups/$TargetResourceGroup/providers/Microsoft.Web/connections/$connName"
      $connBody = @{
        location   = $TargetLocation
        properties = @{
          displayName = if ($conn.displayName) { $conn.displayName } else { $connName }
          api         = @{
            id = $newApiId
          }
        }
      } | ConvertTo-Json -Depth 10

      # Write body to temp file to avoid PS 5.1 quoting issues with az rest --body
      $connBodyFile = Join-Path $env:TEMP ("restore-conn-" + [guid]::NewGuid() + ".json")
      $connBody | Set-Content -Path $connBodyFile -Encoding UTF8

      $connUri = "https://management.azure.com${connResourceId}?api-version=2016-06-01"
      az rest --method PUT --uri $connUri --body "@$connBodyFile" --output none 2>&1 | Out-Null

      # Verify
      $verifyQuery = 'properties.statuses[0].status'
      $verify = az rest --method GET --uri $connUri --query $verifyQuery -o tsv 2>$null
      if ($verify) {
        Write-Host "    Created: $connName (status: $verify)" -ForegroundColor Green
      }
      else {
        Write-Host "    Created: $connName" -ForegroundColor Green
      }

      $connectionMap[$conn.connectionKey] = @{
        connectionId   = $connResourceId
        connectionName = $connName
        id             = $newApiId
      }
    }
  }
}
else {
  Write-Host "  No API connections to restore." -ForegroundColor DarkGray
}

# -- Step 3: Prepare and deploy the Logic App ----------------------------------

Write-Host "`n[3/4] Deploying Logic App: $restoreName ..." -ForegroundColor Cyan

# Build the $connections parameter value from the connection map
$connectionsValue = @{}
foreach ($key in $connectionMap.Keys) {
  $connectionsValue[$key] = $connectionMap[$key]
}

# Extract the raw definition JSON from the backup file to preserve array
# structures. PS 5.1 ConvertFrom-Json flattens single-element arrays like
# ["Succeeded"] to scalar strings, which the ARM API rejects.
$rawDefinition = Extract-RawJsonValue -JsonString $backupJson -PropertyName 'definition'
if (-not $rawDefinition) {
  throw "Could not extract 'definition' from backup JSON."
}
Write-Host "  Extracted raw definition JSON ($($rawDefinition.Length) chars)" -ForegroundColor DarkGray

# Use a placeholder for definition so we can inject raw JSON later
$definitionPlaceholder = '@@RAW_DEFINITION_PLACEHOLDER@@'

$workflowBody = [ordered]@{
  location   = $TargetLocation
  properties = [ordered]@{
    state      = 'Enabled'
    definition = $definitionPlaceholder
    parameters = [ordered]@{}
  }
}

# Add $connections parameter if we have any
if ($connectionsValue.Count -gt 0) {
  $workflowBody.properties.parameters['$connections'] = @{
    value = $connectionsValue
  }
}

# Preserve tags if present
if ($backup.tags) {
  $workflowBody['tags'] = $backup.tags
}

# Preserve integration account reference (update sub/RG/location)
if ($backup.integrationAccount -and $backup.integrationAccount.id) {
  $newIaId = Update-SubscriptionInResourceId -ResourceId $backup.integrationAccount.id -NewSubscriptionId $resolvedSubId
  $newIaId = Update-ResourceGroupInResourceId -ResourceId $newIaId -NewResourceGroup $TargetResourceGroup
  $workflowBody.properties['integrationAccount'] = @{ id = $newIaId }
  Write-Host "  Integration account ref: $newIaId" -ForegroundColor DarkGray
}

# Deploy via ARM REST API
$workflowResourceId = "/subscriptions/$resolvedSubId/resourceGroups/$TargetResourceGroup/providers/Microsoft.Logic/workflows/$restoreName"
$workflowUri = "https://management.azure.com${workflowResourceId}?api-version=2019-05-01"
$workflowJsonFile = Join-Path $env:TEMP ("restore-workflow-" + [guid]::NewGuid() + ".json")

# Serialize body, then replace placeholder with raw definition JSON
$bodyJson = $workflowBody | ConvertTo-Json -Depth 30
$bodyJson = $bodyJson.Replace('"' + $definitionPlaceholder + '"', $rawDefinition)
$bodyJson | Set-Content -Path $workflowJsonFile -Encoding UTF8

Write-Host "  Sending PUT to ARM..." -ForegroundColor DarkGray
$jmesQuery = '{name:name, state:properties.state, location:location}'
$result = az rest --method PUT --uri $workflowUri --body "@$workflowJsonFile" --query $jmesQuery -o json 2>&1

if ($LASTEXITCODE -ne 0) {
  Write-Error "Failed to deploy Logic App. ARM response:`n$result"
  return
}

$deployed = $result | ConvertFrom-Json
Write-Host "  Deployed: $($deployed.name) | State: $($deployed.state) | Location: $($deployed.location)" -ForegroundColor Green

# -- Step 4: Validate ----------------------------------------------------------

Write-Host "`n[4/4] Validating restored Logic App..." -ForegroundColor Cyan

$triggerUri = "https://management.azure.com${workflowResourceId}/triggers?api-version=2016-06-01"
$triggerJmesQuery = 'value[].{name:name, typeName:properties.type}'
$triggersResult = az rest --method GET --uri $triggerUri --query $triggerJmesQuery -o json 2>$null
$triggers = $triggersResult | ConvertFrom-Json

if ($triggers) {
  Write-Host "  Triggers:" -ForegroundColor DarkGray
  foreach ($t in $triggers) {
    Write-Host "    - $($t.name) ($($t.typeName))" -ForegroundColor DarkCyan

    try {
      $cbUri = "https://management.azure.com${workflowResourceId}/triggers/$($t.name)/listCallbackUrl?api-version=2016-06-01"
      $cbResult = az rest --method POST --uri $cbUri --query "value" -o tsv 2>$null
      if ($cbResult -and $LASTEXITCODE -eq 0) {
        Write-Host "      Callback URL: $cbResult" -ForegroundColor DarkGray
      }
    }
    catch { }
  }
}

# Summary
$separator = "=" * 40
Write-Host ""
Write-Host $separator -ForegroundColor Green
Write-Host "Restore completed successfully." -ForegroundColor Green
Write-Host "  Logic App           : $restoreName" -ForegroundColor Cyan
Write-Host "  Subscription        : $resolvedSubId" -ForegroundColor Cyan
Write-Host "  Resource Group      : $TargetResourceGroup" -ForegroundColor Cyan
Write-Host "  Location            : $TargetLocation" -ForegroundColor Cyan
Write-Host "  API Connections     : $($connectionMap.Count)" -ForegroundColor Cyan
Write-Host "  Original backup from: $($backup.backupTimestamp)" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Green
