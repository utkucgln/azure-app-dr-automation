# Function Apps Backup & Restore — Complete Guide

> **Scripts covered:** `Backup-FunctionsToDR.ps1` · `Restore-FunctionsFromDR.ps1`
>
> **Last updated:** March 2026

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Backup Script — `Backup-FunctionsToDR.ps1`](#4-backup-script)
   - [Parameters](#41-parameters)
   - [What Gets Backed Up](#42-what-gets-backed-up)
   - [Helper Functions](#43-helper-functions)
   - [Execution Flow](#44-execution-flow)
   - [ARM Template Generation](#45-arm-template-generation)
   - [Backup Manifest JSON Schema](#46-backup-manifest-json-schema)
   - [Blob Storage Layout](#47-blob-storage-layout)
   - [Usage Examples](#48-usage-examples)
5. [Restore Script — `Restore-FunctionsFromDR.ps1`](#5-restore-script)
   - [Parameters](#51-parameters)
   - [Execution Flow (6 Steps)](#52-execution-flow-6-steps)
   - [Flex Consumption Specifics](#53-flex-consumption-specifics)
   - [Key Restoration](#54-key-restoration)
   - [Usage Examples](#55-usage-examples)
6. [Code Package Acquisition Strategies](#6-code-package-acquisition-strategies)
7. [Flex Consumption Support](#7-flex-consumption-support)
8. [Security & Authentication](#8-security--authentication)
9. [Cross-Subscription Support](#9-cross-subscription-support)
10. [Error Handling & Reporting](#10-error-handling--reporting)
11. [Limitations & Known Caveats](#11-limitations--known-caveats)
12. [Disaster Recovery Runbook](#12-disaster-recovery-runbook)
13. [Reference Links](#13-reference-links)

---

## 1. Overview

These two PowerShell scripts implement a full **backup-and-restore pipeline** for Azure Function Apps across subscriptions and regions. They are designed for **disaster recovery (DR)** scenarios where Function App code packages, configuration, keys, and infrastructure definitions must be replicated to a secondary location.

The backup script produces **three artifacts per Function App** — a code ZIP, a configuration manifest JSON, and a deployable ARM template — providing a self-contained restore package.

| Capability | Backup | Restore |
|---|---|---|
| Classic Consumption (`Y1` / Dynamic) | ✅ | ✅ |
| Premium (Elastic Premium) | ✅ | ✅ |
| Dedicated (App Service Plan) | ✅ | ✅ |
| Flex Consumption | ✅ | ✅ |
| Linux Function Apps | ✅ | ✅ |
| Windows Function Apps | ✅ | ✅ |
| Code package (ZIP) | ✅ Export | ✅ Deploy |
| ARM template generation | ✅ Auto-generated | ✅ Deploy via `New-AzResourceGroupDeployment` |
| Host & function keys | ✅ Export | ✅ Restore |
| Managed identity | ✅ Export | ✅ Re-create (User-Assigned) |
| Cross-subscription storage | ✅ | ✅ |
| Cross-region restore | — | ✅ |
| OAuth / Microsoft Entra ID auth | ✅ | ✅ |
| PowerShell 5.1 compatible | ✅ | ✅ |

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     SOURCE SUBSCRIPTION                                │
│                                                                        │
│  ┌───────────────┐  ┌────────────────┐  ┌──────────────────────────┐  │
│  │ Consumption   │  │ Premium /      │  │ Flex Consumption         │  │
│  │ Function App  │  │ Dedicated FA   │  │ Function App             │  │
│  │ (Kudu/SCM)    │  │ (Kudu/SCM)     │  │ (Blob-based deployment)  │  │
│  └──────┬────────┘  └──────┬─────────┘  └────────┬─────────────────┘  │
│         │                  │                      │                    │
└─────────┼──────────────────┼──────────────────────┼────────────────────┘
          │                  │                      │
          ▼                  ▼                      ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │              Backup-FunctionsToDR.ps1                           │
 │                                                                 │
 │  Per Function App:                                              │
 │  1. Download code package (Kudu ZIP / SitePackages / Flex Blob) │
 │  2. Export config manifest via ARM REST API                     │
 │  3. Generate deployable ARM template                            │
 │  4. Upload all 3 artifacts to target Storage                    │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ Upload via OAuth
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     TARGET SUBSCRIPTION                                │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Storage Account (Blob Container)                               │  │
│  │                                                                  │  │
│  │  <subId>/<appName>/<timestamp>.zip       ← code package         │  │
│  │  <subId>/<appName>/<timestamp>.json      ← config manifest      │  │
│  │  <subId>/<appName>/<timestamp>.arm.json  ← ARM template         │  │
│  │  <subId>/reports/functionapp-backup-<ts>.csv  ← summary report  │  │
│  └───────────────────────────┬──────────────────────────────────────┘  │
│                              │                                         │
└──────────────────────────────┼─────────────────────────────────────────┘
                               │ Download 3 artifacts
                               ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │              Restore-FunctionsFromDR.ps1                        │
 │                                                                 │
 │  1. Download ARM template + manifest + code ZIP from blob       │
 │  2. Flex Consumption: create deployment container, upload ZIP   │
 │  3. Deploy ARM template (hosting plan + identity + Function App)│
 │  4. Classic: deploy code via ZIP deploy / Publish-AzWebApp      │
 │  5. Assign RBAC (Flex: Storage Blob Data Contributor)           │
 │  6. Restore host keys, function keys + validate                 │
 └──────────────────────────┬──────────────────────────────────────┘
                            │ ARM deployment + code deploy
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     TARGET SUBSCRIPTION / REGION                       │
│                                                                        │
│  ┌──────────────┐  ┌──────────────────┐  ┌──────────────────────────┐ │
│  │ App Service  │  │ User-Assigned    │  │ Microsoft.Web/sites/     │ │
│  │ Plan (new)   │◄─┤ Managed Identity │◄─┤ <restored-name>         │ │
│  │              │  │ (if applicable)  │  │ + code + keys            │ │
│  └──────────────┘  └──────────────────┘  └──────────────────────────┘ │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Prerequisites

### Required Azure PowerShell Modules

| Module | Purpose |
|---|---|
| `Az.Accounts` | Authentication, subscription context switching, `Invoke-AzRestMethod` |
| `Az.Websites` | `Get-AzWebApp`, `Get-AzWebAppPublishingProfile`, `Publish-AzWebApp` |
| `Az.Storage` | Blob upload/download, container management |
| `Az.Resources` | `Get-AzResource`, `New-AzResourceGroupDeployment` |
| `Az.ManagedServiceIdentity` | `Get-AzUserAssignedIdentity` (restore only, Flex Consumption) |

### Required Azure CLI (Restore only)

- `az functionapp deployment source config-zip` — for classic ZIP deploy
- `az rest` — for key restoration via ARM REST API

### RBAC Permissions

| Operation | Required Role |
|---|---|
| **Read** Function Apps (source) | `Reader` or `Website Contributor` on source subscription |
| **Read** publishing profile (source) | `Website Contributor` on source resource groups |
| **Read** Flex Consumption blob (source) | `Storage Blob Data Reader` on the deployment storage account |
| **Write** to DR Storage (target) | `Storage Blob Data Contributor` on the backup storage account |
| **Deploy** ARM template (restore) | `Contributor` on the target resource group |
| **Deploy** code via ZIP (restore) | `Website Contributor` on the target resource group |
| **Assign** RBAC (Flex restore) | `User Access Administrator` or `Owner` on the target storage account |
| **Manage** keys (restore) | `Website Contributor` on the restored Function App |

---

## 4. Backup Script

**File:** `Backup-FunctionsToDR.ps1`

### 4.1 Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `SourceSubscriptionId` | `string` | **Yes** | — | Subscription containing the Function Apps to back up. |
| `TargetSubscriptionId` | `string` | **Yes** | — | Subscription containing the backup Storage account. |
| `TargetResourceGroup` | `string` | **Yes** | — | Resource group of the backup Storage account. |
| `TargetStorageAccount` | `string` | **Yes** | — | Name of the backup Storage account. |
| `TargetContainer` | `string` | **Yes** | — | Blob container name (created automatically if missing). |
| `IncludeSlots` | `switch` | No | `$false` | Include deployment slots (currently reserved for future use). |

### 4.2 What Gets Backed Up

Each Function App produces **three artifacts**:

#### 1. Code Package (`.zip`)

The actual deployable code, obtained via one of several strategies depending on the Function App type (see [Section 6](#6-code-package-acquisition-strategies)).

#### 2. Configuration Manifest (`.json`)

| Artifact | Manifest Property | Notes |
|---|---|---|
| App settings | `appSettings{}` | Full key-value map including connection strings, runtime settings, custom settings. Obtained via ARM `listApplicationSettings` (not redacted — includes secrets). |
| Connection strings | `connectionStrings{}` | Named connection strings with type (SQLAzure, Custom, etc.) and values. |
| Site configuration | `siteConfig{}` | Runtime versions, TLS settings, CORS, IP restrictions, always-on, health check path, worker count, FTP state, HTTP/2, WebSockets, managed pipeline mode. |
| Hosting plan | `hostingPlan{}` | App Service Plan ID, name, location, kind, SKU (name/tier/size/family/capacity). |
| Managed identity | `identity{}` | Type (SystemAssigned/UserAssigned), user-assigned identity resource IDs with principal/client IDs. |
| Host keys | `hostKeys{}` | Master key, default function keys, system keys. |
| Per-function keys | `functionKeys{}` | Individual keys per function endpoint. |
| Slot-sticky settings | `slotStickySettings{}` | App setting names, connection string names, and storage config names that are slot-sticky. |
| Flex Consumption config | `flexConsumptionConfig{}` | Deployment storage (blob URL + auth), runtime config, scale and concurrency settings. |
| Custom domains | `customDomains[]` | Hostname bindings, SSL state, certificate thumbprints. |
| Metadata | Various top-level fields | Location, kind, tags, SKU, state, default hostname, HTTPS-only, client cert enabled, server farm ID, backup timestamp. |

#### 3. ARM Template (`.arm.json`)

An auto-generated, parameterized ARM template ready for deployment. See [Section 4.5](#45-arm-template-generation) for full details.

### 4.3 Helper Functions

#### `Get-PublishingCreds`

```
Purpose:  Obtains Kudu SCM credentials from the publish profile.
Method:   Get-AzWebAppPublishingProfile → parse XML → extract userName/userPWD
          for the SCM endpoint → encode as Basic auth header.
Returns:  @{ AuthHeader = "Basic <base64>" }
```

#### `Invoke-KuduJson`

```
Purpose:  Makes authenticated GET/POST/PUT/DELETE calls to Kudu REST API.
Auth:     Uses Basic auth header from Get-PublishingCreds.
Returns:  Parsed JSON response (via Invoke-RestMethod).
```

#### `Download-KuduFile`

```
Purpose:  Downloads a file from Kudu (e.g., ZIP of wwwroot or a SitePackage).
Auth:     Basic auth via Invoke-WebRequest.
Output:   Saves to specified local file path.
```

#### `Get-AppSettings`

```
Purpose:  Retrieves all app settings as a hashtable.
Method:   Get-AzWebApp → SiteConfig.AppSettings → hashtable.
Note:     This is used during backup to check WEBSITE_RUN_FROM_PACKAGE.
          The full manifest uses ARM's listApplicationSettings instead.
```

#### `Ensure-Container`

```
Purpose:  Ensures a blob container exists in the backup storage account.
Input:    PSStorageAccount object + container name.
Returns:  Storage context for subsequent blob operations.
```

#### `Get-FlexConsumptionDeploymentInfo`

```
Purpose:  Detects if a Function App is Flex Consumption and returns deployment
          blob container details.
Method:   ARM REST API GET on the site resource → check properties.sku == 'FlexConsumption'
          → extract functionAppConfig.deployment.storage.
Returns:  @{ Sku; BlobContainerUrl; AuthType } or $null for non-Flex apps.
```

#### `Download-FlexConsumptionPackage`

```
Purpose:  Downloads the latest deployment ZIP from a Flex Consumption app's
          blob container.
Method:   Parses account name and container from the blob URL → lists blobs
          via Az.Storage (OAuth) → downloads the newest .zip blob.
Note:     Works when shared-key access is disabled on the storage account.
```

#### `Invoke-Arm`

```
Purpose:  Convenience wrapper around Invoke-AzRestMethod.
Returns:  Parsed JSON body for 2xx responses, $null otherwise.
```

#### `Export-FunctionAppConfig`

```
Purpose:  Collects ALL configuration for a Function App via ARM REST API and
          returns an ordered dictionary for JSON serialization.

ARM Endpoints Called:
  1. GET  sites/{appName}                           → site resource (kind, identity, tags, etc.)
  2. POST sites/{appName}/config/appsettings/list   → all app settings (including secrets)
  3. POST sites/{appName}/config/connectionstrings/list → connection strings
  4. GET  sites/{appName}/config/slotConfigNames    → slot-sticky settings
  5. POST sites/{appName}/host/default/listkeys     → host keys (master, function, system)
  6. GET  sites/{appName}/functions                 → function list
  7. POST sites/{appName}/functions/{fn}/listkeys   → per-function keys
  8. GET  serverfarms/{planId}                      → hosting plan details
  9. GET  sites/{appName}/hostNameBindings           → custom domains

All calls use api-version=2024-04-01.
```

#### `Build-ArmTemplate`

```
Purpose:  Generates a deployable ARM template JSON from the manifest.
Output:   Complete ARM template with parameters, variables, resources, outputs.
See Section 4.5 for full details.
```

### 4.4 Execution Flow

```
1. Authenticate via Connect-AzAccount
2. Set context to Source subscription
3. Enumerate Function Apps:
   - Get-AzResource -ResourceType "Microsoft.Web/sites"
   - Filter: Kind contains "functionapp" AND NOT "workflowapp" (excludes Standard Logic Apps)
4. Switch to Target subscription → ensure blob container exists (OAuth)
5. Switch back to Source subscription
6. Create temp directory for local staging

── Per Function App ──
  7a. Detect if Flex Consumption (Get-FlexConsumptionDeploymentInfo)
  
  IF Flex Consumption:
    7b. Download code package from deployment blob container (OAuth)
  ELSE (Classic / Consumption / Premium):
    7c. Get publishing credentials (Kudu)
    7d. Check WEBSITE_RUN_FROM_PACKAGE setting
    7e. Download code via appropriate strategy:
        - External URL → direct download
        - "1" → SitePackages via Kudu VFS → newest ZIP
        - Fallback → Kudu ZIP API (/api/zip/site/wwwroot/)
  
  8.  Export-FunctionAppConfig → full configuration manifest
  9.  Build-ArmTemplate → deployable ARM template
  10. Switch to Target sub → upload all 3 artifacts:
      - {subId}/{appName}/{timestamp}.zip
      - {subId}/{appName}/{timestamp}.json
      - {subId}/{appName}/{timestamp}.arm.json
  11. Switch back to Source sub → continue to next app
  12. Append to report array

13. Export report CSV → upload to Target storage
14. Print summary (processed, succeeded, failed, file locations)
```

### 4.5 ARM Template Generation

The `Build-ArmTemplate` function generates a fully parameterized, deployable ARM template from the backup manifest. This template is key to the DR restore process — it provisions all infrastructure without requiring manual configuration.

#### Template Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `location` | string | Original location | Azure region for all resources |
| `functionAppName` | string | Original name | Name of the Function App |
| `storageAccountName` | string | *(required)* | Storage account for the Function App (must exist) |
| `appInsightsConnectionString` | string | Original value | Application Insights connection string (empty to skip) |
| `managedIdentityName` | string | *(conditional)* | User-assigned managed identity name (only if original used one) |

#### Resources Created

| # | Resource Type | Condition | Details |
|---|---|---|---|
| 1 | `Microsoft.ManagedIdentity/userAssignedIdentities` | Only if original used UserAssigned identity | Name from parameter |
| 2 | `Microsoft.Web/serverfarms` | Always | Matches original SKU (tier, size, family, capacity) |
| 3 | `Microsoft.Web/sites` | Always | Full Function App with siteConfig, appSettings, identity |

#### App Settings Handling

The template intelligently rewrites storage-related app settings to reference the deployment storage account parameter:

| Setting Pattern | Template Handling |
|---|---|
| `AzureWebJobsStorage__blobServiceUri` | `concat('https://', parameters('storageAccountName'), '.blob.core.windows.net/')` |
| `AzureWebJobsStorage__queueServiceUri` | `concat('https://', parameters('storageAccountName'), '.queue.core.windows.net/')` |
| `AzureWebJobsStorage__tableServiceUri` | `concat('https://', parameters('storageAccountName'), '.table.core.windows.net/')` |
| `AzureWebJobsStorage` (classic connection string) | Rebuilt with `parameters('storageAccountName')` |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | `if(empty(parameters('appInsightsConnectionString')), '<original>', parameters('appInsightsConnectionString'))` |
| All other settings | Preserved as-is |

#### Flex Consumption Extensions

For Flex Consumption apps, the template includes `functionAppConfig` in the site properties:

```json
{
  "functionAppConfig": {
    "deployment": {
      "storage": {
        "type": "blobContainer",
        "value": "[concat('https://', parameters('storageAccountName'), '.blob.core.windows.net/', parameters('functionAppName'), '-package')]",
        "authentication": {
          "type": "userassignedidentity",
          "userAssignedIdentityResourceId": "[resourceId('Microsoft.ManagedIdentity/...')]"
        }
      }
    },
    "runtime": { ... },
    "scaleAndConcurrency": { ... }
  }
}
```

#### Template Outputs

| Output | Value |
|---|---|
| `functionAppDefaultHostName` | The `defaultHostName` of the deployed Function App |
| `functionAppResourceId` | The full ARM resource ID of the deployed Function App |

### 4.6 Backup Manifest JSON Schema

```json
{
  "backupTimestamp": "2026-03-06T14:25:42.1234567+00:00",
  "appName": "func-api-2eydgai2qkvey",
  "resourceGroup": "rg-production",
  "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "location": "eastus",
  "kind": "functionapp,linux",
  "tags": { "env": "prod" },
  "identity": {
    "type": "UserAssigned",
    "userAssignedIdentities": {
      "/subscriptions/.../Microsoft.ManagedIdentity/.../my-identity": {
        "principalId": "...",
        "clientId": "..."
      }
    }
  },
  "sku": "FlexConsumption",
  "state": "Running",
  "defaultHostName": "func-api-2eydgai2qkvey.azurewebsites.net",
  "httpsOnly": true,
  "clientCertEnabled": false,
  "serverFarmId": "/subscriptions/.../serverfarms/ASP-...",
  "hostingPlan": {
    "id": "/subscriptions/.../serverfarms/ASP-...",
    "name": "ASP-rgproduction",
    "location": "East US",
    "kind": "functionapp",
    "sku": {
      "name": "FC1",
      "tier": "FlexConsumption",
      "size": "FC1",
      "family": "FC",
      "capacity": 0
    }
  },
  "siteConfig": {
    "linuxFxVersion": "PYTHON|3.11",
    "numberOfWorkers": 1,
    "alwaysOn": false,
    "ftpsState": "Disabled",
    "http20Enabled": true,
    "minTlsVersion": "1.2",
    "cors": {
      "allowedOrigins": ["https://portal.azure.com"],
      "supportCredentials": false
    },
    "ipSecurityRestrictions": [],
    "healthCheckPath": "/api/health"
  },
  "appSettings": {
    "FUNCTIONS_EXTENSION_VERSION": "~4",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "AzureWebJobsStorage__blobServiceUri": "https://stprod.blob.core.windows.net/",
    "AzureWebJobsStorage__queueServiceUri": "https://stprod.queue.core.windows.net/",
    "AzureWebJobsStorage__tableServiceUri": "https://stprod.table.core.windows.net/",
    "APPLICATIONINSIGHTS_CONNECTION_STRING": "InstrumentationKey=...",
    "CUSTOM_SETTING": "my-value"
  },
  "connectionStrings": {
    "MyDb": {
      "value": "Server=tcp:myserver.database.windows.net;...",
      "type": "SQLAzure"
    }
  },
  "slotStickySettings": {
    "appSettingNames": ["SLOT_SPECIFIC_SETTING"],
    "connectionStringNames": [],
    "azureStorageConfigNames": []
  },
  "hostKeys": {
    "masterKey": "abc123...",
    "functionKeys": {
      "default": "def456..."
    },
    "systemKeys": {
      "durabletask_extension": "ghi789..."
    }
  },
  "functionKeys": {
    "httpGetFunction": {
      "default": "jkl012..."
    },
    "processQueue": {
      "default": "mno345..."
    }
  },
  "flexConsumptionConfig": {
    "deployment": {
      "storage": {
        "type": "blobContainer",
        "value": "https://stprod.blob.core.windows.net/app-package-xxx",
        "authentication": {
          "type": "userassignedidentity",
          "userAssignedIdentityResourceId": "/subscriptions/.../Microsoft.ManagedIdentity/.../my-identity"
        }
      }
    },
    "runtime": {
      "name": "python",
      "version": "3.11"
    },
    "scaleAndConcurrency": {
      "maximumInstanceCount": 100,
      "instanceMemoryMB": 2048,
      "triggers": { ... }
    }
  },
  "customDomains": [
    {
      "name": "func-api-2eydgai2qkvey/func-api-2eydgai2qkvey.azurewebsites.net",
      "hostName": "Verified",
      "sslState": "Disabled",
      "thumbprint": null
    }
  ],
  "codePackageBlob": "ME-MngEnv.../func-api-2eydgai2qkvey/20260306-142542.zip",
  "packageSource": "FlexConsumption-Blob"
}
```

### 4.7 Blob Storage Layout

Backups are organized by source subscription ID and Function App name. Each backup produces three files:

```
<TargetContainer>/
├── <SourceSubscriptionId>/
│   ├── <FunctionAppName-1>/
│   │   ├── 20260306-142542.zip           ← code package
│   │   ├── 20260306-142542.json          ← configuration manifest
│   │   ├── 20260306-142542.arm.json      ← ARM template
│   │   ├── 20260307-080000.zip           ← next day's backup
│   │   ├── 20260307-080000.json
│   │   └── 20260307-080000.arm.json
│   ├── <FunctionAppName-2>/
│   │   ├── 20260306-142550.zip
│   │   ├── 20260306-142550.json
│   │   └── 20260306-142550.arm.json
│   └── reports/
│       ├── functionapp-backup-20260306-142542.csv
│       └── functionapp-backup-20260307-080000.csv
```

**CSV report columns:**

| Column | Description |
|---|---|
| `AppName` | Function App name |
| `ResourceGroup` | Source resource group |
| `Location` | Azure region |
| `Kind` | Function App kind (e.g., `functionapp,linux`) |
| `Sku` | Hosting SKU (Dynamic, FlexConsumption, ElasticPremium, etc.) |
| `PackageSource` | How the code was obtained: `RunFromPackage`, `wwwroot-zip`, `FlexConsumption-Blob` |
| `CodeBlob` | Blob path for the code ZIP |
| `ConfigBlob` | Blob path for the manifest JSON |
| `ArmTemplate` | Blob path for the ARM template |
| `AppSettings` | Comma-separated list of app setting names |
| `Functions` | Comma-separated list of function names |
| `When` | Export timestamp |
| `Status` | `OK` or `FAILED: <message>` |

### 4.8 Usage Examples

#### Back up all Function Apps to a different subscription

```powershell
.\Backup-FunctionsToDR.ps1 `
  -SourceSubscriptionId "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" `
  -TargetSubscriptionId "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" `
  -TargetResourceGroup "rg-dr-backups" `
  -TargetStorageAccount "stdrbackups" `
  -TargetContainer "functionapp-backups"
```

#### Same-subscription backup

```powershell
.\Backup-FunctionsToDR.ps1 `
  -SourceSubscriptionId "ME-MngEnvMCAP304533-utkugulen-1" `
  -TargetSubscriptionId "ME-MngEnvMCAP304533-utkugulen-1" `
  -TargetResourceGroup "rg-agent-lab-01" `
  -TargetStorageAccount "stagentlab20260105" `
  -TargetContainer "config-docs"
```

---

## 5. Restore Script

**File:** `Restore-FunctionsFromDR.ps1`

### 5.1 Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `ArmTemplateBlobPath` | `string` | **Yes** | — | Blob path of the ARM template (e.g., `<subId>/<appName>/<ts>.arm.json`). |
| `ManifestBlobPath` | `string` | **Yes** | — | Blob path of the manifest JSON (e.g., `<subId>/<appName>/<ts>.json`). |
| `CodeZipBlobPath` | `string` | **Yes** | — | Blob path of the code ZIP (e.g., `<subId>/<appName>/<ts>.zip`). |
| `SourceStorageAccount` | `string` | **Yes** | — | Storage account holding the backup blobs. |
| `SourceStorageContainer` | `string` | **Yes** | — | Blob container holding the backup blobs. |
| `SourceStorageSubscription` | `string` | No | Current context | Subscription of the backup storage account. |
| `TargetSubscriptionId` | `string` | **Yes** | — | Subscription to deploy the restored Function App into. |
| `TargetResourceGroup` | `string` | **Yes** | — | Target resource group (must already exist). |
| `TargetLocation` | `string` | **Yes** | — | Azure region for restored resources. |
| `TargetStorageAccountName` | `string` | **Yes** | — | Storage account for the restored Function App (must already exist). |
| `NewFunctionAppName` | `string` | No | `<original>-dr` | Custom name for the restored Function App. |
| `AppInsightsConnectionString` | `string` | No | *(from backup)* | Override Application Insights connection string. |
| `ManagedIdentityName` | `string` | No | *(from backup)* | Override managed identity name. |
| `SkipCodeDeploy` | `switch` | No | `$false` | Skip code deployment (deploy infrastructure only). |
| `SkipKeyRestore` | `switch` | No | `$false` | Skip restoring host keys and function keys. |

### 5.2 Execution Flow (6 Steps)

#### Step 0: Download Backup Artifacts

```
1. Authenticate via Connect-AzAccount
2. Switch to source storage subscription (if specified)
3. Create OAuth storage context → download all 3 artifacts to temp directory:
   - template.arm.json
   - manifest.json
   - code.zip
4. Parse manifest JSON → determine original name, SKU, Flex status
5. Compute restore name:
   - If -NewFunctionAppName provided → use it
   - Otherwise → "<originalName>-dr"
```

#### Step 1: Prepare ARM Template Parameters

```
Build parameter hashtable:
  - location           = TargetLocation
  - functionAppName    = restoreName
  - storageAccountName = TargetStorageAccountName
  - appInsightsConnectionString (if provided)
  - managedIdentityName:
    - If -ManagedIdentityName provided → use it
    - Elif original used UserAssigned → extract name from backup, append "-dr" if no custom app name
```

#### Step 2: Flex Consumption Deployment Container (Conditional)

```
IF Flex Consumption AND NOT -SkipCodeDeploy:
  1. Determine container name: "{functionAppName}-package"
  2. Create OAuth context for target storage account
  3. Ensure container exists (create if missing)
  4. Upload code.zip as "code.zip" blob
```

#### Step 3: Deploy ARM Template

```
1. Run New-AzResourceGroupDeployment with:
   - TemplateFile = downloaded ARM template
   - TemplateParameterObject = prepared parameters
2. On success: extract defaultHostName from deployment outputs
3. On failure: show deployment name and suggest diagnostic command:
   Get-AzResourceGroupDeploymentOperation -ResourceGroupName <rg> -Name <deployment>
```

This step creates the App Service Plan, User-Assigned Managed Identity (if applicable), and the Function App itself.

#### Step 4: Deploy Code (Classic / Non-Flex)

**For Flex Consumption:** Code was already deployed via the blob container in Step 2. An RBAC assignment of `Storage Blob Data Contributor` is made to the managed identity on the target storage account.

**For Classic / Consumption / Premium:**
1. Primary: `az functionapp deployment source config-zip`
2. Fallback: `Publish-AzWebApp -ArchivePath`
3. If both fail: warning with path to local ZIP for manual deployment

#### Step 5: Restore Keys & Validate

**Runtime Readiness Polling:**
- The script polls the site state and host keys endpoint for up to **240 seconds** (4 minutes) with 15-second intervals
- A site is "ready" when `properties.state == "Running"` AND the `listkeys` endpoint returns a master key
- Flex Consumption apps can take 60-120+ seconds for host runtime initialization

**Key Restoration (via `az rest` PUT):**
- Each key is written to a temp JSON file and PUT via `az rest` to avoid PS 5.1 quoting issues
- Built-in retry logic: up to 3 attempts per key with 15-second waits between retries

| Key Type | ARM Endpoint |
|---|---|
| Master key | `PUT /host/default/functionkeys/master` |
| Host function keys | `PUT /host/default/functionkeys/{keyName}` |
| System keys | `PUT /host/default/systemkeys/{keyName}` |
| Per-function keys | `PUT /functions/{fnName}/keys/{keyName}` |

**Validation:**
- List all functions via ARM API
- Verify site state and default hostname
- Print summary with all deployment details

### 5.3 Flex Consumption Specifics

Flex Consumption Function Apps have unique deployment characteristics:

| Aspect | Behavior |
|---|---|
| **Code deployment** | Code is stored in a blob container, not via Kudu/SCM |
| **Container naming** | `{functionAppName}-package` on the target storage account |
| **Authentication** | User-Assigned Managed Identity with `Storage Blob Data Contributor` role |
| **ARM template** | Includes `functionAppConfig` with deployment storage, runtime, and scale settings |
| **Startup time** | 60-120+ seconds for host runtime initialization after ARM deployment |
| **RBAC assignment** | Script automatically assigns `Storage Blob Data Contributor` to the managed identity |
| **RBAC propagation** | Can take up to 5 minutes; script warns about this |

### 5.4 Key Restoration

The restore script preserves the original Function App keys to maintain API compatibility. This ensures that callers using the original function keys can continue without updating their configurations.

**Key types restored:**

| Key Category | Description | Use Case |
|---|---|---|
| **Master key** | Administrative access to all functions and management endpoints | Admin APIs, Durable Functions HTTP API |
| **Host function keys** | Shared keys available to all functions (e.g., `default`) | General-purpose function invocation |
| **System keys** | Extension-specific keys (e.g., `durabletask_extension`, `eventgrid_extension`) | Azure service integrations |
| **Per-function keys** | Keys scoped to individual function endpoints | Function-specific authorization |

**Retry behavior:** Each key PUT operation retries up to 3 times with 15-second intervals, accounting for host runtime startup delays.

### 5.5 Usage Examples

#### Restore from blob storage

```powershell
.\Restore-FunctionsFromDR.ps1 `
  -ArmTemplateBlobPath  "ME-MngEnv.../func-api-2eydgai2qkvey/20260306-142542.arm.json" `
  -ManifestBlobPath     "ME-MngEnv.../func-api-2eydgai2qkvey/20260306-142542.json" `
  -CodeZipBlobPath      "ME-MngEnv.../func-api-2eydgai2qkvey/20260306-142542.zip" `
  -SourceStorageAccount    stagentlab20260105 `
  -SourceStorageContainer  config-docs `
  -SourceStorageSubscription "ME-MngEnvMCAP304533-utkugulen-1" `
  -TargetSubscriptionId    "ME-MngEnvMCAP304533-utkugulen-1" `
  -TargetResourceGroup     rg-lab `
  -TargetLocation          eastus `
  -TargetStorageAccountName stagentlab20260105
```

#### Restore with a custom name and App Insights override

```powershell
.\Restore-FunctionsFromDR.ps1 `
  -ArmTemplateBlobPath  "sub123/my-func/20260306-142542.arm.json" `
  -ManifestBlobPath     "sub123/my-func/20260306-142542.json" `
  -CodeZipBlobPath      "sub123/my-func/20260306-142542.zip" `
  -SourceStorageAccount    stdrbackups `
  -SourceStorageContainer  functionapp-backups `
  -SourceStorageSubscription "dr-subscription-id" `
  -TargetSubscriptionId    "target-subscription-id" `
  -TargetResourceGroup     rg-dr `
  -TargetLocation          westeurope `
  -TargetStorageAccountName stdrfunctions `
  -NewFunctionAppName      "my-func-westeurope" `
  -AppInsightsConnectionString "InstrumentationKey=xxx;..."
```

#### Infrastructure-only restore (skip code and keys)

```powershell
.\Restore-FunctionsFromDR.ps1 `
  -ArmTemplateBlobPath  "sub123/my-func/20260306-142542.arm.json" `
  -ManifestBlobPath     "sub123/my-func/20260306-142542.json" `
  -CodeZipBlobPath      "sub123/my-func/20260306-142542.zip" `
  -SourceStorageAccount    stdrbackups `
  -SourceStorageContainer  functionapp-backups `
  -TargetSubscriptionId    "target-sub" `
  -TargetResourceGroup     rg-dr `
  -TargetLocation          westeurope `
  -TargetStorageAccountName stdrfunctions `
  -SkipCodeDeploy `
  -SkipKeyRestore
```

---

## 6. Code Package Acquisition Strategies

The backup script uses different strategies to obtain the code package depending on the Function App type and configuration:

```
                    ┌─────────────────────┐
                    │   Function App      │
                    └──────────┬──────────┘
                               │
                  ┌────────────┴────────────┐
                  │                         │
            Flex Consumption?          Classic/Consumption/
                  │                    Premium/Dedicated
                  │                         │
                  ▼                         ▼
     ┌──────────────────┐        ┌──────────────────────┐
     │ Download newest   │        │ Check                │
     │ ZIP from deploy   │        │ WEBSITE_RUN_FROM_    │
     │ blob container    │        │ PACKAGE setting      │
     │ (OAuth)           │        └──────────┬───────────┘
     └──────────────────┘              │
                              ┌────────┼────────┐
                              │        │        │
                          URL value   "1"    Not set / "0"
                              │        │        │
                              ▼        ▼        ▼
                         Direct    SitePackages  Kudu ZIP API
                         download  via Kudu VFS  /api/zip/
                         from URL  (newest ZIP)  site/wwwroot/
                              │        │        │
                              │        ▼        │
                              │   If no ZIPs    │
                              │   found ────────┘
                              │   (fallback)
                              ▼
                        ┌──────────┐
                        │ .zip file │
                        └──────────┘
```
