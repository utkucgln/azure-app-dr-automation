<#
.SYNOPSIS
  Backs up ALL Logic Apps (Consumption AND Standard) in a source subscription to a
  Storage account (Blob container) that lives in a *different* subscription.

.DESCRIPTION
  For each Consumption Logic App (Microsoft.Logic/workflows) the script exports:
  - Full workflow definition (triggers, actions, parameters schema, outputs).
  - Workflow parameters (non-secret values; Key Vault references are preserved as-is).
  - API connection resources (Microsoft.Web/connections) referenced by the workflow.
  - Integration account reference (if any).
  - Managed identity configuration.
  - Run history summary (latest N runs with status, start/end times, error info).
  - Tags, location, SKU, state, access control (IP restrictions).

  For each Standard Logic App (Microsoft.Web/sites, kind=workflowapp) the script exports:
  - All workflow definitions (a Standard app can host multiple workflows).
  - App settings (non-secret connection strings and configuration).
  - Managed identity configuration.
  - App Service Plan details.
  - Site properties (state, default hostname, HTTPS-only, runtime, etc.).
  - Run history summary per workflow.

  All artifacts are uploaded as JSON blobs to the target Storage account container.

.PARAMETER SourceSubscriptionId
  Subscription that hosts the Logic Apps.

.PARAMETER TargetSubscriptionId
  Subscription that hosts the backup Storage account.

.PARAMETER TargetResourceGroup
  Resource group of the backup Storage account.

.PARAMETER TargetStorageAccount
  Name of the backup Storage account.

.PARAMETER TargetContainer
  Name of the blob container (will be created if missing).

.PARAMETER RunHistoryCount
  Number of recent run-history entries to include per Logic App. Default: 10.

.PARAMETER IncludeDisabled
  Include Logic Apps that are in Disabled/Suspended state. Default: $false.

.NOTES
  Azure Logic Apps REST API & PowerShell references:
  - Logic Apps overview:
    https://learn.microsoft.com/azure/logic-apps/logic-apps-overview
  - ARM resource type Microsoft.Logic/workflows:
    https://learn.microsoft.com/azure/templates/microsoft.logic/workflows
  - Get-AzLogicApp:
    https://learn.microsoft.com/powershell/module/az.logicapp/get-azlogicapp
  - Get-AzLogicAppRunHistory:
    https://learn.microsoft.com/powershell/module/az.logicapp/get-azlogicapprunhistory
  - API Connections (Microsoft.Web/connections):
    https://learn.microsoft.com/azure/logic-apps/logic-apps-deploy-azure-resource-manager-templates#connection-resource-definitions
  - Managed connectors reference:
    https://learn.microsoft.com/connectors/connector-reference/connector-reference-logicapps-connectors
  - Standard Logic Apps (single-tenant):
    https://learn.microsoft.com/azure/logic-apps/single-tenant-overview-compare
  - List workflows (Standard):
    https://learn.microsoft.com/rest/api/appservice/workflow-runs/list
  - Get-AzWebApp:
    https://learn.microsoft.com/powershell/module/az.websites/get-azwebapp
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]  [string]$SourceSubscriptionId,
  [Parameter(Mandatory=$true)]  [string]$TargetSubscriptionId,
  [Parameter(Mandatory=$true)]  [string]$TargetResourceGroup,
  [Parameter(Mandatory=$true)]  [string]$TargetStorageAccount,
  [Parameter(Mandatory=$true)]  [string]$TargetContainer,
  [Parameter(Mandatory=$false)] [int]$RunHistoryCount = 10,
  [Parameter(Mandatory=$false)] [ValidateSet('Both','Consumption','Standard')] [string]$Plan = 'Both',
  [switch]$IncludeDisabled
)

#region Helpers

function ConvertFrom-JToken {
  <#
  .SYNOPSIS
    Recursively converts a Newtonsoft.Json.Linq.JToken (JObject, JArray, JValue)
    into native PowerShell types (ordered hashtable, array, string/int/bool/null)
    so that ConvertTo-Json serialises them correctly.
  .NOTES
    Get-AzLogicApp returns Definition and Parameters.$connections.Value as JObject.
    PowerShell 5.1's ConvertTo-Json treats JObject as IEnumerable and produces
    corrupted nested arrays instead of the original JSON structure.
  #>
  param([Parameter(Mandatory=$true)]$Token)

  if ($Token -is [Newtonsoft.Json.Linq.JObject]) {
    $ht = [ordered]@{}
    foreach ($prop in $Token.Properties()) {
      $ht[$prop.Name] = ConvertFrom-JToken $prop.Value
    }
    return $ht
  }
  elseif ($Token -is [Newtonsoft.Json.Linq.JArray]) {
    $arr = @()
    foreach ($item in $Token) {
      $arr += , (ConvertFrom-JToken $item)
    }
    return $arr
  }
  elseif ($Token -is [Newtonsoft.Json.Linq.JValue]) {
    return $Token.Value   # string, int, bool, or $null
  }
  else {
    return $Token
  }
}

