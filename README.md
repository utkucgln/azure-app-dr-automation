# Azure App DR Automation

A disaster recovery (DR) automation toolkit for Azure services. It provides PowerShell scripts to **back up** critical Azure resources to Azure Blob Storage and **restore** them to a different subscription or region during a DR failover.

---

## Modules

| Module | Description |
|--------|-------------|
| [**AISearch**](AISearch/) | Backs up Azure AI Search components (indexes, documents, data sources, skillsets, indexers, synonym maps) to blob storage via the REST API. Restores them on a target search service, remapping data source connection strings using a configurable mapping file. |
| [**APIM**](APIM/) | Extracts all API Management artifacts using the [ApiOps](https://github.com/Azure/apiops) extractor tool and uploads them to blob storage. A companion script restores them to a target APIM instance. |
| [**AutomationAccounts**](AutomationAccounts/) | Backs up Azure Automation Account components (runbooks, schedules, variables, modules, Python packages, job schedules, credentials/certificates/connections metadata) to blob storage via ARM REST API. Restores them to a target Automation Account using Az PowerShell. |
| [**FunctionApps**](FunctionApps/) | Full-subscription DR backup and restore of Azure Function Apps — exports code ZIPs, configuration, ARM templates, keys, and RBAC. Also includes single-app backup/restore utilities. |
| [**LogicApps**](LogicApps/) | Backs up all Logic Apps (Consumption and Standard) in a subscription — workflow definitions, parameters, API connections, managed identity config, run history, and integration account references. Restores via ARM REST API. |
| [**WebApps**](WebApps/) | Single-app backup and restore of Azure Web Apps — site content (VFS / Kudu ZIP), app settings, connection strings, site config, and deployment slots. |

## Key Characteristics

- **Authentication** — Azure CLI (`az login`) and Az PowerShell modules; OAuth-based blob access (Storage Blob Data Contributor role).
- **Storage** — Backups stored in Azure Blob Storage with hierarchical paths (`<subscriptionId>/<appName>/<timestamp>.<ext>`).
- **Cross-region / cross-subscription** — Full-DR scripts support backing up from one subscription and restoring to a different subscription or region.
- **Reporting** — Backup scripts generate CSV summary reports uploaded alongside the artifacts.
- **Idempotent** — Timestamped artifacts allow multiple backup snapshots; restore scripts create or update resources.
- **Schedulable** — Designed to run on a schedule (Azure Automation, Azure DevOps Pipelines, cron) for ongoing DR sync, with restore kept ready for on-demand failover.

## Getting Started

1. **Prerequisites** — Install [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) and the [Az PowerShell module](https://learn.microsoft.com/powershell/azure/install-azure-powershell).
2. **Authenticate** — Run `az login` and `Connect-AzAccount` to sign in with an identity that has the required permissions.
3. **Configure storage** — Provision a Blob Storage account and container for DR artifacts. Assign the **Storage Blob Data Contributor** role to the identity running the scripts.
4. **Run backups** — Execute the backup script for the desired module, supplying subscription, resource group, and storage parameters. See the per-module guide (`DR-Guide.md` / `*-Backup-Restore-Guide.md`) for detailed usage.
5. **Restore** — During a failover, run the corresponding restore script against the target subscription/region.

## Repository Structure

```
├── AISearch/              # AI Search backup & restore
├── APIM/                  # API Management backup & restore
├── AutomationAccounts/    # Automation Accounts backup & restore
├── FunctionApps/          # Function Apps backup & restore
├── LogicApps/             # Logic Apps backup & restore
├── WebApps/               # Web Apps backup & restore
└── docs/                  # Additional documentation
```

---

## Disclaimer

The guidance, scripts, and configuration examples provided in this repository are offered strictly as proof‑of‑concept (POC) materials and are intended for testing, evaluation, and demonstration purposes only.

This content is provided "as is", without any representations or warranties of any kind, express or implied, including but not limited to accuracy, reliability, security, performance, or suitability for production use.

Users are solely responsible for:

- Reviewing, validating, and adapting the scripts and configurations to meet their specific technical, security, and compliance requirements
- Implementing appropriate security hardening, access controls, and governance policies
- Thoroughly testing the solution in non‑production environments (e.g., development and staging)
- Ensuring alignment with their organization's approved deployment, operational, and change‑management practices

**Use of this content in a production environment without proper validation, testing, and organizational approval is undertaken entirely at the user's own risk.**
