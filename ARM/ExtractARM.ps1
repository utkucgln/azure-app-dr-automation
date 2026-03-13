<#
.SYNOPSIS
    Exports individual ARM templates per resource using Azure CLI — PARALLEL version.
    Processes up to N resources concurrently using background jobs.
 
.DESCRIPTION
    Architecture:
      Phase 1: Discovery — sequentially scan subscriptions/RGs, build resource list (fast)
      Phase 2: Export    — launch parallel background jobs (sliding window of MaxParallel)
      Phase 3: Summary   — aggregate results, write report
 
    3-Layer fallback strategy per resource:
      Layer 1: az group export (full params + comments)
      Layer 2: az group export --skip-all-params (avoids dependency errors)
      Layer 3: az resource show → wrapped as ARM template (always works)
 
    Generates:
      - Individual ARM template JSON per resource
      - export_report.csv with status, method, and fallback notes
      - .fallback-notes.txt for any resource that fell back from Layer 1
 
.PARAMETER Subscriptions
    Comma-separated subscription IDs. Default: all enabled subscriptions.
 
.PARAMETER ResourceGroups
    Comma-separated resource group names. Default: all in each subscription.
 
.PARAMETER ResourceNames
    Comma-separated resource name filters (substring match, case-insensitive).
 
.PARAMETER ResourceTypes
    Comma-separated resource types (e.g. Microsoft.Web/sites). Exact match.
 
.PARAMETER OutputDir
    Output directory. Default: ./azure_exports
 
.PARAMETER MaxParallel
    Maximum concurrent export jobs. Default: 10. Tune based on VM CPU/memory.
 
.EXAMPLE
    # All resources, 10 parallel jobs (default)
    .\get-arm-templates-parellel.ps1 -Subscriptions "3698a56c-ad86-4211-badd-d5f2c5bf79b7"
 
.EXAMPLE
    # Specific resource, sequential (for debugging)
    .\get-arm-templates-parellel.ps1 -Subscriptions "3698a56c-..." -ResourceNames "isrgtra" -MaxParallel 1
 
.EXAMPLE
    # Multiple subscriptions, 15 parallel jobs
    .\get-arm-templates-parellel.ps1 -Subscriptions "sub1,sub2,sub3" -MaxParallel 15
 
.EXAMPLE
    # All subscriptions, custom output, 8 jobs
    .\get-arm-templates-parellel.ps1 -OutputDir "C:\backups\arm-templates" -MaxParallel 8
#>
 
[CmdletBinding()]
param(
    [string]$Subscriptions = "",
    [string]$ResourceGroups = "",
    [string]$ResourceNames = "",
    [string]$ResourceTypes = "",
    [string]$OutputDir = "./azure_exports",
    [int]$MaxParallel = 10,
    [string]$TargetSubscriptionId = "",
    [string]$TargetResourceGroup = "",
    [string]$TargetStorageAccount = "",
    [string]$TargetContainer = "arm-templates"
)
 
$ErrorActionPreference = "Continue"
$ScriptStartTime = Get-Date
 