function Ensure-Container {
  <#
  .SYNOPSIS
    Ensures a blob container exists in the given Storage account; creates it if missing.
    Uses OAuth (Azure AD) authentication so the script works when shared-key access is disabled.
  .NOTES
    https://learn.microsoft.com/powershell/module/az.storage/new-azstoragecontainer
  #>
  param(
    [Parameter(Mandatory=$true)] [string]$StorageAccountName,
    [Parameter(Mandatory=$true)] [string]$Container
  )
  # Create an OAuth-based storage context (works even when allowSharedKeyAccess=false)
  $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
  $exists = Get-AzStorageContainer -Context $ctx -Name $Container -ErrorAction SilentlyContinue
  if (-not $exists) {
    New-AzStorageContainer -Context $ctx -Name $Container -Permission Off | Out-Null
    Write-Host "  Created blob container '$Container'." -ForegroundColor DarkGray
  }
  return $ctx
}

function Export-LogicAppConfig {
  <#
  .SYNOPSIS
    Exports the full Consumption Logic App resource as a structured object for JSON backup.
  .DESCRIPTION
    Uses Get-AzLogicApp to retrieve the full resource definition including:
    - Workflow definition (triggers, actions, expressions, parameters schema)
    - Workflow parameters (runtime values — secrets show as Key Vault refs or null)
    - State (Enabled / Disabled / Suspended)
    - SKU, access control, integration account reference
    - Managed identity (system / user assigned)
    - Tags, location
  .NOTES
    https://learn.microsoft.com/powershell/module/az.logicapp/get-azlogicapp
  #>
  param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AppName
  )

  $app = Get-AzLogicApp -ResourceGroupName $ResourceGroupName -Name $AppName -ErrorAction Stop

  $export = [ordered]@{
    backupTimestamp      = (Get-Date).ToString("o")
    subscriptionId       = (Get-AzContext).Subscription.Id
    resourceGroup        = $ResourceGroupName
    name                 = $app.Name
    id                   = $app.Id
    location             = $app.Location
    tags                 = $app.Tags
    state                = $app.State          # Enabled | Disabled | Suspended
    sku                  = $app.Sku
    version              = $app.Version
    createdTime          = $app.CreatedTime
    changedTime          = $app.ChangedTime
    accessEndpoint       = $app.AccessEndpoint  # The HTTP trigger base URL (if any)

    # Identity
    identity = [ordered]@{
      type                   = $app.Identity.Type
      principalId            = $app.Identity.PrincipalId
      tenantId               = $app.Identity.TenantId
      userAssignedIdentities = $app.Identity.UserAssignedIdentities
    }

    # Integration Account (if linked)
    integrationAccount = [ordered]@{
      id   = $app.IntegrationAccount.Id
      name = $app.IntegrationAccount.Name
    }

    # Access control / IP restrictions
    accessControl = $app.AccessControl

    # Workflow definition — the full trigger/action graph
    # Convert from JObject to native PS types for summary/analysis
    definition = if ($app.Definition -is [Newtonsoft.Json.Linq.JObject]) {
      ConvertFrom-JToken $app.Definition
    } else { $app.Definition }

    # Raw definition JSON string -- preserves array structures that PS 5.1
    # ConvertTo-Json would flatten (e.g. runAfter: ["Succeeded"]).
    # This will be spliced into the backup file as-is.
    rawDefinitionJson = if ($app.Definition -is [Newtonsoft.Json.Linq.JObject]) {
      $app.Definition.ToString()
    } else { $null }

    # Workflow parameters — runtime values (secret values will be null/redacted)
    # Convert WorkflowParameter dictionary with JObject values
    parameters = $(
      $paramOut = [ordered]@{}
      if ($app.Parameters) {
        foreach ($pk in $app.Parameters.Keys) {
          $wp = $app.Parameters[$pk]
          $paramOut[$pk] = [ordered]@{
            type  = $wp.Type
            value = if ($wp.Value -is [Newtonsoft.Json.Linq.JToken]) {
              ConvertFrom-JToken $wp.Value
            } else { $wp.Value }
          }
        }
      }
      $paramOut
    )
  }

  return $export
}

