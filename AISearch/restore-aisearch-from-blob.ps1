##############################################################################
# restore-aisearch-from-blob.ps1
#
# Azure AI Search – Restore from Blob Storage Backup
#
# Reads backup files from blob storage (created by backup-aisearch-to-blob.ps1)
# and restores all components to a target AI Search service.
#
# Blob hierarchy expected:
#   <subscription name>/<subscription id>/<resource group>/
#     Microsoft.Search/<search service name>/
#       backup-metadata.json
#       indexes/<index-name>-definition.json
#       indexes/<index-name>-documents.json
#       datasources/<datasource-name>.json
#       skillsets/<skillset-name>.json
#       indexers/<indexer-name>.json
#       synonymmaps/<synonymmap-name>.json
#
# Data Source Connection String Mapping:
#   The script replaces connection strings for data sources during restore
#   so they point to the DR-region data stores. Provide the mapping via:
#
#   Option A – Inline hashtable:
#     -DataSourceConnectionStrings @{
#         "blob-datasource" = "DefaultEndpointsProtocol=https;AccountName=drstg;..."
#         "sql-datasource"  = "Server=tcp:drserver.database.windows.net,..."
#     }
#
#   Option B – JSON config file:
#     -DataSourceConfigFile ".\datasource-config.json"
#     File format:
#       {
#         "blob-datasource": "DefaultEndpointsProtocol=https;AccountName=drstg;...",
#         "sql-datasource":  "Server=tcp:drserver.database.windows.net,..."
#       }
#
#   If neither is provided, the original (source) connection strings are used
#   and a warning is shown.
#
# Pre-requisites:
#   - Azure CLI logged in (az login)
#   - Blob Data Reader role on the backup storage account
#   - Permission to read admin keys on the TARGET AI Search service
#
# Usage:
#   # Restore with data source connection string mapping
#   .\restore-aisearch-from-blob.ps1 `
#       -TargetServiceName  aisearchswissnorth `
#       -TargetResourceGroup swissnorthrg `
#       -BackupStorageAccount stgswissnorth `
#       -BackupContainer backup `
#       -SourceServiceName aisearchuaen `
#       -SourceResourceGroup uaenorthrg `
#       -DataSourceConfigFile ".\datasource-config.json"
#
#   # Or with inline hashtable
#   .\restore-aisearch-from-blob.ps1 `
#       -TargetServiceName  aisearchswissnorth `
#       -TargetResourceGroup swissnorthrg `
#       -BackupStorageAccount stgswissnorth `
#       -BackupContainer backup `
#       -SourceServiceName aisearchuaen `
#       -SourceResourceGroup uaenorthrg `
#       -DataSourceConnectionStrings @{ "blob-datasource" = "DefaultEndpointsProtocol=https;..." }
#
#   # Add -RunIndexersAfterRestore to trigger indexers after creation
#   # Add -SkipDocuments to skip document upload (useful with pull-model indexers)
#   # Add -SkipDataSources / -SkipIndexers if you want to reconfigure manually
#
##############################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetServiceName,
    [Parameter(Mandatory)][string]$TargetResourceGroup,

    [string]$BackupStorageAccount = "stgswissnorth",
    [string]$BackupContainer      = "backup",

    # Either provide BlobPrefix directly, or SourceServiceName + SourceResourceGroup
    [string]$BlobPrefix,
    [string]$SourceServiceName,
    [string]$SourceResourceGroup,

    [string]$ApiVersion          = "2024-07-01",
    [int]$DocumentBatchSize      = 1000,

    # Data source connection string mapping (data source name → new connection string)
    [hashtable]$DataSourceConnectionStrings = @{},
    # OR path to a JSON file with the mapping
    [string]$DataSourceConfigFile,

    [switch]$RunIndexersAfterRestore,
    [switch]$SkipDocuments,
    [switch]$SkipDataSources,
    [switch]$SkipIndexers,
    [switch]$SkipSkillsets
)

