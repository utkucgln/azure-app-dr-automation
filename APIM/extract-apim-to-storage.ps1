<#
.SYNOPSIS
    Extracts APIM artifacts and uploads them to an Azure Storage Account.

.DESCRIPTION
    This script:
    1. Authenticates to Azure using your current az login session
    2. Downloads the ApiOps extractor tool
    3. Extracts all artifacts from the specified APIM instance
    4. Uploads the artifacts to an Azure Blob Storage container

.PARAMETER ApimName
    Name of the APIM instance to extract from.

.PARAMETER ResourceGroupName
    Resource group containing the APIM instance.

.PARAMETER ApimSubscription
    Subscription name or ID where the APIM instance resides.

.PARAMETER StorageAccountName
    Name of the Azure Storage Account to upload artifacts to.

.PARAMETER StorageResourceGroupName
    Resource group of the Storage Account.

.PARAMETER StorageSubscription
    Subscription name or ID where the Storage Account resides.
    Defaults to the same subscription as the APIM instance.

.PARAMETER ContainerName
    Blob container name. Default: apim-artifacts.

.PARAMETER BlobPrefix
    Optional prefix/folder path in the container. Default: uses APIM name + timestamp.

.PARAMETER ApiopsVersion
    ApiOps release version to use. Default: v6.0.2.

.PARAMETER ApiSpecFormat
    OpenAPI spec format. Default: OpenAPIV3Yaml.

.PARAMETER KeepLocalCopy
    If set, keeps the local extracted artifacts after upload.

.EXAMPLE
    # Same subscription for APIM and Storage
    .\extract-apim-to-storage.ps1 `
        -ApimName "apim-poc-k65enjxet44tg" `
        -ResourceGroupName "rg-apim-multiregion-poc" `
        -ApimSubscription "my-subscription-name-or-id" `
        -StorageAccountName "mystorageaccount" `
        -StorageResourceGroupName "rg-storage" `
        -ContainerName "backup"

.EXAMPLE
    # Cross-subscription: APIM in one sub, Storage in another
    .\extract-apim-to-storage.ps1 `
        -ApimName "apim-poc-k65enjxet44tg" `
        -ResourceGroupName "rg-apim-multiregion-poc" `
        -ApimSubscription "sub-prod" `
        -StorageAccountName "mystorageaccount" `
        -StorageResourceGroupName "rg-storage" `
        -StorageSubscription "sub-backup" `
        -ContainerName "backups"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApimName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ApimSubscription,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$StorageResourceGroupName,

    [string]$StorageSubscription = "",

    [string]$ContainerName = "apim-artifacts",

    [string]$BlobPrefix = "",

    [string]$ApiopsVersion = "v6.0.2",

    [ValidateSet("OpenAPIV3Yaml", "OpenAPIV3Json", "OpenAPIV2Yaml", "OpenAPIV2Json")]
    [string]$ApiSpecFormat = "OpenAPIV3Yaml",

    [switch]$KeepLocalCopy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Default StorageSubscription to ApimSubscription if not provided
if ([string]::IsNullOrWhiteSpace($StorageSubscription)) {
    $StorageSubscription = $ApimSubscription
}

# ── Step 1: Verify Azure CLI login ─────────────────────────────────
Write-Information "`n=== Step 1: Verifying Azure CLI login ==="
try {
    $account = az account show --query "{name:name, id:id, user:user.name}" -o json 2>$null | ConvertFrom-Json
    Write-Information "  Logged in as : $($account.user)"
}
catch {
    Write-Error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}

# ── Step 2: Switch to APIM subscription & verify APIM ─────────────
Write-Information "`n=== Step 2: Verifying APIM instance ==="
Write-Information "  Switching to APIM subscription: $ApimSubscription"
az account set --subscription $ApimSubscription 2>$null
$subscriptionId = az account show --query id -o tsv 2>$null
Write-Information "  Subscription ID: $subscriptionId"

