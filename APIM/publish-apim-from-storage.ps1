<#
.SYNOPSIS
    Downloads APIM artifacts from Azure Storage and publishes them to a destination APIM instance.

.DESCRIPTION
    This script:
    1. Reads APIM artifacts from an Azure Blob Storage container (extracted by extract-apim-to-storage.ps1)
    2. Downloads the ApiOps publisher tool
    3. Publishes (applies) all artifacts to the specified destination APIM instance
    4. Verifies the destination APIM has the APIs/products after publishing

    Supports cross-subscription and cross-region migration scenarios.

.PARAMETER SourceStorageAccountName
    Name of the Azure Storage Account containing the extracted APIM artifacts.

.PARAMETER SourceContainerName
    Blob container name where artifacts are stored.

.PARAMETER SourceSubscription
    Subscription name or ID where the source storage account resides.

.PARAMETER SourceApimName
    Name of the source APIM instance (used to locate the blob prefix folder).

.PARAMETER DestinationApimName
    Name of the destination APIM instance to publish to.

.PARAMETER DestinationResourceGroupName
    Resource group of the destination APIM instance.

.PARAMETER DestinationSubscription
    Subscription name or ID where the destination APIM resides.

.PARAMETER BlobPrefix
    Full blob prefix path to download from. If omitted, the script will list
    available backups under the SourceApimName folder and let you choose.

.PARAMETER ApiopsVersion
    ApiOps release version to use. Default: v6.0.2.

.PARAMETER ConfigurationYamlPath
    Optional path to a configuration YAML file for overriding values
    (e.g., backend URLs, named values) when publishing to the destination.

.PARAMETER DryRun
    If set, downloads artifacts and shows what would be published without actually running the publisher.

.EXAMPLE
    # Interactive — lists available backups and lets you choose
    .\publish-apim-from-storage.ps1 `
        -SourceStorageAccountName "stgtfxbackuptest" `
        -SourceContainerName "backup" `
        -SourceSubscription "ME-MngEnvMCAP971227-ovmehboo-1" `
        -SourceApimName "apim-poc-k65enjxet44tg" `
        -DestinationApimName "apim-new-region" `
        -DestinationResourceGroupName "rg-apim-new-region" `
        -DestinationSubscription "ME-MngEnvMCAP971227-ovmehboo-1"

.EXAMPLE
    # With explicit blob prefix and dry run
    .\publish-apim-from-storage.ps1 `
        -SourceStorageAccountName "stgtfxbackuptest" `
        -SourceContainerName "backup" `
        -SourceSubscription "ME-MngEnvMCAP971227-ovmehboo-1" `
        -SourceApimName "apim-poc-k65enjxet44tg" `
        -BlobPrefix "apim-poc-k65enjxet44tg/20260309-155251" `
        -DestinationApimName "apim-new-region" `
        -DestinationResourceGroupName "rg-apim-new-region" `
        -DestinationSubscription "ME-MngEnvMCAP971227-ovmehboo-1" `
        -DryRun

.EXAMPLE
    # Cross-subscription with configuration overrides
    .\publish-apim-from-storage.ps1 `
        -SourceStorageAccountName "stgtfxbackuptest" `
        -SourceContainerName "backup" `
        -SourceSubscription "sub-dev" `
        -SourceApimName "apim-poc-k65enjxet44tg" `
        -DestinationApimName "apim-prod-westeurope" `
        -DestinationResourceGroupName "rg-apim-prod" `
        -DestinationSubscription "sub-prod" `
        -ConfigurationYamlPath ".\configuration.prod.yaml"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceStorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$SourceContainerName,

    [Parameter(Mandatory = $true)]
    [string]$SourceSubscription,

    [Parameter(Mandatory = $true)]
    [string]$SourceApimName,

    [Parameter(Mandatory = $true)]
    [string]$DestinationApimName,

    [Parameter(Mandatory = $true)]
    [string]$DestinationResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$DestinationSubscription,

    [string]$BlobPrefix = "",

    [string]$ApiopsVersion = "v6.0.2",

    [string]$ConfigurationYamlPath = "",

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

# ── Step 1: Verify Azure CLI login ─────────────────────────────────
Write-Information "`n=== Step 1: Verifying Azure CLI login ==="
try {
    $account = az account show --query "{name:name, id:id, user:user.name}" -o json 2>$null | ConvertFrom-Json
    Write-Information "  Logged in as : $($account.user)"
    Write-Information "  Current sub  : $($account.name)"
}
catch {
    Write-Error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}

