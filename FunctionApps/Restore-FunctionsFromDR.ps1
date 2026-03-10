<#
.SYNOPSIS
  Restores a Function App from a DR backup (ARM template + manifest JSON + code ZIP).

.DESCRIPTION
  This script takes the three artifacts produced by Backup-FunctionsToDR.ps1 and restores
  the Function App to a target subscription, resource group, and region:

    1. Downloads ARM template, manifest JSON, and code ZIP from blob storage (or uses local files).
    2. Deploys the ARM template via New-AzResourceGroupDeployment (creates hosting plan,
       managed identity, and the Function App).
    3. Deploys the code package:
       - Flex Consumption: uploads ZIP to the deployment blob container.
       - Classic / Consumption / Premium: uses az functionapp deployment source config-zip.
    4. Restores host keys and per-function keys from the manifest.
    5. Validates the deployment by listing functions and checking the default hostname.

.PARAMETER ArmTemplateBlobPath
  Blob path of the ARM template within the backup container. Mutually exclusive with -ArmTemplateLocalFile.
  Example: ME-MngEnvMCAP304533-utkugulen-1/func-api-2eydgai2qkvey/20260306-142542.arm.json

.PARAMETER ManifestBlobPath
  Blob path of the manifest JSON within the backup container.
  Example: ME-MngEnvMCAP304533-utkugulen-1/func-api-2eydgai2qkvey/20260306-142542.json

.PARAMETER CodeZipBlobPath
  Blob path of the code ZIP within the backup container.
  Example: ME-MngEnvMCAP304533-utkugulen-1/func-api-2eydgai2qkvey/20260306-142542.zip

.PARAMETER SourceStorageAccount
  Storage account name that holds the backup blobs.

.PARAMETER SourceStorageContainer
  Blob container name that holds the backup blobs.

.PARAMETER SourceStorageSubscription
  Subscription name/ID for the backup storage account. Defaults to the current context.

.PARAMETER TargetSubscriptionId
  Subscription name/ID to deploy the Function App into.

.PARAMETER TargetResourceGroup
  Resource group to deploy into (must already exist).

.PARAMETER TargetLocation
  Azure region for the restored Function App (e.g. eastus, westeurope).

.PARAMETER TargetStorageAccountName
  Name of the Storage Account the restored Function App should use (must already exist).
  This is used as the ARM template parameter 'storageAccountName'.

.PARAMETER NewFunctionAppName
  Optional new name for the Function App. If omitted, the original name with '-dr' suffix is used.

.PARAMETER AppInsightsConnectionString
  Optional Application Insights connection string to override the backup value.

.PARAMETER ManagedIdentityName
  Optional override for the managed identity name. If omitted, the backup's identity name is used.

.PARAMETER SkipCodeDeploy
  Switch to skip code deployment (deploy infra only).

.PARAMETER SkipKeyRestore
  Switch to skip restoring host keys and function keys.

.EXAMPLE
  .\Restore-FunctionsFromDR.ps1 `
    -ArmTemplateBlobPath  "ME-MngEnvMCAP304533-utkugulen-1/func-api-2eydgai2qkvey/20260306-142542.arm.json" `
    -ManifestBlobPath     "ME-MngEnvMCAP304533-utkugulen-1/func-api-2eydgai2qkvey/20260306-142542.json" `
    -CodeZipBlobPath      "ME-MngEnvMCAP304533-utkugulen-1/func-api-2eydgai2qkvey/20260306-142542.zip" `
    -SourceStorageAccount    stagentlab20260105 `
    -SourceStorageContainer  config-docs `
    -SourceStorageSubscription "ME-MngEnvMCAP304533-utkugulen-1" `
    -TargetSubscriptionId    "ME-MngEnvMCAP304533-utkugulen-1" `
    -TargetResourceGroup     rg-lab `
    -TargetLocation          eastus `
    -TargetStorageAccountName stagentlab20260105

