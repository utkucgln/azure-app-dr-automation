##############################################################################
# Backup-AutomationAccountToBlob.ps1
#
# Azure Automation Account – Backup to Blob Storage
#
# Exports all Automation Account components (runbooks, schedules, variables,
# modules, job schedules, credentials, certificates, connections) and uploads
# them to a blob storage account using the following hierarchy:
#
#   <subscription name>/<subscription id>/<resource group>/
#     Microsoft.Automation/<automation account name>/
#       backup-metadata.json
#       runbooks/<runbook-name>-definition.json
#       runbooks/<runbook-name>.ps1 | .py | .graphrunbook
#       schedules/<schedule-name>.json
#       variables/<variable-name>.json
#       modules/<module-name>.json
#       python3packages/<package-name>.json
#       python2packages/<package-name>.json
#       jobschedules/<runbook>--<schedule>.json
#       credentials/<credential-name>.json   (metadata only – no secrets)
#       certificates/<certificate-name>.json (metadata only – no secrets)
#       connections/<connection-name>.json   (metadata only – no secrets)
#
# Pre-requisites:
#   - Azure CLI logged in (az login)
#   - Blob Data Contributor role on the backup storage account
#   - Reader / Contributor on the source Automation Account
#
# Usage:
#   .\Backup-AutomationAccountToBlob.ps1 `
#       -SourceAutomationAccount automationaccountdr `
#       -SourceResourceGroup     rg-agent-lab-01 `
#       -TargetStorageAccount    stagentlab20260105 `
#       -TargetContainer         config-docs
#
##############################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceAutomationAccount,
    [Parameter(Mandatory)][string]$SourceResourceGroup,
    [Parameter(Mandatory)][string]$TargetStorageAccount,
    [string]$TargetContainer   = "config-docs",
    [string]$ApiVersion        = "2023-11-01",
    [switch]$SkipRunbooks,
    [switch]$SkipSchedules,
    [switch]$SkipVariables,
    [switch]$SkipModules,
    [switch]$SkipJobSchedules
)

$ErrorActionPreference = "Stop"

#region ── Helper Functions ───────────────────────────────────────────────────