try {
    $apim = az apim show --name $ApimName --resource-group $ResourceGroupName --query "{name:name, location:location, sku:sku.name}" -o json 2>$null | ConvertFrom-Json
    Write-Information "  APIM     : $($apim.name)"
    Write-Information "  Location : $($apim.location)"
    Write-Information "  SKU      : $($apim.sku)"
}
catch {
    Write-Error "APIM instance '$ApimName' not found in resource group '$ResourceGroupName' (subscription: $ApimSubscription)."
    exit 1
}

# ── Step 3: Switch to Storage subscription & verify Storage ───────
Write-Information "`n=== Step 3: Verifying Storage Account ==="
if ($StorageSubscription -ne $ApimSubscription) {
    Write-Information "  Switching to Storage subscription: $StorageSubscription"
    az account set --subscription $StorageSubscription 2>$null
}

try {
    $storage = az storage account show --name $StorageAccountName --resource-group $StorageResourceGroupName --query "{name:name, location:location, kind:kind}" -o json 2>$null | ConvertFrom-Json
    Write-Information "  Storage  : $($storage.name)"
    Write-Information "  Location : $($storage.location)"
}
catch {
    Write-Error "Storage account '$StorageAccountName' not found in resource group '$StorageResourceGroupName' (subscription: $StorageSubscription)."
    exit 1
}

# Create container if it doesn't exist
Write-Information "  Ensuring container '$ContainerName' exists..."
az storage container create --name $ContainerName --account-name $StorageAccountName --auth-mode login --only-show-errors 2>$null | Out-Null
Write-Information "  Container '$ContainerName' ready."

# ── Step 4: Get bearer token (switch back to APIM subscription) ───
Write-Information "`n=== Step 4: Getting Azure bearer token ==="
if ($StorageSubscription -ne $ApimSubscription) {
    az account set --subscription $ApimSubscription 2>$null
}
$bearerToken = az account get-access-token --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($bearerToken)) {
    Write-Error "Failed to get bearer token."
    exit 1
}
Write-Information "  Bearer token acquired."

# ── Step 5: Download extractor ────────────────────────────────────
Write-Information "`n=== Step 5: Downloading ApiOps extractor ($ApiopsVersion) ==="

