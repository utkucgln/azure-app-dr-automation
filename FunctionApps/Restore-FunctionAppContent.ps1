<#
.SYNOPSIS
  Restores site content and configuration to an Azure Function App from a local backup.

.DESCRIPTION
  Uploads the site content (files) and restores app settings, site configuration, and
  function keys from a local backup directory created by Get-FunctionAppContent.ps1.

.PARAMETER FunctionAppName
  Name of the target Azure Function App to restore into.

.PARAMETER ResourceGroupName
  Resource group containing the target Function App.

.PARAMETER InputPath
  Local directory containing the backup content. Defaults to .\<FunctionAppName>-content.

.PARAMETER SubscriptionId
  Azure subscription ID. If not specified, uses the current az CLI subscription.

.PARAMETER SkipAppSettings
  Switch to skip restoring app settings.

.PARAMETER SkipSiteConfig
  Switch to skip restoring site configuration.

.PARAMETER SkipFunctionKeys
  Switch to skip restoring function keys.

.PARAMETER SkipSiteContent
  Switch to skip uploading site content files.

.EXAMPLE
  .\Restore-FunctionAppContent.ps1 -FunctionAppName fabbackuptest -ResourceGroupName rg-agent-lab-01

.EXAMPLE
  .\Restore-FunctionAppContent.ps1 -FunctionAppName fabfuncapptest01 -ResourceGroupName rg-agent-lab-01 -InputPath "C:\backups\fabfuncapptest01-content"

.EXAMPLE
  .\Restore-FunctionAppContent.ps1 -FunctionAppName fabfuncapptest01 -ResourceGroupName rg-agent-lab-01 -SkipFunctionKeys
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$SubscriptionId,

    [string]$InputPath,

    [switch]$SkipAppSettings,

    [switch]$SkipSiteConfig,

    [switch]$SkipFunctionKeys,

    [switch]$SkipSiteContent
)

if (-not $InputPath) {
    $InputPath = Join-Path $PSScriptRoot "$FunctionAppName-content"
}

if (-not (Test-Path $InputPath)) {
    Write-Error "Input path '$InputPath' does not exist. Please provide a valid backup directory."
    return
}

Write-Host "=== Restoring content to '$FunctionAppName' from '$InputPath' ===" -ForegroundColor Cyan

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv)
}
$accessToken = (az account get-access-token --query accessToken -o tsv)
$headers = @{ Authorization = "Bearer $accessToken" }

