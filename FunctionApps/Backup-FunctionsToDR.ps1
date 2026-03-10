<#
.SYNOPSIS
  Backs up ALL Function Apps in a source subscription to a Storage account
  (Blob container) that lives in a *different* subscription.

.DESCRIPTION
  For each Function App the script exports:
  1. Code package (ZIP) -- via Kudu, SitePackages, or Flex Consumption blob
  2. Full configuration manifest (JSON) including:
     - App settings & connection strings
     - Site configuration (runtime, TLS, CORS, IP restrictions, etc.)
     - Hosting plan / SKU details
     - Managed identity configuration
     - Function & host keys
     - Tags, custom domains
     - Flex Consumption-specific config (scaling, runtime, deployment storage)

  The resulting backup is self-contained: everything needed to redeploy the
  Function App to another subscription / region.

.PARAMETER SourceSubscriptionId
  Subscription that hosts the Function Apps.

.PARAMETER TargetSubscriptionId
  Subscription that hosts the backup Storage account.

.PARAMETER TargetResourceGroup
  Resource group of the backup Storage account.

.PARAMETER TargetStorageAccount
  Name of the backup Storage account.

.PARAMETER TargetContainer
  Name of the blob container (will be created if missing).

.PARAMETER IncludeSlots
  Include deployment slots (if any). Default: $false.

.NOTES
  ARM REST API reference:
  - Sites: https://learn.microsoft.com/rest/api/appservice/web-apps/get
  - App settings: https://learn.microsoft.com/rest/api/appservice/web-apps/list-application-settings
  - Connection strings: https://learn.microsoft.com/rest/api/appservice/web-apps/list-connection-strings
  - Function keys: https://learn.microsoft.com/rest/api/appservice/web-apps/list-host-keys
  - Kudu API: https://github.com/projectkudu/kudu/wiki/REST-API
  - Flex Consumption: https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$SourceSubscriptionId,
  [Parameter(Mandatory=$true)] [string]$TargetSubscriptionId,
  [Parameter(Mandatory=$true)] [string]$TargetResourceGroup,
  [Parameter(Mandatory=$true)] [string]$TargetStorageAccount,
  [Parameter(Mandatory=$true)] [string]$TargetContainer,
  [switch]$IncludeSlots
)

#region Helpers

function Get-PublishingCreds {
  param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AppName
  )
  # Get publish profile XML for the Function App
  # (Az.Websites cmdlet returns the publish profile which includes Kudu user/pwd)
  # Docs: Get-AzWebAppPublishingProfile
  # https://learn.microsoft.com/powershell/module/az.websites/get-azwebapppublishingprofile
  $xml = [xml](Get-AzWebAppPublishingProfile -ResourceGroupName $ResourceGroupName -Name $AppName -Format WebDeploy -OutputFile none)
  $node = Select-Xml -Xml $xml -XPath "//publishData/publishProfile[contains(@publishUrl,'.scm.azurewebsites.net')][@userName and @userPWD]" | Select-Object -First 1
  if (-not $node) { throw "Publishing profile with Kudu creds not found for $AppName." }

  $username = $node.Node.userName
  $password = $node.Node.userPWD
  $pair     = "{0}:{1}" -f $username, $password
  $b64      = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
  return @{ AuthHeader = "Basic $b64" }
}

function Invoke-KuduJson {
  param(
    [Parameter(Mandatory=$true)][string]$KuduUrl,
    [Parameter(Mandatory=$true)][hashtable]$Auth,
    [ValidateSet('GET','POST','PUT','DELETE')][string]$Method = 'GET'
  )
  $headers = @{ Authorization = $Auth.AuthHeader }
  Invoke-RestMethod -Uri $KuduUrl -Headers $headers -Method $Method -UseBasicParsing
}

function Download-KuduFile {
  param(
    [Parameter(Mandatory=$true)][string]$KuduUrl,
    [Parameter(Mandatory=$true)][hashtable]$Auth,
    [Parameter(Mandatory=$true)][string]$OutFile
  )
  $headers = @{ Authorization = $Auth.AuthHeader }
  Invoke-WebRequest -Uri $KuduUrl -Headers $headers -OutFile $OutFile -UseBasicParsing
}

function Get-AppSettings {
  param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AppName
  )
  # Get-AzWebApp returns SiteConfig.AppSettings (name/value)
  $app = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $AppName
  $ht = @{}
  foreach ($kv in $app.SiteConfig.AppSettings) { $ht[$kv.Name] = $kv.Value }
  return $ht
}

function Ensure-Container {
  param(
    [Parameter(Mandatory=$true)] [Microsoft.Azure.Commands.Management.Storage.Models.PSStorageAccount] $Storage,
    [Parameter(Mandatory=$true)] [string]$Container
  )
  $ctx = $Storage.Context
  $exists = Get-AzStorageContainer -Context $ctx -Name $Container -ErrorAction SilentlyContinue
  if (-not $exists) {
    New-AzStorageContainer -Context $ctx -Name $Container -Permission Off | Out-Null
  }
  return $ctx
}

