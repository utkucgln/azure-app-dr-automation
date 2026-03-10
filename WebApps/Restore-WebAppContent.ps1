<#
.SYNOPSIS
  Restores site content and configuration to an Azure Web App from a local backup.

.DESCRIPTION
  Uploads the site content (files) and restores app settings, connection strings, and
  site configuration from a local backup directory created by Get-WebAppContent.ps1.

.PARAMETER WebAppName
  Name of the target Azure Web App to restore into.

.PARAMETER ResourceGroupName
  Resource group containing the target Web App.

.PARAMETER InputPath
  Local directory containing the backup content. Defaults to .\<WebAppName>-content.

.PARAMETER SubscriptionId
  Azure subscription ID. If not specified, uses the current az CLI subscription.

.PARAMETER SkipAppSettings
  Switch to skip restoring app settings.

.PARAMETER SkipConnectionStrings
  Switch to skip restoring connection strings.

.PARAMETER SkipSiteConfig
  Switch to skip restoring site configuration.

.PARAMETER SkipSiteContent
  Switch to skip uploading site content files.

.EXAMPLE
  .\Restore-WebAppContent.ps1 -WebAppName mywebapp -ResourceGroupName rg-agent-lab-01

.EXAMPLE
  .\Restore-WebAppContent.ps1 -WebAppName mywebapp -ResourceGroupName rg-agent-lab-01 -InputPath "C:\backups\mywebapp-content"

.EXAMPLE
  .\Restore-WebAppContent.ps1 -WebAppName mywebapp -ResourceGroupName rg-agent-lab-01 -SkipConnectionStrings
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WebAppName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$SubscriptionId,

    [string]$InputPath,

    [switch]$SkipAppSettings,

    [switch]$SkipConnectionStrings,

    [switch]$SkipSiteConfig,

    [switch]$SkipSiteContent
)

if (-not $InputPath) {
    $InputPath = Join-Path $PSScriptRoot "$WebAppName-content"
}

if (-not (Test-Path $InputPath)) {
    Write-Error "Input path '$InputPath' does not exist. Please provide a valid backup directory."
    return
}

Write-Host "=== Restoring content to '$WebAppName' from '$InputPath' ===" -ForegroundColor Cyan

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

        $armVfsBaseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$WebAppName/extensions/api/vfs/site/wwwroot/"

        function Set-WebVfsDirectory {
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
                    # Create directory on remote (PUT with trailing slash)
                    $dirUrl = "${BaseUrl}${subPath}/?api-version=2022-03-01"
                    try {
                        Invoke-RestMethod -Uri $dirUrl -Headers $Headers -Method Put -Body "" -ContentType "application/json" | Out-Null
                    }
                    catch {
                        # Directory may already exist, continue
                    }
                    Set-WebVfsDirectory -LocalPath $item.FullName -RelativePath $subPath -Headers $Headers -BaseUrl $BaseUrl -Depth ($Depth + 1)
                }
                else {
                    $filePath = if ($RelativePath) { "$RelativePath/$($item.Name)" } else { $item.Name }
                    $fileUrl = "${BaseUrl}${filePath}?api-version=2022-03-01"
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
            Set-WebVfsDirectory -LocalPath $vfsDir -RelativePath "" -Headers $headers -BaseUrl $armVfsBaseUrl
            Write-Host "  Site content uploaded via ARM VFS API" -ForegroundColor Green
        }
        catch {
            Write-Host "  ARM VFS API failed ($_), trying Kudu SCM endpoint..." -ForegroundColor Yellow
            try {
                $scmHost = az webapp show --name $WebAppName --resource-group $ResourceGroupName `
                    --query "hostNameSslStates[?hostType=='Repository'].name | [0]" -o tsv
                if (-not $scmHost) {
                    $scmHost = "$WebAppName.scm.azurewebsites.net"
                }
                $scmUrl = "https://$scmHost"
                Write-Host "  SCM URL: $scmUrl" -ForegroundColor Gray

                # Create a ZIP of the vfs-content directory and deploy via Kudu ZIP API
                $tempZip = Join-Path $env:TEMP "$WebAppName-restore-$(Get-Date -Format 'yyyyMMddHHmmss').zip"
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
                az webapp config appsettings set `
                    --name $WebAppName `
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

# --- 3. Restore connection strings ---
if (-not $SkipConnectionStrings) {
    $connStrFile = Join-Path $InputPath "connectionstrings.json"
    if (Test-Path $connStrFile) {
        Write-Host "Restoring connection strings..." -ForegroundColor Yellow
        try {
            $connStrings = Get-Content $connStrFile -Raw | ConvertFrom-Json

            # connectionstrings.json from `az webapp config connection-string list` returns
            # an object with property names as connection string names
            $connStrArgs = @()
            $connStrings.PSObject.Properties | ForEach-Object {
                $csName = $_.Name
                $csValue = $_.Value.value
                $csType = $_.Value.type
                # Format: name=value type=typeName
                $connStrArgs += "$csName=$csValue"

                az webapp config connection-string set `
                    --name $WebAppName `
                    --resource-group $ResourceGroupName `
                    --connection-string-type $csType `
                    --settings "$csName=$csValue" -o none
                Write-Host "    [CONN] $csName ($csType)" -ForegroundColor White
            }

            Write-Host "  Restored connection strings" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to restore connection strings: $_"
        }
    }
    else {
        Write-Host "  No connectionstrings.json found, skipping." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Skipping connection strings restore (SkipConnectionStrings specified)." -ForegroundColor Yellow
}

# --- 4. Restore site configuration ---
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
            if ($config.alwaysOn -eq $true)  { $configArgs += "--always-on"; $configArgs += "true" }
            if ($config.alwaysOn -eq $false) { $configArgs += "--always-on"; $configArgs += "false" }
            if ($config.webSocketsEnabled -eq $true)  { $configArgs += "--web-sockets-enabled"; $configArgs += "true" }
            if ($config.webSocketsEnabled -eq $false) { $configArgs += "--web-sockets-enabled"; $configArgs += "false" }

            if ($configArgs.Count -gt 0) {
                $baseArgs = @("webapp", "config", "set", "--name", $WebAppName, "--resource-group", $ResourceGroupName, "-o", "none")
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

# --- Summary ---
Write-Host "`n=== Restore complete for '$WebAppName' ===" -ForegroundColor Cyan
Write-Host "  Source: $InputPath" -ForegroundColor White
Write-Host "  Target: $WebAppName (RG: $ResourceGroupName)" -ForegroundColor White