function Export-ApiConnections {
  <#
  .SYNOPSIS
    Finds and exports all API connection resources (Microsoft.Web/connections)
    referenced by a Logic App workflow definition.
  .DESCRIPTION
    Scans the workflow's $connections parameter for connection references, then
    retrieves each Microsoft.Web/connections resource from the same resource group.
    Exports: display name, API reference, connection status, parameter set names
    (NOT secret values — those require list action which is connector-specific).
  .NOTES
    https://learn.microsoft.com/azure/logic-apps/logic-apps-deploy-azure-resource-manager-templates#connection-resource-definitions
    https://learn.microsoft.com/rest/api/logic/workflows
  #>
  param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)]$WorkflowParameters   # Dictionary<string, WorkflowParameter> or hashtable
  )

  $connections = @()

  # The $connections parameter holds the map of connection names -> resourceId
  if (-not $WorkflowParameters.Contains('$connections')) {
    return $connections
  }

  $connParam = $WorkflowParameters['$connections']
  $connValue = $connParam.Value
  if (-not $connValue) { return $connections }

  # The Value may be a Newtonsoft.Json.Linq.JObject (from Az.LogicApp) rather than
  # a plain hashtable.  Normalise to hashtable so that .Keys and indexer access
  # work uniformly.  (-AsHashtable is PS7+, so we do manual conversion.)
  if ($connValue -is [Newtonsoft.Json.Linq.JObject]) {
    $tmp = @{}
    foreach ($prop in $connValue.Properties()) {
      $inner = @{}
      foreach ($ip in $prop.Value.Properties()) {
        $inner[$ip.Name] = $ip.Value.ToString()
      }
      $tmp[$prop.Name] = $inner
    }
    $connValue = $tmp
  }
  elseif ($connValue -is [System.Collections.IDictionary] -and $connValue -isnot [hashtable]) {
    # OrderedDictionary (from ConvertFrom-JToken) — normalise to plain hashtable
    $tmp = @{}
    foreach ($k in $connValue.Keys) { $tmp[$k] = $connValue[$k] }
    $connValue = $tmp
  }
  elseif ($connValue -isnot [System.Collections.IDictionary]) {
    # PSCustomObject from ConvertFrom-Json (without -AsHashtable)
    $tmp = @{}
    foreach ($p in $connValue.PSObject.Properties) { $tmp[$p.Name] = $p.Value }
    $connValue = $tmp
  }

  foreach ($key in $connValue.Keys) {
    $connRef = $connValue[$key]
    # Use indexer syntax — dot notation is unreliable on OrderedDictionary in PS 5.1
    $connName = if ($connRef -is [System.Collections.IDictionary]) { $connRef['connectionName'] } else { $connRef.connectionName }
    if (-not $connName) { $connName = $key }

    try {
      # Retrieve the Microsoft.Web/connections resource
      # https://learn.microsoft.com/powershell/module/az.resources/get-azresource
      $connResource = Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType "Microsoft.Web/connections" `
        -Name $connName `
        -ExpandProperties -ErrorAction Stop

      $connections += [ordered]@{
        connectionKey    = $key
        connectionName   = $connResource.Name
        resourceId       = $connResource.ResourceId
        location         = $connResource.Location
        displayName      = $connResource.Properties.displayName
        apiDisplayName   = $connResource.Properties.api.displayName
        apiId            = $connResource.Properties.api.id
        apiType          = $connResource.Properties.api.type
        statuses         = $connResource.Properties.statuses
        createdTime      = $connResource.Properties.createdTime
        changedTime      = $connResource.Properties.changedTime
        parameterSetName = $connResource.Properties.parameterSetName
        # Non-OAuth connection parameter names only (not values — those are secret)
        nonSecretParameterNames = @(
          if ($connResource.Properties.nonSecretParameterValues) {
            $connResource.Properties.nonSecretParameterValues.PSObject.Properties.Name
          }
        )
      }

      Write-Host "    Found API connection: $connName ($($connResource.Properties.api.displayName))" -ForegroundColor DarkCyan
    }
    catch {
      Write-Warning "    Could not retrieve connection '$connName': $($_.Exception.Message)"
      $connections += [ordered]@{
        connectionKey  = $key
        connectionName = $connName
        resourceId     = if ($connRef -is [System.Collections.IDictionary]) { $connRef['connectionId'] } else { $connRef.connectionId }
        error          = $_.Exception.Message
      }
    }
  }

  return $connections
}