function Get-FlexConsumptionDeploymentInfo {
  <#
  .SYNOPSIS
    Checks if a Function App is Flex Consumption and returns the deployment blob container URL.
    Returns $null for non-Flex apps.
  .NOTES
    Flex Consumption apps store code in a blob container; Kudu/SCM is not available.
    https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan
  #>
  param(
    [Parameter(Mandatory=$true)][string]$SubscriptionId,
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AppName
  )
  # Resolve actual subscription GUID from current context
  $ctx = Get-AzContext
  $subId = $ctx.Subscription.Id
  $path = "/subscriptions/$subId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/${AppName}?api-version=2024-04-01"
  $response = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
  if ($response.StatusCode -ne 200) { return $null }
  $body = $response.Content | ConvertFrom-Json
  $sku = $body.properties.sku
  if ($sku -ne 'FlexConsumption') { return $null }

  $deployStorage = $body.properties.functionAppConfig.deployment.storage
  if (-not $deployStorage) { return $null }
  return [ordered]@{
    Sku              = 'FlexConsumption'
    BlobContainerUrl = $deployStorage.value   # e.g. https://stxxx.blob.core.windows.net/app-package-xxx
    AuthType         = $deployStorage.authentication.type
  }
}

function Download-FlexConsumptionPackage {
  <#
  .SYNOPSIS
    Downloads the latest deployment package from a Flex Consumption app's blob container.
    Uses OAuth via Az.Storage (works when shared-key access is disabled).
  #>
  param(
    [Parameter(Mandatory=$true)][string]$BlobContainerUrl,
    [Parameter(Mandatory=$true)][string]$OutFile
  )
  # Parse storage account name and container from URL
  # Format: https://<account>.blob.core.windows.net/<container>
  $uri = [System.Uri]$BlobContainerUrl
  $accountName = $uri.Host -replace '\.blob\.core\.windows\.net$', ''
  $containerName = $uri.AbsolutePath.TrimStart('/')

  $ctx = New-AzStorageContext -StorageAccountName $accountName -UseConnectedAccount
  $blobs = Get-AzStorageBlob -Context $ctx -Container $containerName -ErrorAction Stop |
           Where-Object { $_.Name -like '*.zip' } |
           Sort-Object LastModified -Descending

  if (-not $blobs) {
    throw "No ZIP blobs found in Flex Consumption container '$containerName'."
  }

  $latest = $blobs | Select-Object -First 1
  Write-Host "  Downloading Flex Consumption package: $($latest.Name) ($([math]::Round($latest.Length/1KB, 1)) KB)" -ForegroundColor Yellow
  Get-AzStorageBlobContent -Context $ctx -Container $containerName -Blob $latest.Name -Destination $OutFile -Force | Out-Null
}

# -------------------------------------------------------------------
#  ARM helper -- calls Invoke-AzRestMethod and returns parsed body
# -------------------------------------------------------------------
function Invoke-Arm {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$Method = 'GET'
  )
  $resp = Invoke-AzRestMethod -Method $Method -Path $Path -ErrorAction Stop
  if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
    return $resp.Content | ConvertFrom-Json
  }
  return $null
}

