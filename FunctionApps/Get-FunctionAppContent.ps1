<#
.SYNOPSIS
  Downloads the site content (deployed code/files) for a given Azure Function App.

.PARAMETER FunctionAppName
  Name of the Azure Function App.

.PARAMETER ResourceGroupName
  Resource group containing the Function App.

.PARAMETER OutputPath
  Local directory to save the downloaded content. Defaults to .\<FunctionAppName>-content.

.PARAMETER SubscriptionId
  Azure subscription ID. If not specified, uses the current az CLI subscription.

.EXAMPLE
  .\Get-FunctionAppContent.ps1 -FunctionAppName fabbackuptest -ResourceGroupName rg-agent-lab-01

.EXAMPLE
  .\Get-FunctionAppContent.ps1 -FunctionAppName fabfuncapptest01 -ResourceGroupName rg-agent-lab-01 -SubscriptionId "30459864-17d2-4001-ad88-1472f3dd1ba5"

.EXAMPLE
  .\Get-FunctionAppContent.ps1 -FunctionAppName fabfuncapptest01 -ResourceGroupName rg-agent-lab-01 -OutputPath "C:\backups\fabfuncapptest01"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$SubscriptionId,

    [string]$OutputPath
)

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "$FunctionAppName-content"
}

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "=== Getting site content for '$FunctionAppName' ===" -ForegroundColor Cyan

# --- 1. Download ZIP of site content via Kudu VFS/zip API ---
$zipFile = Join-Path $OutputPath "$FunctionAppName-site.zip"
$vfsDir = Join-Path $OutputPath "vfs-content"
Write-Host "Downloading site content..." -ForegroundColor Yellow

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv)
}
$accessToken = (az account get-access-token --query accessToken -o tsv)
$headers = @{ Authorization = "Bearer $accessToken" }

# Use ARM hostruntime VFS API to list and download site content
$armVfsBaseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/hostruntime/admin/vfs/"
Write-Host "  Using ARM VFS API..." -ForegroundColor Gray

function Get-FunctionVfsDirectory {
    param(
        [string]$RelativePath,
        [string]$LocalPath,
        [hashtable]$Headers,
        [string]$BaseUrl,
        [int]$Depth = 0
    )
    $indent = "    " * ($Depth + 1)

    if ($RelativePath) {
        $url = "${BaseUrl}${RelativePath}/?relativePath=1&api-version=2022-03-01"
    } else {
        $url = "${BaseUrl}?relativePath=1&api-version=2022-03-01"
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
            Get-FunctionVfsDirectory -RelativePath $subPath -LocalPath $subDir -Headers $Headers -BaseUrl $BaseUrl -Depth ($Depth + 1)
        }
        else {
            $outFile = Join-Path $LocalPath $itemName
            $filePath = if ($RelativePath) { "$RelativePath/$itemName" } else { $itemName }
            $fileUrl = "${BaseUrl}${filePath}?relativePath=1&api-version=2022-03-01"
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
    Get-FunctionVfsDirectory -RelativePath "" -LocalPath $vfsDir -Headers $headers -BaseUrl $armVfsBaseUrl
    Write-Host "  Site content downloaded via ARM VFS API" -ForegroundColor Green
}
catch {
    Write-Host "  ARM VFS API failed ($_), trying Kudu SCM endpoint..." -ForegroundColor Yellow
    try {
        # Fallback: resolve SCM hostname dynamically and download ZIP
        $scmHost = az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName `
            --query "hostNameSslStates[?hostType=='Repository'].name | [0]" -o tsv
        if (-not $scmHost) {
            $scmHost = "$FunctionAppName.scm.azurewebsites.net"
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
    $settings = az functionapp config appsettings list `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName -o json
    $settings | Out-File -FilePath $settingsFile -Encoding utf8
    Write-Host "  Saved to appsettings.json" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to export app settings: $_"
}

# --- 3. Export site configuration ---
$configFile = Join-Path $OutputPath "siteconfig.json"
Write-Host "Exporting site configuration..." -ForegroundColor Yellow
try {
    $config = az functionapp config show `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName -o json
    $config | Out-File -FilePath $configFile -Encoding utf8
    Write-Host "  Saved to siteconfig.json" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to export site config: $_"
}

# --- 4. Export function & host keys ---
$keysFile = Join-Path $OutputPath "functionkeys.json"
Write-Host "Exporting function keys..." -ForegroundColor Yellow
try {
    $keys = az functionapp keys list `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName -o json
    $keys | Out-File -FilePath $keysFile -Encoding utf8
    Write-Host "  Saved to functionkeys.json" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to export function keys: $_"
}

# --- Summary ---
Write-Host "`n=== Content saved to: $OutputPath ===" -ForegroundColor Cyan
Get-ChildItem $OutputPath | ForEach-Object {
    $size = if ($_.Length -ge 1KB) { "{0:N1} KB" -f ($_.Length / 1KB) } else { "$($_.Length) B" }
    Write-Host "  $($_.Name) ($size)" -ForegroundColor White
}