# ── Logging helpers ──────────────────────────────────────────────────────────
function Write-LogInfo  { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-LogOK    { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-LogFail  { param([string]$Msg) Write-Host "[FAIL]  $Msg" -ForegroundColor Red }
function Write-LogWarn  { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
 
# ── Pre-checks ───────────────────────────────────────────────────────────────
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Error "Azure CLI (az) is not installed."
    exit 1
}
 
$accountRaw = az account show -o json 2>&1 | Out-String
$accountObj = $null
try { $accountObj = $accountRaw | ConvertFrom-Json -ErrorAction Stop } catch { }
 
if (-not $accountObj -or -not $accountObj.id) {
    Write-Host ""
    Write-Host "[WARN]  'az account show' did not return a valid account." -ForegroundColor Yellow
    Write-Host "[INFO]  If on a VM with Managed Identity, run:  az login --identity" -ForegroundColor Cyan
    Write-Host "[INFO]  If using your own account, run:         az login" -ForegroundColor Cyan
    Write-Host "[INFO]  Raw output was:" -ForegroundColor Gray
    Write-Host "        $($accountRaw.Trim().Substring(0, [Math]::Min(300, $accountRaw.Trim().Length)))" -ForegroundColor Gray
    Write-Host ""
    Write-Error "Not logged in to Azure CLI. Login first, then re-run."
    exit 1
} else {
    Write-LogInfo "Logged in as: $($accountObj.user.name) | Type: $($accountObj.user.type) | Sub: $($accountObj.name)"
}
 
# ── Helper functions ─────────────────────────────────────────────────────────
function Format-Name {
    param([string]$Name)
    $Name -replace '[<>:"/\\|?*]', '_' -replace ' ', '_'
}
 
function Test-NameMatch {
    param([string]$Value, [string]$Filters)
    $filterArray = $Filters -split ',' | ForEach-Object { $_.Trim().ToLower() }
    $valueLower = $Value.ToLower()
    foreach ($f in $filterArray) {
        if ($f -and $valueLower -like "*$f*") { return $true }
    }
    return $false
}
 
function Test-TypeMatch {
    param([string]$Value, [string]$Filters)
    $filterArray = $Filters -split ',' | ForEach-Object { $_.Trim().ToLower() }
    $valueLower = $Value.ToLower()
    foreach ($f in $filterArray) {
        if ($f -and $valueLower -eq $f) { return $true }
    }
    return $false
}
 
# ── Setup ────────────────────────────────────────────────────────────────────
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$ReportFile = Join-Path $OutputDir "export_report.csv"
"subscription,subscription_id,resource_group,resource_type,resource_name,resource_id,status,file,method_or_error,timestamp,fallback_notes" | Out-File -FilePath $ReportFile -Encoding UTF8
 
# ── Capture proxy env vars to pass into jobs ─────────────────────────────────
$ProxyEnv = @{
    HTTP_PROXY  = $env:HTTP_PROXY
    HTTPS_PROXY = $env:HTTPS_PROXY
    NO_PROXY    = $env:NO_PROXY
    AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = $env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION
    REQUESTS_CA_BUNDLE = $env:REQUESTS_CA_BUNDLE
}
 
# ── Storage account upload flag ──────────────────────────────────────────────
$UploadToStorage = $false
if ($TargetSubscriptionId -and $TargetResourceGroup -and $TargetStorageAccount) {
    $UploadToStorage = $true
    Write-LogInfo "Storage upload enabled: $TargetStorageAccount/$TargetContainer"
    Write-LogInfo "  Subscription : $TargetSubscriptionId"
    Write-LogInfo "  Resource Group: $TargetResourceGroup"
}
 
# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1: DISCOVERY — Build flat list of all resources to export
# ══════════════════════════════════════════════════════════════════════════════
Write-LogInfo "Phase 1: Discovering resources..."
Write-Host ""
 
if ($Subscriptions) {
    $SubIds = $Subscriptions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else {
    $SubIds = (az account list --query "[?state=='Enabled'].id" -o tsv 2>$null) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
 
Write-LogInfo "Subscriptions to scan: $($SubIds.Count)"
 
$AllResources = [System.Collections.ArrayList]::new()
 
foreach ($SubId in $SubIds) {
    $SubId = $SubId.Trim()
    $SubName = (az account show --subscription $SubId --query "name" -o tsv 2>$null)
    if (-not $SubName) { $SubName = $SubId }
 
    Write-LogInfo ("=" * 60)
    Write-LogInfo "Scanning: $SubName ($SubId)"
 
    if ($ResourceGroups) {
        $RGList = $ResourceGroups -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        $RGList = (az group list --subscription $SubId --query "[].name" -o tsv 2>$null) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
 
    Write-LogInfo "  Resource groups: $($RGList.Count)"
 
    foreach ($RGName in $RGList) {
        $RGName = $RGName.Trim()
        if (-not $RGName) { continue }
 
        $ResourcesRaw = az resource list `
            --subscription $SubId `
            --resource-group $RGName `
            --query "[].{name:name, type:type, id:id, location:location}" `
            -o json 2>$null
 
        if (-not $ResourcesRaw -or $ResourcesRaw -eq "[]") { continue }
 
        try { $Resources = $ResourcesRaw | ConvertFrom-Json } catch { continue }
        if ($Resources.Count -eq 0) { continue }
 
        $filtered = 0
        foreach ($Res in $Resources) {
            # Apply filters
            if ($ResourceNames) {
                if (-not (Test-NameMatch -Value $Res.name -Filters $ResourceNames)) { continue }
            }
            if ($ResourceTypes) {
                if (-not (Test-TypeMatch -Value $Res.type -Filters $ResourceTypes)) { continue }
            }
 
            # Build output path — now includes SubId in folder structure
            # Pattern: OutputDir/date/sub-name/sub-id/rg-name/resource-type/resource-name.json
            $DateFolder = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
            $TypeFolder = Format-Name ($Res.type -replace '/', '-')
            $ResOutDir = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $OutputDir $DateFolder) (Format-Name $SubName)) $SubId) (Format-Name $RGName)) $TypeFolder
            $ResOutFile = Join-Path $ResOutDir "$(Format-Name $Res.name).json"
 
            [void]$AllResources.Add([PSCustomObject]@{
                SubId      = $SubId
                SubName    = $SubName
                RGName     = $RGName
                RName      = $Res.name
                RType      = $Res.type
                RId        = $Res.id
                RLoc       = $Res.location
                OutDir     = $ResOutDir
                OutFile    = $ResOutFile
            })
            $filtered++
        }
 
        if ($filtered -gt 0) {
            Write-LogInfo "    $RGName : $filtered resource(s) queued"
        }
    }
}
 
$TotalCount = $AllResources.Count
Write-Host ""
Write-LogInfo ("=" * 60)
Write-LogInfo "Phase 1 complete: $TotalCount resources to export"
Write-LogInfo "Max parallel jobs: $MaxParallel"
Write-LogInfo ("=" * 60)
Write-Host ""
 
if ($TotalCount -eq 0) {
    Write-LogWarn "No resources found matching filters. Exiting."
    exit 0
}
 
# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2: PARALLEL EXPORT — Sliding window of background jobs
# ══════════════════════════════════════════════════════════════════════════════
Write-LogInfo "Phase 2: Exporting ARM templates ($MaxParallel parallel jobs)..."
Write-Host ""
 
# ── The ScriptBlock that runs inside each background job ─────────────────────
$ExportScriptBlock = {
    param(
        [string]$SubId,
        [string]$SubName,
        [string]$RGName,
        [string]$RName,
        [string]$RType,
        [string]$RId,
        [string]$RLoc,
        [string]$OutDir,
        [string]$OutFile,
        [hashtable]$ProxyEnv
    )
 
    # Restore proxy environment variables inside the job
    if ($ProxyEnv.HTTP_PROXY)  { $env:HTTP_PROXY  = $ProxyEnv.HTTP_PROXY }
    if ($ProxyEnv.HTTPS_PROXY) { $env:HTTPS_PROXY = $ProxyEnv.HTTPS_PROXY }
    if ($ProxyEnv.NO_PROXY)    { $env:NO_PROXY    = $ProxyEnv.NO_PROXY }
    if ($ProxyEnv.AZURE_CLI_DISABLE_CONNECTION_VERIFICATION) {
        $env:AZURE_CLI_DISABLE_CONNECTION_VERIFICATION = $ProxyEnv.AZURE_CLI_DISABLE_CONNECTION_VERIFICATION
    }
    if ($ProxyEnv.REQUESTS_CA_BUNDLE) {
        $env:REQUESTS_CA_BUNDLE = $ProxyEnv.REQUESTS_CA_BUNDLE
    }
 
    $Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
 
    # Create output directory
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
 
    $Exported = $false
    $ExportMethod = ""
    $L1Error = ""
    $L2Error = ""
    $FallbackNotes = ""
 
    # ── Layer 1: az group export (full params) ────────────────────────────
    $ExportResult = az group export `
        --subscription $SubId `
        --resource-group $RGName `
        --resource-ids $RId `
        --include-parameter-default-value `
        --include-comments `
        -o json 2>&1 | Out-String
 
    try {
        $parsed = $ExportResult | ConvertFrom-Json -ErrorAction Stop
        if ($parsed.'$schema') {
            $ExportResult | Out-File -FilePath $OutFile -Encoding UTF8
            $Exported = $true
            $ExportMethod = "group-export"
        }
    } catch { }
 
    if (-not $Exported) {
        $L1Error = ($ExportResult -split "`n" | Where-Object { $_ -match 'ERROR|WARNING|Could not' } | Select-Object -First 5) -join "`n"
    }
 
    # ── Layer 2: az group export --skip-all-params ────────────────────────
    if (-not $Exported) {
        $ExportResult = az group export `
            --subscription $SubId `
            --resource-group $RGName `
            --resource-ids $RId `
            --skip-all-params `
            --skip-resource-name-params `
            -o json 2>&1 | Out-String
 
        try {
            $parsed = $ExportResult | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.'$schema') {
                $ExportResult | Out-File -FilePath $OutFile -Encoding UTF8
                $Exported = $true
                $ExportMethod = "group-export-skip-params"
            }
        } catch { }
 
        if (-not $Exported) {
            $L2Error = ($ExportResult -split "`n" | Where-Object { $_ -match 'ERROR|WARNING|Could not' } | Select-Object -First 5) -join "`n"
        }
    }
 
    # ── Layer 3: az resource show → build ARM template ────────────────────
    if (-not $Exported) {
        $ResourceRaw = az resource show --ids $RId -o json 2>&1 | Out-String
 
        try {
            $ResourceObj = $ResourceRaw | ConvertFrom-Json -ErrorAction Stop
            if ($ResourceObj.id) {
                $ApiVersion = $ResourceObj.apiVersion
                if (-not $ApiVersion) {
                    $Provider = ($RType -split '/')[0]
                    $SubType = ($RType -split '/', 2)[1]
                    $ApiVersion = (az provider show `
                        --namespace $Provider `
                        --query "resourceTypes[?resourceType=='$SubType'].apiVersions[0]" `
                        -o tsv 2>$null | Select-Object -First 1)
                }
                if (-not $ApiVersion) { $ApiVersion = "2023-01-01" }
 
                $ArmTemplate = [ordered]@{
                    '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
                    contentVersion = "1.0.0.0"
                    metadata       = @{
                        _generator = @{
                            name    = "get-arm-templates.ps1 (az resource show fallback)"
                            version = "1.0.0"
                        }
                    }
                    resources      = @(
                        [ordered]@{
                            type       = $RType
                            apiVersion = $ApiVersion
                            name       = $RName
                            location   = $RLoc
                            properties = $ResourceObj.properties
                            tags       = if ($ResourceObj.tags) { $ResourceObj.tags } else { @{} }
                        }
                    )
                }
 
                if ($ResourceObj.sku)      { $ArmTemplate.resources[0].sku      = $ResourceObj.sku }
                if ($ResourceObj.kind)     { $ArmTemplate.resources[0].kind     = $ResourceObj.kind }
                if ($ResourceObj.identity) { $ArmTemplate.resources[0].identity = $ResourceObj.identity }
 
                $ArmTemplate | ConvertTo-Json -Depth 20 | Out-File -FilePath $OutFile -Encoding UTF8
                $Exported = $true
                $ExportMethod = "resource-show-fallback"
            }
        } catch { }
    }
 
    # ── Build fallback notes and write .fallback-notes.txt ────────────────
    if ($Exported) {
        if ($ExportMethod -eq "group-export-skip-params" -and $L1Error) {
            $depMatches = [regex]::Matches($L1Error, "Could not get resources of the type '([^']+)'")
            $MissingDeps = ($depMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join '|'
            $L1Short = ($L1Error -split "`n" | Select-Object -First 1) -replace '.*ERROR:\s*', ''
            $FallbackNotes = "Layer1 failed: $L1Short"
            if ($MissingDeps) { $FallbackNotes += " | Missing deps: $MissingDeps" }
 
            $ErrorsFile = $OutFile -replace '\.json$', '.fallback-notes.txt'
            @(
                "=== Fallback Report for $RType/$RName ==="
                "Export method used: $ExportMethod"
                ""
                "-- Layer 1 (group-export) errors: --"
                $L1Error
            ) | Out-File -FilePath $ErrorsFile -Encoding UTF8
 
        } elseif ($ExportMethod -eq "resource-show-fallback") {
            $AllErrors = "$L1Error`n$L2Error"
            $depMatches = [regex]::Matches($AllErrors, "Could not get resources of the type '([^']+)'")
            $MissingDepsArr = $depMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            $MissingDeps = $MissingDepsArr -join '|'
            $L1Short = if ($L1Error) { ($L1Error -split "`n" | Select-Object -First 1) -replace '.*ERROR:\s*', '' } else { "ok" }
            $L2Short = if ($L2Error) { ($L2Error -split "`n" | Select-Object -First 1) -replace '.*ERROR:\s*', '' } else { "ok" }
            $FallbackNotes = "Layer1: $L1Short | Layer2: $L2Short"
            if ($MissingDeps) { $FallbackNotes += " | Missing deps: $MissingDeps" }
 
            $ErrorsFile = $OutFile -replace '\.json$', '.fallback-notes.txt'
            $DepLines = if ($MissingDepsArr.Count -gt 0) {
                $MissingDepsArr | ForEach-Object { "  - $_" }
            } else { "  (none detected)" }
            $CmdLines = if ($MissingDepsArr.Count -gt 0) {
                $MissingDepsArr | ForEach-Object { "  .\get-arm-templates-parellel.ps1 -Subscriptions `"$SubId`" -ResourceGroups `"$RGName`" -ResourceTypes `"$_`"" }
            } else { "  (no specific commands)" }
 
            @(
                "=== Fallback Report for $RType/$RName ==="
                "Export method used: $ExportMethod"
                "The ARM template was built from 'az resource show' output."
                "It contains the full resource definition but NOT dependent resources."
                ""
                "-- Missing dependencies (export these separately): --"
                $DepLines
                ""
                "-- To export missing dependencies, run: --"
                $CmdLines
                ""
                "-- Full Layer 1 errors: --"
                $L1Error
                ""
                "-- Full Layer 2 errors: --"
                $L2Error
            ) | Out-File -FilePath $ErrorsFile -Encoding UTF8
        }
    }
 
    # ── Return result object to parent ────────────────────────────────────
    $ErrorMsg = ""
    if (-not $Exported) {
        $ErrorMsg = ($ExportResult -replace ',', ';' -replace '"', "'" -replace "`n", ' ')
        if ($ErrorMsg.Length -gt 300) { $ErrorMsg = $ErrorMsg.Substring(0, 300) }
    }
 
    [PSCustomObject]@{
        SubName        = $SubName
        SubId          = $SubId
        RGName         = $RGName
        RType          = $RType
        RName          = $RName
        RId            = $RId
        Exported       = $Exported
        ExportMethod   = $ExportMethod
        OutFile        = $OutFile
        Timestamp      = $Timestamp
        FallbackNotes  = $FallbackNotes
        ErrorMsg       = $ErrorMsg
    }
}
 
# ── Job management: sliding window ───────────────────────────────────────────
$RunningJobs = [System.Collections.ArrayList]::new()
$CompletedCount = 0
$OKCount = 0
$FailCount = 0
$L1Count = 0
$L2Count = 0
$L3Count = 0
 
# Helper: drain completed jobs and process results
function Complete-FinishedJobs {
    param([bool]$WaitForAll = $false)
 
    $jobsToRemove = [System.Collections.ArrayList]::new()
 
    foreach ($job in $RunningJobs) {
        if ($job.State -eq 'Completed' -or $job.State -eq 'Failed') {
            [void]$jobsToRemove.Add($job)
 
            $result = $null
            try {
                $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
            } catch { }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
 
            if (-not $result) { continue }
 
            $script:CompletedCount++
 
            if ($result.Exported) {
                $script:OKCount++
                switch ($result.ExportMethod) {
                    "group-export"            { $script:L1Count++ }
                    "group-export-skip-params" { $script:L2Count++ }
                    "resource-show-fallback"   { $script:L3Count++ }
                }
 
                Write-LogOK "    [$script:CompletedCount/$script:TotalCount] $($result.RType)/$($result.RName)  [$($result.ExportMethod)]"
 
                if ($result.FallbackNotes) {
                    Write-LogWarn "      +-- $($result.FallbackNotes.Substring(0, [Math]::Min(120, $result.FallbackNotes.Length)))"
                }
 
                $NotesCsv = $result.FallbackNotes -replace ',', ';' -replace '"', "'"
                "$($result.SubName),$($result.SubId),$($result.RGName),$($result.RType),$($result.RName),$($result.RId),SUCCESS,$($result.OutFile),$($result.ExportMethod),$($result.Timestamp),$NotesCsv" | Out-File -FilePath $script:ReportFile -Append -Encoding UTF8
 
            } else {
                $script:FailCount++
                $shortErr = if ($result.ErrorMsg.Length -gt 100) { $result.ErrorMsg.Substring(0, 100) } else { $result.ErrorMsg }
                Write-LogFail "    [$script:CompletedCount/$script:TotalCount] $($result.RType)/$($result.RName): $shortErr"
                "$($result.SubName),$($result.SubId),$($result.RGName),$($result.RType),$($result.RName),$($result.RId),FAILED,,`"$($result.ErrorMsg)`",$($result.Timestamp),all layers failed" | Out-File -FilePath $script:ReportFile -Append -Encoding UTF8
            }
 
            # Update progress bar
            $pct = [Math]::Floor(($script:CompletedCount / $script:TotalCount) * 100)
            $activeJobs = ($script:RunningJobs.Count - $jobsToRemove.Count)
            Write-Progress -Activity "Exporting ARM templates" `
                -Status "$($script:CompletedCount)/$($script:TotalCount) done | $activeJobs active jobs | OK:$($script:OKCount) Fail:$($script:FailCount)" `
                -PercentComplete $pct
        }
    }
 
    # Remove completed jobs from the running list
    foreach ($j in $jobsToRemove) {
        [void]$script:RunningJobs.Remove($j)
    }
 
    # If waiting for all, block until all are done
    if ($WaitForAll -and $script:RunningJobs.Count -gt 0) {
        $remaining = $script:RunningJobs | Where-Object { $_.State -eq 'Running' }
        if ($remaining) {
            $remaining | Wait-Job -Timeout 600 | Out-Null
            # Recurse to drain the rest
            Complete-FinishedJobs -WaitForAll $true
        }
    }
}
 
# ── Launch jobs with sliding window ──────────────────────────────────────────
$jobIndex = 0
 
foreach ($res in $AllResources) {
    $jobIndex++
 
    # Wait if we're at the max parallel limit
    while ($RunningJobs.Count -ge $MaxParallel) {
        Start-Sleep -Milliseconds 500
        Complete-FinishedJobs
    }
 
    # Also drain any that finished while we were launching
    Complete-FinishedJobs
 
    $jobName = "ARM-$jobIndex-$(Format-Name $res.RName)"
 
    $job = Start-Job -Name $jobName -ScriptBlock $ExportScriptBlock -ArgumentList @(
        $res.SubId,
        $res.SubName,
        $res.RGName,
        $res.RName,
        $res.RType,
        $res.RId,
        $res.RLoc,
        $res.OutDir,
        $res.OutFile,
        $ProxyEnv
    )
 
    [void]$RunningJobs.Add($job)
 
    # Log job launch (minimal)
    Write-Host "  [JOB $jobIndex/$TotalCount] Launched: $($res.RType)/$($res.RName)" -ForegroundColor DarkGray
}
 
# ── Wait for all remaining jobs ──────────────────────────────────────────────
Write-LogInfo "All $TotalCount jobs launched. Waiting for remaining $($RunningJobs.Count) to complete..."
 
while ($RunningJobs.Count -gt 0) {
    Start-Sleep -Milliseconds 1000
    Complete-FinishedJobs
}
 
# Final drain (catch any stragglers)
Complete-FinishedJobs -WaitForAll $true
 
Write-Progress -Activity "Exporting ARM templates" -Completed
 
# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2.5: UPLOAD ENTIRE FOLDER TO STORAGE ACCOUNT (batch upload)
# ══════════════════════════════════════════════════════════════════════════════
$UploadOKCount = 0
$UploadFailCount = 0
$DatePrefix = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
 
if ($UploadToStorage) {
    Write-Host ""
    Write-LogInfo ("=" * 60)
    Write-LogInfo "Phase 2.5: Batch uploading entire export folder to Storage Account..."
    Write-LogInfo "  Target: $TargetStorageAccount/$TargetContainer"
    Write-LogInfo ("=" * 60)
    Write-Host ""
 
    try {
        $previousSub = (az account show --query "id" -o tsv 2>$null)
        az account set --subscription $TargetSubscriptionId 2>$null
 
        # Get storage account key
        $storageKeysRaw = az storage account keys list `
            --subscription $TargetSubscriptionId `
            --resource-group $TargetResourceGroup `
            --account-name $TargetStorageAccount `
            -o json 2>&1 | Out-String
 
        $storageKeys = $storageKeysRaw | ConvertFrom-Json -ErrorAction Stop
        $storageKey = $storageKeys[0].value
 
        # Ensure container exists
        az storage container create `
            --account-name $TargetStorageAccount `
            --account-key $storageKey `
            --name $TargetContainer `
            --auth-mode key 2>$null | Out-Null
 
        Write-LogOK "Storage container '$TargetContainer' ready."
 
        # The local folder to upload is: OutputDir/date/
        # This matches the blob structure: container/date/sub-name/sub-id/rg/type/name.json
        $LocalDateFolder = Join-Path $OutputDir $DatePrefix
 
        if (Test-Path $LocalDateFolder) {
            # Count files to upload
            $filesToUpload = (Get-ChildItem -Path $LocalDateFolder -Recurse -File).Count
            Write-LogInfo "Uploading $filesToUpload file(s) from: $LocalDateFolder"
            Write-LogInfo "Blob prefix: $DatePrefix/"
            Write-LogInfo "Using 'az storage blob upload-batch' for maximum speed..."
            Write-Host ""
 
            # Single batch upload — uploads the entire folder tree in one command
            # az storage blob upload-batch preserves the relative folder structure as blob paths
            $batchOut = az storage blob upload-batch `
                --account-name $TargetStorageAccount `
                --account-key $storageKey `
                --destination $TargetContainer `
                --destination-path $DatePrefix `
                --source $LocalDateFolder `
                --overwrite true `
                --no-progress 2>&1 | Out-String
 
            if ($LASTEXITCODE -ne 0) {
                Write-LogWarn "upload-batch for *.json may have had issues: $($batchOut.Substring(0, [Math]::Min(200, $batchOut.Length)))"
            }
 
            # Also upload fallback notes
            $notesCount = (Get-ChildItem -Path $LocalDateFolder -Recurse -Filter "*.fallback-notes.txt").Count
            if ($notesCount -gt 0) {
                Write-LogInfo "Uploading $notesCount fallback-notes file(s)..."
                az storage blob upload-batch `
                    --account-name $TargetStorageAccount `
                    --account-key $storageKey `
                    --destination $TargetContainer `
                    --destination-path $DatePrefix `
                    --source $LocalDateFolder `
                    --overwrite true `
                    --pattern "*.txt" `
                    --no-progress 2>&1 | Out-Null
            }
 
            # Verify upload count — parse carefully to avoid noisy az CLI output
            $UploadOKCount = $filesToUpload  # assume success as default
            try {
                $blobCountRaw = az storage blob list `
                    --account-name $TargetStorageAccount `
                    --account-key $storageKey `
                    --container-name $TargetContainer `
                    --prefix "$DatePrefix/" `
                    --query "length(@)" `
                    -o tsv 2>$null
 
                # Extract just the number from output (may contain command echo)
                $numberMatch = [regex]::Match("$blobCountRaw", '(\d+)\s*$')
                if ($numberMatch.Success) {
                    $UploadOKCount = [int]$numberMatch.Groups[1].Value
                }
            } catch {
                Write-LogWarn "Could not verify blob count - assuming $filesToUpload uploaded."
            }
 
            Write-LogOK "Batch upload complete: $UploadOKCount blob(s) in container."
        } else {
            Write-LogWarn "No date folder found at: $LocalDateFolder"
        }
 
        # Upload the CSV report to: container/date/reports/export_report.csv
        $reportBlobPath = "$DatePrefix/reports/export_report.csv"
        try {
            az storage blob upload `
                --account-name $TargetStorageAccount `
                --account-key $storageKey `
                --container-name $TargetContainer `
                --file $ReportFile `
                --name $reportBlobPath `
                --overwrite true `
                --no-progress 2>$null | Out-Null
            Write-LogOK "Report uploaded: $reportBlobPath"
        } catch {
            Write-LogWarn "Failed to upload report CSV."
        }
 
        # Restore original subscription
        if ($previousSub) {
            az account set --subscription $previousSub 2>$null
        }
 
    } catch {
        Write-LogFail "Storage upload failed: $($_.Exception.Message)"
        Write-LogWarn "ARM templates are still available locally in: $OutputDir"
        if ($previousSub) {
            az account set --subscription $previousSub 2>$null
        }
    }
}
 
# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3: SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
$Elapsed = (Get-Date) - $ScriptStartTime
$ElapsedStr = "{0:hh\:mm\:ss}" -f $Elapsed
 
Write-Host ""
Write-Host ("=" * 60)
Write-Host "  EXPORT COMPLETE"
Write-Host ("=" * 60)
Write-Host "  Total resources : $TotalCount"
Write-Host "  Exported (OK)   : $OKCount" -ForegroundColor Green
if ($L1Count -gt 0) { Write-Host ('    |-- group export        : ' + $L1Count) }
if ($L2Count -gt 0) { Write-Host ('    |-- skip-params export  : ' + $L2Count) }
if ($L3Count -gt 0) { Write-Host ('    +-- resource show (fb)  : ' + $L3Count) }
if ($FailCount -gt 0) {
    Write-Host "  Failed          : $FailCount" -ForegroundColor Red
} else {
    Write-Host "  Failed          : 0"
}
Write-Host "  Parallel jobs   : $MaxParallel"
Write-Host "  Elapsed time    : $ElapsedStr"
Write-Host "  Report          : $ReportFile"
Write-Host "  Output dir      : $(Resolve-Path $OutputDir)"
if ($UploadToStorage) {
    Write-Host ""
    Write-Host "  Storage Upload:" -ForegroundColor Cyan
    Write-Host "    Account       : $TargetStorageAccount"
    Write-Host "    Container     : $TargetContainer"
    Write-Host "    Blob prefix   : $DatePrefix/"
    Write-Host "    Uploaded OK   : $UploadOKCount" -ForegroundColor Green
    if ($UploadFailCount -gt 0) {
        Write-Host "    Upload Failed : $UploadFailCount" -ForegroundColor Red
    }
}
Write-Host ("=" * 60)
 
# Show failed resources if any
if ($FailCount -gt 0) {
    Write-Host ""
    Write-LogWarn "Failed resources:"
    try {
        Import-Csv $ReportFile | Where-Object { $_.status -eq 'FAILED' } | ForEach-Object {
            $errSnippet = if ($_.method_or_error.Length -gt 200) { $_.method_or_error.Substring(0, 200) } else { $_.method_or_error }
            Write-Host "  $($_.resource_type)/$($_.resource_name) => $errSnippet" -ForegroundColor Red
        }
    } catch { }
}
 
# Show per-subscription breakdown
Write-Host ""
Write-LogInfo "Per-subscription breakdown:"
try {
    $csvData = Import-Csv $ReportFile
    $csvData | Group-Object subscription | ForEach-Object {
        $subOk = ($_.Group | Where-Object { $_.status -eq 'SUCCESS' }).Count
        $subFail = ($_.Group | Where-Object { $_.status -eq 'FAILED' }).Count
        Write-Host "  $($_.Name): $subOk OK, $subFail failed (total $($_.Count))"
    }
} catch { }
 
Write-Host ""
Write-LogInfo "Done. Report: $ReportFile"