function Export-RunHistory {
  <#
  .SYNOPSIS
    Exports the most recent N run-history entries for a Logic App.
  .DESCRIPTION
    Retrieves run metadata including status, start/end times, trigger info, and
    error details for failed runs. Does NOT include action-level detail (use
    Get-AzLogicAppRunAction for deeper diagnostics if needed).
  .NOTES
    https://learn.microsoft.com/powershell/module/az.logicapp/get-azlogicapprunhistory
  #>
  param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AppName,
    [Parameter(Mandatory=$false)][int]$Top = 10
  )

  try {
    $runs = Get-AzLogicAppRunHistory -ResourceGroupName $ResourceGroupName -Name $AppName -ErrorAction Stop |
            Sort-Object StartTime -Descending |
            Select-Object -First $Top

    return @($runs | ForEach-Object {
      [ordered]@{
        runName    = $_.Name
        status     = $_.Status        # Succeeded | Failed | Cancelled | Running
        startTime  = $_.StartTime
        endTime    = $_.EndTime
        triggerName = $_.Trigger.Name
        error      = $_.Error
        correlation = $_.Correlation
      }
    })
  }
  catch {
    Write-Warning "    Could not retrieve run history: $($_.Exception.Message)"
    return @()
  }
}

function Export-TriggerCallbackUrl {
  <#
  .SYNOPSIS
    Retrieves the callback URL for HTTP Request triggers (if present).
  .DESCRIPTION
    For Logic Apps with an HTTP Request trigger (kind=Http), the callback URL
    is the endpoint external systems use to invoke the workflow.
  .NOTES
    https://learn.microsoft.com/powershell/module/az.logicapp/get-azlogicapptrigger
    https://learn.microsoft.com/powershell/module/az.logicapp/get-azlogicapptriggercallbackurl
  #>
  param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AppName
  )

  $triggers = @{}
  try {
    $triggerList = Get-AzLogicAppTrigger -ResourceGroupName $ResourceGroupName -Name $AppName -ErrorAction Stop

    foreach ($t in $triggerList) {
      $triggerInfo = [ordered]@{
        name        = $t.Name
        type        = $t.Type
        state       = $t.State
        lastFired   = $t.LastExecutionTime
        nextFire    = $t.NextExecutionTime
        recurrence  = $t.Recurrence
        callbackUrl = $null
      }

      # Try to get callback URL (only works for Request/Webhook triggers)
      try {
        $cb = Get-AzLogicAppTriggerCallbackUrl -ResourceGroupName $ResourceGroupName `
          -Name $AppName -TriggerName $t.Name -ErrorAction Stop
        $triggerInfo.callbackUrl = $cb.Value
      }
      catch {
        # Not all trigger types support callback URLs - that's expected
      }

      $triggers[$t.Name] = $triggerInfo
    }
  }
  catch {
    Write-Warning "    Could not retrieve triggers: $($_.Exception.Message)"
  }

  return $triggers
}

function Export-StandardLogicAppConfig {
  <#
  .SYNOPSIS
    Exports a Standard Logic App (Microsoft.Web/sites, kind=workflowapp) as a
    structured object for JSON backup.
  .DESCRIPTION
    Uses Get-AzWebApp and the ARM REST API to retrieve:
    - Site properties (state, hostname, HTTPS, runtime version)
    - App settings (non-secret)
    - Managed identity
    - App Service Plan details
    - All hosted workflow definitions via ARM management API
    - Run history per workflow
  .NOTES
    https://learn.microsoft.com/azure/logic-apps/single-tenant-overview-compare
    https://learn.microsoft.com/powershell/module/az.websites/get-azwebapp
  #>
  param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AppName,
    [Parameter(Mandatory=$false)][int]$RunHistoryTop = 10
  )

  $app = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $AppName -ErrorAction Stop

  # Build app settings hashtable (exclude secrets like connection strings)
  $appSettings = [ordered]@{}
  if ($app.SiteConfig.AppSettings) {
    foreach ($s in $app.SiteConfig.AppSettings) {
      # Exclude settings that contain keys/passwords
      if ($s.Name -match 'KEY|SECRET|PASSWORD|CONNECTIONSTRING' -and $s.Name -notmatch 'FUNCTIONS_EXTENSION|AzureFunctionsJobHost|APP_KIND|WEBSITE_NODE|FUNCTIONS_WORKER') {
        $appSettings[$s.Name] = '*** REDACTED ***'
      } else {
        $appSettings[$s.Name] = $s.Value
      }
    }
  }

  # Determine state from app properties
  $siteState = if ($app.State) { $app.State } else { 'Unknown' }  # Running | Stopped

  $export = [ordered]@{
    backupTimestamp      = (Get-Date).ToString("o")
    subscriptionId       = (Get-AzContext).Subscription.Id
    resourceGroup        = $ResourceGroupName
    name                 = $app.Name
    id                   = $app.Id
    type                 = 'Standard'  # distinguish from Consumption
    location             = $app.Location
    tags                 = $app.Tags
    state                = $siteState
    defaultHostName      = $app.DefaultHostName
    httpsOnly            = $app.HttpsOnly
    kind                 = $app.Kind

    # Identity
    identity = [ordered]@{
      type                   = $app.Identity.Type
      principalId            = $app.Identity.PrincipalId
      tenantId               = $app.Identity.TenantId
      userAssignedIdentities = $app.Identity.UserAssignedIdentities
    }

    # App Service Plan
    appServicePlan = $app.ServerFarmId

    # Runtime / framework
    runtime = [ordered]@{
      netFrameworkVersion   = $app.SiteConfig.NetFrameworkVersion
      nodeVersion           = $app.SiteConfig.NodeVersion
      functionsExtVersion   = ($app.SiteConfig.AppSettings | Where-Object { $_.Name -eq 'FUNCTIONS_EXTENSION_VERSION' }).Value
      workerRuntime         = ($app.SiteConfig.AppSettings | Where-Object { $_.Name -eq 'FUNCTIONS_WORKER_RUNTIME' }).Value
    }

    # App settings (redacted)
    appSettings = $appSettings

    # Workflows will be populated below
    workflows = [ordered]@{}
  }

  # ── Retrieve workflows via ARM REST API ──
  # Standard Logic Apps host workflows under Microsoft.Web/sites/workflows
  # Use Invoke-AzRestMethod which handles authentication automatically
  $ctx = Get-AzContext
  $subId = $ctx.Subscription.Id
  $apiVersion = '2024-04-01'
  $listPath = "/subscriptions/$subId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$AppName/workflows?api-version=$apiVersion"

  try {
    $wfResponse = Invoke-AzRestMethod -Path $listPath -Method GET -ErrorAction Stop
    if ($wfResponse.StatusCode -ne 200) {
      throw "API returned status $($wfResponse.StatusCode): $($wfResponse.Content)"
    }
    $wfContent = $wfResponse.Content | ConvertFrom-Json
    $workflowList = @($wfContent.value)
    Write-Host "    Found $($workflowList.Count) workflow(s) in Standard Logic App." -ForegroundColor DarkCyan

    foreach ($wf in $workflowList) {
      $wfName = $wf.name
      # The name comes as "siteName/workflowName" — extract just the workflow part
      if ($wfName -match '/') {
        $wfName = ($wfName -split '/')[-1]
      }

      $wfExport = [ordered]@{
        name       = $wfName
        id         = $wf.id
        type       = $wf.type
        kind       = $wf.kind   # Stateful | Stateless
        state      = $wf.properties.flowState
        health     = $wf.properties.health
        definition = $wf.properties.definition
        createdTime = $wf.properties.createdTime
        changedTime = $wf.properties.changedTime
      }

      # ── Run history for this workflow via ARM ──
      $runsPath = "/subscriptions/$subId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$AppName/hostruntime/runtime/webhooks/workflow/api/management/workflows/$wfName/runs?api-version=$apiVersion&`$top=$RunHistoryTop"
      try {
        $runsResponse = Invoke-AzRestMethod -Path $runsPath -Method GET -ErrorAction Stop
        if ($runsResponse.StatusCode -eq 200) {
          $runsContent = $runsResponse.Content | ConvertFrom-Json
          $wfExport['runHistory'] = @($runsContent.value | ForEach-Object {
            [ordered]@{
              runName   = $_.name
              status    = $_.properties.status
              startTime = $_.properties.startTime
              endTime   = $_.properties.endTime
              error     = $_.properties.error
            }
          })
        } else {
          Write-Warning "      Run history API returned status $($runsResponse.StatusCode) for workflow '$wfName'"
          $wfExport['runHistory'] = @()
        }
      }
      catch {
        Write-Warning "      Could not retrieve run history for workflow '$wfName': $($_.Exception.Message)"
        $wfExport['runHistory'] = @()
      }

      $export.workflows[$wfName] = $wfExport
    }
  }
  catch {
    Write-Warning "    Could not list workflows: $($_.Exception.Message)"
  }

  # Summary
  $allActions = @()
  foreach ($wfKey in $export.workflows.Keys) {
    $wfDef = $export.workflows[$wfKey].definition
    if ($wfDef -and $wfDef.actions) {
      if ($wfDef.actions -is [System.Collections.IDictionary]) {
        foreach ($aKey in $wfDef.actions.Keys) { $allActions += $wfDef.actions[$aKey].type }
      }
      elseif ($wfDef.actions.PSObject -and $wfDef.actions.PSObject.Properties) {
        foreach ($prop in $wfDef.actions.PSObject.Properties) { $allActions += $prop.Value.type }
      }
    }
  }
  $allActions = @($allActions | Select-Object -Unique)

  $export['summary'] = [ordered]@{
    workflowCount  = $export.workflows.Count
    actionTypes    = $allActions
    actionCount    = $allActions.Count
  }

  return $export
}