function Upload-JsonToBlob {
    param(
        [string]$BlobPath,
        [string]$JsonContent,
        [string]$StorageAccount,
        [string]$Container
    )
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

function Upload-FileToBlob {
    param(
        [string]$BlobPath,
        [string]$LocalFile,
        [string]$StorageAccount,
        [string]$Container
    )
    $uploadOutput = az storage blob upload `
        --account-name $StorageAccount `
        --container-name $Container `
        --name $BlobPath `
        --file $LocalFile `
        --auth-mode login `
        --overwrite `
        --no-progress `
        -o none 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload blob: $BlobPath `n$uploadOutput" }
    Write-Host "    ↑ $BlobPath" -ForegroundColor DarkGray
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  AUTOMATION ACCOUNT BACKUP TO BLOB                               ║" -ForegroundColor Cyan
Write-Host "║  Source : $SourceAutomationAccount (RG: $SourceResourceGroup)" -ForegroundColor Cyan
Write-Host "║  Target : $TargetStorageAccount / $TargetContainer"             -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# ── Resolve subscription info ───────────────────────────────────────────────
Write-Host "[0/9] Resolving subscription context ..." -ForegroundColor Yellow
$subJson = az account show -o json | ConvertFrom-Json
$subName = $subJson.name
$subId   = $subJson.id
Write-Host "  Subscription : $subName" -ForegroundColor White
Write-Host "  ID           : $subId" -ForegroundColor White

$blobPrefix = "$subName/$subId/$SourceResourceGroup/Microsoft.Automation/$SourceAutomationAccount"
Write-Host "  Blob prefix  : $blobPrefix`n" -ForegroundColor DarkCyan

# Summary counters
$counts = [ordered]@{
    Runbooks        = 0; Schedules       = 0; Variables       = 0
    Modules         = 0; Python3Packages = 0; Python2Packages = 0
    JobSchedules    = 0; Credentials     = 0; Certificates    = 0
    Connections     = 0
}

# ── Validate source Automation Account ──────────────────────────────────────
Write-Host "[0/9] Validating source Automation Account ..." -ForegroundColor Yellow
$armBase = "/subscriptions/$subId/resourceGroups/$SourceResourceGroup/providers/Microsoft.Automation/automationAccounts/$SourceAutomationAccount"
$armUrl  = "https://management.azure.com${armBase}?api-version=$ApiVersion"

$aaJson = az rest --method GET --url $armUrl -o json 2>$null | ConvertFrom-Json
if (-not $aaJson) {
    throw "Automation Account '$SourceAutomationAccount' not found in RG '$SourceResourceGroup'."
}
Write-Host "  Found: $($aaJson.name) ($($aaJson.location))`n" -ForegroundColor Green

# ── Backup metadata ────────────────────────────────────────────────────────
$metadata = [ordered]@{
    sourceAutomationAccount = $SourceAutomationAccount
    sourceResourceGroup     = $SourceResourceGroup
    sourceLocation          = $aaJson.location
    subscriptionName        = $subName
    subscriptionId          = $subId
    sku                     = $aaJson.properties.sku.name
    state                   = $aaJson.properties.state
    backupTimestamp         = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    apiVersion              = $ApiVersion
} | ConvertTo-Json -Depth 5

Upload-JsonToBlob -BlobPath "$blobPrefix/backup-metadata.json" `
    -JsonContent $metadata -StorageAccount $TargetStorageAccount -Container $TargetContainer

# ── 1. Runbooks ─────────────────────────────────────────────────────────────
if (-not $SkipRunbooks) {
    Write-Host "`n[1/9] Exporting runbooks ..." -ForegroundColor Yellow
    $rbResult = az rest --method GET `
        --url "https://management.azure.com${armBase}/runbooks?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json
    $runbooks = @()
    if ($rbResult -and $rbResult.value) { $runbooks = @($rbResult.value) }

    if ($runbooks.Count -eq 0) {
        Write-Host "  No runbooks found." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Found $($runbooks.Count) runbook(s)." -ForegroundColor Green

        $tempDir = Join-Path $env:TEMP ("aa-backup-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        foreach ($rb in $runbooks) {
            $rbName = $rb.name
            $rbProps = $rb.properties

            # Upload definition JSON
            $rbDef = [ordered]@{
                name             = $rbName
                runbookType      = $rbProps.runbookType
                state            = $rbProps.state
                location         = $rb.location
                description      = $rbProps.description
                logVerbose       = $rbProps.logVerbose
                logProgress      = $rbProps.logProgress
                logActivityTrace = $rbProps.logActivityTrace
                creationTime     = $rbProps.creationTime
                lastModifiedTime = $rbProps.lastModifiedTime
                tags             = $rb.tags
            } | ConvertTo-Json -Depth 10
            Upload-JsonToBlob -BlobPath "$blobPrefix/runbooks/$rbName-definition.json" `
                -JsonContent $rbDef -StorageAccount $TargetStorageAccount -Container $TargetContainer

            # Export runbook content via ARM REST
            $ext = switch ($rbProps.runbookType) {
                'PowerShell'                    { '.ps1' }
                'PowerShell72'                  { '.ps1' }
                'PowerShellWorkflow'            { '.ps1' }
                'Python2'                       { '.py' }
                'Python3'                       { '.py' }
                'GraphicalPowerShell'           { '.graphrunbook' }
                'GraphPowerShell'               { '.graphrunbook' }
                'GraphicalPowerShellWorkflow'   { '.graphrunbook' }
                'GraphPowerShellWorkflow'       { '.graphrunbook' }
                default                         { '.ps1' }
            }

            try {
                $contentUrl = "https://management.azure.com${armBase}/runbooks/$rbName/content?api-version=$ApiVersion"
                $contentOutput = az rest --method GET --url $contentUrl -o tsv 2>$null

                if ($contentOutput) {
                    $localFile = Join-Path $tempDir ($rbName + $ext)
                    $contentOutput | Out-File -FilePath $localFile -Encoding utf8 -Force
                    Upload-FileToBlob -BlobPath "$blobPrefix/runbooks/$rbName$ext" `
                        -LocalFile $localFile -StorageAccount $TargetStorageAccount -Container $TargetContainer
                }
                else {
                    Write-Host "    (no published content for $rbName)" -ForegroundColor DarkGray
                }
            }
            catch {
                Write-Warning "    Could not export content for '$rbName': $($_.Exception.Message)"
            }

            $counts.Runbooks++
        }

        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host "`n[1/9] Skipping runbooks (-SkipRunbooks)." -ForegroundColor DarkGray
}

# ── 2. Schedules ────────────────────────────────────────────────────────────
if (-not $SkipSchedules) {
    Write-Host "`n[2/9] Exporting schedules ..." -ForegroundColor Yellow
    $schResult = az rest --method GET `
        --url "https://management.azure.com${armBase}/schedules?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json
    $schedules = @()
    if ($schResult -and $schResult.value) { $schedules = @($schResult.value) }

    if ($schedules.Count -eq 0) {
        Write-Host "  No schedules found." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Found $($schedules.Count) schedule(s)." -ForegroundColor Green
        foreach ($sch in $schedules) {
            $schJson = [ordered]@{
                name             = $sch.name
                frequency        = $sch.properties.frequency
                interval         = $sch.properties.interval
                startTime        = $sch.properties.startTime
                expiryTime       = $sch.properties.expiryTime
                timeZone         = $sch.properties.timeZone
                isEnabled        = $sch.properties.isEnabled
                nextRun          = $sch.properties.nextRun
                description      = $sch.properties.description
                advancedSchedule = $sch.properties.advancedSchedule
                creationTime     = $sch.properties.creationTime
                lastModifiedTime = $sch.properties.lastModifiedTime
            } | ConvertTo-Json -Depth 10
            Upload-JsonToBlob -BlobPath "$blobPrefix/schedules/$($sch.name).json" `
                -JsonContent $schJson -StorageAccount $TargetStorageAccount -Container $TargetContainer
            $counts.Schedules++
        }
    }
}
else {
    Write-Host "`n[2/9] Skipping schedules (-SkipSchedules)." -ForegroundColor DarkGray
}

# ── 3. Variables ────────────────────────────────────────────────────────────
if (-not $SkipVariables) {
    Write-Host "`n[3/9] Exporting variables ..." -ForegroundColor Yellow
    $varResult = az rest --method GET `
        --url "https://management.azure.com${armBase}/variables?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json
    $variables = @()
    if ($varResult -and $varResult.value) { $variables = @($varResult.value) }

    if ($variables.Count -eq 0) {
        Write-Host "  No variables found." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Found $($variables.Count) variable(s)." -ForegroundColor Green
        foreach ($var in $variables) {
            $varJson = [ordered]@{
                name        = $var.name
                value       = $var.properties.value
                isEncrypted = $var.properties.isEncrypted
                description = $var.properties.description
                creationTime     = $var.properties.creationTime
                lastModifiedTime = $var.properties.lastModifiedTime
            } | ConvertTo-Json -Depth 10

            $label = if ($var.properties.isEncrypted) { "(encrypted – value not readable)" } else { "" }
            if ($label) { Write-Host "    $($var.name) $label" -ForegroundColor DarkGray }

            Upload-JsonToBlob -BlobPath "$blobPrefix/variables/$($var.name).json" `
                -JsonContent $varJson -StorageAccount $TargetStorageAccount -Container $TargetContainer
            $counts.Variables++
        }
    }
}
else {
    Write-Host "`n[3/9] Skipping variables (-SkipVariables)." -ForegroundColor DarkGray
}

