# Azure Function Apps — Backup & Restore Guide

> **Last updated:** March 2026  
> **Scope:** All scripts in the `FunctionApps/` folder of the `azure-app-dr-automation` repository.

---

## Table of Contents

1. [Overview](#overview)
2. [Script Inventory](#script-inventory)
3. [Architecture & Workflow](#architecture--workflow)
4. [Backup-FunctionsToDR.ps1](#backup-functionstodrps1)
5. [Restore-FunctionsFromDR.ps1](#restore-functionsfromdrps1)
6. [Get-FunctionAppContent.ps1](#get-functionappcontentps1)
7. [Restore-FunctionAppContent.ps1](#restore-functionappcontentps1)
8. [Supported SKUs & Hosting Models](#supported-skus--hosting-models)
9. [Prerequisites](#prerequisites)
10. [Authentication & Identity](#authentication--identity)
11. [Parameter Reference](#parameter-reference)
12. [Backup Artifacts](#backup-artifacts)
13. [Step-by-Step Workflows](#step-by-step-workflows)


---

## Overview

This folder contains four PowerShell scripts that together provide a complete **backup and disaster-recovery (DR) restore** solution for Azure Function Apps. The scripts are designed to work across subscriptions and regions, enabling full cross-region DR scenarios.

There are two complementary script pairs:

| Pair | Purpose | Scope | Storage |
|------|---------|-------|---------|
| **Backup-FunctionsToDR** / **Restore-FunctionsFromDR** | Full DR (cross-subscription, cross-region) | All Function Apps in a subscription | Azure Blob Storage |
| **Get-FunctionAppContent** / **Restore-FunctionAppContent** | Individual app backup/restore | Single Function App | Local filesystem |

---

## Script Inventory

### 1. Backup-FunctionsToDR.ps1

| Property | Value |
|----------|-------|
| **Lines** | ~950 |
| **Module** | Az PowerShell (`Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.Websites`) |
| **Purpose** | Backs up ALL Function Apps in a source subscription to a blob container in a different (target) subscription |
| **Outputs** | Per-app: code ZIP, config manifest JSON, ARM template JSON; overall: CSV report |

### 2. Restore-FunctionsFromDR.ps1

| Property | Value |
|----------|-------|
| **Lines** | ~500 |
| **Module** | Az PowerShell (`Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.Websites`) |
| **Purpose** | Restores a single Function App from DR backup artifacts (ARM template + manifest + code ZIP) |
| **Outputs** | Fully deployed Function App with code, config, keys, and RBAC |

### 3. Get-FunctionAppContent.ps1

| Property | Value |
|----------|-------|
| **Lines** | ~150 |
| **Module** | Azure CLI (`az`) |
| **Purpose** | Downloads site content and configuration for a single Function App to the local filesystem |
| **Outputs** | Local directory with VFS content tree, appsettings.json, siteconfig.json, functionkeys.json |

### 4. Restore-FunctionAppContent.ps1

| Property | Value |
|----------|-------|
| **Lines** | ~250 |
| **Module** | Azure CLI (`az`) |
| **Purpose** | Restores site content and configuration from a local backup to a target Function App |
| **Outputs** | Updated Function App with restored files, settings, and keys |

---

## Architecture & Workflow

### Full DR Flow (Cross-Subscription / Cross-Region)

```
Source Subscription                           Target Subscription
┌──────────────────────┐                      ┌──────────────────────────┐
│  Function App 1      │                      │  Storage Account (Blob)  │
│  Function App 2      │  Backup-Functions    │  ┌────────────────────┐  │
│  Function App 3      │ ──────────────────►  │  │ container/         │  │
│  ...                 │   ToDR.ps1           │  │  ├─ app1/           │  │
└──────────────────────┘                      │  │  │  ├─ .zip         │  │
                                              │  │  │  ├─ .json        │  │
                                              │  │  │  └─ .arm.json    │  │
                                              │  │  └─ reports/        │  │
                                              │  └────────────────────┘  │
                                              └──────────────────────────┘
                                                          │
                                               Restore-Functions
                                                FromDR.ps1
                                                          │
                                                          ▼
                                              ┌──────────────────────────┐
                                              │  DR Region               │
                                              │  ┌────────────────────┐  │
                                              │  │ Hosting Plan       │  │
                                              │  │ Managed Identity   │  │
                                              │  │ Function App (DR)  │  │
                                              │  │  + Code + Keys     │  │
                                              │  └────────────────────┘  │
                                              └──────────────────────────┘
```

### Individual App Flow (Local Backup)

```
Azure Function App                Local Filesystem
┌──────────────────┐              ┌──────────────────────────┐
│  Site Content    │  Get-        │  <appname>-content/      │
│  App Settings    │  FunctionApp │   ├─ vfs-content/        │
│  Site Config     │ ──────────►  │   │  ├─ host.json        │
│  Function Keys   │  Content.ps1 │   │  ├─ function1/       │
└──────────────────┘              │   │  └─ ...              │
                                  │   ├─ appsettings.json    │
        ▲                         │   ├─ siteconfig.json     │
        │                         │   └─ functionkeys.json   │
        │  Restore-               └──────────────────────────┘
        │  FunctionApp                       │
        └────────────── Content.ps1 ◄────────┘
```

---

## Backup-FunctionsToDR.ps1

### What It Does

This is the primary DR backup script. It enumerates **all** Function Apps in a source subscription (excluding Logic Apps Standard / workflow apps) and for each one:

1. **Downloads the code package (ZIP)**
   - Flex Consumption: downloads from the deployment blob container via `Az.Storage` (OAuth)
   - Classic with `WEBSITE_RUN_FROM_PACKAGE=1`: fetches the latest ZIP from `/home/data/SitePackages/` via Kudu VFS
   - Classic with `WEBSITE_RUN_FROM_PACKAGE=<url>`: downloads directly from the external URL
   - Fallback: ZIPs `/site/wwwroot/` via Kudu ZIP API

2. **Exports a full configuration manifest (JSON)** including:
   - App settings & connection strings
   - Site configuration (runtime stack, TLS, CORS, IP restrictions, health check, etc.)
   - Hosting plan / SKU details
   - Managed identity configuration (system-assigned & user-assigned)
   - Host keys (master, function, system) and per-function keys
   - Tags, custom domains, slot-sticky settings
   - Flex Consumption-specific config (scaling, runtime, deployment storage)

3. **Generates a deployable ARM template** that creates:
   - App Service Plan (matching original SKU)
   - User-Assigned Managed Identity (if the original used one)
   - Function App with full `siteConfig`, `appSettings`, `connectionStrings`
   - Parameterized references for `storageAccountName`, `location`, `functionAppName`, `appInsightsConnectionString`, `managedIdentityName`
   - Smart substitution of storage URIs (`AzureWebJobsStorage__*ServiceUri`, connection strings)

4. **Uploads all artifacts to target blob storage** with path structure:
   ```
   <container>/<sourceSubscriptionId>/<appName>/<timestamp>.zip
   <container>/<sourceSubscriptionId>/<appName>/<timestamp>.json
   <container>/<sourceSubscriptionId>/<appName>/<timestamp>.arm.json
   ```

5. **Generates and uploads a CSV report** with backup status for all apps.

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `SourceSubscriptionId` | string | Yes | Subscription hosting the Function Apps |
| `TargetSubscriptionId` | string | Yes | Subscription hosting the backup storage account |
| `TargetResourceGroup` | string | Yes | Resource group of the backup storage account |
| `TargetStorageAccount` | string | Yes | Name of the backup storage account |
| `TargetContainer` | string | Yes | Blob container name (auto-created if missing) |
| `IncludeSlots` | switch | No | Include deployment slots (default: `$false`) |

### Example

```powershell
.\Backup-FunctionsToDR.ps1 `
  -SourceSubscriptionId  "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" `
  -TargetSubscriptionId  "ffffffff-1111-2222-3333-444444444444" `
  -TargetResourceGroup   "rg-dr-backup" `
  -TargetStorageAccount  "stdrbackup2026" `
  -TargetContainer       "func-backups"
```

### Key Helper Functions

| Function | Purpose |
|----------|---------|
| `Get-PublishingCreds` | Retrieves Kudu publishing credentials via `Get-AzWebAppPublishingProfile` |
| `Invoke-KuduJson` | Calls Kudu REST API endpoints with Basic auth |
| `Download-KuduFile` | Downloads files from Kudu VFS endpoints |
| `Get-FlexConsumptionDeploymentInfo` | Detects Flex Consumption SKU and returns deployment blob container URL |
| `Download-FlexConsumptionPackage` | Downloads the latest ZIP from a Flex Consumption deployment container via OAuth |
| `Export-FunctionAppConfig` | Collects full configuration via ARM REST API (`Invoke-AzRestMethod`) |
| `Build-ArmTemplate` | Generates a parameterized ARM template from the config manifest |
| `Invoke-Arm` | Generic ARM REST API helper with error handling |

---

## Restore-FunctionsFromDR.ps1

### What It Does

This is the primary DR restore script. It takes the three artifacts produced by `Backup-FunctionsToDR.ps1` and restores a single Function App through a 5-step process:

#### Step 0: Download Backup Artifacts
- Authenticates to Azure (`Connect-AzAccount`)
- Downloads ARM template, manifest JSON, and code ZIP from blob storage
- Parses the manifest to determine app type, SKU, and identity requirements

#### Step 1: Prepare ARM Template Parameters
- Builds parameter set: `location`, `functionAppName`, `storageAccountName`
- Resolves managed identity naming (appends `-dr` suffix if keeping original name)
- Optionally overrides App Insights connection string

#### Step 2: Flex Consumption Deployment Container (Flex only)
- Creates a blob container named `<functionAppName>-package` in the target storage account
- Uploads the code ZIP to this container (Flex apps read code from blob, not Kudu)

#### Step 3: Deploy ARM Template
- Executes `New-AzResourceGroupDeployment` with the downloaded ARM template
- Creates the hosting plan, managed identity, and Function App in a single deployment

#### Step 4: Deploy Code
- **Flex Consumption:** Code already uploaded in Step 2
- **Classic/Consumption/Premium:** Uses `az functionapp deployment source config-zip`
- Falls back to `Publish-AzWebApp` if ZIP deploy fails
- Assigns `Storage Blob Data Contributor` RBAC to managed identity on the storage account

#### Step 5: Restore Keys & Validate
- Waits for the Function App and host runtime to be fully ready (up to 240 seconds, polling every 15 seconds)
- Restores master key, host function keys, system keys, and per-function keys via ARM REST API (`PUT`)
- Includes retry logic (3 attempts with 15-second intervals)
- Validates by listing functions and checking site state/hostname

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `ArmTemplateBlobPath` | string | Yes | Blob path of the ARM template |
| `ManifestBlobPath` | string | Yes | Blob path of the manifest JSON |
| `CodeZipBlobPath` | string | Yes | Blob path of the code ZIP |
| `SourceStorageAccount` | string | Yes | Storage account holding backup blobs |
| `SourceStorageContainer` | string | Yes | Container holding backup blobs |
| `SourceStorageSubscription` | string | No | Subscription for backup storage (default: current context) |
| `TargetSubscriptionId` | string | Yes | Subscription to deploy into |
| `TargetResourceGroup` | string | Yes | Resource group to deploy into (must exist) |
| `TargetLocation` | string | Yes | Azure region (e.g., `eastus`, `westeurope`) |
| `TargetStorageAccountName` | string | Yes | Storage account for the restored Function App (must exist) |
| `NewFunctionAppName` | string | No | Override name (default: `<originalName>-dr`) |
| `AppInsightsConnectionString` | string | No | Override App Insights connection string |
| `ManagedIdentityName` | string | No | Override managed identity name |
| `SkipCodeDeploy` | switch | No | Skip code deployment (infra only) |
| `SkipKeyRestore` | switch | No | Skip restoring host/function keys |

### Example

```powershell
.\Restore-FunctionsFromDR.ps1 `
  -ArmTemplateBlobPath  "sub-id/func-api/20260306-142542.arm.json" `
  -ManifestBlobPath     "sub-id/func-api/20260306-142542.json" `
  -CodeZipBlobPath      "sub-id/func-api/20260306-142542.zip" `
  -SourceStorageAccount    "stdrbackup2026" `
  -SourceStorageContainer  "func-backups" `
  -SourceStorageSubscription "source-sub-id" `
  -TargetSubscriptionId    "target-sub-id" `
  -TargetResourceGroup     "rg-dr-region" `
  -TargetLocation          "eastus" `
  -TargetStorageAccountName "stdrfuncapps"
```

---

## Get-FunctionAppContent.ps1

### What It Does

A lightweight script for downloading an individual Function App's content and configuration to the local filesystem. Uses **Azure CLI** (not Az PowerShell).

1. **Downloads site content** via ARM VFS API (`hostruntime/admin/vfs/`)
   - Recursively traverses the virtual filesystem, downloading files individually
   - Falls back to Kudu SCM ZIP API (`/api/zip/site/wwwroot/`) if VFS fails

2. **Exports app settings** → `appsettings.json` (via `az functionapp config appsettings list`)

3. **Exports site configuration** → `siteconfig.json` (via `az functionapp config show`)

4. **Exports function & host keys** → `functionkeys.json` (via `az functionapp keys list`)

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `FunctionAppName` | string | Yes | Name of the Function App |
| `ResourceGroupName` | string | Yes | Resource group name |
| `SubscriptionId` | string | No | Azure subscription ID (default: current CLI subscription) |
| `OutputPath` | string | No | Local output directory (default: `./<appName>-content`) |

### Example

```powershell
.\Get-FunctionAppContent.ps1 `
  -FunctionAppName "my-function-app" `
  -ResourceGroupName "rg-prod" `
  -OutputPath "C:\backups\my-function-app"
```

### Output Structure

```
<appName>-content/
├── vfs-content/           # Full file tree from the Function App
│   ├── host.json
│   ├── function1/
│   │   ├── function.json
│   │   └── run.csx
│   └── ...
├── appsettings.json       # App settings (name/value array)
├── siteconfig.json        # Site configuration
└── functionkeys.json      # Host & function keys
```

---

## Restore-FunctionAppContent.ps1

### What It Does

Restores content from a local backup directory (created by `Get-FunctionAppContent.ps1`) into a target Function App. Uses **Azure CLI** (not Az PowerShell).

1. **Uploads site content** via ARM VFS API (`PUT` per file)
   - Recursively uploads from the `vfs-content/` directory
   - Falls back to Kudu SCM ZIP API if VFS fails (creates a temporary ZIP)

2. **Restores app settings** from `appsettings.json` via `az functionapp config appsettings set`

3. **Restores site configuration** from `siteconfig.json` via `az functionapp config set`
   - Handles: `linuxFxVersion`, `phpVersion`, `pythonVersion`, `nodeVersion`, `javaVersion`, `netFrameworkVersion`, `use32BitWorkerProcess`, `ftpsState`, `http20Enabled`, `minTlsVersion`, `numberOfWorkers`

4. **Restores function & host keys** from `functionkeys.json` via `az functionapp keys set`
   - Restores both `functionKeys` and `systemKeys`

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `FunctionAppName` | string | Yes | Name of the target Function App |
| `ResourceGroupName` | string | Yes | Resource group name |
| `SubscriptionId` | string | No | Azure subscription ID (default: current CLI subscription) |
| `InputPath` | string | No | Local backup directory (default: `./<appName>-content`) |
| `SkipAppSettings` | switch | No | Skip restoring app settings |
| `SkipSiteConfig` | switch | No | Skip restoring site configuration |
| `SkipFunctionKeys` | switch | No | Skip restoring function keys |
| `SkipSiteContent` | switch | No | Skip uploading site content files |

### Example

```powershell
# Full restore
.\Restore-FunctionAppContent.ps1 `
  -FunctionAppName "my-function-app" `
  -ResourceGroupName "rg-prod"

# Restore only code (skip settings and keys)
.\Restore-FunctionAppContent.ps1 `
  -FunctionAppName "my-function-app" `
  -ResourceGroupName "rg-prod" `
  -SkipAppSettings -SkipSiteConfig -SkipFunctionKeys
```

---

## Supported SKUs & Hosting Models

| SKU / Plan | Backup Support | Code Download Method | Code Deploy Method |
|------------|---------------|----------------------|---------------------|
| **Flex Consumption** | ✅ Full | Blob container (OAuth via Az.Storage) | Upload to `<appName>-package` blob container |
| **Consumption (Y1)** | ✅ Full | Kudu SitePackages / wwwroot ZIP | `az functionapp deployment source config-zip` |
| **Premium (EP1/EP2/EP3)** | ✅ Full | Kudu SitePackages / wwwroot ZIP | `az functionapp deployment source config-zip` |
| **Dedicated (App Service Plan)** | ✅ Full | Kudu SitePackages / wwwroot ZIP | `az functionapp deployment source config-zip` |
---

## Prerequisites

### For Backup-FunctionsToDR / Restore-FunctionsFromDR (Az PowerShell)

- **PowerShell 5.1+** or **PowerShell 7+**
- **Az PowerShell modules:**
  - `Az.Accounts`
  - `Az.Resources`
  - `Az.Storage`
  - `Az.Websites`

### For Get-FunctionAppContent / Restore-FunctionAppContent (Azure CLI)

- **Azure CLI** (`az`) installed and logged in

### Azure Permissions

| Role | Scope | Required For |
|------|-------|-------------|
| **Reader** | Source subscription | Enumerating Function Apps |
| **Website Contributor** | Source Function Apps | Downloading code, reading config, listing keys |
| **Storage Blob Data Contributor** | Target storage account (backup) | Uploading backup artifacts |
| **Contributor** | Target resource group (restore) | ARM template deployment |
| **Storage Blob Data Contributor** | Target storage account (restore) | Flex Consumption code deployment |
| **User Access Administrator** | Target storage account (restore) | RBAC assignment for managed identity |

---

## Authentication & Identity

### Backup Script (Az PowerShell)
- Uses `Connect-AzAccount` for interactive login
- Storage operations use **OAuth** (`-UseConnectedAccount`) — works even when shared-key access is disabled
- Kudu access uses **publishing credentials** (`Get-AzWebAppPublishingProfile` with Basic auth)
- ARM calls use **`Invoke-AzRestMethod`** (current Az context token)

### Restore Script (Az PowerShell)
- Uses `Connect-AzAccount` for interactive login
- ARM template deployment via `New-AzResourceGroupDeployment`
- Storage operations use **OAuth** (`-UseConnectedAccount`)
- Key restoration uses `az rest --method PUT` (ARM REST API)
- Code deployment uses `az functionapp deployment source config-zip` or `Publish-AzWebApp`

### Content Scripts (Azure CLI)
- Uses `az account get-access-token` for Bearer token
- ARM VFS API calls use Bearer auth
- Kudu SCM fallback uses the same Bearer token
- Configuration management via `az functionapp config` commands

---

## Backup Artifacts

### Per-App Artifacts (Backup-FunctionsToDR)

| Artifact | Format | Contents |
|----------|--------|----------|
| `<timestamp>.zip` | ZIP | Deployable code package |
| `<timestamp>.json` | JSON | Full configuration manifest (see below) |
| `<timestamp>.arm.json` | JSON | Deployable ARM template |

### Configuration Manifest Schema (`<timestamp>.json`)

```json
{
  "backupTimestamp": "2026-03-06T14:25:42.000Z",
  "appName": "func-api-example",
  "resourceGroup": "rg-prod",
  "subscriptionId": "...",
  "location": "westus2",
  "kind": "functionapp,linux",
  "tags": { "env": "prod" },
  "identity": {
    "type": "UserAssigned",
    "userAssignedIdentities": { ... }
  },
  "sku": "FlexConsumption",
  "state": "Running",
  "defaultHostName": "func-api-example.azurewebsites.net",
  "httpsOnly": true,
  "clientCertEnabled": false,
  "serverFarmId": "/subscriptions/.../serverfarms/plan-...",
  "hostingPlan": { "id": "...", "name": "...", "sku": { ... } },
  "siteConfig": {
    "linuxFxVersion": "...",
    "ftpsState": "Disabled",
    "minTlsVersion": "1.2",
    "cors": { ... },
    "ipSecurityRestrictions": [ ... ]
  },
  "appSettings": { "KEY": "value", ... },
  "connectionStrings": { "name": { "value": "...", "type": "SQLAzure" } },
  "slotStickySettings": { ... },
  "hostKeys": { "masterKey": "...", "functionKeys": { ... }, "systemKeys": { ... } },
  "functionKeys": { "HttpTrigger1": { "default": "..." } },
  "flexConsumptionConfig": { "deployment": { ... }, "runtime": { ... }, "scaleAndConcurrency": { ... } },
  "customDomains": [ ... ],
  "codePackageBlob": "sub-id/app-name/timestamp.zip",
  "packageSource": "FlexConsumption-Blob"
}
```

### ARM Template Features

The generated ARM template includes:

- **Parameterized inputs:** `location`, `functionAppName`, `storageAccountName`, `appInsightsConnectionString`, `managedIdentityName`
- **Smart storage URI substitution:** `AzureWebJobsStorage__blobServiceUri`, `queueServiceUri`, `tableServiceUri` are templated to reference the parameter
- **Classic connection string substitution:** `AzureWebJobsStorage` connection strings are also parameterized
- **App Insights override:** Can inject a new connection string at deploy time
- **Identity support:** Creates User-Assigned Managed Identity resource when the original app used one
- **Flex Consumption support:** Includes `functionAppConfig` with deployment storage, runtime, and scale settings
- **Full siteConfig:** TLS, CORS, IP restrictions, runtime versions, health check, etc.

### Blob Storage Layout

```
<container>/
├── <sourceSubscriptionId>/
│   ├── <appName1>/
│   │   ├── 20260306-142542.zip
│   │   ├── 20260306-142542.json
│   │   └── 20260306-142542.arm.json
│   ├── <appName2>/
│   │   └── ...
│   └── reports/
│       └── functionapp-backup-20260306-142542.csv
└── ...
```

---

## Step-by-Step Workflows

### Scenario 1: Full DR Backup & Restore

```powershell
# 1. Backup all Function Apps from production subscription
.\Backup-FunctionsToDR.ps1 `
  -SourceSubscriptionId  "prod-sub-id" `
  -TargetSubscriptionId  "dr-sub-id" `
  -TargetResourceGroup   "rg-dr-backup" `
  -TargetStorageAccount  "stdrbackup" `
  -TargetContainer       "func-backups"

# 2. Check the CSV report for backup status
# (uploaded to: func-backups/<prod-sub-id>/reports/functionapp-backup-<timestamp>.csv)

# 3. Restore a specific Function App to DR region
.\Restore-FunctionsFromDR.ps1 `
  -ArmTemplateBlobPath  "prod-sub-id/func-api/20260306-142542.arm.json" `
  -ManifestBlobPath     "prod-sub-id/func-api/20260306-142542.json" `
  -CodeZipBlobPath      "prod-sub-id/func-api/20260306-142542.zip" `
  -SourceStorageAccount    "stdrbackup" `
  -SourceStorageContainer  "func-backups" `
  -SourceStorageSubscription "dr-sub-id" `
  -TargetSubscriptionId    "dr-sub-id" `
  -TargetResourceGroup     "rg-dr-apps" `
  -TargetLocation          "eastus" `
  -TargetStorageAccountName "stdrfuncapps"
```

### Scenario 2: Individual App Content Backup & Restore

```powershell
# 1. Backup a single Function App locally
.\Get-FunctionAppContent.ps1 `
  -FunctionAppName "my-func-app" `
  -ResourceGroupName "rg-prod"

# 2. Restore to a different (or same) Function App
.\Restore-FunctionAppContent.ps1 `
  -FunctionAppName "my-func-app-clone" `
  -ResourceGroupName "rg-staging" `
  -InputPath ".\my-func-app-content"
```

### Scenario 3: Infra-Only Restore (Skip Code)

```powershell
.\Restore-FunctionsFromDR.ps1 `
  -ArmTemplateBlobPath  "..." `
  -ManifestBlobPath     "..." `
  -CodeZipBlobPath      "..." `
  -SourceStorageAccount    "stdrbackup" `
  -SourceStorageContainer  "func-backups" `
  -TargetSubscriptionId    "dr-sub-id" `
  -TargetResourceGroup     "rg-dr-apps" `
  -TargetLocation          "eastus" `
  -TargetStorageAccountName "stdrfuncapps" `
  -SkipCodeDeploy `
  -SkipKeyRestore
```

### Scenario 4: Selective Content Restore

```powershell
# Restore only app settings (skip code, config, and keys)
.\Restore-FunctionAppContent.ps1 `
  -FunctionAppName "my-func-app" `
  -ResourceGroupName "rg-prod" `
  -SkipSiteContent -SkipSiteConfig -SkipFunctionKeys
```

---