.NOTES
  Prerequisites:
    - Az PowerShell modules: Az.Accounts, Az.Resources, Az.Storage, Az.Websites
    - Caller must have Contributor on the target RG and Storage Blob Data Contributor
      on both the source (backup) and target (deployment) storage accounts.
    - PowerShell 5.1 compatible.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]  [string]$ArmTemplateBlobPath,
  [Parameter(Mandatory=$true)]  [string]$ManifestBlobPath,
  [Parameter(Mandatory=$true)]  [string]$CodeZipBlobPath,
  [Parameter(Mandatory=$true)]  [string]$SourceStorageAccount,
  [Parameter(Mandatory=$true)]  [string]$SourceStorageContainer,
  [string]$SourceStorageSubscription,
  [Parameter(Mandatory=$true)]  [string]$TargetSubscriptionId,
  [Parameter(Mandatory=$true)]  [string]$TargetResourceGroup,
  [Parameter(Mandatory=$true)]  [string]$TargetLocation,
  [Parameter(Mandatory=$true)]  [string]$TargetStorageAccountName,
  [string]$NewFunctionAppName,
  [string]$AppInsightsConnectionString,
  [string]$ManagedIdentityName,
  [switch]$SkipCodeDeploy,
  [switch]$SkipKeyRestore
)

$ErrorActionPreference = 'Stop'

#region Helpers

function Invoke-Arm {
  <#
  .SYNOPSIS
    Calls ARM REST API via Invoke-AzRestMethod and returns parsed body.
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$Method  = 'GET',
    [string]$Payload = $null
  )
  $params = @{ Method = $Method; Path = $Path; ErrorAction = 'Stop' }
  if ($Payload) { $params['Payload'] = $Payload }
  $resp = Invoke-AzRestMethod @params
  if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
    return $resp.Content | ConvertFrom-Json
  }
  if ($resp.StatusCode -ge 400) {
    Write-Warning "ARM $Method $Path returned $($resp.StatusCode): $($resp.Content)"
  }
  return $null
}

#endregion Helpers

# ============================================================
#  Step 0: Authenticate and download backup artifacts
# ============================================================

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop | Out-Null

# -- Download backup blobs --
Write-Host "`n[0/5] Downloading backup artifacts from blob storage..." -ForegroundColor Cyan

if ($SourceStorageSubscription) {
  Set-AzContext -Subscription $SourceStorageSubscription -ErrorAction Stop | Out-Null
}

$sourceCtx = New-AzStorageContext -StorageAccountName $SourceStorageAccount -UseConnectedAccount