# ── 4. Modules ──────────────────────────────────────────────────────────────
if (-not $SkipModules) {
    Write-Host "`n[4/9] Exporting custom modules ..." -ForegroundColor Yellow

    # Use ARM REST to get isGlobal flag
    $modulesRaw = az rest --method GET `
        --url "https://management.azure.com${armBase}/modules?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json

    $customModules = @()
    if ($modulesRaw -and $modulesRaw.value) {
        $customModules = @($modulesRaw.value | Where-Object {
            $_.properties.isGlobal -eq $false
        })
    }

    if ($customModules.Count -eq 0) {
        Write-Host "  No custom modules found." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Found $($customModules.Count) custom module(s)." -ForegroundColor Green
        foreach ($mod in $customModules) {
            $modJson = [ordered]@{
                name              = $mod.name
                version           = $mod.properties.version
                provisioningState = $mod.properties.provisioningState
                isGlobal          = $mod.properties.isGlobal
                contentLink       = $mod.properties.contentLink
                creationTime      = $mod.properties.creationTime
                lastModifiedTime  = $mod.properties.lastModifiedTime
            } | ConvertTo-Json -Depth 10
            Upload-JsonToBlob -BlobPath "$blobPrefix/modules/$($mod.name).json" `
                -JsonContent $modJson -StorageAccount $TargetStorageAccount -Container $TargetContainer
            $counts.Modules++
        }
    }
}
else {
    Write-Host "`n[4/9] Skipping modules (-SkipModules)." -ForegroundColor DarkGray
}