# ── Step 2: Switch to source subscription & verify storage ────────
Write-Information "`n=== Step 2: Verifying source Storage Account ==="
Write-Information "  Switching to source subscription: $SourceSubscription"
az account set --subscription $SourceSubscription 2>$null
$sourceSubId = az account show --query id -o tsv 2>$null
Write-Information "  Source subscription ID: $sourceSubId"

try {
    $storage = az storage account show --name $SourceStorageAccountName --query "{name:name, location:location}" -o json 2>$null | ConvertFrom-Json
    Write-Information "  Storage account : $($storage.name)"
    Write-Information "  Location        : $($storage.location)"
}
catch {
    Write-Error "Storage account '$SourceStorageAccountName' not found in subscription '$SourceSubscription'."
    exit 1
}

# ── Step 3: List available backups / resolve blob prefix ──────────
Write-Information "`n=== Step 3: Resolving backup to restore ==="

if ([string]::IsNullOrWhiteSpace($BlobPrefix)) {
    Write-Information "  Listing available backups for '$SourceApimName'..."

    $blobs = az storage blob list `
        --account-name $SourceStorageAccountName `
        --container-name $SourceContainerName `
        --prefix "$SourceApimName/" `
        --auth-mode login `
        --query "[].name" -o json 2>$null | ConvertFrom-Json

    if (-not $blobs -or $blobs.Count -eq 0) {
        Write-Error "No backups found for '$SourceApimName' in container '$SourceContainerName'."
        exit 1
    }

    # Extract unique backup timestamps (apim-name/timestamp)
    $prefixes = @($blobs | ForEach-Object {
        $parts = $_.Split("/")
        if ($parts.Length -ge 2) { "$($parts[0])/$($parts[1])" }
    } | Sort-Object -Unique)

    Write-Information ""
    Write-Information "  Available backups:"
    Write-Information "  ─────────────────"
    $i = 0
    foreach ($prefix in $prefixes) {
        $i++
        $matchingFiles = @($blobs | Where-Object { $_.StartsWith("$prefix/") })
        Write-Information "    [$i] $prefix ($($matchingFiles.Count) files)"
    }
    Write-Information ""

    $selection = Read-Host "  Select backup number (1-$($prefixes.Count))"
    $selectedIndex = [int]$selection - 1
    if ($selectedIndex -lt 0 -or $selectedIndex -ge $prefixes.Count) {
        Write-Error "Invalid selection."
        exit 1
    }
    $BlobPrefix = $prefixes[$selectedIndex]
    Write-Information "  Selected: $BlobPrefix"
}
else {
    Write-Information "  Using specified prefix: $BlobPrefix"
}

# ── Step 4: Download artifacts from Storage ───────────────────────
Write-Information "`n=== Step 4: Downloading artifacts from Storage ==="

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "apiops-publish-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
$artifactsDir = Join-Path $tempDir "artifacts"
New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

Write-Information "  Source      : $SourceStorageAccountName/$SourceContainerName/$BlobPrefix"
Write-Information "  Download to : $artifactsDir"
Write-Information ""

$blobList = az storage blob list `
    --account-name $SourceStorageAccountName `
    --container-name $SourceContainerName `
    --prefix "$BlobPrefix/" `
    --auth-mode login `
    --query "[].name" -o json 2>$null | ConvertFrom-Json

if (-not $blobList -or $blobList.Count -eq 0) {
    Write-Error "No artifacts found under prefix '$BlobPrefix'."
    exit 1
}

Write-Information "  Found $($blobList.Count) files to download."
Write-Information ""

$downloadCount = 0
foreach ($blobName in $blobList) {
    $relativePath = $blobName.Substring($BlobPrefix.Length).TrimStart("/")
    $localFilePath = Join-Path $artifactsDir $relativePath

    $localDir = Split-Path -Parent $localFilePath
    if (-not (Test-Path $localDir)) {
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    }

    az storage blob download `
        --account-name $SourceStorageAccountName `
        --container-name $SourceContainerName `
        --name $blobName `
        --file $localFilePath `
        --auth-mode login `
        --only-show-errors 2>$null | Out-Null

    $downloadCount++
    Write-Information "  [$downloadCount/$($blobList.Count)] $relativePath"
}

Write-Information ""
Write-Information "  Download complete: $downloadCount files"

# ── Step 5: Show artifact summary ─────────────────────────────────
Write-Information "`n=== Step 5: Artifact summary ==="
$downloadedFiles = @(Get-ChildItem -Path $artifactsDir -Recurse -File)
Write-Information "  Total files: $($downloadedFiles.Count)"
Write-Information ""

$dirs = Get-ChildItem -Path $artifactsDir -Recurse -Directory | Sort-Object FullName
foreach ($dir in $dirs) {
    $depth = ($dir.FullName.Replace($artifactsDir, "").Split([IO.Path]::DirectorySeparatorChar).Length - 1)
    $indent = "  " + ("  " * $depth)
    $filesInDir = @(Get-ChildItem -Path $dir.FullName -File -ErrorAction SilentlyContinue)
    $fileCount = $filesInDir.Count
    Write-Information "$indent[$($dir.Name)] ($fileCount files)"
}

# ── Step 6: Switch to destination subscription & verify APIM ──────
Write-Information "`n=== Step 6: Verifying destination APIM ==="
Write-Information "  Switching to destination subscription: $DestinationSubscription"
az account set --subscription $DestinationSubscription 2>$null
$destSubId = az account show --query id -o tsv 2>$null
Write-Information "  Destination subscription ID: $destSubId"

try {
    $destApim = az apim show --name $DestinationApimName --resource-group $DestinationResourceGroupName --query "{name:name, location:location, sku:sku.name, state:provisioningState}" -o json 2>$null | ConvertFrom-Json
    Write-Information "  Destination APIM : $($destApim.name)"
    Write-Information "  Location         : $($destApim.location)"
    Write-Information "  SKU              : $($destApim.sku)"
    Write-Information "  State            : $($destApim.state)"
}
catch {
    Write-Error "Destination APIM '$DestinationApimName' not found in resource group '$DestinationResourceGroupName' (subscription: $DestinationSubscription)."
    exit 1
}

# ── Show summary before proceeding ────────────────────────────────
Write-Information "`n  ┌──────────────────────────────────────────────┐"
Write-Information "  │           PUBLISH SUMMARY                    │"
Write-Information "  ├──────────────────────────────────────────────┤"
Write-Information "  │ Source                                       │"
Write-Information "  │   Storage  : $SourceStorageAccountName"
Write-Information "  │   Container: $SourceContainerName"
Write-Information "  │   Prefix   : $BlobPrefix"
Write-Information "  │   Files    : $($downloadedFiles.Count)"
Write-Information "  ├──────────────────────────────────────────────┤"
Write-Information "  │ Destination                                  │"
Write-Information "  │   APIM     : $DestinationApimName"
Write-Information "  │   RG       : $DestinationResourceGroupName"
Write-Information "  │   Sub      : $DestinationSubscription"
Write-Information "  │   Location : $($destApim.location)"
if (-not [string]::IsNullOrWhiteSpace($ConfigurationYamlPath)) {
    Write-Information "  │   Config   : $ConfigurationYamlPath"
}
Write-Information "  └──────────────────────────────────────────────┘"

# ── Dry Run check ─────────────────────────────────────────────────
if ($DryRun) {
    Write-Information "`n  *** DRY RUN MODE — no changes will be made ***"
    Write-Information "  Artifacts downloaded to: $artifactsDir"
    Write-Information "  Re-run without -DryRun to publish."
    exit 0
}

# ── Confirm before publishing ─────────────────────────────────────
Write-Information ""
$confirm = Read-Host "  Proceed with publishing to '$DestinationApimName'? (y/N)"
if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-Information "  Cancelled. Artifacts preserved at: $artifactsDir"
    exit 0
}