$ErrorActionPreference = "Stop"

#region ── Helper Functions ───────────────────────────────────────────────────

function Invoke-SearchApi {
    param(
        [string]$Uri,
        [string]$Method = "Get",
        [hashtable]$Headers,
        [string]$Body = $null
    )
    $params = @{ Uri = $Uri; Method = $Method; Headers = $Headers }
    if ($Body) { $params.Body = $Body }
    try {
        return Invoke-RestMethod @params
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $detail     = $_.ErrorDetails.Message
        Write-Warning "API [$Method] $Uri → [$statusCode]: $detail"
        throw
    }
}

function Download-BlobAsJson {
    param(
        [string]$BlobPath,
        [string]$StorageAccount,
        [string]$Container
    )
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        az storage blob download `
            --account-name $StorageAccount `
            --container-name $Container `
            --name $BlobPath `
            --file $tmpFile `
            --auth-mode login `
            --no-progress `
            -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Failed to download blob: $BlobPath" }
        $content = Get-Content -Path $tmpFile -Raw
        return $content
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-BlobList {
    param(
        [string]$Prefix,
        [string]$StorageAccount,
        [string]$Container
    )
    $json = az storage blob list `
        --account-name $StorageAccount `
        --container-name $Container `
        --prefix $Prefix `
        --auth-mode login `
        -o json 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to list blobs with prefix: $Prefix" }
    return ($json | ConvertFrom-Json)
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║  AI SEARCH RESTORE FROM BLOB                                     ║" -ForegroundColor Magenta
Write-Host "║  Target : $TargetServiceName (RG: $TargetResourceGroup)" -ForegroundColor Magenta
Write-Host "║  Backup : $BackupStorageAccount / $BackupContainer"       -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Magenta

# ── Resolve blob prefix ─────────────────────────────────────────────────────
if (-not $BlobPrefix) {
    if (-not $SourceServiceName -or -not $SourceResourceGroup) {
        throw "Provide either -BlobPrefix or both -SourceServiceName and -SourceResourceGroup to locate the backup."
    }
    Write-Host "[0] Resolving backup prefix ..." -ForegroundColor Yellow
    $subJson  = az account show -o json | ConvertFrom-Json
    $subName  = $subJson.name
    $subId    = $subJson.id
    $BlobPrefix = "$subName/$subId/$SourceResourceGroup/Microsoft.Search/$SourceServiceName"
    Write-Host "  Prefix: $BlobPrefix" -ForegroundColor White
}

# ── Verify backup exists ────────────────────────────────────────────────────
Write-Host "`n[0] Verifying backup ..." -ForegroundColor Yellow
$metadataContent = Download-BlobAsJson -BlobPath "$BlobPrefix/backup-metadata.json" `
    -StorageAccount $BackupStorageAccount -Container $BackupContainer
$metadata = $metadataContent | ConvertFrom-Json
Write-Host "  Source service  : $($metadata.sourceService)" -ForegroundColor White
Write-Host "  Backup timestamp: $($metadata.backupTimestamp)" -ForegroundColor White
Write-Host "  Subscription    : $($metadata.subscriptionName)`n" -ForegroundColor White

# ── Get target admin key ────────────────────────────────────────────────────
Write-Host "[0] Retrieving target AI Search admin key ..." -ForegroundColor Yellow
$adminKey = az search admin-key show `
    --service-name $TargetServiceName `
    --resource-group $TargetResourceGroup `
    --query "primaryKey" -o tsv 2>$null
if (-not $adminKey) { throw "Could not retrieve admin key for '$TargetServiceName'." }
Write-Host "  Admin key retrieved.`n" -ForegroundColor Green

$headers = @{ "Content-Type" = "application/json"; "api-key" = $adminKey }
$baseUrl = "https://$TargetServiceName.search.windows.net"

# ── List all backup blobs ───────────────────────────────────────────────────
$allBlobs = Get-BlobList -Prefix "$BlobPrefix/" -StorageAccount $BackupStorageAccount -Container $BackupContainer
Write-Host "  Found $($allBlobs.Count) backup blob(s).`n" -ForegroundColor DarkCyan

# Classify blobs by type
$indexDefBlobs  = $allBlobs | Where-Object { $_.name -like "*/indexes/*-definition.json" }
$indexDocBlobs  = $allBlobs | Where-Object { $_.name -like "*/indexes/*-documents.json" }
$dsBlobs        = $allBlobs | Where-Object { $_.name -like "*/datasources/*.json" }
$ssBlobs        = $allBlobs | Where-Object { $_.name -like "*/skillsets/*.json" }
$smBlobs        = $allBlobs | Where-Object { $_.name -like "*/synonymmaps/*.json" }
$ixrBlobs       = $allBlobs | Where-Object { $_.name -like "*/indexers/*.json" }

# ── 1. Synonym Maps (before indexes that may reference them) ────────────────
Write-Host "[1/5] Restoring $($smBlobs.Count) synonym map(s) ..." -ForegroundColor Yellow
foreach ($b in $smBlobs) {
    $smJson = Download-BlobAsJson -BlobPath $b.name -StorageAccount $BackupStorageAccount -Container $BackupContainer
    $smDef  = $smJson | ConvertFrom-Json
    try {
        Invoke-SearchApi -Uri "$baseUrl/synonymmaps/$($smDef.name)?api-version=$ApiVersion" `
            -Method Delete -Headers $headers | Out-Null
    } catch { }
    Invoke-SearchApi -Uri "$baseUrl/synonymmaps?api-version=$ApiVersion" `
        -Method Post -Headers $headers -Body $smJson | Out-Null
    Write-Host "    ✓ $($smDef.name)" -ForegroundColor Green
}
if ($smBlobs.Count -eq 0) { Write-Host "    (none)" -ForegroundColor DarkGray }

# ── 2. Indexes + Documents ──────────────────────────────────────────────────
Write-Host "`n[2/5] Restoring $($indexDefBlobs.Count) index(es) ..." -ForegroundColor Yellow
foreach ($b in $indexDefBlobs) {
    $idxJson = Download-BlobAsJson -BlobPath $b.name -StorageAccount $BackupStorageAccount -Container $BackupContainer
    $idxDef  = $idxJson | ConvertFrom-Json
    $idxName = $idxDef.name

    # Delete existing index on target
    try {
        Invoke-SearchApi -Uri "$baseUrl/indexes/$($idxName)?api-version=$ApiVersion" `
            -Method Delete -Headers $headers | Out-Null
        Write-Host "    Deleted existing '$idxName'." -ForegroundColor DarkYellow
    } catch { }

    # Create index
    Invoke-SearchApi -Uri "$baseUrl/indexes?api-version=$ApiVersion" `
        -Method Post -Headers $headers -Body $idxJson | Out-Null
    Write-Host "    ✓ Index '$idxName' created." -ForegroundColor Green

    # Upload documents
    if (-not $SkipDocuments) {
        $docBlobName = $b.name -replace '-definition\.json$', '-documents.json'
        $docBlob = $indexDocBlobs | Where-Object { $_.name -eq $docBlobName }
        if ($docBlob) {
            Write-Host "    Downloading documents for '$idxName' ..." -ForegroundColor Yellow
            $docsJson = Download-BlobAsJson -BlobPath $docBlobName `
                -StorageAccount $BackupStorageAccount -Container $BackupContainer
            $docs = $docsJson | ConvertFrom-Json
            if ($null -eq $docs) { $docs = @() }
            if ($docs -isnot [System.Array]) { $docs = @($docs) }
            # Skip upload if no documents
            if ($docs.Count -eq 0) {
                Write-Host "    No documents to upload for '$idxName'." -ForegroundColor DarkGray
                continue
            }
            Write-Host "    Uploading $($docs.Count) documents ..." -ForegroundColor Yellow

            for ($i = 0; $i -lt $docs.Count; $i += $DocumentBatchSize) {
                $batch = $docs[$i..([Math]::Min($i + $DocumentBatchSize - 1, $docs.Count - 1))]

                $uploadBatch = $batch | ForEach-Object {
                    $doc = $_
                    if ($doc -is [System.Management.Automation.PSCustomObject]) {
                        $ht = [ordered]@{ "@search.action" = "upload" }
                        foreach ($prop in $doc.PSObject.Properties) {
                            $ht[$prop.Name] = $prop.Value
                        }
                        $ht
                    } else {
                        $_["@search.action"] = "upload"
                        $_
                    }
                }

                $payload = @{ value = @($uploadBatch) } | ConvertTo-Json -Depth 50
                Invoke-SearchApi -Uri "$baseUrl/indexes/$idxName/docs/index?api-version=$ApiVersion" `
                    -Method Post -Headers $headers -Body $payload | Out-Null

                $uploaded = [Math]::Min($i + $DocumentBatchSize, $docs.Count)
                Write-Host "      $uploaded / $($docs.Count)" -ForegroundColor DarkGray
            }
            Write-Host "    ✓ Documents uploaded." -ForegroundColor Green
        }
    }
}

# ── 3. Data Sources ─────────────────────────────────────────────────────────
if (-not $SkipDataSources) {
    Write-Host "`n[3/5] Restoring $($dsBlobs.Count) data source(s) ..." -ForegroundColor Yellow

    # Build merged connection string map: config file + inline hashtable
    $connStringMap = @{}
    if ($DataSourceConfigFile -and (Test-Path $DataSourceConfigFile)) {
        Write-Host "  Loading data source config from: $DataSourceConfigFile" -ForegroundColor DarkCyan
        $fileMap = Get-Content -Path $DataSourceConfigFile -Raw | ConvertFrom-Json
        foreach ($prop in $fileMap.PSObject.Properties) {
            $connStringMap[$prop.Name] = $prop.Value
        }
    }
    # Inline hashtable overrides file values
    foreach ($key in $DataSourceConnectionStrings.Keys) {
        $connStringMap[$key] = $DataSourceConnectionStrings[$key]
    }

    if ($connStringMap.Count -gt 0) {
        Write-Host "  Connection string mappings provided for: $($connStringMap.Keys -join ', ')" -ForegroundColor DarkCyan
    }

    foreach ($b in $dsBlobs) {
        $dsJson = Download-BlobAsJson -BlobPath $b.name -StorageAccount $BackupStorageAccount -Container $BackupContainer
        $dsDef  = $dsJson | ConvertFrom-Json
        $dsName = $dsDef.name

        # Replace connection string if mapping exists for this data source
        if ($connStringMap.ContainsKey($dsName)) {
            Write-Host "    ↻ Mapping connection string for '$dsName' → target environment" -ForegroundColor Cyan
            $dsDef.credentials.connectionString = $connStringMap[$dsName]
            $dsJson = $dsDef | ConvertTo-Json -Depth 50
        } else {
            Write-Host "    ⚠  No connection string mapping for '$dsName' — using original (source) value" -ForegroundColor Yellow
            Write-Host "       Provide via -DataSourceConnectionStrings or -DataSourceConfigFile" -ForegroundColor DarkYellow
        }

        try {
            Invoke-SearchApi -Uri "$baseUrl/datasources/$($dsName)?api-version=$ApiVersion" `
                -Method Delete -Headers $headers | Out-Null
        } catch { }
        Invoke-SearchApi -Uri "$baseUrl/datasources?api-version=$ApiVersion" `
            -Method Post -Headers $headers -Body $dsJson | Out-Null
        Write-Host "    ✓ $dsName" -ForegroundColor Green
    }
    if ($dsBlobs.Count -eq 0) { Write-Host "    (none)" -ForegroundColor DarkGray }
} else {
    Write-Host "`n[3/5] Skipping data sources (--SkipDataSources)." -ForegroundColor DarkGray
}

# ── 4. Skillsets ────────────────────────────────────────────────────────────
if (-not $SkipSkillsets) {
    Write-Host "`n[4/5] Restoring $($ssBlobs.Count) skillset(s) ..." -ForegroundColor Yellow
    foreach ($b in $ssBlobs) {
        $ssJson = Download-BlobAsJson -BlobPath $b.name -StorageAccount $BackupStorageAccount -Container $BackupContainer
        $ssDef  = $ssJson | ConvertFrom-Json
        try {
            Invoke-SearchApi -Uri "$baseUrl/skillsets/$($ssDef.name)?api-version=$ApiVersion" `
                -Method Delete -Headers $headers | Out-Null
        } catch { }
        Invoke-SearchApi -Uri "$baseUrl/skillsets?api-version=$ApiVersion" `
            -Method Post -Headers $headers -Body $ssJson | Out-Null
        Write-Host "    ✓ $($ssDef.name)" -ForegroundColor Green
    }
    if ($ssBlobs.Count -eq 0) { Write-Host "    (none)" -ForegroundColor DarkGray }
} else {
    Write-Host "`n[4/5] Skipping skillsets (--SkipSkillsets)." -ForegroundColor DarkGray
}

# ── 5. Indexers ─────────────────────────────────────────────────────────────
if (-not $SkipIndexers) {
    Write-Host "`n[5/5] Restoring $($ixrBlobs.Count) indexer(s) ..." -ForegroundColor Yellow
    foreach ($b in $ixrBlobs) {
        $ixrJson = Download-BlobAsJson -BlobPath $b.name -StorageAccount $BackupStorageAccount -Container $BackupContainer
        $ixrDef  = $ixrJson | ConvertFrom-Json
        try {
            Invoke-SearchApi -Uri "$baseUrl/indexers/$($ixrDef.name)?api-version=$ApiVersion" `
                -Method Delete -Headers $headers | Out-Null
        } catch { }
        Invoke-SearchApi -Uri "$baseUrl/indexers?api-version=$ApiVersion" `
            -Method Post -Headers $headers -Body $ixrJson | Out-Null
        Write-Host "    ✓ $($ixrDef.name)" -ForegroundColor Green

        if ($RunIndexersAfterRestore) {
            Write-Host "      Running indexer ..." -ForegroundColor Yellow
            Invoke-SearchApi -Uri "$baseUrl/indexers/$($ixrDef.name)/run?api-version=$ApiVersion" `
                -Method Post -Headers $headers | Out-Null
            Write-Host "      ✓ Started." -ForegroundColor Green
        }
    }
    if ($ixrBlobs.Count -eq 0) { Write-Host "    (none)" -ForegroundColor DarkGray }
} else {
    Write-Host "`n[5/5] Skipping indexers (--SkipIndexers)." -ForegroundColor DarkGray
}

# ── Verification ────────────────────────────────────────────────────────────
Write-Host "`n── Verification ──" -ForegroundColor Cyan
Start-Sleep -Seconds 2
$targetIndexes = (Invoke-SearchApi -Uri "$baseUrl/indexes?api-version=$ApiVersion" -Headers $headers).value
foreach ($idx in $targetIndexes) {
    $countUrl = "$baseUrl/indexes/$($idx.name)/docs/`$count?api-version=$ApiVersion"
    try { $docCount = Invoke-SearchApi -Uri $countUrl -Method Get -Headers $headers } catch { $docCount = "N/A" }
    Write-Host "  Index: $($idx.name)  |  Documents: $docCount" -ForegroundColor White
}

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " RESTORE COMPLETE" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Target    : $TargetServiceName" -ForegroundColor White
Write-Host "  Timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host ""

#endregion