# ── 5. Python 3 Packages ───────────────────────────────────────────────────
Write-Host "`n[5/9] Exporting Python 3 packages ..." -ForegroundColor Yellow
try {
    $py3Raw = az rest --method GET `
        --url "https://management.azure.com${armBase}/python3Packages?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json
    $py3Packages = @()
    if ($py3Raw -and $py3Raw.value) { $py3Packages = @($py3Raw.value) }

    if ($py3Packages.Count -eq 0) {
        Write-Host "  No Python 3 packages found." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Found $($py3Packages.Count) Python 3 package(s)." -ForegroundColor Green
        foreach ($pkg in $py3Packages) {
            $pkgJson = [ordered]@{
                name              = $pkg.name
                version           = $pkg.properties.version
                provisioningState = $pkg.properties.provisioningState
                contentLink       = $pkg.properties.contentLink
                creationTime      = $pkg.properties.creationTime
                lastModifiedTime  = $pkg.properties.lastModifiedTime
            } | ConvertTo-Json -Depth 10
            Upload-JsonToBlob -BlobPath "$blobPrefix/python3packages/$($pkg.name).json" `
                -JsonContent $pkgJson -StorageAccount $TargetStorageAccount -Container $TargetContainer
            $counts.Python3Packages++
        }
    }
} catch { Write-Host "  Could not list Python 3 packages: $($_.Exception.Message)" -ForegroundColor DarkGray }

# ── 6. Python 2 Packages ───────────────────────────────────────────────────
Write-Host "`n[6/9] Exporting Python 2 packages ..." -ForegroundColor Yellow
try {
    $py2Raw = az rest --method GET `
        --url "https://management.azure.com${armBase}/python2Packages?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json
    $py2Packages = @()
    if ($py2Raw -and $py2Raw.value) { $py2Packages = @($py2Raw.value) }

    if ($py2Packages.Count -eq 0) {
        Write-Host "  No Python 2 packages found." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Found $($py2Packages.Count) Python 2 package(s)." -ForegroundColor Green
        foreach ($pkg in $py2Packages) {
            $pkgJson = [ordered]@{
                name              = $pkg.name
                version           = $pkg.properties.version
                provisioningState = $pkg.properties.provisioningState
                contentLink       = $pkg.properties.contentLink
                creationTime      = $pkg.properties.creationTime
                lastModifiedTime  = $pkg.properties.lastModifiedTime
            } | ConvertTo-Json -Depth 10
            Upload-JsonToBlob -BlobPath "$blobPrefix/python2packages/$($pkg.name).json" `
                -JsonContent $pkgJson -StorageAccount $TargetStorageAccount -Container $TargetContainer
            $counts.Python2Packages++
        }
    }
} catch { Write-Host "  Could not list Python 2 packages: $($_.Exception.Message)" -ForegroundColor DarkGray }