$tempDir = Join-Path $env:TEMP ("func-restore-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

# Download ARM template
$armLocalFile = Join-Path $tempDir "template.arm.json"
Write-Host "  Downloading ARM template: $ArmTemplateBlobPath" -ForegroundColor DarkGray
Get-AzStorageBlobContent -Context $sourceCtx -Container $SourceStorageContainer `
  -Blob $ArmTemplateBlobPath -Destination $armLocalFile -Force | Out-Null

# Download manifest JSON
$manifestLocalFile = Join-Path $tempDir "manifest.json"
Write-Host "  Downloading manifest: $ManifestBlobPath" -ForegroundColor DarkGray
Get-AzStorageBlobContent -Context $sourceCtx -Container $SourceStorageContainer `
  -Blob $ManifestBlobPath -Destination $manifestLocalFile -Force | Out-Null

# Download code ZIP
$codeZipLocalFile = Join-Path $tempDir "code.zip"
Write-Host "  Downloading code package: $CodeZipBlobPath" -ForegroundColor DarkGray
Get-AzStorageBlobContent -Context $sourceCtx -Container $SourceStorageContainer `
  -Blob $CodeZipBlobPath -Destination $codeZipLocalFile -Force | Out-Null

# Parse manifest
$manifestJson = Get-Content $manifestLocalFile -Raw -ErrorAction Stop
$manifest = $manifestJson | ConvertFrom-Json -ErrorAction Stop

$originalName = $manifest.appName
$restoreName  = if ($NewFunctionAppName) { $NewFunctionAppName } else { "$originalName-dr" }
$isFlex       = ($manifest.sku -eq 'FlexConsumption')

Write-Host "`n  Original Function App : $originalName" -ForegroundColor Green
Write-Host "  Original region       : $($manifest.location)" -ForegroundColor Green
Write-Host "  SKU                   : $($manifest.sku)" -ForegroundColor Green
Write-Host "  Kind                  : $($manifest.kind)" -ForegroundColor Green
Write-Host "  Restore as            : $restoreName" -ForegroundColor Green
Write-Host "  Target region         : $TargetLocation" -ForegroundColor Green
Write-Host "  Target RG             : $TargetResourceGroup" -ForegroundColor Green
Write-Host "  Target Storage        : $TargetStorageAccountName" -ForegroundColor Green

# ============================================================
#  Step 1: Prepare ARM template parameters
# ============================================================

Write-Host "`n[1/5] Preparing ARM template parameters..." -ForegroundColor Cyan

Set-AzContext -Subscription $TargetSubscriptionId -ErrorAction Stop | Out-Null
$resolvedSubId = (Get-AzContext).Subscription.Id

$armParams = @{
  location           = $TargetLocation
  functionAppName    = $restoreName
  storageAccountName = $TargetStorageAccountName
}

if ($AppInsightsConnectionString) {
  $armParams['appInsightsConnectionString'] = $AppInsightsConnectionString
}

# Managed identity name
if ($ManagedIdentityName) {
  $armParams['managedIdentityName'] = $ManagedIdentityName
}
elseif ($manifest.identity -and $manifest.identity.type -like '*UserAssigned*') {
  # Use backup's identity name but append -dr if we're renaming the app
  $origUaiKey = @($manifest.identity.userAssignedIdentities.PSObject.Properties.Name)[0]
  $origUaiName = $origUaiKey.Split('/')[-1]
  if (-not $NewFunctionAppName) {
    $armParams['managedIdentityName'] = "$origUaiName-dr"
  }
  else {
    $armParams['managedIdentityName'] = $origUaiName
  }
  Write-Host "  Managed Identity      : $($armParams['managedIdentityName'])" -ForegroundColor DarkGray
}

foreach ($key in $armParams.Keys) {
  Write-Host "  param: $key = $($armParams[$key])" -ForegroundColor DarkGray
}

# ============================================================
#  Step 2: For Flex Consumption -- create deployment container & upload code
# ============================================================

if ($isFlex -and -not $SkipCodeDeploy) {
  Write-Host "`n[2/5] Preparing Flex Consumption deployment container..." -ForegroundColor Cyan

  # The ARM template expects the container name to be: {functionAppName}-package
  $deployContainerName = "$restoreName-package"
  Write-Host "  Deployment container: $deployContainerName on $TargetStorageAccountName" -ForegroundColor DarkGray

  $targetStorageCtx = New-AzStorageContext -StorageAccountName $TargetStorageAccountName -UseConnectedAccount

  # Ensure the container exists
  $existingContainer = Get-AzStorageContainer -Context $targetStorageCtx -Name $deployContainerName -ErrorAction SilentlyContinue
  if (-not $existingContainer) {
    Write-Host "  Creating container '$deployContainerName'..." -ForegroundColor Yellow
    New-AzStorageContainer -Context $targetStorageCtx -Name $deployContainerName -Permission Off | Out-Null
  }

  # Upload the code ZIP
  Write-Host "  Uploading code package to deployment container..." -ForegroundColor Yellow
  $codeZipSize = [math]::Round((Get-Item $codeZipLocalFile).Length / 1KB, 1)
  Write-Host "  Package size: $codeZipSize KB" -ForegroundColor DarkGray
  Set-AzStorageBlobContent -Context $targetStorageCtx -File $codeZipLocalFile `
    -Container $deployContainerName -Blob "code.zip" -Force | Out-Null
  Write-Host "  Code package uploaded." -ForegroundColor Green
}
else {
  Write-Host "`n[2/5] Skipping deployment container setup (not Flex or -SkipCodeDeploy)." -ForegroundColor DarkGray
}

# ============================================================
#  Step 3: Deploy ARM template
# ============================================================

Write-Host "`n[3/5] Deploying ARM template to $TargetResourceGroup ..." -ForegroundColor Cyan

$deploymentName = "restore-$restoreName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Build the template parameter object for New-AzResourceGroupDeployment
$templateParamObject = @{}
foreach ($key in $armParams.Keys) {
  $templateParamObject[$key] = $armParams[$key]
}

try {
  $deployment = New-AzResourceGroupDeployment `
    -Name                    $deploymentName `
    -ResourceGroupName       $TargetResourceGroup `
    -TemplateFile            $armLocalFile `
    -TemplateParameterObject $templateParamObject `
    -Verbose `
    -ErrorAction Stop

  Write-Host "  Deployment succeeded: $($deployment.ProvisioningState)" -ForegroundColor Green
  if ($deployment.Outputs -and $deployment.Outputs.functionAppDefaultHostName) {
    $defaultHostName = $deployment.Outputs.functionAppDefaultHostName.Value
    Write-Host "  Default hostname: $defaultHostName" -ForegroundColor Green
  }
}
catch {
  Write-Error "ARM deployment failed: $($_.Exception.Message)"
  Write-Host "`n  Deployment name: $deploymentName" -ForegroundColor Red
  Write-Host "  Check deployment details with:" -ForegroundColor Red
  Write-Host "    Get-AzResourceGroupDeploymentOperation -ResourceGroupName $TargetResourceGroup -Name $deploymentName | Select -ExpandProperty Properties" -ForegroundColor Yellow
  return
}

# ============================================================
#  Step 4: Deploy code (classic / non-Flex)
# ============================================================

# -- RBAC assignment EARLY so it can propagate during startup --
if ($isFlex -and $armParams.ContainsKey('managedIdentityName')) {
  $uaiName = $armParams['managedIdentityName']
  Write-Host "`n  Assigning Storage Blob Data Contributor to identity '$uaiName'..." -ForegroundColor Yellow
  try {
    $uai = Get-AzUserAssignedIdentity -ResourceGroupName $TargetResourceGroup -Name $uaiName -ErrorAction Stop
    $storageAcct = Get-AzStorageAccount -ResourceGroupName $TargetResourceGroup -Name $TargetStorageAccountName -ErrorAction SilentlyContinue
    if (-not $storageAcct) {
      $storageAcct = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $TargetStorageAccountName } | Select-Object -First 1
    }
    if ($storageAcct) {
      $existing = Get-AzRoleAssignment -ObjectId $uai.PrincipalId -RoleDefinitionName 'Storage Blob Data Contributor' -Scope $storageAcct.Id -ErrorAction SilentlyContinue
      if ($existing) {
        Write-Host "  Role already assigned." -ForegroundColor DarkGray
      }
      else {
        New-AzRoleAssignment -ObjectId $uai.PrincipalId -RoleDefinitionName 'Storage Blob Data Contributor' -Scope $storageAcct.Id -ErrorAction Stop | Out-Null
        Write-Host "  Storage Blob Data Contributor assigned to '$uaiName' on '$TargetStorageAccountName'." -ForegroundColor Green
        Write-Host "  RBAC propagation can take up to 5 minutes." -ForegroundColor DarkGray
      }
    }
    else {
      Write-Warning "  Could not find storage account '$TargetStorageAccountName'. Assign RBAC manually."
    }
  }
  catch {
    Write-Warning "  RBAC assignment failed: $($_.Exception.Message)"
  }
}