#endregion Helpers

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop | Out-Null

# Source: list Logic Apps
Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction Stop | Out-Null

# ── Consumption Logic Apps ──
if ($Plan -eq 'Both' -or $Plan -eq 'Consumption') {
  Write-Host "Enumerating Logic Apps (Consumption) in subscription $SourceSubscriptionId ..." -ForegroundColor Cyan
  # Get-AzLogicApp returns all Microsoft.Logic/workflows in the subscription
  # https://learn.microsoft.com/powershell/module/az.logicapp/get-azlogicapp
  $logicApps = Get-AzLogicApp -ErrorAction SilentlyContinue
  if (-not $logicApps) { $logicApps = @() }

  if (-not $IncludeDisabled) {
    $logicApps = @($logicApps | Where-Object { $_.State -eq 'Enabled' })
  }

  Write-Host "Found $($logicApps.Count) Consumption Logic App(s)." -ForegroundColor Cyan
} else {
  $logicApps = @()
  Write-Host "Skipping Consumption Logic Apps (Plan=$Plan)." -ForegroundColor DarkGray
}

# ── Standard Logic Apps ──
if ($Plan -eq 'Both' -or $Plan -eq 'Standard') {
  Write-Host "Enumerating Logic Apps (Standard) in subscription $SourceSubscriptionId ..." -ForegroundColor Cyan
  # Standard Logic Apps are Microsoft.Web/sites with kind containing 'workflowapp'
  $allWebApps = Get-AzWebApp -ErrorAction SilentlyContinue
  $standardLogicApps = @($allWebApps | Where-Object { $_.Kind -and $_.Kind -match 'workflowapp' })

  if (-not $IncludeDisabled) {
    $standardLogicApps = @($standardLogicApps | Where-Object { $_.State -eq 'Running' })
  }

  Write-Host "Found $($standardLogicApps.Count) Standard Logic App(s)." -ForegroundColor Cyan
} else {
  $standardLogicApps = @()
  Write-Host "Skipping Standard Logic Apps (Plan=$Plan)." -ForegroundColor DarkGray
}