# ── 7. Job Schedules ───────────────────────────────────────────────────────
if (-not $SkipJobSchedules) {
    Write-Host "`n[7/9] Exporting job schedule links ..." -ForegroundColor Yellow

    $jobSchedulesRaw = az rest --method GET `
        --url "https://management.azure.com${armBase}/jobSchedules?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json

    $jobSchedules = @()
    if ($jobSchedulesRaw -and $jobSchedulesRaw.value) {
        $jobSchedules = @($jobSchedulesRaw.value)
    }

    if ($jobSchedules.Count -eq 0) {
        Write-Host "  No job schedule links found." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Found $($jobSchedules.Count) job schedule link(s)." -ForegroundColor Green
        foreach ($js in $jobSchedules) {
            $rbName  = $js.properties.runbook.name
            $schName = $js.properties.schedule.name
            $jsJson = [ordered]@{
                jobScheduleId = $js.properties.jobScheduleId
                runbookName   = $rbName
                scheduleName  = $schName
                parameters    = $js.properties.parameters
            } | ConvertTo-Json -Depth 10

            $safeName = "$rbName--$schName"
            Upload-JsonToBlob -BlobPath "$blobPrefix/jobschedules/$safeName.json" `
                -JsonContent $jsJson -StorageAccount $TargetStorageAccount -Container $TargetContainer
            $counts.JobSchedules++
        }
    }
}
else {
    Write-Host "`n[7/9] Skipping job schedules (-SkipJobSchedules)." -ForegroundColor DarkGray
}

# ── 8. Credentials / Certificates / Connections (metadata only) ─────────────
Write-Host "`n[8/9] Exporting credentials, certificates, connections (metadata only) ..." -ForegroundColor Yellow

# Credentials
try {
    $credsRaw = az rest --method GET `
        --url "https://management.azure.com${armBase}/credentials?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json
    $creds = @()
    if ($credsRaw -and $credsRaw.value) { $creds = @($credsRaw.value) }
    if ($creds.Count -gt 0) {
        Write-Host "  Credentials: $($creds.Count)" -ForegroundColor Green
        foreach ($c in $creds) {
            $cJson = [ordered]@{
                name             = $c.name
                userName         = $c.properties.userName
                description      = $c.properties.description
                creationTime     = $c.properties.creationTime
                lastModifiedTime = $c.properties.lastModifiedTime
                note             = "Password/secret NOT included – must be re-entered manually."
            } | ConvertTo-Json -Depth 5
            Upload-JsonToBlob -BlobPath "$blobPrefix/credentials/$($c.name).json" `
                -JsonContent $cJson -StorageAccount $TargetStorageAccount -Container $TargetContainer
            $counts.Credentials++
        }
    }
    else { Write-Host "  No credentials found." -ForegroundColor DarkGray }
} catch { Write-Host "  Could not list credentials." -ForegroundColor DarkGray }

# Certificates
try {
    $certsRaw = az rest --method GET `
        --url "https://management.azure.com${armBase}/certificates?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json
    $certs = @()
    if ($certsRaw -and $certsRaw.value) { $certs = @($certsRaw.value) }
    if ($certs.Count -gt 0) {
        Write-Host "  Certificates: $($certs.Count)" -ForegroundColor Green
        foreach ($cert in $certs) {
            $certJson = [ordered]@{
                name             = $cert.name
                thumbprint       = $cert.properties.thumbprint
                expiryTime       = $cert.properties.expiryTime
                isExportable     = $cert.properties.isExportable
                creationTime     = $cert.properties.creationTime
                lastModifiedTime = $cert.properties.lastModifiedTime
                description      = $cert.properties.description
                note             = "Certificate content NOT included – must be re-imported manually."
            } | ConvertTo-Json -Depth 5
            Upload-JsonToBlob -BlobPath "$blobPrefix/certificates/$($cert.name).json" `
                -JsonContent $certJson -StorageAccount $TargetStorageAccount -Container $TargetContainer
            $counts.Certificates++
        }
    }
    else { Write-Host "  No certificates found." -ForegroundColor DarkGray }
} catch { Write-Host "  Could not list certificates." -ForegroundColor DarkGray }