# -------------------------------------------------------------------
#  Export-FunctionAppConfig -- full configuration manifest via ARM
# -------------------------------------------------------------------
function Export-FunctionAppConfig {
  <#
  .SYNOPSIS
    Collects all configuration for a Function App via ARM REST API and returns
    an ordered dictionary ready to be serialized to JSON.
  .NOTES
    Uses Invoke-AzRestMethod so it works with the current Az context token.
    https://learn.microsoft.com/rest/api/appservice/web-apps
  #>
  param(
    [Parameter(Mandatory=$true)][string]$ResourceGroupName,
    [Parameter(Mandatory=$true)][string]$AppName
  )

  $subId = (Get-AzContext).Subscription.Id
  $base  = "/subscriptions/$subId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$AppName"
  $api   = "api-version=2024-04-01"

  # 1. Full site resource (kind, location, tags, identity, properties, functionAppConfig)
  Write-Host "  Fetching site resource..." -ForegroundColor DarkGray
  $site = Invoke-Arm -Path "${base}?${api}"
  if (-not $site) { throw "Failed to read site resource for $AppName" }

  # 2. App Settings (POST listApplicationSettings -- returns properties bag)
  Write-Host "  Fetching app settings..." -ForegroundColor DarkGray
  $appSettingsRaw = Invoke-Arm -Path "${base}/config/appsettings/list?${api}" -Method POST
  $appSettings = [ordered]@{}
  if ($appSettingsRaw -and $appSettingsRaw.properties) {
    foreach ($p in $appSettingsRaw.properties.PSObject.Properties) {
      $appSettings[$p.Name] = $p.Value
    }
  }

  # 3. Connection Strings (POST listConnectionStrings)
  Write-Host "  Fetching connection strings..." -ForegroundColor DarkGray
  $connStringsRaw = Invoke-Arm -Path "${base}/config/connectionstrings/list?${api}" -Method POST
  $connStrings = [ordered]@{}
  if ($connStringsRaw -and $connStringsRaw.properties) {
    foreach ($p in $connStringsRaw.properties.PSObject.Properties) {
      $connStrings[$p.Name] = [ordered]@{
        value = $p.Value.value
        type  = $p.Value.type
      }
    }
  }

  # 4. Slot-sticky settings
  Write-Host "  Fetching slot-sticky settings..." -ForegroundColor DarkGray
  $stickyRaw = Invoke-Arm -Path "${base}/config/slotConfigNames?${api}"
  $stickySettings = $null
  if ($stickyRaw -and $stickyRaw.properties) {
    $stickySettings = [ordered]@{
      appSettingNames       = @($stickyRaw.properties.appSettingNames)
      connectionStringNames = @($stickyRaw.properties.connectionStringNames)
      azureStorageConfigNames = @($stickyRaw.properties.azureStorageConfigNames)
    }
  }

  # 5. Host Keys & System Keys (master key, default function key, system keys)
  Write-Host "  Fetching host keys..." -ForegroundColor DarkGray
  $hostKeys = $null
  try {
    $hostKeysRaw = Invoke-Arm -Path "${base}/host/default/listkeys?${api}" -Method POST
    if ($hostKeysRaw) {
      $hostKeys = [ordered]@{
        masterKey    = $hostKeysRaw.masterKey
        functionKeys = [ordered]@{}
        systemKeys   = [ordered]@{}
      }
      if ($hostKeysRaw.functionKeys) {
        foreach ($p in $hostKeysRaw.functionKeys.PSObject.Properties) {
          $hostKeys.functionKeys[$p.Name] = $p.Value
        }
      }
      if ($hostKeysRaw.systemKeys) {
        foreach ($p in $hostKeysRaw.systemKeys.PSObject.Properties) {
          $hostKeys.systemKeys[$p.Name] = $p.Value
        }
      }
    }
  }
  catch {
    Write-Warning "    Could not retrieve host keys: $($_.Exception.Message)"
  }

  # 6. Per-function keys
  Write-Host "  Fetching function list & keys..." -ForegroundColor DarkGray
  $functionKeys = [ordered]@{}
  try {
    $funcsRaw = Invoke-Arm -Path "${base}/functions?${api}"
    if ($funcsRaw -and $funcsRaw.value) {
      foreach ($fn in $funcsRaw.value) {
        $fnName = $fn.properties.name
        try {
          $fk = Invoke-Arm -Path "${base}/functions/${fnName}/listkeys?${api}" -Method POST
          if ($fk) {
            $keys = [ordered]@{}
            foreach ($p in $fk.PSObject.Properties) {
              if ($p.Name -ne 'id' -and $p.Name -ne 'name' -and $p.Name -ne 'type') {
                $keys[$p.Name] = $p.Value
              }
            }
            $functionKeys[$fnName] = $keys
          }
        }
        catch {
          Write-Warning "    Could not get keys for function ${fnName}: $($_.Exception.Message)"
        }
      }
    }
  }
  catch {
    Write-Warning "    Could not list functions: $($_.Exception.Message)"
  }

  # 7. Hosting plan / ASP details
  Write-Host "  Fetching hosting plan..." -ForegroundColor DarkGray
  $hostingPlan = $null
  $planId = $site.properties.serverFarmId
  if ($planId) {
    try {
      $plan = Invoke-Arm -Path "${planId}?${api}"
      if ($plan) {
        $hostingPlan = [ordered]@{
          id       = $plan.id
          name     = $plan.name
          location = $plan.location
          kind     = $plan.kind
          sku      = $plan.sku
        }
      }
    }
    catch {
      Write-Warning "    Could not read hosting plan."
    }
  }


  # 9. Custom domains
  Write-Host "  Fetching custom domains..." -ForegroundColor DarkGray
  $customDomains = @()
  try {
    $hostBindings = Invoke-Arm -Path "${base}/hostNameBindings?${api}"
    if ($hostBindings -and $hostBindings.value) {
      foreach ($hb in $hostBindings.value) {
        $customDomains += [ordered]@{
          name      = $hb.name
          hostName  = $hb.properties.hostNameType
          sslState  = $hb.properties.sslState
          thumbprint = $hb.properties.thumbprint
        }
      }
    }
  }
  catch { }

  # 10. Build the site config section from the site resource
  $sc = $site.properties.siteConfig
  $siteConfig = [ordered]@{}
  if ($sc) {
    $configProps = @(
      'numberOfWorkers','linuxFxVersion','windowsFxVersion','netFrameworkVersion',
      'javaVersion','javaContainer','javaContainerVersion','pythonVersion','nodeVersion',
      'powerShellVersion','use32BitWorkerProcess','alwaysOn','httpLoggingEnabled',
      'detailedErrorLoggingEnabled','requestTracingEnabled','ftpsState','http20Enabled',
      'minTlsVersion','scmMinTlsVersion','webSocketsEnabled','managedPipelineMode',
      'loadBalancing','autoHealEnabled','functionsRuntimeScaleMonitoringEnabled',
      'minimumElasticInstanceCount','preWarmedInstanceCount','healthCheckPath'
    )
    foreach ($prop in $configProps) {
      $val = $sc.PSObject.Properties[$prop]
      if ($val) { $siteConfig[$prop] = $val.Value }
    }
    # CORS
    if ($sc.cors) {
      $siteConfig['cors'] = [ordered]@{
        allowedOrigins     = @($sc.cors.allowedOrigins)
        supportCredentials = $sc.cors.supportCredentials
      }
    }
    # IP restrictions
    if ($sc.ipSecurityRestrictions) {
      $siteConfig['ipSecurityRestrictions'] = @($sc.ipSecurityRestrictions)
    }
    if ($sc.scmIpSecurityRestrictions) {
      $siteConfig['scmIpSecurityRestrictions'] = @($sc.scmIpSecurityRestrictions)
    }
  }

  # 11. Flex Consumption-specific config
  $flexConfig = $null
  if ($site.properties.sku -eq 'FlexConsumption' -and $site.properties.functionAppConfig) {
    $fac = $site.properties.functionAppConfig
    $flexConfig = [ordered]@{
      deployment = $fac.deployment
      runtime    = $fac.runtime
    }
    if ($fac.scaleAndConcurrency) {
      $flexConfig['scaleAndConcurrency'] = $fac.scaleAndConcurrency
    }
  }

  # 12. Identity
  $identityInfo = $null
  if ($site.identity) {
    $identityInfo = [ordered]@{
      type = $site.identity.type
    }
    if ($site.identity.userAssignedIdentities) {
      $uai = [ordered]@{}
      foreach ($p in $site.identity.userAssignedIdentities.PSObject.Properties) {
        $uai[$p.Name] = [ordered]@{
          principalId = $p.Value.principalId
          clientId    = $p.Value.clientId
        }
      }
      $identityInfo['userAssignedIdentities'] = $uai
    }
  }

  # -- Assemble the manifest --
  $manifest = [ordered]@{
    backupTimestamp   = (Get-Date -Format 'o')
    appName           = $AppName
    resourceGroup     = $ResourceGroupName
    subscriptionId    = $subId
    location          = $site.location
    kind              = $site.kind
    tags              = $site.tags
    identity          = $identityInfo
    sku               = $site.properties.sku
    state             = $site.properties.state
    defaultHostName   = $site.properties.defaultHostName
    httpsOnly         = $site.properties.httpsOnly
    clientCertEnabled = $site.properties.clientCertEnabled
    serverFarmId      = $site.properties.serverFarmId
    hostingPlan       = $hostingPlan
    siteConfig        = $siteConfig
    appSettings       = $appSettings
    connectionStrings = $connStrings
    slotStickySettings = $stickySettings
    hostKeys          = $hostKeys
    functionKeys      = $functionKeys
    flexConsumptionConfig = $flexConfig
    customDomains     = $customDomains
  }

  return $manifest
}

