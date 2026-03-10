##############################################################################
# backup-aisearch-to-blob.ps1
#
# Azure AI Search – Backup to Blob Storage
#
# Exports all AI Search components (indexes, documents, data sources,
# skillsets, indexers, synonym maps) and uploads them to a blob storage
# account using the following hierarchy:
#
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
# Pre-requisites:
#   - Azure CLI logged in (az login)
#   - Blob Data Contributor role on the backup storage account
#   - Permission to read AI Search admin keys
#
# Usage:
#   .\backup-aisearch-to-blob.ps1 `
#       -SourceServiceName  aisearchuaen `
#       -SourceResourceGroup uaenorthrg `
#       -BackupStorageAccount stgswissnorth `
#       -BackupContainer backup
#
##############################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceServiceName,
    [Parameter(Mandatory)][string]$SourceResourceGroup,
    [string]$BackupStorageAccount = "stgswissnorth",
    [string]$BackupContainer     = "backup",
    [string]$ApiVersion          = "2024-07-01",
    [int]$DocumentBatchSize      = 1000,
    [switch]$SkipDocuments
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

function Upload-JsonToBlob {
    param(
        [string]$BlobPath,
        [string]$JsonContent,
        [string]$StorageAccount,
        [string]$Container
    )
    # Write to a temp file, upload, then clean up
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        $JsonContent | Out-File -FilePath $tmpFile -Encoding utf8 -Force
        $uploadOutput = az storage blob upload `
            --account-name $StorageAccount `
            --container-name $Container `
            --name $BlobPath `
            --file $tmpFile `
            --auth-mode login `
            --overwrite `
            --no-progress `
            -o none 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Failed to upload blob: $BlobPath `n$uploadOutput" }
        Write-Host "    ↑ $BlobPath" -ForegroundColor DarkGray
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  AI SEARCH BACKUP TO BLOB                                        ║" -ForegroundColor Cyan
Write-Host "║  Source : $SourceServiceName (RG: $SourceResourceGroup)" -ForegroundColor Cyan
Write-Host "║  Target : $BackupStorageAccount / $BackupContainer"       -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# ── Resolve subscription info ───────────────────────────────────────────────
Write-Host "[0/6] Resolving subscription context ..." -ForegroundColor Yellow
$subJson  = az account show -o json | ConvertFrom-Json
$subName  = $subJson.name
$subId    = $subJson.id
Write-Host "  Subscription : $subName" -ForegroundColor White
Write-Host "  ID           : $subId" -ForegroundColor White

# Build the blob prefix path following the hierarchy
$blobPrefix = "$subName/$subId/$SourceResourceGroup/Microsoft.Search/$SourceServiceName"
Write-Host "  Blob prefix  : $blobPrefix`n" -ForegroundColor DarkCyan

# ── Get admin key ───────────────────────────────────────────────────────────
Write-Host "[0/6] Retrieving AI Search admin key ..." -ForegroundColor Yellow
$adminKey = az search admin-key show `
    --service-name $SourceServiceName `
    --resource-group $SourceResourceGroup `
    --query "primaryKey" -o tsv 2>$null
if (-not $adminKey) { throw "Could not retrieve admin key for '$SourceServiceName'." }
Write-Host "  Admin key retrieved.`n" -ForegroundColor Green

$headers = @{ "Content-Type" = "application/json"; "api-key" = $adminKey }
$baseUrl = "https://$SourceServiceName.search.windows.net"

# ── Backup metadata ────────────────────────────────────────────────────────
$metadata = @{
    sourceService       = $SourceServiceName
    sourceResourceGroup = $SourceResourceGroup
    subscriptionName    = $subName
    subscriptionId      = $subId
    backupTimestamp     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    apiVersion          = $ApiVersion
} | ConvertTo-Json -Depth 5

Upload-JsonToBlob -BlobPath "$blobPrefix/backup-metadata.json" `
    -JsonContent $metadata -StorageAccount $BackupStorageAccount -Container $BackupContainer

# ── 1. Indexes ──────────────────────────────────────────────────────────────
Write-Host "`n[1/6] Exporting indexes ..." -ForegroundColor Yellow
$indexes = (Invoke-SearchApi -Uri "$baseUrl/indexes?api-version=$ApiVersion" -Headers $headers).value
Write-Host "  Found $($indexes.Count) index(es)." -ForegroundColor Green

foreach ($idx in $indexes) {
    $indexDef = Invoke-SearchApi -Uri "$baseUrl/indexes/$($idx.name)?api-version=$ApiVersion" -Headers $headers

    # Clean server-side-only properties
    $cleanJson = $indexDef | Select-Object -Property * -ExcludeProperty '@odata.context', '@odata.etag' | ConvertTo-Json -Depth 50
    Upload-JsonToBlob -BlobPath "$blobPrefix/indexes/$($idx.name)-definition.json" `
        -JsonContent $cleanJson -StorageAccount $BackupStorageAccount -Container $BackupContainer

    # ── Documents ───────────────────────────────────────────────────────────
    if (-not $SkipDocuments) {
        Write-Host "  Exporting documents from '$($idx.name)' ..." -ForegroundColor Yellow

        $allDocs   = @()
        $batchNum  = 0
        $searchUrl = "$baseUrl/indexes/$($idx.name)/docs/search?api-version=$ApiVersion"

        $keyFieldDef   = $indexDef.fields | Where-Object { $_.key -eq $true }
        $keyIsSortable = $keyFieldDef.sortable -eq $true

        $searchParams = @{ search = "*"; top = $DocumentBatchSize; count = $true }
        if ($keyIsSortable) { $searchParams.orderby = $keyFieldDef.name }

        $result    = Invoke-SearchApi -Uri $searchUrl -Method Post -Headers $headers -Body ($searchParams | ConvertTo-Json)
        $totalDocs = $result.'@odata.count'
        Write-Host "    Total: $totalDocs" -ForegroundColor DarkCyan

        $allDocs += $result.value
        $batchNum++
        Write-Host "    Batch $batchNum : $($result.value.Count) docs" -ForegroundColor DarkGray

        while ($allDocs.Count -lt $totalDocs) {
            $searchParams.skip = $allDocs.Count
            $result = Invoke-SearchApi -Uri $searchUrl -Method Post -Headers $headers -Body ($searchParams | ConvertTo-Json)
            if ($result.value.Count -eq 0) { break }
            $allDocs += $result.value
            $batchNum++
            Write-Host "    Batch $batchNum : $($result.value.Count) docs (total: $($allDocs.Count))" -ForegroundColor DarkGray
        }

        # Clean @search.* properties
        $cleanDocs = $allDocs | ForEach-Object {
            $clean = [ordered]@{}
            foreach ($p in $_.PSObject.Properties) {
                if ($p.Name -notlike '@search.*') { $clean[$p.Name] = $p.Value }
            }
            $clean
        }

        $docsJson = $cleanDocs | ConvertTo-Json -Depth 50
        Upload-JsonToBlob -BlobPath "$blobPrefix/indexes/$($idx.name)-documents.json" `
            -JsonContent $docsJson -StorageAccount $BackupStorageAccount -Container $BackupContainer
        Write-Host "    Exported $($cleanDocs.Count) documents." -ForegroundColor Green
    }
}