if (-not $isFlex -and -not $SkipCodeDeploy) {
  Write-Host "`n[4/5] Deploying code package to $restoreName ..." -ForegroundColor Cyan

  # Use az functionapp deployment source config-zip for classic consumption/premium
  $zipDeployResult = az functionapp deployment source config-zip `
    --resource-group $TargetResourceGroup `
    --name $restoreName `
    --src $codeZipLocalFile `
    --subscription $resolvedSubId `
    --output json 2>&1

  if ($LASTEXITCODE -eq 0) {
    Write-Host "  Code deployed successfully via ZIP deploy." -ForegroundColor Green
  }
  else {
    Write-Warning "  ZIP deploy returned exit code $LASTEXITCODE. Output: $zipDeployResult"
    Write-Host "  Attempting Publish-AzWebApp fallback..." -ForegroundColor Yellow
    try {
      Publish-AzWebApp -ResourceGroupName $TargetResourceGroup -Name $restoreName `
        -ArchivePath $codeZipLocalFile -Force -ErrorAction Stop
      Write-Host "  Code deployed via Publish-AzWebApp." -ForegroundColor Green
    }
    catch {
      Write-Warning "  Code deployment failed: $($_.Exception.Message)"
      Write-Host "  You can manually deploy the code later from: $codeZipLocalFile" -ForegroundColor Yellow
    }
  }
}
elseif ($isFlex) {
  Write-Host "`n[4/5] Flex Consumption code already deployed via blob container in Step 2." -ForegroundColor Green
}
else {
  Write-Host "`n[4/5] Skipping code deployment (-SkipCodeDeploy)." -ForegroundColor DarkGray
}

# ============================================================
#  Step 5: Restore keys & validate
# ============================================================

Write-Host "`n[5/5] Restoring keys and validating..." -ForegroundColor Cyan

$base = "/subscriptions/$resolvedSubId/resourceGroups/$TargetResourceGroup/providers/Microsoft.Web/sites/$restoreName"
$api  = "api-version=2024-04-01"

# -- Wait for the app AND host runtime to be ready --
# Flex Consumption apps can take 60-120+ seconds for the host runtime to initialize
# after ARM deployment. We poll both the site state AND the host keys endpoint.
$maxWaitSeconds = 240
$waitInterval   = 15
$elapsed        = 0
$appReady       = $false
$hostReady      = $false