# -------------------------------------------------------------------
#  Build-ArmTemplate -- generates a deployable ARM template from manifest
# -------------------------------------------------------------------
function Build-ArmTemplate {
  <#
  .SYNOPSIS
    Generates an ARM template JSON from the config manifest that can be
    deployed with New-AzResourceGroupDeployment or az deployment group create.
  .DESCRIPTION
    The template is parameterized:
      - location (default: original location)
      - functionAppName (default: original name)
      - storageAccountName (no default -- user must supply for DR)
      - appInsightsConnectionString (optional override)
    It creates:
      1. App Service Plan (matching original SKU)
      2. User-Assigned Managed Identity (if original used one)
      3. Function App with full siteConfig, appSettings, connectionStrings
    For Flex Consumption, the template uses the 2024-04-01 API with
    functionAppConfig for runtime/scaling/deployment-storage.
  .NOTES
    ARM template schema: https://learn.microsoft.com/azure/templates/microsoft.web/sites
  #>
  param(
    [Parameter(Mandatory=$true)][System.Collections.Specialized.OrderedDictionary]$Manifest
  )

  $isFlex = ($Manifest.sku -eq 'FlexConsumption')
  $isLinux = ($Manifest.kind -like '*linux*')

  # -- Parameters --
  $parameters = [ordered]@{
    location = [ordered]@{
      type         = 'string'
      defaultValue = $Manifest.location
      metadata     = [ordered]@{ description = 'Azure region for all resources' }
    }
    functionAppName = [ordered]@{
      type         = 'string'
      defaultValue = $Manifest.appName
      metadata     = [ordered]@{ description = 'Name of the Function App' }
    }
    storageAccountName = [ordered]@{
      type     = 'string'
      metadata = [ordered]@{ description = 'Name of the Storage Account for the Function App (must exist or be created separately)' }
    }
    appInsightsConnectionString = [ordered]@{
      type         = 'string'
      defaultValue = ''
      metadata     = [ordered]@{ description = 'Application Insights connection string (leave empty to skip)' }
    }
  }

  # -- Variables --
  $planName = if ($Manifest.hostingPlan) { $Manifest.hostingPlan.name } else { "plan-[parameters('functionAppName')]" }
  $variables = [ordered]@{
    hostingPlanName = $planName
  }

  # -- Resources --
  $resources = @()

  # 1. User-Assigned Managed Identity (if original used one)
  $identityRef = $null
  if ($Manifest.identity -and $Manifest.identity.type -like '*UserAssigned*' -and $Manifest.identity.userAssignedIdentities) {
    $uaiName = ($Manifest.identity.userAssignedIdentities.Keys | Select-Object -First 1).Split('/')[-1]
    $parameters['managedIdentityName'] = [ordered]@{
      type         = 'string'
      defaultValue = $uaiName
      metadata     = [ordered]@{ description = 'Name of the User-Assigned Managed Identity' }
    }
    $resources += [ordered]@{
      type       = 'Microsoft.ManagedIdentity/userAssignedIdentities'
      apiVersion = '2023-01-31'
      name       = "[parameters('managedIdentityName')]"
      location   = "[parameters('location')]"
    }
    $identityRef = [ordered]@{
      type = 'UserAssigned'
      userAssignedIdentities = [ordered]@{
        "[resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', parameters('managedIdentityName'))]" = [ordered]@{}
      }
    }
  }

  # 2. App Service Plan
  $planSku = if ($Manifest.hostingPlan -and $Manifest.hostingPlan.sku) {
    [ordered]@{
      name     = $Manifest.hostingPlan.sku.name
      tier     = $Manifest.hostingPlan.sku.tier
      size     = $Manifest.hostingPlan.sku.size
      family   = $Manifest.hostingPlan.sku.family
      capacity = $Manifest.hostingPlan.sku.capacity
    }
  } else {
    [ordered]@{ name = 'Y1'; tier = 'Dynamic'; size = 'Y1'; family = 'Y'; capacity = 0 }
  }
  $planKind = if ($Manifest.hostingPlan -and $Manifest.hostingPlan.kind) { $Manifest.hostingPlan.kind } else { 'functionapp' }
  $planResource = [ordered]@{
    type       = 'Microsoft.Web/serverfarms'
    apiVersion = '2024-04-01'
    name       = "[variables('hostingPlanName')]"
    location   = "[parameters('location')]"
    kind       = $planKind
    sku        = $planSku
    properties = [ordered]@{
      reserved = $isLinux
    }
  }
  $resources += $planResource

  # 3. Function App
  # -- Build app settings array for siteConfig --
  $appSettingsArray = @()
  foreach ($key in $Manifest.appSettings.Keys) {
    $val = $Manifest.appSettings[$key]
    # Replace App Insights connection string with parameter reference
    if ($key -eq 'APPLICATIONINSIGHTS_CONNECTION_STRING') {
      $appSettingsArray += [ordered]@{
        name  = $key
        value = "[if(empty(parameters('appInsightsConnectionString')), '$val', parameters('appInsightsConnectionString'))]"
      }
    }
    # Replace storage references so user can point to DR storage
    elseif ($key -like 'AzureWebJobsStorage*' -and $key -eq 'AzureWebJobsStorage__blobServiceUri') {
      $appSettingsArray += [ordered]@{
        name  = $key
        value = "[concat('https://', parameters('storageAccountName'), '.blob.core.windows.net/')]"
      }
    }
    elseif ($key -like 'AzureWebJobsStorage*' -and $key -eq 'AzureWebJobsStorage__queueServiceUri') {
      $appSettingsArray += [ordered]@{
        name  = $key
        value = "[concat('https://', parameters('storageAccountName'), '.queue.core.windows.net/')]"
      }
    }
    elseif ($key -like 'AzureWebJobsStorage*' -and $key -eq 'AzureWebJobsStorage__tableServiceUri') {
      $appSettingsArray += [ordered]@{
        name  = $key
        value = "[concat('https://', parameters('storageAccountName'), '.table.core.windows.net/')]"
      }
    }
    elseif ($key -eq 'AzureWebJobsStorage' -and $val -like '*AccountName=*') {
      # Classic connection-string-based storage reference
      $appSettingsArray += [ordered]@{
        name  = $key
        value = "[concat('DefaultEndpointsProtocol=https;AccountName=', parameters('storageAccountName'), ';EndpointSuffix=core.windows.net')]"
      }
    }
    else {
      $appSettingsArray += [ordered]@{ name = $key; value = $val }
    }
  }

  # -- siteConfig properties --
  $siteConfigArm = [ordered]@{}
  $scalarProps = @(
    'numberOfWorkers','linuxFxVersion','netFrameworkVersion','javaVersion',
    'pythonVersion','nodeVersion','powerShellVersion','use32BitWorkerProcess',
    'alwaysOn','httpLoggingEnabled','ftpsState','http20Enabled',
    'minTlsVersion','scmMinTlsVersion','webSocketsEnabled',
    'functionsRuntimeScaleMonitoringEnabled','healthCheckPath'
  )
  foreach ($prop in $scalarProps) {
    if ($Manifest.siteConfig.Contains($prop) -and $null -ne $Manifest.siteConfig[$prop]) {
      $siteConfigArm[$prop] = $Manifest.siteConfig[$prop]
    }
  }
  $siteConfigArm['appSettings'] = $appSettingsArray

  # -- Connection strings --
  if ($Manifest.connectionStrings -and $Manifest.connectionStrings.Count -gt 0) {
    $connStringArm = @()
    foreach ($csName in $Manifest.connectionStrings.Keys) {
      $cs = $Manifest.connectionStrings[$csName]
      $connStringArm += [ordered]@{
        name             = $csName
        connectionString = $cs.value
        type             = $cs.type
      }
    }
    $siteConfigArm['connectionStrings'] = $connStringArm
  }

  # CORS
  if ($Manifest.siteConfig.Contains('cors') -and $Manifest.siteConfig['cors']) {
    $siteConfigArm['cors'] = $Manifest.siteConfig['cors']
  }
  # IP restrictions
  if ($Manifest.siteConfig.Contains('ipSecurityRestrictions') -and $Manifest.siteConfig['ipSecurityRestrictions']) {
    $siteConfigArm['ipSecurityRestrictions'] = $Manifest.siteConfig['ipSecurityRestrictions']
  }

  # -- Build Function App resource --
  $siteProperties = [ordered]@{
    serverFarmId  = "[resourceId('Microsoft.Web/serverfarms', variables('hostingPlanName'))]"
    httpsOnly     = $(if ($null -ne $Manifest.httpsOnly) { $Manifest.httpsOnly } else { $true })
    siteConfig    = $siteConfigArm
  }
  if ($Manifest.clientCertEnabled) {
    $siteProperties['clientCertEnabled'] = $Manifest.clientCertEnabled
  }

  # Flex Consumption-specific: functionAppConfig
  if ($isFlex -and $Manifest.flexConsumptionConfig) {
    $fc = $Manifest.flexConsumptionConfig
    $deploymentStorage = [ordered]@{
      type  = $fc.deployment.storage.type
      value = "[concat('https://', parameters('storageAccountName'), '.blob.core.windows.net/', parameters('functionAppName'), '-package')]"
    }
    # Auth block
    if ($fc.deployment.storage.authentication) {
      $authBlock = [ordered]@{
        type = $fc.deployment.storage.authentication.type
      }
      if ($fc.deployment.storage.authentication.type -eq 'userassignedidentity' -and $identityRef) {
        $authBlock['userAssignedIdentityResourceId'] = "[resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', parameters('managedIdentityName'))]"
      }
      $deploymentStorage['authentication'] = $authBlock
    }

    $facArm = [ordered]@{
      deployment = [ordered]@{ storage = $deploymentStorage }
      runtime    = $fc.runtime
    }
    if ($fc.scaleAndConcurrency) {
      $facArm['scaleAndConcurrency'] = $fc.scaleAndConcurrency
    }
    $siteProperties['functionAppConfig'] = $facArm
  }

  $siteDependsOn = @("[resourceId('Microsoft.Web/serverfarms', variables('hostingPlanName'))]")
  if ($identityRef) {
    $siteDependsOn += "[resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', parameters('managedIdentityName'))]"
  }

  $siteResource = [ordered]@{
    type       = 'Microsoft.Web/sites'
    apiVersion = '2024-04-01'
    name       = "[parameters('functionAppName')]"
    location   = "[parameters('location')]"
    kind       = $Manifest.kind
    dependsOn  = $siteDependsOn
    properties = $siteProperties
  }
  if ($Manifest.tags) {
    $tagsArm = [ordered]@{}
    foreach ($p in $Manifest.tags.PSObject.Properties) { $tagsArm[$p.Name] = $p.Value }
    $siteResource['tags'] = $tagsArm
  }
  if ($identityRef) {
    $siteResource['identity'] = $identityRef
  }
  $resources += $siteResource

  # -- Assemble template --
  $template = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    metadata       = [ordered]@{
      description = "ARM template generated from backup of Function App '$($Manifest.appName)' on $($Manifest.backupTimestamp)"
      generator   = 'Backup-FunctionsToDR.ps1'
    }
    parameters     = $parameters
    variables      = $variables
    resources      = $resources
    outputs        = [ordered]@{
      functionAppDefaultHostName = [ordered]@{
        type  = 'string'
        value = "[reference(resourceId('Microsoft.Web/sites', parameters('functionAppName'))).defaultHostName]"
      }
      functionAppResourceId = [ordered]@{
        type  = 'string'
        value = "[resourceId('Microsoft.Web/sites', parameters('functionAppName'))]"
      }
    }
  }

  return $template
}

