<#
.SYNOPSIS
  Downloads the site content (deployed code/files) and configuration for a given Azure Web App.

.PARAMETER WebAppName
  Name of the Azure Web App.

.PARAMETER ResourceGroupName
  Resource group containing the Web App.

.PARAMETER OutputPath
  Local directory to save the downloaded content. Defaults to .\<WebAppName>-content.

.PARAMETER SubscriptionId
  Azure subscription ID. If not specified, uses the current az CLI subscription.

.EXAMPLE
  .\Get-WebAppContent.ps1 -WebAppName mywebapp -ResourceGroupName rg-agent-lab-01

.EXAMPLE
  .\Get-WebAppContent.ps1 -WebAppName mywebapp -ResourceGroupName rg-agent-lab-01 -SubscriptionId "30459864-17d2-4001-ad88-1472f3dd1ba5"

.EXAMPLE
  .\Get-WebAppContent.ps1 -WebAppName mywebapp -ResourceGroupName rg-agent-lab-01 -OutputPath "C:\backups\mywebapp"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WebAppName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$SubscriptionId,

    [string]$OutputPath
)

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "$WebAppName-content"
}

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "=== Getting site content for '$WebAppName' ===" -ForegroundColor Cyan

# --- 1. Download site content via ARM VFS API ---
$vfsDir = Join-Path $OutputPath "vfs-content"
$zipFile = Join-Path $OutputPath "$WebAppName-site.zip"
Write-Host "Downloading site content..." -ForegroundColor Yellow

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv)
}
$accessToken = (az account get-access-token --query accessToken -o tsv)
$headers = @{ Authorization = "Bearer $accessToken" }

$armVfsBaseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$WebAppName/extensions/api/vfs/site/wwwroot/"
Write-Host "  Using ARM VFS API..." -ForegroundColor Gray

function Get-VfsDirectory {
    param(
        [string]$RelativePath,
        [string]$LocalPath,
        [hashtable]$Headers,
        [string]$BaseUrl,
        [int]$Depth = 0
    )
    $indent = "    " * ($Depth + 1)

    if ($RelativePath) {
        $url = "${BaseUrl}${RelativePath}/?api-version=2022-03-01"
    } else {
        $url = "${BaseUrl}?api-version=2022-03-01"
    }

    try {
        $items = Invoke-RestMethod -Uri $url -Headers $Headers
    }
    catch {
        Write-Warning "${indent}Failed to list directory: $_"
        return
    }

    if (-not (Test-Path $LocalPath)) {
        New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
    }

    foreach ($item in $items) {
        $itemName = $item.name
        if ($item.mime -eq "inode/directory") {
            $subDir = Join-Path $LocalPath $itemName
            Write-Host "${indent}[DIR]  $itemName" -ForegroundColor Gray
            $subPath = if ($RelativePath) { "$RelativePath/$itemName" } else { $itemName }
            Get-VfsDirectory -RelativePath $subPath -LocalPath $subDir -Headers $Headers -BaseUrl $BaseUrl -Depth ($Depth + 1)
        }
        else {
            $outFile = Join-Path $LocalPath $itemName
            $filePath = if ($RelativePath) { "$RelativePath/$itemName" } else { $itemName }
            $fileUrl = "${BaseUrl}${filePath}?api-version=2022-03-01"
            try {
                Invoke-RestMethod -Uri $fileUrl -Headers $Headers -OutFile $outFile
                Write-Host "${indent}[FILE] $itemName" -ForegroundColor White
            }
            catch {
                Write-Warning "${indent}Failed to download $itemName : $_"
            }
        }
    }
}

try {
    Get-VfsDirectory -RelativePath "" -LocalPath $vfsDir -Headers $headers -BaseUrl $armVfsBaseUrl
    Write-Host "  Site content downloaded via ARM VFS API" -ForegroundColor Green
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

        Invoke-RestMethod -Uri "$scmUrl/api/zip/site/wwwroot/" -Headers $headers -OutFile $zipFile
        Write-Host "  Downloaded via Kudu ZIP API" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to download site content: $_"
    }
}

# --- 2. Export app settings ---
$settingsFile = Join-Path $OutputPath "appsettings.json"
Write-Host "Exporting app settings..." -ForegroundColor Yellow
try {
    $settings = az webapp config appsettings list `
        --name $WebAppName `
        --resource-group $ResourceGroupName -o json
    $settings | Out-File -FilePath $settingsFile -Encoding utf8
    Write-Host "  Saved to appsettings.json" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to export app settings: $_"
}

# --- 3. Export connection strings ---
$connStrFile = Join-Path $OutputPath "connectionstrings.json"
Write-Host "Exporting connection strings..." -ForegroundColor Yellow
try {
    $connStr = az webapp config connection-string list `
        --name $WebAppName `
        --resource-group $ResourceGroupName -o json
    $connStr | Out-File -FilePath $connStrFile -Encoding utf8
    Write-Host "  Saved to connectionstrings.json" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to export connection strings: $_"
}

# --- 4. Export site configuration ---
$configFile = Join-Path $OutputPath "siteconfig.json"
Write-Host "Exporting site configuration..." -ForegroundColor Yellow
try {
    $config = az webapp config show `
        --name $WebAppName `
        --resource-group $ResourceGroupName -o json
    $config | Out-File -FilePath $configFile -Encoding utf8
    Write-Host "  Saved to siteconfig.json" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to export site config: $_"
}

# --- 5. Export general web app properties ---
$propsFile = Join-Path $OutputPath "webapp-properties.json"
Write-Host "Exporting web app properties..." -ForegroundColor Yellow
try {
    $props = az webapp show `
        --name $WebAppName `
        --resource-group $ResourceGroupName -o json
    $props | Out-File -FilePath $propsFile -Encoding utf8
    Write-Host "  Saved to webapp-properties.json" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to export web app properties: $_"
}

# --- 6. Export deployment slots (if any) ---
$slotsFile = Join-Path $OutputPath "slots.json"
Write-Host "Exporting deployment slots..." -ForegroundColor Yellow
try {
    $slots = az webapp deployment slot list `
        --name $WebAppName `
        --resource-group $ResourceGroupName -o json
    $slots | Out-File -FilePath $slotsFile -Encoding utf8
    $slotCount = ($slots | ConvertFrom-Json).Count
    Write-Host "  Saved to slots.json ($slotCount slot(s))" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to export slots: $_"
}

# --- Summary ---
Write-Host "`n=== Content saved to: $OutputPath ===" -ForegroundColor Cyan
Get-ChildItem $OutputPath | ForEach-Object {
    if ($_.PSIsContainer) {
        $fileCount = (Get-ChildItem $_.FullName -Recurse -File).Count
        Write-Host "  $($_.Name)/ ($fileCount files)" -ForegroundColor White
    }
    else {
        $size = if ($_.Length -ge 1KB) { "{0:N1} KB" -f ($_.Length / 1KB) } else { "$($_.Length) B" }
        Write-Host "  $($_.Name) ($size)" -ForegroundColor White
    }
}
