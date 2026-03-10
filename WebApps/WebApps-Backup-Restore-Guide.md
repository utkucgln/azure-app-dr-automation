# Azure Web Apps — Backup & Restore Guide

> **Last updated:** March 2026  
> **Scope:** All scripts in the `WebApps/` folder of the `azure-app-dr-automation` repository.

---

## Table of Contents

1. [Overview](#overview)
2. [Script Inventory](#script-inventory)
3. [Architecture & Workflow](#architecture--workflow)
4. [Get-WebAppContent.ps1](#get-webappcontentps1)
5. [Restore-WebAppContent.ps1](#restore-webappcontentps1)
6. [Prerequisites](#prerequisites)
7. [Authentication](#authentication)
8. [Parameter Reference](#parameter-reference)
9. [Backup Artifacts](#backup-artifacts)
10. [Step-by-Step Workflows](#step-by-step-workflows)

---

## Overview

This folder contains two PowerShell scripts that provide a **backup and restore** solution for individual Azure Web Apps (App Service). The scripts download site content, configuration, connection strings, deployment slots, and general properties to a local directory, and restore them to a target Web App.

| Script | Purpose |
|--------|---------|
| **Get-WebAppContent.ps1** | Downloads site content and full configuration from a Web App to a local directory |
| **Restore-WebAppContent.ps1** | Restores site content and configuration from a local backup to a target Web App |

Both scripts use **Azure CLI** (`az`) for authentication and configuration management, and the **ARM VFS API** (with Kudu SCM fallback) for file operations.

---

## Script Inventory

### 1. Get-WebAppContent.ps1

| Property | Value |
|----------|-------|
| **Lines** | ~190 |
| **Module** | Azure CLI (`az`) |
| **Purpose** | Downloads site content and exports configuration for a single Azure Web App |
| **Outputs** | Local directory with VFS content tree, appsettings.json, connectionstrings.json, siteconfig.json, webapp-properties.json, slots.json |

### 2. Restore-WebAppContent.ps1

| Property | Value |
|----------|-------|
| **Lines** | ~260 |
| **Module** | Azure CLI (`az`) |
| **Purpose** | Restores site content and configuration from a local backup to a target Web App |
| **Outputs** | Updated Web App with restored files, app settings, connection strings, and site config |

---

## Architecture & Workflow

```
Azure Web App                     Local Filesystem
┌──────────────────────┐          ┌──────────────────────────────┐
│  Site Content        │  Get-    │  <appname>-content/          │
│  (wwwroot files)     │  WebApp  │   ├─ vfs-content/            │
│  App Settings        │ ──────►  │   │  ├─ index.html           │
│  Connection Strings  │  Content │   │  ├─ web.config            │
│  Site Configuration  │  .ps1    │   │  ├─ bin/                  │
│  Web App Properties  │          │   │  └─ ...                   │
│  Deployment Slots    │          │   ├─ appsettings.json         │
└──────────────────────┘          │   ├─ connectionstrings.json   │
                                  │   ├─ siteconfig.json          │
         ▲                        │   ├─ webapp-properties.json   │
         │                        │   └─ slots.json               │
         │  Restore-              └──────────────────────────────┘
         │  WebApp                            │
         └──── Content.ps1 ◄──────────────────┘
```

---

## Get-WebAppContent.ps1

### What It Does

Downloads the complete site content and configuration for a single Azure Web App to the local filesystem. Performs six operations:

#### 1. Download Site Content (VFS)
- Uses the **ARM VFS API** endpoint:
  ```
  https://management.azure.com/subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.Web/sites/{appName}/extensions/api/vfs/site/wwwroot/
  ```
- Recursively traverses the virtual filesystem, downloading each file individually
- Falls back to **Kudu SCM ZIP API** (`/api/zip/site/wwwroot/`) if VFS fails
  - Dynamically resolves the SCM hostname via `az webapp show`
  - Falls back to `<appName>.scm.azurewebsites.net` if resolution fails

#### 2. Export App Settings
- Runs `az webapp config appsettings list` → saves as `appsettings.json`
- Captures all application settings as a name/value array

#### 3. Export Connection Strings
- Runs `az webapp config connection-string list` → saves as `connectionstrings.json`
- Captures connection string names, values, and types (e.g., `SQLAzure`, `Custom`)

#### 4. Export Site Configuration
- Runs `az webapp config show` → saves as `siteconfig.json`
- Captures runtime stack, TLS settings, FTPS state, Always On, WebSockets, etc.

#### 5. Export Web App Properties
- Runs `az webapp show` → saves as `webapp-properties.json`
- Captures the full Web App resource including location, kind, tags, identity, hostnames, SSL states, etc.

#### 6. Export Deployment Slots
- Runs `az webapp deployment slot list` → saves as `slots.json`
- Captures all deployment slot configurations

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `WebAppName` | string | Yes | Name of the Azure Web App |
| `ResourceGroupName` | string | Yes | Resource group containing the Web App |
| `SubscriptionId` | string | No | Azure subscription ID (default: current CLI subscription) |
| `OutputPath` | string | No | Local output directory (default: `./<WebAppName>-content`) |

### Examples

```powershell
# Basic usage (uses current CLI subscription, saves to ./mywebapp-content)
.\Get-WebAppContent.ps1 -WebAppName mywebapp -ResourceGroupName rg-prod

# Specify subscription and custom output path
.\Get-WebAppContent.ps1 `
  -WebAppName mywebapp `
  -ResourceGroupName rg-prod `
  -SubscriptionId "30459864-17d2-4001-ad88-1472f3dd1ba5" `
  -OutputPath "C:\backups\mywebapp"
```

### Key Helper Function

| Function | Purpose |
|----------|---------|
| `Get-VfsDirectory` | Recursively traverses the ARM VFS API, downloading files and creating directories locally. Accepts `RelativePath`, `LocalPath`, `Headers`, `BaseUrl`, and `Depth` parameters. |

---

## Restore-WebAppContent.ps1

### What It Does

Restores content from a local backup directory (created by `Get-WebAppContent.ps1`) into a target Web App. Performs four operations:

#### 1. Upload Site Content (VFS)
- Uses the **ARM VFS API** endpoint (same base URL as backup, but with `PUT` method)
- Recursively uploads from the `vfs-content/` directory
- Creates remote directories first (PUT with trailing slash)
- Reads files as byte arrays and uploads with `application/octet-stream` content type
- Falls back to **Kudu SCM ZIP API** if VFS fails:
  - Creates a temporary ZIP from the `vfs-content/` directory
  - Uploads via `PUT /api/zip/site/wwwroot/`
  - Cleans up the temporary ZIP after upload

#### 2. Restore App Settings
- Reads `appsettings.json` and parses the name/value array
- Applies via `az webapp config appsettings set --settings name1=value1 name2=value2 ...`
- Reports the count of restored settings

#### 3. Restore Connection Strings
- Reads `connectionstrings.json` and iterates over each connection string property
- Applies each one individually via `az webapp config connection-string set`:
  - Preserves the connection string type (`SQLAzure`, `Custom`, `MySql`, etc.)
  - Uses `--connection-string-type` and `--settings name=value`
- Reports each restored connection string with its type

#### 4. Restore Site Configuration
- Reads `siteconfig.json` and maps properties to `az webapp config set` flags
- Supported properties:

| Property | CLI Flag |
|----------|----------|
| `linuxFxVersion` | `--linux-fx-version` |
| `phpVersion` | `--php-version` |
| `pythonVersion` | `--python-version` |
| `nodeVersion` | `--node-version` |
| `javaVersion` | `--java-version` |
| `netFrameworkVersion` | `--net-framework-version` |
| `use32BitWorkerProcess` | `--use-32bit-worker-process` |
| `ftpsState` | `--ftps-state` |
| `http20Enabled` | `--http20-enabled` |
| `minTlsVersion` | `--min-tls-version` |
| `numberOfWorkers` | `--number-of-workers` |
| `alwaysOn` | `--always-on` |
| `webSocketsEnabled` | `--web-sockets-enabled` |

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `WebAppName` | string | Yes | Name of the target Web App to restore into |
| `ResourceGroupName` | string | Yes | Resource group containing the target Web App |
| `SubscriptionId` | string | No | Azure subscription ID (default: current CLI subscription) |
| `InputPath` | string | No | Local backup directory (default: `./<WebAppName>-content`) |
| `SkipAppSettings` | switch | No | Skip restoring app settings |
| `SkipConnectionStrings` | switch | No | Skip restoring connection strings |
| `SkipSiteConfig` | switch | No | Skip restoring site configuration |
| `SkipSiteContent` | switch | No | Skip uploading site content files |

### Examples

```powershell
# Full restore (all content + config)
.\Restore-WebAppContent.ps1 `
  -WebAppName mywebapp `
  -ResourceGroupName rg-prod

# Restore from a custom backup directory
.\Restore-WebAppContent.ps1 `
  -WebAppName mywebapp `
  -ResourceGroupName rg-prod `
  -InputPath "C:\backups\mywebapp-content"

# Restore only code (skip settings, connection strings, and config)
.\Restore-WebAppContent.ps1 `
  -WebAppName mywebapp `
  -ResourceGroupName rg-prod `
  -SkipAppSettings -SkipConnectionStrings -SkipSiteConfig

# Restore only connection strings
.\Restore-WebAppContent.ps1 `
  -WebAppName mywebapp `
  -ResourceGroupName rg-prod `
  -SkipSiteContent -SkipAppSettings -SkipSiteConfig
```

### Key Helper Function

| Function | Purpose |
|----------|---------|
| `Set-WebVfsDirectory` | Recursively uploads files to the ARM VFS API. Creates directories via PUT with trailing slash, uploads files as byte arrays. Accepts `LocalPath`, `RelativePath`, `Headers`, `BaseUrl`, and `Depth` parameters. |

---

## Prerequisites

### Software

- **Azure CLI** (`az`) installed and logged in (`az login`)
- **PowerShell 5.1+** or **PowerShell 7+**

### Azure Permissions

| Role | Scope | Required For |
|------|-------|-------------|
| **Reader** | Web App | Reading site content and configuration |
| **Website Contributor** | Web App | Downloading content via VFS/Kudu, reading config |
| **Contributor** | Web App (restore) | Uploading content, setting config |

---

## Authentication

Both scripts use **Azure CLI** for authentication:

1. **Bearer token** — obtained via `az account get-access-token` for ARM VFS API calls
2. **CLI commands** — `az webapp config appsettings`, `az webapp config connection-string`, `az webapp config show/set`, `az webapp show`, `az webapp deployment slot list`
3. **Subscription context** — defaults to `az account show --query id` if `SubscriptionId` is not specified

Ensure you are logged in and the correct subscription is selected:

```powershell
az login
az account set --subscription "your-subscription-id"
```

---

## Backup Artifacts

### Output Structure (Get-WebAppContent)

```
<WebAppName>-content/
├── vfs-content/               # Full file tree from /site/wwwroot/
│   ├── index.html
│   ├── web.config
│   ├── bin/
│   │   ├── MyApp.dll
│   │   └── ...
│   ├── wwwroot/               # Static assets (if applicable)
│   └── ...
├── appsettings.json           # App settings (name/value array from az CLI)
├── connectionstrings.json     # Connection strings (name/value/type object)
├── siteconfig.json            # Site configuration (runtime, TLS, etc.)
├── webapp-properties.json     # Full Web App resource properties
└── slots.json                 # Deployment slot list
```

### File Format Details

#### appsettings.json
```json
[
  { "name": "WEBSITE_NODE_DEFAULT_VERSION", "value": "~18", "slotSetting": false },
  { "name": "MY_SETTING", "value": "my-value", "slotSetting": false }
]
```

#### connectionstrings.json
```json
{
  "MyDatabase": {
    "value": "Server=tcp:myserver.database.windows.net...",
    "type": "SQLAzure"
  },
  "StorageConn": {
    "value": "DefaultEndpointsProtocol=https;AccountName=...",
    "type": "Custom"
  }
}
```

#### siteconfig.json
```json
{
  "linuxFxVersion": "NODE|18-lts",
  "ftpsState": "Disabled",
  "http20Enabled": true,
  "minTlsVersion": "1.2",
  "alwaysOn": true,
  "webSocketsEnabled": false,
  "use32BitWorkerProcess": false,
  "numberOfWorkers": 1,
  ...
}
```

#### webapp-properties.json
Contains the full ARM representation of the Web App resource including:
- Location, kind, tags
- Identity (system-assigned / user-assigned)
- Hostnames and SSL states
- Outbound IP addresses
- Container settings (if applicable)
- Availability state

#### slots.json
```json
[
  {
    "name": "mywebapp/staging",
    "resourceGroup": "rg-prod",
    ...
  }
]
```

---

## Step-by-Step Workflows

### Scenario 1: Full Backup & Restore (Same App)

```powershell
# 1. Backup
.\Get-WebAppContent.ps1 -WebAppName mywebapp -ResourceGroupName rg-prod

# 2. (Make changes, test, etc.)

# 3. Restore to original state
.\Restore-WebAppContent.ps1 -WebAppName mywebapp -ResourceGroupName rg-prod
```

### Scenario 2: Clone to a Different Web App

```powershell
# 1. Backup source app
.\Get-WebAppContent.ps1 -WebAppName source-app -ResourceGroupName rg-prod

# 2. Restore to a different (pre-existing) target app
.\Restore-WebAppContent.ps1 `
  -WebAppName target-app `
  -ResourceGroupName rg-staging `
  -InputPath ".\source-app-content"
```

### Scenario 3: Backup to Custom Location

```powershell
# Backup to a specific directory (useful for versioned backups)
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
.\Get-WebAppContent.ps1 `
  -WebAppName mywebapp `
  -ResourceGroupName rg-prod `
  -OutputPath "C:\backups\mywebapp\$timestamp"
```

### Scenario 4: Restore Only Configuration (No Code)

```powershell
.\Restore-WebAppContent.ps1 `
  -WebAppName mywebapp `
  -ResourceGroupName rg-prod `
  -SkipSiteContent
```

### Scenario 5: Restore Only Code (No Config)

```powershell
.\Restore-WebAppContent.ps1 `
  -WebAppName mywebapp `
  -ResourceGroupName rg-prod `
  -SkipAppSettings -SkipConnectionStrings -SkipSiteConfig
```

### Scenario 6: Cross-Subscription Backup

```powershell
.\Get-WebAppContent.ps1 `
  -WebAppName mywebapp `
  -ResourceGroupName rg-prod `
  -SubscriptionId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
```

---