# --- 1. Upload site content via ARM VFS API ---
if (-not $SkipSiteContent) {
    $vfsDir = Join-Path $InputPath "vfs-content"
    if (Test-Path $vfsDir) {
        Write-Host "Uploading site content..." -ForegroundColor Yellow

        $armVfsBaseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/hostruntime/admin/vfs/"

        function Set-FunctionVfsDirectory {
            param(
                [string]$LocalPath,
                [string]$RelativePath,
                [hashtable]$Headers,
                [string]$BaseUrl,
                [int]$Depth = 0
            )
            $indent = "    " * ($Depth + 1)

            foreach ($item in Get-ChildItem -Path $LocalPath) {
                if ($item.PSIsContainer) {
                    Write-Host "${indent}[DIR]  $($item.Name)" -ForegroundColor Gray
                    $subPath = if ($RelativePath) { "$RelativePath/$($item.Name)" } else { $item.Name }
                    Set-FunctionVfsDirectory -LocalPath $item.FullName -RelativePath $subPath -Headers $Headers -BaseUrl $BaseUrl -Depth ($Depth + 1)
                }
                else {
                    $filePath = if ($RelativePath) { "$RelativePath/$($item.Name)" } else { $item.Name }
                    $fileUrl = "${BaseUrl}${filePath}?relativePath=1&api-version=2022-03-01"
                    try {
                        $fileBytes = [System.IO.File]::ReadAllBytes($item.FullName)
                        Invoke-RestMethod -Uri $fileUrl -Headers $Headers -Method Put -Body $fileBytes -ContentType "application/octet-stream" | Out-Null
                        Write-Host "${indent}[FILE] $($item.Name)" -ForegroundColor White
                    }
                    catch {
                        Write-Warning "${indent}Failed to upload $($item.Name): $_"
                    }
                }
            }
        }

        try {
            Set-FunctionVfsDirectory -LocalPath $vfsDir -RelativePath "" -Headers $headers -BaseUrl $armVfsBaseUrl
            Write-Host "  Site content uploaded via ARM VFS API" -ForegroundColor Green
        }
        catch {
            Write-Host "  ARM VFS API failed ($_), trying Kudu SCM endpoint..." -ForegroundColor Yellow
            try {
                $scmHost = az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName `
                    --query "hostNameSslStates[?hostType=='Repository'].name | [0]" -o tsv
                if (-not $scmHost) {
                    $scmHost = "$FunctionAppName.scm.azurewebsites.net"
                }
                $scmUrl = "https://$scmHost"
                Write-Host "  SCM URL: $scmUrl" -ForegroundColor Gray

                # Create a ZIP of the vfs-content directory and deploy via Kudu ZIP API
                $tempZip = Join-Path $env:TEMP "$FunctionAppName-restore-$(Get-Date -Format 'yyyyMMddHHmmss').zip"
                Compress-Archive -Path "$vfsDir\*" -DestinationPath $tempZip -Force
                Invoke-RestMethod -Uri "$scmUrl/api/zip/site/wwwroot/" -Headers $headers -Method Put -InFile $tempZip -ContentType "application/zip" | Out-Null
                Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
                Write-Host "  Uploaded via Kudu ZIP API" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to upload site content: $_"
            }
        }
    }
    else {
        Write-Host "No vfs-content directory found, skipping site content upload." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Skipping site content upload (SkipSiteContent specified)." -ForegroundColor Yellow
}

# --- 2. Restore app settings ---
if (-not $SkipAppSettings) {
    $settingsFile = Join-Path $InputPath "appsettings.json"
    if (Test-Path $settingsFile) {
        Write-Host "Restoring app settings..." -ForegroundColor Yellow
        try {
            $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
            $settingsArgs = @()
            foreach ($s in $settings) {
                $settingsArgs += "$($s.name)=$($s.value)"
            }
            if ($settingsArgs.Count -gt 0) {
                az functionapp config appsettings set `
                    --name $FunctionAppName `
                    --resource-group $ResourceGroupName `
                    --settings @settingsArgs -o none
                Write-Host "  Restored $($settingsArgs.Count) app settings" -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "Failed to restore app settings: $_"
        }
    }
    else {
        Write-Host "  No appsettings.json found, skipping." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Skipping app settings restore (SkipAppSettings specified)." -ForegroundColor Yellow
}

# --- 3. Restore site configuration ---
if (-not $SkipSiteConfig) {
    $configFile = Join-Path $InputPath "siteconfig.json"
    if (Test-Path $configFile) {
        Write-Host "Restoring site configuration..." -ForegroundColor Yellow
        try {
            $config = Get-Content $configFile -Raw | ConvertFrom-Json

            $configArgs = @()
            if ($config.linuxFxVersion)     { $configArgs += "--linux-fx-version"; $configArgs += $config.linuxFxVersion }
            if ($config.phpVersion)          { $configArgs += "--php-version"; $configArgs += $config.phpVersion }
            if ($config.pythonVersion)       { $configArgs += "--python-version"; $configArgs += $config.pythonVersion }
            if ($config.nodeVersion)         { $configArgs += "--node-version"; $configArgs += $config.nodeVersion }
            if ($config.javaVersion)         { $configArgs += "--java-version"; $configArgs += $config.javaVersion }
            if ($config.netFrameworkVersion) { $configArgs += "--net-framework-version"; $configArgs += $config.netFrameworkVersion }
            if ($config.use32BitWorkerProcess -eq $true) { $configArgs += "--use-32bit-worker-process"; $configArgs += "true" }
            if ($config.use32BitWorkerProcess -eq $false) { $configArgs += "--use-32bit-worker-process"; $configArgs += "false" }
            if ($config.ftpsState)           { $configArgs += "--ftps-state"; $configArgs += $config.ftpsState }
            if ($config.http20Enabled -eq $true)  { $configArgs += "--http20-enabled"; $configArgs += "true" }
            if ($config.http20Enabled -eq $false) { $configArgs += "--http20-enabled"; $configArgs += "false" }
            if ($config.minTlsVersion)       { $configArgs += "--min-tls-version"; $configArgs += $config.minTlsVersion }
            if ($config.numberOfWorkers)     { $configArgs += "--number-of-workers"; $configArgs += $config.numberOfWorkers.ToString() }

            if ($configArgs.Count -gt 0) {
                $baseArgs = @("functionapp", "config", "set", "--name", $FunctionAppName, "--resource-group", $ResourceGroupName, "-o", "none")
                & az @baseArgs @configArgs
                Write-Host "  Restored site configuration" -ForegroundColor Green
            }
            else {
                Write-Host "  No applicable site config properties to restore" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Warning "Failed to restore site config: $_"
        }
    }
    else {
        Write-Host "  No siteconfig.json found, skipping." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Skipping site configuration restore (SkipSiteConfig specified)." -ForegroundColor Yellow
}

# --- 4. Restore function & host keys ---
if (-not $SkipFunctionKeys) {
    $keysFile = Join-Path $InputPath "functionkeys.json"
    if (Test-Path $keysFile) {
        Write-Host "Restoring function keys..." -ForegroundColor Yellow
        try {
            $keys = Get-Content $keysFile -Raw | ConvertFrom-Json

            # Restore host-level function keys
            if ($keys.functionKeys) {
                $keys.functionKeys.PSObject.Properties | ForEach-Object {
                    $keyName = $_.Name
                    $keyValue = $_.Value
                    az functionapp keys set `
                        --name $FunctionAppName `
                        --resource-group $ResourceGroupName `
                        --key-type functionKeys `
                        --key-name $keyName `
                        --key-value $keyValue -o none 2>$null
                    Write-Host "    [KEY] functionKeys/$keyName" -ForegroundColor White
                }
            }

            # Restore host-level system keys
            if ($keys.systemKeys) {
                $keys.systemKeys.PSObject.Properties | ForEach-Object {
                    $keyName = $_.Name
                    $keyValue = $_.Value
                    az functionapp keys set `
                        --name $FunctionAppName `
                        --resource-group $ResourceGroupName `
                        --key-type systemKeys `
                        --key-name $keyName `
                        --key-value $keyValue -o none 2>$null
                    Write-Host "    [KEY] systemKeys/$keyName" -ForegroundColor White
                }
            }

            Write-Host "  Restored function keys" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to restore function keys: $_"
        }
    }
    else {
        Write-Host "  No functionkeys.json found, skipping." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Skipping function keys restore (SkipFunctionKeys specified)." -ForegroundColor Yellow
}

# --- Summary ---
Write-Host "`n=== Restore complete for '$FunctionAppName' ===" -ForegroundColor Cyan
Write-Host "  Source: $InputPath" -ForegroundColor White
Write-Host "  Target: $FunctionAppName (RG: $ResourceGroupName)" -ForegroundColor White
