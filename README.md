# Azure App DR Automation

Disaster recovery (DR) backup and restore scripts for Azure services. Each folder contains PowerShell scripts and a detailed guide for a specific service.

---

## Service Coverage

| Folder | Service | Scripts | Guide |
|--------|---------|---------|-------|
| **AISearch/** | Azure AI Search | `backup-aisearch-to-blob.ps1`, `restore-aisearch-from-blob.ps1` | [DR-Guide.md](AISearch/DR-Guide.md) |
| **APIM/** | Azure API Management | `extract-apim-to-storage.ps1`, `publish-apim-from-storage.ps1` | — |
| **AutomationAccounts/** | Azure Automation Accounts | `Backup-AutomationAccountToBlob.ps1`, `RestoreAutomationAccountsToDR.ps1` | [AutomationAccounts-Backup-Restore-Guide.md](AutomationAccounts/AutomationAccounts-Backup-Restore-Guide.md) |
| **FunctionApps/** | Azure Function Apps | `Backup-FunctionsToDR.ps1`, `Restore-FunctionsFromDR.ps1`, `Get-FunctionAppContent.ps1`, `Restore-FunctionAppContent.ps1` | [FunctionApps-Backup-Restore-Guide.md](FunctionApps/FunctionApps-Backup-Restore-Guide.md) |
| **LogicApps/** | Azure Logic Apps | `Backup-LogicAppsToDR.ps1`, `Restore-LogicAppFromDR.ps1` | [LogicApps-Backup-Restore-Guide.md](LogicApps/LogicApps-Backup-Restore-Guide.md) |
| **WebApps/** | Azure Web Apps | `Get-WebAppContent.ps1`, `Restore-WebAppContent.ps1` | [WebApps-Backup-Restore-Guide.md](WebApps/WebApps-Backup-Restore-Guide.md) |

---

## Common Pattern

All backup scripts follow the same approach:

1. **Export** service components via Azure ARM REST API or Azure CLI
2. **Upload** JSON definitions and content files to Azure Blob Storage using `--auth-mode login` (Microsoft Entra ID)
3. **Organize** blobs under a consistent hierarchy: `<subscriptionName>/<subscriptionId>/<resourceGroup>/<provider>/<resourceName>/`

All restore scripts:

1. **Download** backup artifacts from blob storage
2. **Re-create** resources in the target subscription/region using Azure CLI, Az PowerShell, or ARM REST
3. **Report** a summary of restored, failed, and skipped items
4. **List** any secrets that require manual re-entry (credentials, certificates, encrypted values)

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Azure CLI** | Installed and logged in (`az login`) |
| **Az PowerShell** | Modules: `Az.Accounts`, plus service-specific modules (see individual guides) |
| **RBAC** | `Reader` on source resources, `Storage Blob Data Contributor` on backup storage, `Contributor` on target resources |

---

## Quick Start

```powershell
# 1. Log in
az login
Connect-AzAccount

# 2. Run a backup (example: Automation Accounts)
cd AutomationAccounts
.\Backup-AutomationAccountToBlob.ps1 `
  -SourceAutomationAccount "my-account" `
  -SourceResourceGroup     "rg-prod" `
  -TargetStorageAccount    "stdrbackup" `
  -TargetContainer         "config-docs"

# 3. Restore to DR region
.\RestoreAutomationAccountsToDR.ps1 `
  -SourceStorageAccount    "stdrbackup" `
  -SourceContainer         "config-docs" `
  -SourceBlobPrefix        "<subName>/<subId>/rg-prod/Microsoft.Automation/my-account" `
  -TargetSubscriptionId    "target-sub-id" `
  -TargetResourceGroup     "rg-dr" `
  -TargetAutomationAccount "my-account-dr"
```

See each folder's guide for service-specific parameters and workflows.