# Connections
try {
    $connsRaw = az rest --method GET `
        --url "https://management.azure.com${armBase}/connections?api-version=$ApiVersion" `
        -o json 2>$null | ConvertFrom-Json
    $conns = @()
    if ($connsRaw -and $connsRaw.value) { $conns = @($connsRaw.value) }
    if ($conns.Count -gt 0) {
        Write-Host "  Connections: $($conns.Count)" -ForegroundColor Green
        foreach ($conn in $conns) {
            $connJson = [ordered]@{
                name               = $conn.name
                connectionTypeName = $conn.properties.connectionType.name
                description        = $conn.properties.description
                creationTime       = $conn.properties.creationTime
                lastModifiedTime   = $conn.properties.lastModifiedTime
                fieldDefinitions   = $conn.properties.fieldDefinitionValues
                note               = "Secret field values NOT included – must be re-entered manually."
            } | ConvertTo-Json -Depth 10
            Upload-JsonToBlob -BlobPath "$blobPrefix/connections/$($conn.name).json" `
                -JsonContent $connJson -StorageAccount $TargetStorageAccount -Container $TargetContainer
            $counts.Connections++
        }
    }
    else { Write-Host "  No connections found." -ForegroundColor DarkGray }
} catch { Write-Host "  Could not list connections." -ForegroundColor DarkGray }

# ── 9. Summary ──────────────────────────────────────────────────────────────
Write-Host "`n[9/9] Listing backup contents ..." -ForegroundColor Yellow
$blobs = az storage blob list `
    --account-name $TargetStorageAccount `
    --container-name $TargetContainer `
    --prefix "$blobPrefix/" `
    --auth-mode login `
    -o json 2>$null | ConvertFrom-Json

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " BACKUP COMPLETE" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Storage   : $TargetStorageAccount / $TargetContainer" -ForegroundColor White
Write-Host "  Prefix    : $blobPrefix/" -ForegroundColor White
Write-Host "  Files     : $($blobs.Count)" -ForegroundColor White
Write-Host "  Timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host ""
Write-Host "  Runbooks      : $($counts.Runbooks)" -ForegroundColor DarkCyan
Write-Host "  Schedules     : $($counts.Schedules)" -ForegroundColor DarkCyan
Write-Host "  Variables     : $($counts.Variables)" -ForegroundColor DarkCyan
Write-Host "  Modules       : $($counts.Modules)" -ForegroundColor DarkCyan
Write-Host "  Python3 Pkgs  : $($counts.Python3Packages)" -ForegroundColor DarkCyan
Write-Host "  Python2 Pkgs  : $($counts.Python2Packages)" -ForegroundColor DarkCyan
Write-Host "  Job Schedules : $($counts.JobSchedules)" -ForegroundColor DarkCyan
Write-Host "  Credentials   : $($counts.Credentials) (metadata only)" -ForegroundColor DarkCyan
Write-Host "  Certificates  : $($counts.Certificates) (metadata only)" -ForegroundColor DarkCyan
Write-Host "  Connections   : $($counts.Connections) (metadata only)" -ForegroundColor DarkCyan
Write-Host ""

foreach ($b in $blobs) {
    $relPath = $b.name.Replace("$blobPrefix/", "")
    $sizeKB  = [math]::Round($b.properties.contentLength / 1024, 1)
    Write-Host "    $relPath ($sizeKB KB)" -ForegroundColor DarkGray
}
Write-Host ""

#endregion