#endregion Helpers

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop | Out-Null

# Source: list Function Apps
Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction Stop | Out-Null

Write-Host "Enumerating Function Apps in subscription $SourceSubscriptionId ..." -ForegroundColor Cyan
# Microsoft.Web/sites with kind containing 'functionapp' but NOT 'workflowapp' (Logic App Standard)
$sites = Get-AzResource -ResourceType "Microsoft.Web/sites" -ExpandProperties |
         Where-Object { $_.Kind -like "*functionapp*" -and $_.Kind -notlike "*workflowapp*" }

if (-not $sites) {
  Write-Warning "No Function Apps found in subscription $SourceSubscriptionId."
  return
}

# Target: storage context (OAuth - shared key may be disabled)
Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop | Out-Null
$storage = Get-AzStorageAccount -ResourceGroupName $TargetResourceGroup -Name $TargetStorageAccount -ErrorAction Stop
$targetCtx = New-AzStorageContext -StorageAccountName $TargetStorageAccount -UseConnectedAccount
# Ensure container exists
$exists = Get-AzStorageContainer -Context $targetCtx -Name $TargetContainer -ErrorAction SilentlyContinue
if (-not $exists) {
  New-AzStorageContainer -Context $targetCtx -Name $TargetContainer -Permission Off | Out-Null
}