Write-Host "  Waiting for Function App and host runtime to be ready..." -ForegroundColor DarkGray
while ($elapsed -lt $maxWaitSeconds) {
  # Check site state first
  if (-not $appReady) {
    $siteCheck = Invoke-Arm -Path "${base}?${api}"
    if ($siteCheck -and $siteCheck.properties.state -eq 'Running') {
      $appReady = $true
      Write-Host "  Site is Running. Waiting for host runtime..." -ForegroundColor DarkGray
    }
  }

  # Once site is running, try listkeys to check if host runtime is ready
  if ($appReady -and -not $hostReady) {
    $hostCheck = Invoke-Arm -Path "${base}/host/default/listkeys?${api}" -Method POST
    if ($hostCheck -and $hostCheck.masterKey) {
      $hostReady = $true
      Write-Host "  Host runtime is ready." -ForegroundColor Green
      break
    }
  }

  Start-Sleep -Seconds $waitInterval
  $elapsed += $waitInterval
  Write-Host "  Still waiting... ($elapsed s)" -ForegroundColor DarkGray
}

if (-not $appReady) {
  Write-Warning "Function App $restoreName is not in 'Running' state after $maxWaitSeconds seconds."
  Write-Host "  Current state: $($siteCheck.properties.state)" -ForegroundColor Yellow
}
elseif (-not $hostReady) {
  Write-Warning "Host runtime not fully initialized after $maxWaitSeconds seconds. Key restoration may fail; you can re-run with just key restore later."
}

# -- Restore host keys --
if (-not $SkipKeyRestore -and $manifest.hostKeys -and $hostReady) {
  Write-Host "  Restoring host keys..." -ForegroundColor Yellow

  # Helper: PUT a key with retry
  function Restore-Key {
    param(
      [string]$Uri,
      [string]$BodyFile,
      [string]$Label,
      [int]$MaxRetries = 3
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
      $result = az rest --method PUT --uri $Uri --body "@$BodyFile" --output none 2>&1
      if ($LASTEXITCODE -eq 0) {
        Write-Host "      $Label restored." -ForegroundColor Green
        return $true
      }
      if ($attempt -lt $MaxRetries) {
        Write-Host "      Retry $attempt/$MaxRetries for $Label (waiting 15s)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
      }
    }
    Write-Warning "      Failed to restore $Label after $MaxRetries attempts."
    return $false
  }

  # Master key
  if ($manifest.hostKeys.masterKey) {
    Write-Host "    Restoring master key..." -ForegroundColor DarkGray
    $keyBody = @{ properties = @{ name = 'master'; value = $manifest.hostKeys.masterKey } } | ConvertTo-Json -Depth 5
    $keyBodyFile = Join-Path $tempDir ("key-master-" + [guid]::NewGuid() + ".json")
    $keyBody | Set-Content -Path $keyBodyFile -Encoding UTF8
    $keyUri = "https://management.azure.com${base}/host/default/functionkeys/master?${api}"
    Restore-Key -Uri $keyUri -BodyFile $keyBodyFile -Label "Master key"
  }

  # Function-level host keys (e.g. 'default')
  if ($manifest.hostKeys.functionKeys) {
    foreach ($prop in $manifest.hostKeys.functionKeys.PSObject.Properties) {
      $keyName  = $prop.Name
      $keyValue = $prop.Value
      Write-Host "    Restoring host function key: $keyName" -ForegroundColor DarkGray
      $keyBody = @{ properties = @{ name = $keyName; value = $keyValue } } | ConvertTo-Json -Depth 5
      $keyBodyFile = Join-Path $tempDir ("key-hfk-$keyName-" + [guid]::NewGuid() + ".json")
      $keyBody | Set-Content -Path $keyBodyFile -Encoding UTF8
      $keyUri = "https://management.azure.com${base}/host/default/functionkeys/${keyName}?${api}"
      Restore-Key -Uri $keyUri -BodyFile $keyBodyFile -Label "Host function key '$keyName'"
    }
  }

  # System keys
  if ($manifest.hostKeys.systemKeys) {
    foreach ($prop in $manifest.hostKeys.systemKeys.PSObject.Properties) {
      $keyName  = $prop.Name
      $keyValue = $prop.Value
      Write-Host "    Restoring system key: $keyName" -ForegroundColor DarkGray
      $keyBody = @{ properties = @{ name = $keyName; value = $keyValue } } | ConvertTo-Json -Depth 5
      $keyBodyFile = Join-Path $tempDir ("key-sys-$keyName-" + [guid]::NewGuid() + ".json")
      $keyBody | Set-Content -Path $keyBodyFile -Encoding UTF8
      $keyUri = "https://management.azure.com${base}/host/default/systemkeys/${keyName}?${api}"
      Restore-Key -Uri $keyUri -BodyFile $keyBodyFile -Label "System key '$keyName'"
    }
  }

  Write-Host "  Host keys restored." -ForegroundColor Green
}
elseif (-not $SkipKeyRestore -and $manifest.hostKeys -and -not $hostReady) {
  Write-Host "  Skipping key restoration -- host runtime not ready." -ForegroundColor Yellow
  Write-Host "  Re-run with the same parameters once the app is fully initialized." -ForegroundColor Yellow
}

