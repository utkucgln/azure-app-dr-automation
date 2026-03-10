# Logic Apps Backup & Restore — Complete Guide

> **Scripts covered:** `Backup-LogicAppsToDR.ps1` · `Restore-LogicAppFromDR.ps1`
>
> **Last updated:** March 2026

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Backup Script — `Backup-LogicAppsToDR.ps1`](#4-backup-script)
   - [Parameters](#41-parameters)
   - [What Gets Backed Up](#42-what-gets-backed-up)
   - [Helper Functions](#43-helper-functions)
   - [Execution Flow](#44-execution-flow)
   - [Backup JSON Schema](#45-backup-json-schema)
   - [Blob Storage Layout](#46-blob-storage-layout)
   - [Usage Examples](#47-usage-examples)
5. [Restore Script — `Restore-LogicAppFromDR.ps1`](#5-restore-script)
   - [Parameters](#51-parameters)
   - [Helper Functions](#52-helper-functions)
   - [Execution Flow (4 Steps)](#53-execution-flow-4-steps)
   - [Usage Examples](#54-usage-examples)
6. [PowerShell 5.1 Compatibility Considerations](#6-powershell-51-compatibility-considerations)
7. [Security & Authentication](#7-security--authentication)
8. [Cross-Subscription Support](#8-cross-subscription-support)
9. [Error Handling & Reporting](#9-error-handling--reporting)
10. [Limitations & Known Caveats](#10-limitations--known-caveats)
11. [Disaster Recovery Runbook](#11-disaster-recovery-runbook)
12. [Reference Links](#12-reference-links)

---

## 1. Overview

These two PowerShell scripts implement a full **backup-and-restore pipeline** for Azure Logic Apps across subscriptions and regions. They are designed for **disaster recovery (DR)** scenarios where Logic App definitions, API connections, run history, and configuration must be replicated to a secondary location.

| Capability | Backup | Restore |
|---|---|---|
| Consumption Logic Apps (`Microsoft.Logic/workflows`) | ✅ | ✅ |
| Standard Logic Apps (`Microsoft.Web/sites`, kind=`workflowapp`) | ✅ | ✅
| API connections (`Microsoft.Web/connections`) | ✅ Export | ✅ Re-create |
| Cross-subscription storage | ✅ | ✅ |
| Cross-region restore | — | ✅ |
| OAuth / Microsoft Entra ID auth | ✅ | ✅ |
| PowerShell 5.1 compatible | ✅ | ✅ |

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     SOURCE SUBSCRIPTION                            │
│                                                                    │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐  │
│  │  Consumption LA  │  │  Consumption LA  │  │  Standard LA    │  │
│  │  (Logic/workflows│  │  (Logic/workflows│  │  (Web/sites)    │  │
│  │   + Web/connections)│  + Web/connections)│  │  + N workflows  │  │
│  └────────┬─────────┘  └────────┬─────────┘  └───────┬─────────┘  │
│           │                     │                     │            │
└───────────┼─────────────────────┼─────────────────────┼────────────┘
            │                     │                     │
            ▼                     ▼                     ▼
   ┌───────────────────────────────────────────────────────────┐
   │            Backup-LogicAppsToDR.ps1                       │
   │  1. Export definitions, params, connections, run history  │
   │  2. Serialize to JSON (with raw definition preservation)  │
   │  3. Upload blobs + CSV report                             │
   └──────────────────────────┬────────────────────────────────┘
                              │ Upload via OAuth
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     TARGET SUBSCRIPTION                            │
│                                                                    │
│  ┌────────────────────────────────────────────────────────────────┐│
│  │  Storage Account (Blob Container)                             ││
│  │                                                               ││
│  │  <subId>/<appName>/<timestamp>.json   ← per-app backup       ││
│  │  <subId>/reports/logicapp-backup-<ts>.csv  ← summary report  ││
│  └───────────────────────────┬───────────────────────────────────┘│
│                              │                                    │
└──────────────────────────────┼────────────────────────────────────┘
                               │ Download blob or read local file
                               ▼
   ┌───────────────────────────────────────────────────────────┐
   │           Restore-LogicAppFromDR.ps1                      │
   │  1. Load backup JSON (blob or local file)                 │
   │  2. Re-create API connections in target RG/region         │
   │  3. Deploy Logic App via ARM REST PUT                     │
   │  4. Validate triggers & callback URLs                     │
   └──────────────────────────┬────────────────────────────────┘
                              │ ARM REST API PUT
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     TARGET SUBSCRIPTION / REGION                   │
│                                                                    │
│  ┌──────────────────────┐  ┌──────────────────────────────────┐   │
│  │ Microsoft.Web/       │  │ Microsoft.Logic/workflows/       │   │
│  │ connections (new)    │◄─┤ <restored-name>                  │   │
│  └──────────────────────┘  └──────────────────────────────────┘   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## 3. Prerequisites

### Required Azure PowerShell Modules

| Module | Purpose |
|---|---|
| `Az.Accounts` | Authentication, subscription context switching |
| `Az.LogicApp` | `Get-AzLogicApp`, `Get-AzLogicAppRunHistory`, `Get-AzLogicAppTrigger`, `Get-AzLogicAppTriggerCallbackUrl` |
| `Az.Websites` | `Get-AzWebApp` (Standard Logic Apps) |
| `Az.Storage` | `New-AzStorageContext`, `Get-AzStorageContainer`, `New-AzStorageContainer`, `Set-AzStorageBlobContent`, `Get-AzStorageBlobContent` |
| `Az.Resources` | `Get-AzResource` (API connections) |

### Required Azure CLI (Restore only)

The restore script uses `az rest` for ARM REST API calls. Ensure Azure CLI is installed and `az login` has been run.

### RBAC Permissions

| Operation | Required Role / Permission |
|---|---|
| **Read** Logic Apps (source) | `Logic App Contributor` or `Reader` on source subscription |
| **Read** API connections (source) | `Reader` on the resource groups containing `Microsoft.Web/connections` |
| **Write** to Storage (target) | `Storage Blob Data Contributor` on the target storage account |
| **Create** container (target) | `Storage Blob Data Contributor` on the target storage account |
| **Create** Logic Apps (restore target) | `Logic App Contributor` on the target resource group |
| **Create** API connections (restore target) | `Contributor` on the target resource group |

---

## 4. Backup Script

**File:** `Backup-LogicAppsToDR.ps1`

### 4.1 Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `SourceSubscriptionId` | `string` | **Yes** | — | Subscription containing the Logic Apps to back up. |
| `TargetSubscriptionId` | `string` | **Yes** | — | Subscription containing the backup Storage account. |
| `TargetResourceGroup` | `string` | **Yes** | — | Resource group of the backup Storage account. |
| `TargetStorageAccount` | `string` | **Yes** | — | Name of the Storage account for backup blobs. |
| `TargetContainer` | `string` | **Yes** | — | Blob container name (created automatically if missing). |
| `RunHistoryCount` | `int` | No | `10` | Number of recent run-history entries to export per Logic App. |
| `Plan` | `string` | No | `Both` | Which Logic App types to include: `Both`, `Consumption`, or `Standard`. |
| `IncludeDisabled` | `switch` | No | `$false` | Include Logic Apps in Disabled/Suspended (Consumption) or Stopped (Standard) state. |

### 4.2 What Gets Backed Up

#### Consumption Logic Apps (`Microsoft.Logic/workflows`)

| Artifact | Storage Property | Notes |
|---|---|---|
| Workflow definition | `definition` + `rawDefinitionJson` | Full trigger/action graph. Raw JSON preserved separately for PS 5.1 fidelity. |
| Workflow parameters | `parameters` | Runtime parameter values. Secret values appear as Key Vault references or `null`. |
| API connections | `apiConnections[]` | Each `Microsoft.Web/connections` resource: display name, API reference, status, created/changed times. Secret parameter **values** are NOT exported. |
| Trigger details | `triggers{}` | Name, type, state, last/next firing time, recurrence config, callback URL (for HTTP triggers). |
| Run history | `runHistory[]` | Latest N runs: run ID, status, start/end times, trigger name, error info, correlation. |
| Managed identity | `identity{}` | Type (SystemAssigned/UserAssigned), principal ID, tenant ID, user-assigned identity map. |
| Integration account | `integrationAccount{}` | Resource ID and name of linked integration account (if any). |
| Metadata | Various top-level fields | Tags, location, SKU, state, version, created/changed times, access endpoint, access control (IP restrictions). |
| Summary | `summary{}` | Action count, action types, connectors used, trigger count, HTTP trigger flag, run history count. |

#### Standard Logic Apps (`Microsoft.Web/sites`, kind=`workflowapp`)

| Artifact | Storage Property | Notes |
|---|---|---|
| Site properties | Top-level fields | State, default hostname, HTTPS-only flag, kind, location, tags. |
| App settings | `appSettings{}` | Non-secret settings. Settings matching `KEY|SECRET|PASSWORD|CONNECTIONSTRING` are redacted as `*** REDACTED ***`. |
| Managed identity | `identity{}` | Same structure as Consumption. |
| App Service Plan | `appServicePlan` | Server farm resource ID. |
| Runtime info | `runtime{}` | .NET framework version, Node version, Functions extension version, worker runtime. |
| Workflow definitions | `workflows{}.<name>.definition` | Full definition for each hosted workflow. Retrieved via ARM REST API (`Microsoft.Web/sites/workflows`). |
| Workflow metadata | `workflows{}.<name>.*` | Per-workflow: name, ID, type, kind (Stateful/Stateless), flow state, health, created/changed times. |
| Run history (per workflow) | `workflows{}.<name>.runHistory[]` | Latest N runs per workflow via ARM management API. |
| Summary | `summary{}` | Total workflow count, unique action types, action count. |

### 4.3 Helper Functions

#### `ConvertFrom-JToken`

```
Purpose:  Recursively converts Newtonsoft.Json.Linq.JToken objects to native
          PowerShell types (ordered hashtable, array, scalar).
Why:      Get-AzLogicApp returns Definition and $connections as JObject.
          PS 5.1's ConvertTo-Json treats JObject as IEnumerable, producing
          corrupted nested arrays instead of valid JSON.
Input:    A JToken (JObject, JArray, or JValue).
Output:   Ordered hashtable / array / scalar value.
```

#### `Ensure-Container`

```
Purpose:  Ensures a blob container exists; creates it if missing.
Auth:     Uses OAuth (UseConnectedAccount) — works even when shared-key
          access is disabled on the Storage account.
Returns:  The Azure Storage context for subsequent blob operations.
```

#### `Export-LogicAppConfig`

```
Purpose:  Exports a single Consumption Logic App as a structured hashtable.
Cmdlet:   Get-AzLogicApp
Exports:  Definition, parameters, identity, integration account, access
          control, SKU, tags, location, timestamps, raw definition JSON.
```

#### `Export-ApiConnections`

```
Purpose:  Discovers and exports all Microsoft.Web/connections resources
          referenced by a Logic App's $connections parameter.
Method:   Reads the $connections parameter → calls Get-AzResource for each
          connection → builds a structured export with display name, API
          reference, status, parameter names (NOT secret values).
Handles:  JObject, OrderedDictionary, plain hashtable, PSCustomObject input
          formats (normalises to hashtable internally).
```

#### `Export-RunHistory`

```
Purpose:  Exports the most recent N run-history entries.
Cmdlet:   Get-AzLogicAppRunHistory
Exports:  Run name, status (Succeeded/Failed/Cancelled/Running), start/end
          times, trigger name, error details, correlation info.
Note:     Does NOT include action-level detail.
```

#### `Export-TriggerCallbackUrl`

```
Purpose:  Retrieves trigger metadata and callback URLs for HTTP triggers.
Cmdlets:  Get-AzLogicAppTrigger, Get-AzLogicAppTriggerCallbackUrl
Exports:  Name, type, state, last/next execution time, recurrence,
          callback URL (for Request/Webhook triggers).
```

#### `Export-StandardLogicAppConfig`

```
Purpose:  Exports a single Standard Logic App as a structured hashtable.
Cmdlet:   Get-AzWebApp + Invoke-AzRestMethod (ARM REST API)
Exports:  Site properties, app settings (redacted), identity, App Service
          Plan, runtime info, all workflow definitions (via ARM), run
          history per workflow.
ARM API:  Microsoft.Web/sites/workflows (api-version=2024-04-01)
          Workflow runs via hostruntime/runtime/webhooks/workflow/api/
          management/workflows/<name>/runs
```

### 4.4 Execution Flow

```
1. Authenticate via Connect-AzAccount
2. Set context to Source subscription
3. Enumerate Logic Apps according to -Plan parameter:
   a. Consumption: Get-AzLogicApp → filter by State unless -IncludeDisabled
   b. Standard:    Get-AzWebApp → filter kind=workflowapp → filter by State
4. Switch to Target subscription → ensure blob container exists (OAuth)
5. Switch back to Source subscription
6. Create temp directory for local JSON staging

── Per Consumption Logic App ──
   6a. Export-LogicAppConfig       → definition, params, identity, etc.
   6b. Export-ApiConnections       → referenced Microsoft.Web/connections
   6c. Export-TriggerCallbackUrl   → trigger details + callback URLs
   6d. Export-RunHistory           → latest N runs
   6e. Build summary              → action types, connectors, trigger info
   6f. Serialize to JSON file     → splice raw definition to preserve arrays
   6g. Switch to Target sub       → upload blob
   6h. Switch back to Source sub  → continue to next app
   6i. Append to report array

── Per Standard Logic App ──
   7a. Export-StandardLogicAppConfig → site, app settings, workflows, runs
   7b. Serialize to JSON file
   7c. Switch to Target sub → upload blob → switch back
   7d. Append to report array

8. Export report CSV → upload to Target storage
9. Print summary (processed count, success/fail counts, file locations)
```

### 4.5 Backup JSON Schema

#### Consumption Logic App Backup

```json
{
  "backupTimestamp": "2026-03-06T11:08:04.1234567+00:00",
  "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "resourceGroup": "rg-production",
  "name": "logic-order-processor",
  "id": "/subscriptions/.../Microsoft.Logic/workflows/logic-order-processor",
  "location": "eastus",
  "tags": { "env": "prod", "team": "platform" },
  "state": "Enabled",
  "sku": { "name": "Standard" },
  "version": "08585...",
  "createdTime": "2025-01-15T...",
  "changedTime": "2026-03-01T...",
  "accessEndpoint": "https://prod-12.eastus.logic.azure.com:443/workflows/...",
  "identity": {
    "type": "SystemAssigned",
    "principalId": "...",
    "tenantId": "...",
    "userAssignedIdentities": null
  },
  "integrationAccount": { "id": null, "name": null },
  "accessControl": null,
  "definition": {
    "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
    "contentVersion": "1.0.0.0",
    "triggers": { ... },
    "actions": { ... },
    "outputs": { ... }
  },
  "parameters": {
    "$connections": {
      "type": "Object",
      "value": {
        "office365": {
          "connectionId": "/subscriptions/.../Microsoft.Web/connections/office365",
          "connectionName": "office365",
          "id": "/subscriptions/.../managedApis/office365"
        }
      }
    }
  },
  "apiConnections": [
    {
      "connectionKey": "office365",
      "connectionName": "office365",
      "resourceId": "/subscriptions/...",
      "location": "eastus",
      "displayName": "Office 365",
      "apiDisplayName": "Office 365 Outlook",
      "apiId": "/subscriptions/.../managedApis/office365",
      "apiType": "Microsoft.Web/locations/managedApis",
      "statuses": [ { "status": "Connected" } ],
      "createdTime": "2025-01-15T...",
      "changedTime": "2025-06-20T...",
      "parameterSetName": null,
      "nonSecretParameterNames": []
    }
  ],
  "triggers": {
    "When_a_HTTP_request_is_received": {
      "name": "When_a_HTTP_request_is_received",
      "type": "Microsoft.Logic/workflows/triggers",
      "state": "Enabled",
      "lastFired": "2026-03-06T10:55:00Z",
      "nextFire": null,
      "recurrence": null,
      "callbackUrl": "https://prod-12.eastus.logic.azure.com:443/workflows/.../triggers/When_a_HTTP_request_is_received/paths/invoke?..."
    }
  },
  "runHistory": [
    {
      "runName": "08585...",
      "status": "Succeeded",
      "startTime": "2026-03-06T10:55:00Z",
      "endTime": "2026-03-06T10:55:02Z",
      "triggerName": "When_a_HTTP_request_is_received",
      "error": null,
      "correlation": { "clientTrackingId": "..." }
    }
  ],
  "summary": {
    "actionCount": 5,
    "actionTypes": [ "Http", "ParseJson", "Condition", "Response" ],
    "connectorsUsed": [ "Office 365 Outlook" ],
    "hasHttpTrigger": true,
    "triggerCount": 1,
    "runHistoryCount": 10
  }
}
```

#### Standard Logic App Backup

```json
{
  "backupTimestamp": "2026-03-06T...",
  "subscriptionId": "...",
  "resourceGroup": "rg-production",
  "name": "logic-std-app",
  "id": "/subscriptions/.../Microsoft.Web/sites/logic-std-app",
  "type": "Standard",
  "location": "eastus",
  "tags": { ... },
  "state": "Running",
  "defaultHostName": "logic-std-app.azurewebsites.net",
  "httpsOnly": true,
  "kind": "functionapp,workflowapp",
  "identity": { ... },
  "appServicePlan": "/subscriptions/.../serverfarms/ASP-...",
  "runtime": {
    "netFrameworkVersion": "v6.0",
    "nodeVersion": "",
    "functionsExtVersion": "~4",
    "workerRuntime": "dotnet"
  },
  "appSettings": {
    "FUNCTIONS_EXTENSION_VERSION": "~4",
    "AzureWebJobsStorage__accountName": "stlogicstd...",
    "SOME_SECRET_KEY": "*** REDACTED ***"
  },
  "workflows": {
    "rss-workflow": {
      "name": "rss-workflow",
      "id": "/subscriptions/.../workflows/rss-workflow",
      "type": "Microsoft.Web/sites/workflows",
      "kind": "Stateful",
      "state": "Enabled",
      "health": { "state": "Healthy" },
      "definition": { ... },
      "createdTime": "...",
      "changedTime": "...",
      "runHistory": [ ... ]
    }
  },
  "summary": {
    "workflowCount": 1,
    "actionTypes": [ "Http", "ParseJson" ],
    "actionCount": 2
  }
}
```

### 4.6 Blob Storage Layout

Backups are organized in the container by source subscription ID and Logic App name:

```
<TargetContainer>/
├── <SourceSubscriptionId>/
│   ├── <LogicAppName-1>/
│   │   ├── 20260306-110804.json          ← timestamped backup
│   │   ├── 20260307-080000.json          ← next day's backup
│   │   └── ...
│   ├── <LogicAppName-2>/
│   │   └── 20260306-110810.json
│   └── reports/
│       ├── logicapp-backup-20260306-110804.csv   ← summary CSV
│       └── logicapp-backup-20260307-080000.csv
```

### 4.7 Usage Examples

#### Back up all Logic Apps (Consumption + Standard) to a different subscription

```powershell
.\Backup-LogicAppsToDR.ps1 `
  -SourceSubscriptionId "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" `
  -TargetSubscriptionId "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" `
  -TargetResourceGroup "rg-dr-backups" `
  -TargetStorageAccount "stdrbackups" `
  -TargetContainer "logicapp-backups"
```

#### Back up only Consumption Logic Apps with 20 runs of history

```powershell
.\Backup-LogicAppsToDR.ps1 `
  -SourceSubscriptionId "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" `
  -TargetSubscriptionId "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" `
  -TargetResourceGroup "rg-dr-backups" `
  -TargetStorageAccount "stdrbackups" `
  -TargetContainer "logicapp-backups" `
  -Plan Consumption `
  -RunHistoryCount 20
```

#### Back up only Standard Logic Apps, including disabled ones

```powershell
.\Backup-LogicAppsToDR.ps1 `
  -SourceSubscriptionId "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" `
  -TargetSubscriptionId "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" `
  -TargetResourceGroup "rg-dr-backups" `
  -TargetStorageAccount "stdrbackups" `
  -TargetContainer "logicapp-backups" `
  -Plan Standard `
  -IncludeDisabled
```

#### Same subscription backup (source and target in same sub)

```powershell
.\Backup-LogicAppsToDR.ps1 `
  -SourceSubscriptionId "ME-MngEnvMCAP304533-utkugulen-1" `
  -TargetSubscriptionId "ME-MngEnvMCAP304533-utkugulen-1" `
  -TargetResourceGroup "rg-agent-lab-01" `
  -TargetStorageAccount "stagentlab20260105" `
  -TargetContainer "config-docs"
```

---

## 5. Restore Script

**File:** `Restore-LogicAppFromDR.ps1`

> **Scope:** Currently supports **Consumption Logic Apps** only. Standard Logic App restore is not implemented.

### 5.1 Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `BackupSource` | `string` | **Yes** | — | Local file path to backup JSON **OR** blob path in DR storage (e.g. `<subId>/<appName>/<timestamp>.json`). |
| `SourceStorageAccount` | `string` | No* | — | DR Storage account name. *Required when `BackupSource` is a blob path. |
| `SourceStorageContainer` | `string` | No | `config-docs` | Blob container name in the DR Storage account. |
| `SourceStorageSubscription` | `string` | No* | — | Subscription of the DR Storage account. *Required when `BackupSource` is a blob path. |
| `TargetSubscriptionId` | `string` | **Yes** | — | Subscription where the Logic App will be restored. |
| `TargetResourceGroup` | `string` | **Yes** | — | Resource group for the restored Logic App. |
| `TargetLocation` | `string` | **Yes** | — | Azure region for restored resources (e.g. `westeurope`, `eastus`). |
| `NewLogicAppName` | `string` | No | `<original>-dr` | Name for the restored Logic App. Defaults to `<originalName>-dr`. |
| `SkipConnections` | `switch` | No | `$false` | Skip re-creating API connections (use when they already exist in target RG). |

### 5.2 Helper Functions

#### `Update-SubscriptionInResourceId`

Replaces the subscription segment in an ARM resource ID with a new subscription ID.

```
Input:   /subscriptions/old-sub-id/resourceGroups/rg/providers/...
Output:  /subscriptions/NEW-SUB-ID/resourceGroups/rg/providers/...
```

#### `Update-ResourceGroupInResourceId`

Replaces the resource group segment in an ARM resource ID.

```
Input:   /subscriptions/.../resourceGroups/old-rg/providers/...
Output:  /subscriptions/.../resourceGroups/NEW-RG/providers/...
```

#### `Update-LocationInManagedApiId`

Replaces the location segment in a managed API ID (used for API connections).

```
Input:   /subscriptions/.../locations/eastus/managedApis/office365
Output:  /subscriptions/.../locations/westeurope/managedApis/office365
```

#### `Extract-RawJsonValue`

Extracts a raw JSON object value for a given property from a JSON string using character-level parsing (brace depth tracking). This is critical because PowerShell 5.1's `ConvertFrom-Json` flattens single-element JSON arrays (e.g., `["Succeeded"]` becomes the scalar `"Succeeded"`), which the ARM API rejects.

```
Input:   Full JSON string + property name "definition"
Output:  The raw JSON object string for that property, with all arrays preserved
```

### 5.3 Execution Flow (4 Steps)

#### Step 1: Load Backup JSON

```
IF BackupSource exists as local file:
  → Read file directly (Get-Content -Raw)
ELSE:
  → Validate SourceStorageAccount + SourceStorageSubscription provided
  → Switch to DR storage subscription
  → Download blob via Get-AzStorageBlobContent (OAuth)
  → Read downloaded temp file

Parse JSON → extract original name, build restore name
  Default restore name = "<originalName>-dr"
  Override with -NewLogicAppName
```

#### Step 2: Restore API Connections

For each API connection in the backup's `apiConnections[]` array:

**With `-SkipConnections`:**
- Build the expected resource ID in the target subscription/RG
- Update the managed API location reference
- Add to `$connectionMap` without creating resources

**Without `-SkipConnections`:**
1. Extract the managed API name from the original API ID
2. Build new API ID pointing to the target region's managed API
3. Construct `Microsoft.Web/connections` resource body:
   ```json
   {
     "location": "<TargetLocation>",
     "properties": {
       "displayName": "<original display name>",
       "api": { "id": "/subscriptions/.../locations/<region>/managedApis/<apiName>" }
     }
   }
   ```
4. Write body to temp file (avoids PS 5.1 quoting issues with `az rest`)
5. `PUT` via `az rest` to `https://management.azure.com/<resourceId>?api-version=2016-06-01`
6. Verify creation with a `GET` request
7. Add to `$connectionMap`

#### Step 3: Deploy the Logic App

1. Build `$connections` parameter value from the connection map
2. Extract raw definition JSON from backup using `Extract-RawJsonValue` (preserves array structures)
3. Build workflow body with a placeholder for the definition:
   ```json
   {
     "location": "<TargetLocation>",
     "properties": {
       "state": "Enabled",
       "definition": "@@RAW_DEFINITION_PLACEHOLDER@@",
       "parameters": {
         "$connections": { "value": { ... } }
       }
     },
     "tags": { ... }
   }
   ```
4. If integration account exists in backup → update sub/RG references → add to body
5. Serialize body → string-replace placeholder with raw definition JSON
6. Write to temp file → `PUT` via `az rest` with `api-version=2019-05-01`
7. Verify deployment succeeded (check name, state, location in response)

#### Step 4: Validate

1. List triggers via ARM REST API (`api-version=2016-06-01`)
2. For each trigger, attempt to retrieve callback URL via `listCallbackUrl`
3. Print summary: Logic App name, subscription, RG, location, connection count, original backup timestamp

### 5.4 Usage Examples

#### Restore from a blob in DR storage

```powershell
.\Restore-LogicAppFromDR.ps1 `
  -BackupSource "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/logic-rss-demo/20260306-110804.json" `
  -SourceStorageAccount "stdrbackups" `
  -SourceStorageContainer "logicapp-backups" `
  -SourceStorageSubscription "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" `
  -TargetSubscriptionId "cccccccc-cccc-cccc-cccc-cccccccccccc" `
  -TargetResourceGroup "rg-dr" `
  -TargetLocation "westeurope"
```

#### Restore from a local backup file with a custom name

```powershell
.\Restore-LogicAppFromDR.ps1 `
  -BackupSource "C:\backups\logic-rss-demo-20260306-110804.json" `
  -TargetSubscriptionId "cccccccc-cccc-cccc-cccc-cccccccccccc" `
  -TargetResourceGroup "rg-dr" `
  -TargetLocation "westeurope" `
  -NewLogicAppName "logic-rss-demo-westeurope"
```

#### Restore when API connections already exist in the target

```powershell
.\Restore-LogicAppFromDR.ps1 `
  -BackupSource "C:\backups\logic-order-processor-20260306.json" `
  -TargetSubscriptionId "cccccccc-cccc-cccc-cccc-cccccccccccc" `
  -TargetResourceGroup "rg-dr" `
  -TargetLocation "westeurope" `
  -SkipConnections
```

#### Restore to the same subscription in a different region

```powershell
.\Restore-LogicAppFromDR.ps1 `
  -BackupSource "ME-MngEnvMCAP304533-utkugulen-1/logic-rss-demo/20260306-110804.json" `
  -SourceStorageAccount "stagentlab20260105" `
  -SourceStorageContainer "config-docs" `
  -SourceStorageSubscription "ME-MngEnvMCAP304533-utkugulen-1" `
  -TargetSubscriptionId "ME-MngEnvMCAP304533-utkugulen-1" `
  -TargetResourceGroup "rg-lab" `
  -TargetLocation "westeurope"
```

---