$totalCount = $logicApps.Count + $standardLogicApps.Count
if ($totalCount -eq 0) {
  Write-Warning "No Logic Apps found in subscription $SourceSubscriptionId."
  return
}

Write-Host "Total Logic Apps to back up: $totalCount" -ForegroundColor Cyan

# Target: storage context (OAuth-based — works when shared-key access is disabled)
Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop | Out-Null
$targetCtx = Ensure-Container -StorageAccountName $TargetStorageAccount -Container $TargetContainer

# Switch back to source for per-app export operations
Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction Stop | Out-Null

$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$tempRoot  = Join-Path $env:TEMP ("logicapp-backups-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null

$report = @()

foreach ($la in $logicApps) {
  try {
    # Extract RG from resource ID:  /subscriptions/.../resourceGroups/<RG>/providers/...
    $rgName  = ($la.Id -split '/')[4]
    $appName = $la.Name

    Write-Host "`n==> Processing $appName (RG: $rgName, State: $($la.State))" -ForegroundColor Green

    # ── 1. Export full configuration ──
    Write-Host "  Exporting workflow definition & parameters..." -ForegroundColor Yellow
    $exportData = Export-LogicAppConfig -ResourceGroupName $rgName -AppName $appName

    # ── 2. Export API connections ──
    Write-Host "  Exporting API connections..." -ForegroundColor Yellow
    $apiConnections = Export-ApiConnections -ResourceGroupName $rgName -WorkflowParameters $exportData.parameters
    $exportData["apiConnections"] = $apiConnections

    # ── 3. Export trigger details & callback URLs ──
    Write-Host "  Exporting trigger details..." -ForegroundColor Yellow
    $triggers = Export-TriggerCallbackUrl -ResourceGroupName $rgName -AppName $appName
    $exportData["triggers"] = $triggers

    # ── 4. Export run history ──
    Write-Host "  Exporting run history (last $RunHistoryCount)..." -ForegroundColor Yellow
    $runHistory = Export-RunHistory -ResourceGroupName $rgName -AppName $appName -Top $RunHistoryCount
    $exportData["runHistory"] = $runHistory

    # ── 5. Summarise actions & connectors used ──
    $actionTypes = @()
    $connectorsUsed = @()
    if ($exportData.definition -and $exportData.definition.actions) {
      $actions = $exportData.definition.actions
      if ($actions -is [hashtable]) {
        foreach ($aKey in $actions.Keys) {
          $actionTypes += $actions[$aKey].type
        }
      }
      elseif ($actions.PSObject -and $actions.PSObject.Properties) {
        foreach ($prop in $actions.PSObject.Properties) {
          $actionTypes += $prop.Value.type
        }
      }
    }
    $actionTypes = @($actionTypes | Select-Object -Unique)
    $connectorsUsed = @($apiConnections | ForEach-Object { $_.apiDisplayName } | Where-Object { $_ } | Select-Object -Unique)

    $exportData["summary"] = [ordered]@{
      actionCount    = $actionTypes.Count
      actionTypes    = $actionTypes
      connectorsUsed = $connectorsUsed
      hasHttpTrigger = ($triggers.Values | Where-Object { $_.callbackUrl }) -ne $null
      triggerCount   = $triggers.Count
      runHistoryCount = $runHistory.Count
    }

    # ── 6. Write JSON to temp file ──
    $jsonFile = Join-Path $tempRoot "$($appName)-$timestamp.json"

    # If we have a raw definition JSON string, splice it in to preserve array
    # structures that PS 5.1 ConvertTo-Json flattens (e.g. runAfter: ["Succeeded"]).
    $rawDefJson = $exportData['rawDefinitionJson']
    $exportData.Remove('rawDefinitionJson')  # don't include the raw copy in output

    if ($rawDefJson) {
      $placeholder = '@@RAW_DEFINITION_PLACEHOLDER@@'
      $savedDef = $exportData['definition']
      $exportData['definition'] = $placeholder
      $outputJson = $exportData | ConvertTo-Json -Depth 30
      $outputJson = $outputJson.Replace('"' + $placeholder + '"', $rawDefJson)
      $exportData['definition'] = $savedDef  # restore for summary extraction below
      $outputJson | Set-Content -Path $jsonFile -Encoding UTF8
    }
    else {
      $exportData | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonFile -Encoding UTF8
    }

    # ── 7. Upload to target Storage ──
    Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop | Out-Null
    $blobPath = "{0}/{1}/{2}.json" -f $SourceSubscriptionId, $appName, $timestamp
    Write-Host "  Uploading to $TargetStorageAccount/$TargetContainer/$blobPath ..." -ForegroundColor Cyan
    Set-AzStorageBlobContent -Context $targetCtx -File $jsonFile -Container $TargetContainer -Blob $blobPath -Force | Out-Null

    # Switch back to source for next app
    Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction Stop | Out-Null

    $report += [pscustomobject]@{
      AppName           = $appName
      ResourceGroup     = $rgName
      Location          = $la.Location
      State             = $la.State
      Type              = 'Consumption'
      WorkflowCount     = 1
      ActionCount       = $actionTypes.Count
      ConnectorsUsed    = ($connectorsUsed -join "; ")
      ApiConnectionCount = $apiConnections.Count
      RecentRuns        = $runHistory.Count
      Blob              = $blobPath
      When              = (Get-Date)
      Status            = "OK"
    }

    Write-Host "  Done." -ForegroundColor Green
  }
  catch {
    Write-Warning "Error on $($la.Name): $($_.Exception.Message)"
    $report += [pscustomobject]@{
      AppName           = $la.Name
      ResourceGroup     = ($la.Id -split '/')[4]
      Location          = $la.Location
      State             = $la.State
      Type              = 'Consumption'
      WorkflowCount     = 1
      ActionCount       = 0
      ConnectorsUsed    = ""
      ApiConnectionCount = 0
      RecentRuns        = 0
      Blob              = ""
      When              = (Get-Date)
      Status            = "FAILED: $($_.Exception.Message)"
    }
    # Ensure we remain in source context for next iteration
    Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction SilentlyContinue | Out-Null
  }
}

# ── Standard Logic Apps backup loop ───────────────────────────────────────────

foreach ($sla in $standardLogicApps) {
  try {
    $rgName  = ($sla.Id -split '/')[4]
    $appName = $sla.Name

    Write-Host "`n==> Processing [Standard] $appName (RG: $rgName, State: $($sla.State))" -ForegroundColor Magenta

    # ── 1. Export full Standard Logic App ──
    Write-Host "  Exporting Standard Logic App config & workflows..." -ForegroundColor Yellow
    $exportData = Export-StandardLogicAppConfig -ResourceGroupName $rgName -AppName $appName -RunHistoryTop $RunHistoryCount

    # ── 2. Write JSON to temp file ──
    $jsonFile = Join-Path $tempRoot "$($appName)-std-$timestamp.json"
    $exportData | ConvertTo-Json -Depth 30 | Set-Content -Path $jsonFile -Encoding UTF8

    # ── 3. Upload to target Storage ──
    Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop | Out-Null
    $blobPath = "{0}/{1}/{2}.json" -f $SourceSubscriptionId, $appName, $timestamp
    Write-Host "  Uploading to $TargetStorageAccount/$TargetContainer/$blobPath ..." -ForegroundColor Cyan
    Set-AzStorageBlobContent -Context $targetCtx -File $jsonFile -Container $TargetContainer -Blob $blobPath -Force | Out-Null

    # Switch back to source for next app
    Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction Stop | Out-Null

    $wfCount = if ($exportData.workflows) { $exportData.workflows.Count } else { 0 }
    $report += [pscustomobject]@{
      AppName           = $appName
      ResourceGroup     = $rgName
      Location          = $sla.Location
      State             = $sla.State
      Type              = 'Standard'
      WorkflowCount     = $wfCount
      ActionCount       = $exportData.summary.actionCount
      ConnectorsUsed    = ""
      ApiConnectionCount = 0
      RecentRuns        = 0
      Blob              = $blobPath
      When              = (Get-Date)
      Status            = "OK"
    }

    Write-Host "  Done ($wfCount workflow(s) backed up)." -ForegroundColor Green
  }
  catch {
    Write-Warning "Error on [Standard] $($sla.Name): $($_.Exception.Message)"
    $report += [pscustomobject]@{
      AppName           = $sla.Name
      ResourceGroup     = ($sla.Id -split '/')[4]
      Location          = $sla.Location
      State             = $sla.State
      Type              = 'Standard'
      WorkflowCount     = 0
      ActionCount       = 0
      ConnectorsUsed    = ""
      ApiConnectionCount = 0
      RecentRuns        = 0
      Blob              = ""
      When              = (Get-Date)
      Status            = "FAILED: $($_.Exception.Message)"
    }
    Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction SilentlyContinue | Out-Null
  }
}

# ── Report ────────────────────────────────────────────────────────────────────

$csv = Join-Path $tempRoot ("report-" + $timestamp + ".csv")
$report | Export-Csv -Path $csv -NoTypeInformation

# Upload report CSV to target storage as well
Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop | Out-Null
$reportBlobPath = "{0}/reports/logicapp-backup-{1}.csv" -f $SourceSubscriptionId, $timestamp
Set-AzStorageBlobContent -Context $targetCtx -File $csv -Container $TargetContainer -Blob $reportBlobPath -Force | Out-Null

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Backup completed." -ForegroundColor Green
Write-Host "  Apps processed : $($report.Count)" -ForegroundColor Cyan
Write-Host "  Succeeded      : $(($report | Where-Object Status -eq 'OK').Count)" -ForegroundColor Cyan
Write-Host "  Failed         : $(($report | Where-Object Status -ne 'OK').Count)" -ForegroundColor Yellow
Write-Host "  Local report   : $csv" -ForegroundColor Cyan
Write-Host "  Remote report  : $reportBlobPath" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Green

# TIP: Keep tempRoot for audit, or clean up:
# Remove-Item -Recurse -Force $tempRoot