# ── Step 7: Get bearer token for destination subscription ─────────
Write-Information "`n=== Step 7: Getting Azure bearer token ==="
$bearerToken = az account get-access-token --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($bearerToken)) {
    Write-Error "Failed to get bearer token for destination subscription."
    exit 1
}
Write-Information "  Bearer token acquired for destination subscription."

# ── Step 8: Download publisher tool ───────────────────────────────
Write-Information "`n=== Step 8: Downloading ApiOps publisher ($ApiopsVersion) ==="

if ($IsWindows -or $env:OS -like "*Windows*") {
    $releaseFileName = "publisher-win-x64.zip"
    $executableFileName = "publisher.exe"
}
elseif ($IsMacOS) {
    $arch = uname -m
    if ($arch -eq "arm64") {
        $releaseFileName = "publisher-osx-arm64.zip"
    }
    else {
        $releaseFileName = "publisher-osx-x64.zip"
    }
    $executableFileName = "publisher"
}
else {
    $releaseFileName = "publisher-linux-x64.zip"
    $executableFileName = "publisher"
}

$downloadUrl = "https://github.com/Azure/apiops/releases/download/$ApiopsVersion/$releaseFileName"
$downloadPath = Join-Path $tempDir $releaseFileName
Write-Information "  Downloading: $downloadUrl"
Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath

$publisherDir = Join-Path $tempDir "publisher"
Expand-Archive -Path $downloadPath -DestinationPath $publisherDir -Force
$publisherPath = Join-Path $publisherDir $executableFileName

if (-not ($IsWindows -or $env:OS -like "*Windows*")) {
    & chmod +x $publisherPath
}
Write-Information "  Publisher ready."

# ── Step 9: Run publisher ─────────────────────────────────────────
Write-Information "`n=== Step 9: Publishing to $DestinationApimName ==="

# Set environment variables for the publisher
$env:AZURE_SUBSCRIPTION_ID = $destSubId
$env:AZURE_RESOURCE_GROUP_NAME = $DestinationResourceGroupName
$env:API_MANAGEMENT_SERVICE_NAME = $DestinationApimName
$env:API_MANAGEMENT_SERVICE_OUTPUT_FOLDER_PATH = $artifactsDir
$env:AZURE_BEARER_TOKEN = $bearerToken

# Set optional configuration yaml path
if (-not [string]::IsNullOrWhiteSpace($ConfigurationYamlPath)) {
    $resolvedConfigPath = Resolve-Path $ConfigurationYamlPath -ErrorAction SilentlyContinue
    if ($resolvedConfigPath) {
        $env:CONFIGURATION_YAML_PATH = $resolvedConfigPath.Path
        Write-Information "  Config override: $($resolvedConfigPath.Path)"
    }
    else {
        Write-Warning "  Configuration file '$ConfigurationYamlPath' not found. Proceeding without overrides."
    }
}

# Do NOT set COMMIT_ID — full publish of all artifacts
Write-Information "  Running publisher (full publish — all artifacts)..."
Write-Information ""

& $publisherPath
$publisherExitCode = $LASTEXITCODE

# ── Clean up environment variables ────────────────────────────────
Remove-Item Env:\AZURE_BEARER_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_RESOURCE_GROUP_NAME -ErrorAction SilentlyContinue
Remove-Item Env:\API_MANAGEMENT_SERVICE_NAME -ErrorAction SilentlyContinue
Remove-Item Env:\API_MANAGEMENT_SERVICE_OUTPUT_FOLDER_PATH -ErrorAction SilentlyContinue
Remove-Item Env:\CONFIGURATION_YAML_PATH -ErrorAction SilentlyContinue

if ($publisherExitCode -ne 0) {
    Write-Error "`n  Publisher failed with exit code $publisherExitCode"
    Write-Information "  Artifacts preserved at: $artifactsDir"
    exit 1
}

Write-Information "`n  Publisher completed successfully!"

# ── Step 10: Verify destination APIM ──────────────────────────────
Write-Information "`n=== Step 10: Verifying destination APIM ==="

$targetApis = az apim api list `
    --service-name $DestinationApimName `
    --resource-group $DestinationResourceGroupName `
    --query "[].{name:name, displayName:displayName, path:path}" -o json 2>$null | ConvertFrom-Json

Write-Information "  APIs in $DestinationApimName :"
foreach ($api in $targetApis) {
    Write-Information "    - $($api.displayName) (path: /$($api.path))"
}

$targetProducts = az apim product list `
    --service-name $DestinationApimName `
    --resource-group $DestinationResourceGroupName `
    --query "[].{displayName:displayName, state:state}" -o json 2>$null | ConvertFrom-Json

Write-Information "  Products in $DestinationApimName :"
foreach ($product in $targetProducts) {
    Write-Information "    - $($product.displayName) ($($product.state))"
}

# ── Step 11: Cleanup ──────────────────────────────────────────────
Write-Information "`n=== Step 11: Cleanup ==="
Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Information "  Temp files cleaned up."

# ── Switch back to original subscription ──────────────────────────
Write-Information "  Restoring original subscription context..."
az account set --subscription $SourceSubscription 2>$null

# ── Done ──────────────────────────────────────────────────────────
Write-Information "`n========================================="
Write-Information "  PUBLISH COMPLETE"
Write-Information "========================================="
Write-Information "  Source      : $SourceStorageAccountName/$SourceContainerName/$BlobPrefix"
Write-Information "  Destination : $DestinationApimName ($($destApim.location))"
Write-Information "  Dest RG     : $DestinationResourceGroupName"
Write-Information "  Dest Sub    : $DestinationSubscription"
Write-Information "  Files       : $($downloadedFiles.Count)"
Write-Information "========================================="