if ($IsWindows -or $env:OS -like "*Windows*") {
    $releaseFileName = "extractor-win-x64.zip"
    $executableFileName = "extractor.exe"
}
elseif ($IsMacOS) {
    $arch = uname -m
    if ($arch -eq "arm64") {
        $releaseFileName = "extractor-osx-arm64.zip"
    }
    else {
        $releaseFileName = "extractor-osx-x64.zip"
    }
    $executableFileName = "extractor"
}
else {
    $releaseFileName = "extractor-linux-x64.zip"
    $executableFileName = "extractor"
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "apiops-extract-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$downloadUrl = "https://github.com/Azure/apiops/releases/download/$ApiopsVersion/$releaseFileName"
$downloadPath = Join-Path $tempDir $releaseFileName
Write-Information "  Downloading: $downloadUrl"
Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath

$extractorDir = Join-Path $tempDir "extractor"
Expand-Archive -Path $downloadPath -DestinationPath $extractorDir -Force
$extractorPath = Join-Path $extractorDir $executableFileName

if (-not ($IsWindows -or $env:OS -like "*Windows*")) {
    & chmod +x $extractorPath
}
Write-Information "  Extractor ready."

# ── Step 6: Run extractor ─────────────────────────────────────────
Write-Information "`n=== Step 6: Running extractor ==="
$outputPath = Join-Path $tempDir "artifacts"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$env:AZURE_SUBSCRIPTION_ID = $subscriptionId
$env:AZURE_RESOURCE_GROUP_NAME = $ResourceGroupName
$env:API_MANAGEMENT_SERVICE_NAME = $ApimName
$env:API_MANAGEMENT_SERVICE_OUTPUT_FOLDER_PATH = $outputPath
$env:API_SPECIFICATION_FORMAT = $ApiSpecFormat
$env:AZURE_BEARER_TOKEN = $bearerToken

Write-Information "  Extracting from: $ApimName"
Write-Information "  Output folder  : $outputPath"
Write-Information "  Spec format    : $ApiSpecFormat"
Write-Information ""

& $extractorPath
if ($LASTEXITCODE -ne 0) {
    Write-Error "Extractor failed with exit code $LASTEXITCODE"
    exit 1
}

# Clean up sensitive env vars immediately
Remove-Item Env:\AZURE_BEARER_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
Remove-Item Env:\AZURE_RESOURCE_GROUP_NAME -ErrorAction SilentlyContinue
Remove-Item Env:\API_MANAGEMENT_SERVICE_NAME -ErrorAction SilentlyContinue
Remove-Item Env:\API_MANAGEMENT_SERVICE_OUTPUT_FOLDER_PATH -ErrorAction SilentlyContinue
Remove-Item Env:\API_SPECIFICATION_FORMAT -ErrorAction SilentlyContinue

# ── Step 7: Show extracted files ──────────────────────────────────
$extractedFiles = Get-ChildItem -Path $outputPath -Recurse -File
Write-Information "`n=== Step 7: Extraction summary ==="
Write-Information "  Total files extracted: $($extractedFiles.Count)"
Write-Information ""

# Show directory tree
$dirs = Get-ChildItem -Path $outputPath -Recurse -Directory | Sort-Object FullName
foreach ($dir in $dirs) {
    $depth = ($dir.FullName.Replace($outputPath, "").Split([IO.Path]::DirectorySeparatorChar).Length - 1)
    $indent = "  " + ("  " * $depth)
    $filesInDir = @(Get-ChildItem -Path $dir.FullName -File -ErrorAction SilentlyContinue)
    $fileCount = $filesInDir.Count
    Write-Information "$indent[$($dir.Name)] ($fileCount files)"
}

# ── Step 8: Upload to Storage Account ─────────────────────────────
Write-Information "`n=== Step 8: Uploading to Storage Account ==="

# Switch to storage subscription for upload
if ($StorageSubscription -ne $ApimSubscription) {
    Write-Information "  Switching to Storage subscription: $StorageSubscription"
    az account set --subscription $StorageSubscription 2>$null
}

if ([string]::IsNullOrWhiteSpace($BlobPrefix)) {
    $BlobPrefix = "$ApimName/$timestamp"
}

Write-Information "  Storage Account : $StorageAccountName"
Write-Information "  Container       : $ContainerName"
Write-Information "  Blob Prefix     : $BlobPrefix"
Write-Information "  Files to upload : $($extractedFiles.Count)"
Write-Information ""

$uploadCount = 0
$failCount = 0

foreach ($file in $extractedFiles) {
    $relativePath = $file.FullName.Replace($outputPath, "").TrimStart([IO.Path]::DirectorySeparatorChar)
    # Normalize path separators for blob name
    $blobName = "$BlobPrefix/$($relativePath.Replace('\', '/'))"

    try {
        az storage blob upload `
            --account-name $StorageAccountName `
            --container-name $ContainerName `
            --name $blobName `
            --file $file.FullName `
            --auth-mode login `
            --overwrite `
            --only-show-errors 2>$null | Out-Null

        $uploadCount++
        Write-Information "  [$uploadCount/$($extractedFiles.Count)] Uploaded: $blobName"
    }
    catch {
        $failCount++
        Write-Warning "  Failed to upload: $blobName - $_"
    }
}

Write-Information ""
Write-Information "  Upload complete: $uploadCount succeeded, $failCount failed"

# ── Step 9: Cleanup ───────────────────────────────────────────────
Write-Information "`n=== Step 9: Cleanup ==="
if ($KeepLocalCopy) {
    $localCopyPath = Join-Path (Get-Location) "apim-extract-$timestamp"
    Copy-Item -Path $outputPath -Destination $localCopyPath -Recurse -Force
    Write-Information "  Local copy saved to: $localCopyPath"
}

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Information "  Temp files cleaned up."

# ── Done ──────────────────────────────────────────────────────────
Write-Information "`n========================================="
Write-Information "  EXTRACTION COMPLETE"
Write-Information "========================================="
Write-Information "  Source APIM     : $ApimName"
Write-Information "  Files extracted : $($extractedFiles.Count)"
Write-Information "  Uploaded to     : $StorageAccountName/$ContainerName/$BlobPrefix"
Write-Information "========================================="