# ── 2. Data Sources ─────────────────────────────────────────────────────────
Write-Host "`n[2/6] Exporting data sources ..." -ForegroundColor Yellow
try {
    $dataSources = (Invoke-SearchApi -Uri "$baseUrl/datasources?api-version=$ApiVersion" -Headers $headers).value
    Write-Host "  Found $($dataSources.Count) data source(s)." -ForegroundColor Green
    foreach ($ds in $dataSources) {
        $dsDef = Invoke-SearchApi -Uri "$baseUrl/datasources/$($ds.name)?api-version=$ApiVersion" -Headers $headers
        $cleanJson = $dsDef | Select-Object -Property * -ExcludeProperty '@odata.context', '@odata.etag' | ConvertTo-Json -Depth 50
        Upload-JsonToBlob -BlobPath "$blobPrefix/datasources/$($ds.name).json" `
            -JsonContent $cleanJson -StorageAccount $BackupStorageAccount -Container $BackupContainer
    }
} catch {
    Write-Host "  No data sources found or access denied." -ForegroundColor DarkYellow
}

# ── 3. Skillsets ────────────────────────────────────────────────────────────
Write-Host "`n[3/6] Exporting skillsets ..." -ForegroundColor Yellow
try {
    $skillsets = (Invoke-SearchApi -Uri "$baseUrl/skillsets?api-version=$ApiVersion" -Headers $headers).value
    Write-Host "  Found $($skillsets.Count) skillset(s)." -ForegroundColor Green
    foreach ($ss in $skillsets) {
        $ssDef = Invoke-SearchApi -Uri "$baseUrl/skillsets/$($ss.name)?api-version=$ApiVersion" -Headers $headers
        $cleanJson = $ssDef | Select-Object -Property * -ExcludeProperty '@odata.context', '@odata.etag' | ConvertTo-Json -Depth 50
        Upload-JsonToBlob -BlobPath "$blobPrefix/skillsets/$($ss.name).json" `
            -JsonContent $cleanJson -StorageAccount $BackupStorageAccount -Container $BackupContainer
    }
} catch {
    Write-Host "  No skillsets found or access denied." -ForegroundColor DarkYellow
}

# ── 4. Synonym Maps ────────────────────────────────────────────────────────
Write-Host "`n[4/6] Exporting synonym maps ..." -ForegroundColor Yellow
try {
    $synonyms = (Invoke-SearchApi -Uri "$baseUrl/synonymmaps?api-version=$ApiVersion" -Headers $headers).value
    Write-Host "  Found $($synonyms.Count) synonym map(s)." -ForegroundColor Green
    foreach ($sm in $synonyms) {
        $smDef = Invoke-SearchApi -Uri "$baseUrl/synonymmaps/$($sm.name)?api-version=$ApiVersion" -Headers $headers
        $cleanJson = $smDef | Select-Object -Property * -ExcludeProperty '@odata.context', '@odata.etag' | ConvertTo-Json -Depth 50
        Upload-JsonToBlob -BlobPath "$blobPrefix/synonymmaps/$($sm.name).json" `
            -JsonContent $cleanJson -StorageAccount $BackupStorageAccount -Container $BackupContainer
    }
} catch {
    Write-Host "  No synonym maps found or access denied." -ForegroundColor DarkYellow
}

# ── 5. Indexers ─────────────────────────────────────────────────────────────
Write-Host "`n[5/6] Exporting indexers ..." -ForegroundColor Yellow
try {
    $indexers = (Invoke-SearchApi -Uri "$baseUrl/indexers?api-version=$ApiVersion" -Headers $headers).value
    Write-Host "  Found $($indexers.Count) indexer(s)." -ForegroundColor Green
    foreach ($ixr in $indexers) {
        $ixrDef = Invoke-SearchApi -Uri "$baseUrl/indexers/$($ixr.name)?api-version=$ApiVersion" -Headers $headers
        $cleanJson = $ixrDef | Select-Object -Property * -ExcludeProperty '@odata.context', '@odata.etag' | ConvertTo-Json -Depth 50
        Upload-JsonToBlob -BlobPath "$blobPrefix/indexers/$($ixr.name).json" `
            -JsonContent $cleanJson -StorageAccount $BackupStorageAccount -Container $BackupContainer
    }
} catch {
    Write-Host "  No indexers found or access denied." -ForegroundColor DarkYellow
}

# ── 6. Summary ──────────────────────────────────────────────────────────────
Write-Host "`n[6/6] Listing backup contents ..." -ForegroundColor Yellow
$blobs = az storage blob list `
    --account-name $BackupStorageAccount `
    --container-name $BackupContainer `
    --prefix "$blobPrefix/" `
    --auth-mode login `
    -o json 2>$null | ConvertFrom-Json

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " BACKUP COMPLETE" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Storage   : $BackupStorageAccount / $BackupContainer" -ForegroundColor White
Write-Host "  Prefix    : $blobPrefix/" -ForegroundColor White
Write-Host "  Files     : $($blobs.Count)" -ForegroundColor White
Write-Host "  Timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host ""

foreach ($b in $blobs) {
    $relPath = $b.name.Replace("$blobPrefix/", "")
    $sizeKB  = [math]::Round($b.properties.contentLength / 1024, 1)
    Write-Host "    $relPath ($sizeKB KB)" -ForegroundColor DarkGray
}
Write-Host ""

#endregion