# -- Restore per-function keys --
if (-not $SkipKeyRestore -and $manifest.functionKeys -and $hostReady) {
  $fnKeyProps = @($manifest.functionKeys.PSObject.Properties)
  if ($fnKeyProps.Count -gt 0) {
    Write-Host "  Restoring per-function keys..." -ForegroundColor Yellow
    foreach ($fnProp in $fnKeyProps) {
      $fnName = $fnProp.Name
      foreach ($kp in $fnProp.Value.PSObject.Properties) {
        $keyName  = $kp.Name
        $keyValue = $kp.Value
        Write-Host "    $fnName / $keyName" -ForegroundColor DarkGray
        $keyBody = @{ properties = @{ name = $keyName; value = $keyValue } } | ConvertTo-Json -Depth 5
        $keyBodyFile = Join-Path $tempDir ("key-fn-$fnName-$keyName-" + [guid]::NewGuid() + ".json")
        $keyBody | Set-Content -Path $keyBodyFile -Encoding UTF8
        $keyUri = "https://management.azure.com${base}/functions/${fnName}/keys/${keyName}?${api}"
        Restore-Key -Uri $keyUri -BodyFile $keyBodyFile -Label "Function key '$fnName/$keyName'"
      }
    }
    Write-Host "  Per-function keys restored." -ForegroundColor Green
  }
}

# -- Validate: list functions --
Write-Host "`n  Validating deployment..." -ForegroundColor Cyan

$funcsResult = Invoke-Arm -Path "${base}/functions?${api}"
$functionNames = @()
if ($funcsResult -and $funcsResult.value) {
  $functionNames = @($funcsResult.value | ForEach-Object { $_.properties.name })
  Write-Host "  Functions found: $($functionNames -join ', ')" -ForegroundColor Green
}
else {
  Write-Host "  No functions listed yet (may need a few minutes for cold start)." -ForegroundColor Yellow
}

# -- Validate: check site status --
$siteResult = Invoke-Arm -Path "${base}?${api}"
$siteState = "Unknown"
$siteHostName = ""
if ($siteResult) {
  $siteState    = $siteResult.properties.state
  $siteHostName = $siteResult.properties.defaultHostName
}

# ============================================================
#  Summary
# ============================================================

$separator = "=" * 50
Write-Host ""
Write-Host $separator -ForegroundColor Green
Write-Host "Restore completed." -ForegroundColor Green
Write-Host "  Function App        : $restoreName" -ForegroundColor Cyan
Write-Host "  Subscription        : $resolvedSubId" -ForegroundColor Cyan
Write-Host "  Resource Group      : $TargetResourceGroup" -ForegroundColor Cyan
Write-Host "  Location            : $TargetLocation" -ForegroundColor Cyan
Write-Host "  State               : $siteState" -ForegroundColor Cyan
Write-Host "  Default Hostname    : $siteHostName" -ForegroundColor Cyan
Write-Host "  SKU                 : $($manifest.sku)" -ForegroundColor Cyan
Write-Host "  Functions           : $($functionNames -join ', ')" -ForegroundColor Cyan
Write-Host "  Code deployed       : $(-not $SkipCodeDeploy)" -ForegroundColor Cyan
Write-Host "  Keys restored       : $(-not $SkipKeyRestore)" -ForegroundColor Cyan
Write-Host "  Original backup     : $($manifest.backupTimestamp)" -ForegroundColor Cyan
Write-Host "  ARM deployment      : $deploymentName" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Green

# Cleanup temp files (optional -- keep for debugging)
# Remove-Item -Recurse -Force $tempDir
Write-Host "`nTemp files at: $tempDir" -ForegroundColor DarkGray