# Switch back to source for per-app Kudu/download operations
Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction Stop | Out-Null

$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$tempRoot  = Join-Path $env:TEMP ("func-backups-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null

$report = @()

foreach ($site in $sites) {
  try {
    $rgName = $site.ResourceGroupName
    $appName = $site.Name

    Write-Host "`n==> Processing $appName (RG: $rgName)" -ForegroundColor Green

    $outFile = Join-Path $tempRoot "$($appName)-$timestamp.zip"
    $packageSource = 'unknown'

    # Check if Flex Consumption (no Kudu/SCM available)
    $flexInfo = Get-FlexConsumptionDeploymentInfo -SubscriptionId $SourceSubscriptionId `
      -ResourceGroupName $rgName -AppName $appName

    if ($flexInfo) {
      Write-Host "  Flex Consumption detected (auth: $($flexInfo.AuthType))" -ForegroundColor Cyan
      Write-Host "  Blob container: $($flexInfo.BlobContainerUrl)" -ForegroundColor DarkGray
      Download-FlexConsumptionPackage -BlobContainerUrl $flexInfo.BlobContainerUrl -OutFile $outFile
      $packageSource = 'FlexConsumption-Blob'
    }
    else {
    # -- Classic / Consumption / Premium: use Kudu --

    # Build SCM URL
    $scm = "https://$($appName).scm.azurewebsites.net"

    # Publishing creds (for Kudu)
    $auth = Get-PublishingCreds -ResourceGroupName $rgName -AppName $appName

    # Detect WEBSITE_RUN_FROM_PACKAGE
    $settings = Get-AppSettings -ResourceGroupName $rgName -AppName $appName
    $wrfp = $null
    if ($settings.ContainsKey("WEBSITE_RUN_FROM_PACKAGE")) { $wrfp = $settings["WEBSITE_RUN_FROM_PACKAGE"] }

    if ($wrfp -and $wrfp -ne "0") {
      # Prefer original package
      if ($wrfp -match "^https?://") {
        Write-Host "WEBSITE_RUN_FROM_PACKAGE is URL -> downloading package directly..." -ForegroundColor Yellow
        try {
          Invoke-WebRequest -Uri $wrfp -OutFile $outFile -UseBasicParsing
        }
        catch {
          Write-Warning "Direct download failed. Falling back to SitePackages via Kudu..."
          $wrfp = "1"
        }
      }

      if ($wrfp -eq "1") {
        # List /home/data/SitePackages/ and pick the newest ZIP (Kudu VFS)
        # Kudu VFS list: GET /api/vfs/{path}/  [1](https://github.com/projectkudu/kudu/wiki/REST-API)
        $listUrl = "$scm/api/vfs/data/SitePackages/"
        $items = Invoke-KuduJson -KuduUrl $listUrl -Auth $auth
        $zips = @($items | Where-Object { $_.name -like "*.zip" })
        if (-not $zips) {
          Write-Warning "No SitePackages ZIP found; falling back to /site/wwwroot ZIP."
        }
        else {
          $latest = $zips | Sort-Object { [datetime]$_.mtime } -Descending | Select-Object -First 1
          $pkgUrl = $latest.href
          Write-Host "Downloading original package $($latest.name) from SitePackages..." -ForegroundColor Yellow
          Download-KuduFile -KuduUrl $pkgUrl -Auth $auth -OutFile $outFile
        }
      }
    }

    if (-not (Test-Path $outFile)) {
      # Fallback: zip the current deployment from wwwroot
      # Kudu ZIP API: GET /api/zip/site/wwwroot/  [1](https://github.com/projectkudu/kudu/wiki/REST-API)
      $zipUrl = "$scm/api/zip/site/wwwroot/"
      Write-Host "Downloading ZIP of /site/wwwroot via Kudu..." -ForegroundColor Yellow
      Download-KuduFile -KuduUrl $zipUrl -Auth $auth -OutFile $outFile
    }

    $packageSource = $(if ($wrfp) { 'RunFromPackage' } else { 'wwwroot-zip' })
    } # end else (non-Flex)

    if (-not (Test-Path $outFile)) { throw "Failed to obtain a package ZIP for $appName." }

    # -- Export full configuration manifest --
    Write-Host "  Exporting configuration manifest..." -ForegroundColor Cyan
    $manifest = Export-FunctionAppConfig -ResourceGroupName $rgName -AppName $appName
    $manifest['codePackageBlob'] = "{0}/{1}/{2}.zip" -f $SourceSubscriptionId, $appName, $timestamp
    $manifest['packageSource']   = $packageSource

    $manifestFile = Join-Path $tempRoot "$($appName)-$timestamp.json"
    $manifest | ConvertTo-Json -Depth 20 | Out-File -FilePath $manifestFile -Encoding utf8

    # -- Generate ARM template --
    Write-Host "  Generating ARM template..." -ForegroundColor Cyan
    $armTemplate = Build-ArmTemplate -Manifest $manifest
    $armFile = Join-Path $tempRoot "$($appName)-$timestamp.arm.json"
    $armTemplate | ConvertTo-Json -Depth 30 | Out-File -FilePath $armFile -Encoding utf8

    # Upload to target Storage (switch context to target sub for upload)
    Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop | Out-Null

    # Upload code ZIP
    $blobPath = "{0}/{1}/{2}.zip" -f $SourceSubscriptionId, $appName, $timestamp
    Write-Host "  Uploading code package to $TargetContainer/$blobPath ..." -ForegroundColor Cyan
    Set-AzStorageBlobContent -Context $targetCtx -File $outFile -Container $TargetContainer -Blob $blobPath -Force | Out-Null

    # Upload config manifest JSON
    $manifestBlobPath = "{0}/{1}/{2}.json" -f $SourceSubscriptionId, $appName, $timestamp
    Write-Host "  Uploading config manifest to $TargetContainer/$manifestBlobPath ..." -ForegroundColor Cyan
    Set-AzStorageBlobContent -Context $targetCtx -File $manifestFile -Container $TargetContainer -Blob $manifestBlobPath -Force | Out-Null

    # Upload ARM template
    $armBlobPath = "{0}/{1}/{2}.arm.json" -f $SourceSubscriptionId, $appName, $timestamp
    Write-Host "  Uploading ARM template to $TargetContainer/$armBlobPath ..." -ForegroundColor Cyan
    Set-AzStorageBlobContent -Context $targetCtx -File $armFile -Container $TargetContainer -Blob $armBlobPath -Force | Out-Null

    # Switch back to source for next app
    Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction Stop | Out-Null

    $report += [pscustomobject]@{
      AppName       = $appName
      ResourceGroup = $rgName
      Location      = $manifest.location
      Kind          = $manifest.kind
      Sku           = $manifest.sku
      PackageSource = $packageSource
      CodeBlob      = $blobPath
      ConfigBlob    = $manifestBlobPath
      ArmTemplate   = $armBlobPath
      AppSettings   = ($manifest.appSettings.Keys -join ', ')
      Functions     = ($manifest.functionKeys.Keys -join ', ')
      When          = (Get-Date)
      Status        = "OK"
    }
  }
  catch {
    Write-Warning "Error on $($site.Name): $($_.Exception.Message)"
    $report += [pscustomobject]@{
      AppName       = $site.Name
      ResourceGroup = $site.ResourceGroupName
      Location      = ''
      Kind          = ''
      Sku           = ''
      PackageSource = "n/a"
      CodeBlob      = ''
      ConfigBlob    = ''
      ArmTemplate   = ''
      AppSettings   = ''
      Functions     = ''
      When          = (Get-Date)
      Status        = "FAILED: $($_.Exception.Message)"
    }
    # Ensure we remain in source context for next iteration
    Set-AzContext -Subscription $SourceSubscriptionId -ErrorAction SilentlyContinue | Out-Null
  }
}

# Save a CSV report alongside
$csv = Join-Path $tempRoot ("report-" + $timestamp + ".csv")
$report | Export-Csv -Path $csv -NoTypeInformation

# Upload report to blob storage
Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop | Out-Null
$reportBlob = "{0}/reports/functionapp-backup-{1}.csv" -f $SourceSubscriptionId, $timestamp
Set-AzStorageBlobContent -Context $targetCtx -File $csv -Container $TargetContainer -Blob $reportBlob -Force | Out-Null

$succeeded = @($report | Where-Object { $_.Status -eq 'OK' }).Count
$failed    = @($report | Where-Object { $_.Status -ne 'OK' }).Count

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Backup completed."
Write-Host "  Apps processed : $($report.Count)"
Write-Host "  Succeeded      : $succeeded"
Write-Host "  Failed         : $failed"
Write-Host "  Local report   : $csv"
Write-Host "  Remote report  : $reportBlob"
Write-Host "========================================" -ForegroundColor Cyan

# TIP: Keep tempRoot for audit, or clean up:
# Remove-Item -Recurse -Force $tempRoot