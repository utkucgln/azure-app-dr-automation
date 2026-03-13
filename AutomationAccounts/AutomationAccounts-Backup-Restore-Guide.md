# Azure Automation Accounts — Backup & Restore Guide

> **Scripts covered:** `Backup-AutomationAccountToBlob.ps1` · `RestoreAutomationAccountsToDR.ps1`
>
> **Last updated:** March 2026

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Backup Script — `Backup-AutomationAccountToBlob.ps1`](#4-backup-script)
   - [Parameters](#41-parameters)
   - [What Gets Backed Up](#42-what-gets-backed-up)
   - [Helper Functions](#43-helper-functions)
   - [Execution Flow](#44-execution-flow)
   - [Backup Storage Layout](#45-backup-storage-layout)
   - [Usage Examples](#46-usage-examples)
5. [Restore Script — `RestoreAutomationAccountsToDR.ps1`](#5-restore-script)
   - [Parameters](#51-parameters)
   - [Helper Functions](#52-helper-functions)
   - [Execution Flow (7 Steps)](#53-execution-flow-7-steps)
   - [Usage Examples](#54-usage-examples)
6. [Security & Authentication](#6-security--authentication)
7. [Limitations & Known Caveats](#7-limitations--known-caveats)
8. [Disaster Recovery Runbook](#8-disaster-recovery-runbook)

---

## 1. Overview

These two PowerShell scripts implement a full **backup-and-restore pipeline** for Azure Automation Accounts. They are designed for **disaster recovery (DR)** scenarios where all Automation Account components must be replicated to a secondary region or subscription.

| Capability | Backup | Restore |
|---|---|---|
| Runbooks (PowerShell, Python, Graphical) | ✅ Definition + content | ✅ Import + publish |
| Schedules (OneTime, Hourly, Daily, Weekly, Monthly) | ✅ | ✅ (start time adjusted if in past) |
| Variables (plain + encrypted) | ✅ (encrypted values not readable) | ✅ (encrypted as placeholders) |
| Custom modules | ✅ | ✅ (from PSGallery) |
| Python 3 packages | ✅ | ✅ (via ARM REST) |
| Python 2 packages | ✅ | ✅ (via ARM REST) |
| Job schedule links | ✅ | ✅ |
| Credentials | ✅ Metadata only | ⚠️ Manual re-entry |
| Certificates | ✅ Metadata only | ⚠️ Manual re-entry |
| Connections | ✅ Metadata only | ⚠️ Manual re-entry |
| Cross-subscription | ✅ | ✅ |
| Cross-region | — | ✅ |

---

## 2. Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                     SOURCE SUBSCRIPTION                           │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │  Azure Automation Account                                    │ │
│  │  ├─ Runbooks (PowerShell, Python, Graphical)                │ │
│  │  ├─ Schedules                                                │ │
│  │  ├─ Variables                                                │ │
│  │  ├─ Modules                                                  │ │
│  │  ├─ Python 3/2 Packages                                     │ │
│  │  ├─ Job Schedules (runbook ↔ schedule links)                │ │
│  │  ├─ Credentials (secrets)                                    │ │
│  │  ├─ Certificates (secrets)                                   │ │
│  │  └─ Connections (secrets)                                    │ │
│  └────────────────────────┬─────────────────────────────────────┘ │
│                           │                                       │
└───────────────────────────┼───────────────────────────────────────┘
                            │  Backup-AutomationAccountToBlob.ps1
                            │  (az rest + az storage blob upload)
                            ▼
   ┌────────────────────────────────────────────────────────────────┐
   │  Azure Blob Storage                                            │
   │                                                                │
   │  <subName>/<subId>/<resourceGroup>/                           │
   │    Microsoft.Automation/<accountName>/                         │
   │      ├─ backup-metadata.json                                   │
   │      ├─ runbooks/                                              │
   │      │   ├─ <name>-definition.json                             │
   │      │   └─ <name>.ps1 | .py | .graphrunbook                  │
   │      ├─ schedules/<name>.json                                  │
   │      ├─ variables/<name>.json                                  │
   │      ├─ modules/<name>.json                                    │
   │      ├─ python3packages/<name>.json                            │
   │      ├─ python2packages/<name>.json                            │
   │      ├─ jobschedules/<runbook>--<schedule>.json                │
   │      ├─ credentials/<name>.json  (metadata only)               │
   │      ├─ certificates/<name>.json (metadata only)               │
   │      └─ connections/<name>.json  (metadata only)               │
   └───────────────────────────┬────────────────────────────────────┘
                               │  RestoreAutomationAccountsToDR.ps1
                               │  (az storage blob download + Az PowerShell)
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│                     TARGET SUBSCRIPTION / DR REGION                │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │  Azure Automation Account (DR)                               │ │
│  │  ├─ Runbooks (imported + published)                         │ │
│  │  ├─ Schedules (recreated, future start times)               │ │
│  │  ├─ Variables (encrypted = placeholders)                     │ │
│  │  ├─ Modules (installed from PSGallery)                      │ │
│  │  ├─ Python 3/2 Packages (installed via ARM)                 │ │
│  │  └─ Job Schedules (re-linked)                               │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ⚠ Credentials, certificates, connections → manual re-entry      │
└────────────────────────────────────────────────────────────────────┘
```

---

## 3. Prerequisites

### Required Tools

| Tool | Used By | Purpose |
|---|---|---|
| **Azure CLI** (`az`) | Backup script, Restore script (blob operations) | ARM REST calls (`az rest`), blob upload/download (`az storage blob`) |
| **Az PowerShell modules** | Restore script | `Import-AzAutomationRunbook`, `New-AzAutomationSchedule`, `New-AzAutomationVariable`, `New-AzAutomationModule`, `Register-AzAutomationScheduledRunbook`, `Invoke-AzRestMethod` |

### Required Az PowerShell Modules (Restore)

| Module | Purpose |
|---|---|
| `Az.Accounts` | Authentication, subscription context switching (`Get-AzContext`, `Set-AzContext`) |
| `Az.Automation` | Runbook import/publish, schedule/variable/module creation, job schedule registration |

### RBAC Permissions

| Operation | Required Role | Scope |
|---|---|---|
| Read source Automation Account | `Reader` or `Contributor` | Source Automation Account |
| Upload blobs (backup) | `Storage Blob Data Contributor` | Target storage account |
| Download blobs (restore) | `Storage Blob Data Reader` | Source storage account |
| Create resources in target AA | `Contributor` | Target Automation Account |

---

## 4. Backup Script

**File:** `Backup-AutomationAccountToBlob.ps1`

### 4.1 Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `SourceAutomationAccount` | `string` | **Yes** | — | Name of the Automation Account to back up |
| `SourceResourceGroup` | `string` | **Yes** | — | Resource group of the source Automation Account |
| `TargetStorageAccount` | `string` | **Yes** | — | Storage account for backup blobs |
| `TargetContainer` | `string` | No | `config-docs` | Blob container name |
| `ApiVersion` | `string` | No | `2023-11-01` | ARM API version |
| `SkipRunbooks` | `switch` | No | — | Skip runbook export |
| `SkipSchedules` | `switch` | No | — | Skip schedule export |
| `SkipVariables` | `switch` | No | — | Skip variable export |
| `SkipModules` | `switch` | No | — | Skip module export |
| `SkipJobSchedules` | `switch` | No | — | Skip job schedule export |

### 4.2 What Gets Backed Up

| Component | Backup Content | Secrets Included? |
|---|---|---|
| **Runbooks** | Definition JSON (type, state, description, log settings, tags) + content file (`.ps1`, `.py`, or `.graphrunbook`) | N/A |
| **Schedules** | Frequency, interval, start/expiry time, time zone, advanced schedule (weekdays, month days, monthly occurrences) | N/A |
| **Variables** | Name, value, description, encrypted flag | ❌ Encrypted values are not readable via ARM API |
| **Custom Modules** | Name, version, provisioning state, content link | N/A |
| **Python 3 Packages** | Name, version, provisioning state, content link | N/A |
| **Python 2 Packages** | Name, version, provisioning state, content link | N/A |
| **Job Schedules** | Runbook name, schedule name, parameters | N/A |
| **Credentials** | Username, description (metadata only) | ❌ Passwords excluded |
| **Certificates** | Thumbprint, expiry, exportability (metadata only) | ❌ Certificate content excluded |
| **Connections** | Connection type, field definitions (metadata only) | ❌ Secret field values excluded |

### 4.3 Helper Functions

| Function | Purpose |
|---|---|
| `Upload-JsonToBlob` | Serializes JSON to a temp file && uploads via `az storage blob upload --auth-mode login` |
| `Upload-FileToBlob` | Uploads a local file (runbook content) via `az storage blob upload --auth-mode login` |

### 4.4 Execution Flow

The backup script runs 9 steps:

| Step | Action |
|---|---|
| **0** | Resolve subscription context (`az account show`), validate source AA via ARM REST |
| **1** | Export runbooks — definition JSON + content file per runbook |
| **2** | Export schedules — one JSON per schedule |
| **3** | Export variables — one JSON per variable (encrypted values shown as not readable) |
| **4** | Export custom modules — only non-global modules (`isGlobal -eq $false`) |
| **5** | Export Python 3 packages |
| **6** | Export Python 2 packages |
| **7** | Export job schedule links — one JSON per runbook↔schedule pairing |
| **8** | Export credentials, certificates, connections (metadata only — no secrets) |
| **9** | Print summary with counts and list all uploaded blobs |

### 4.5 Backup Storage Layout

```
<subscription name>/
  <subscription id>/
    <resource group>/
      Microsoft.Automation/
        <automation account name>/
          backup-metadata.json
          runbooks/
            MyRunbook-definition.json
            MyRunbook.ps1
            PythonScript-definition.json
            PythonScript.py
            GraphicalRunbook-definition.json
            GraphicalRunbook.graphrunbook
          schedules/
            DailyHealthCheck.json
            WeeklyCleanup.json
          variables/
            Environment.json
            ApiKey.json
          modules/
            CustomModule.json
          python3packages/
            azure_identity.json
            azure_mgmt_resource.json
          python2packages/
            (package).json
          jobschedules/
            MyRunbook--DailyHealthCheck.json
          credentials/
            SampleServiceAccount.json
          certificates/
            MyCert.json
          connections/
            SampleAzureConnection.json
```

### 4.6 Usage Examples

```powershell
# Full backup
.\Backup-AutomationAccountToBlob.ps1 `
  -SourceAutomationAccount "automationaccountdr" `
  -SourceResourceGroup     "rg-agent-lab-01" `
  -TargetStorageAccount    "stagentlab20260105" `
  -TargetContainer         "config-docs"

# Skip runbooks and modules (schedules/variables only)
.\Backup-AutomationAccountToBlob.ps1 `
  -SourceAutomationAccount "automationaccountdr" `
  -SourceResourceGroup     "rg-agent-lab-01" `
  -TargetStorageAccount    "stagentlab20260105" `
  -SkipRunbooks -SkipModules
```

---

## 5. Restore Script

**File:** `RestoreAutomationAccountsToDR.ps1`

### 5.1 Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `SourceStorageAccount` | `string` | **Yes** | — | Storage account where backup blobs are stored |
| `SourceContainer` | `string` | No | `config-docs` | Blob container name |
| `SourceBlobPrefix` | `string` | **Yes** | — | Blob prefix path to the backup (produced by backup script) |
| `TargetSubscriptionId` | `string` | **Yes** | — | Subscription hosting the DR Automation Account |
| `TargetResourceGroup` | `string` | **Yes** | — | Resource group of the DR Automation Account |
| `TargetAutomationAccount` | `string` | **Yes** | — | Name of the DR Automation Account |
| `SkipRunbooks` | `switch` | No | — | Skip runbook restore |
| `SkipSchedules` | `switch` | No | — | Skip schedule restore |
| `SkipVariables` | `switch` | No | — | Skip variable restore |
| `SkipModules` | `switch` | No | — | Skip module installation |
| `SkipPythonPackages` | `switch` | No | — | Skip Python package installation |
| `SkipJobSchedules` | `switch` | No | — | Skip re-linking job schedules |

### 5.2 Helper Functions

| Function | Purpose |
|---|---|
| `Invoke-Arm` | ARM REST call via `Invoke-AzRestMethod` with status code handling |
| `Download-BlobJson` | Downloads a blob to temp file, parses JSON, returns object |
| `Download-BlobToFile` | Downloads a blob to a specified local path |
| `List-Blobs` | Lists blobs under a prefix via `az storage blob list --auth-mode login` |
| `Set-Sub` | Wrapper for `Set-AzContext` that passes `-Tenant` to avoid multi-tenant token errors |

### 5.3 Execution Flow (7 Steps)

| Step | Action | Tool |
|---|---|---|
| **0** | Download `backup-metadata.json` from blob, validate backup exists | `az storage blob download` |
| **1** | Validate target Automation Account exists via ARM REST | `Invoke-AzRestMethod` |
| **2** | **Runbooks** — download definition JSON + content file per runbook, `Import-AzAutomationRunbook`, `Publish-AzAutomationRunbook`. Maps ARM type names (`GraphPowerShell` → `GraphicalPowerShell`). | `az storage blob download` + Az PowerShell |
| **3** | **Schedules** — recreate with frequency/interval/timezone. Expired one-time schedules are skipped. Start times in the past are adjusted to the future. | Az PowerShell |
| **4** | **Variables** — recreate plain variables with original values. Encrypted variables are created as empty placeholders (must be updated manually). Falls back to `Set-AzAutomationVariable` if variable already exists. | Az PowerShell |
| **5** | **Modules** — install custom modules from PowerShell Gallery using the backed-up version number. | Az PowerShell |
| **6** | **Python packages** — install Python 3 and Python 2 packages via ARM REST PUT, using the original content link URI or falling back to PyPI. | `Invoke-AzRestMethod` |
| **7** | **Job schedules** — re-link runbooks to schedules with original parameters via `Register-AzAutomationScheduledRunbook`. Fails gracefully if the runbook or schedule doesn't exist. | Az PowerShell |

After all steps, the script prints a summary including:
- Counts of copied/failed/skipped items per component
- List of credentials, certificates, and connections that require manual re-creation

### 5.4 Usage Examples

```powershell
# Full restore from blob backup
.\RestoreAutomationAccountsToDR.ps1 `
  -SourceStorageAccount    "stagentlab20260105" `
  -SourceContainer         "config-docs" `
  -SourceBlobPrefix        "ME-MngEnvMCAP304533-utkugulen-1/30459864-17d2-4001-ad88-1472f3dd1ba5/rg-agent-lab-01/Microsoft.Automation/automationaccountdr" `
  -TargetSubscriptionId    "30459864-17d2-4001-ad88-1472f3dd1ba5" `
  -TargetResourceGroup     "rg-lab" `
  -TargetAutomationAccount "automationaccountdrbackup"

# Restore only runbooks and schedules (skip variables, modules, packages, job links)
.\RestoreAutomationAccountsToDR.ps1 `
  -SourceStorageAccount    "stagentlab20260105" `
  -SourceContainer         "config-docs" `
  -SourceBlobPrefix        "<subName>/<subId>/<rg>/Microsoft.Automation/<accountName>" `
  -TargetSubscriptionId    "target-sub-id" `
  -TargetResourceGroup     "rg-dr" `
  -TargetAutomationAccount "automation-dr" `
  -SkipVariables -SkipModules -SkipPythonPackages -SkipJobSchedules

# Restore only variables
.\RestoreAutomationAccountsToDR.ps1 `
  -SourceStorageAccount    "stagentlab20260105" `
  -SourceContainer         "config-docs" `
  -SourceBlobPrefix        "<subName>/<subId>/<rg>/Microsoft.Automation/<accountName>" `
  -TargetSubscriptionId    "target-sub-id" `
  -TargetResourceGroup     "rg-dr" `
  -TargetAutomationAccount "automation-dr" `
  -SkipRunbooks -SkipSchedules -SkipModules -SkipPythonPackages -SkipJobSchedules
```

---


## 6. Disaster Recovery Runbook

### Step 1: Take a backup (run periodically or on-demand)

```powershell
.\Backup-AutomationAccountToBlob.ps1 `
  -SourceAutomationAccount "my-automation-account" `
  -SourceResourceGroup     "rg-production" `
  -TargetStorageAccount    "stdrbackup2026" `
  -TargetContainer         "config-docs"
```

### Step 2: Verify backup in blob storage

Check that `backup-metadata.json` and all component folders are populated under the blob prefix:
```
<subName>/<subId>/rg-production/Microsoft.Automation/my-automation-account/
```

### Step 3: Ensure DR Automation Account exists

Create the target Automation Account in the DR region if it doesn't exist:
```powershell
az automation account create `
  --name "my-automation-account-dr" `
  --resource-group "rg-dr" `
  --location "westeurope"
```

### Step 4: Restore from backup

```powershell
.\RestoreAutomationAccountsToDR.ps1 `
  -SourceStorageAccount    "stdrbackup2026" `
  -SourceContainer         "config-docs" `
  -SourceBlobPrefix        "<subName>/<subId>/rg-production/Microsoft.Automation/my-automation-account" `
  -TargetSubscriptionId    "target-sub-id" `
  -TargetResourceGroup     "rg-dr" `
  -TargetAutomationAccount "my-automation-account-dr"
```

### Step 5: Post-restore manual tasks

1. **Update encrypted variables** — The summary will show how many encrypted variables were created as placeholders. Update them with the correct values:
   ```powershell
   Set-AzAutomationVariable -Name "ApiKey" `
     -ResourceGroupName "rg-dr" `
     -AutomationAccountName "my-automation-account-dr" `
     -Value "actual-secret-value" -Encrypted $true
   ```

2. **Re-create credentials** — The summary lists credential names. Create them in the Azure portal or via PowerShell:
   ```powershell
   New-AzAutomationCredential -Name "SampleServiceAccount" `
     -ResourceGroupName "rg-dr" `
     -AutomationAccountName "my-automation-account-dr" `
     -Value (Get-Credential)
   ```

3. **Re-create certificates and connections** — Import certificates and configure connections manually via the Azure portal.

4. **Validate runbooks** — Test-run key runbooks to confirm they work with the DR environment's resources.

5. **Update managed identity permissions** — If runbooks use the Automation Account's managed identity, ensure the DR account's identity has the required RBAC roles.
