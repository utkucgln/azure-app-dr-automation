# Azure AI Search – Disaster Recovery: Backup & Restore Guide

## Overview

Azure AI Search does not offer native backup/restore capability. This guide provides a scripted DR approach that:

1. **Backs up** all AI Search components (indexes, documents, data sources, skillsets, indexers, synonym maps) to an Azure Blob Storage account
2. **Restores** them to a target AI Search service in any region, remapping data source connection strings to point to the DR-region data stores

### Backup Storage Hierarchy

Backups are organized in blob storage using the following path structure:

```
<subscription name>/
  <subscription id>/
    <resource group>/
      Microsoft.Search/
        <search service name>/
          backup-metadata.json
          indexes/
            <index-name>-definition.json
            <index-name>-documents.json
          datasources/
            <datasource-name>.json
          skillsets/
            <skillset-name>.json
          indexers/
            <indexer-name>.json
          synonymmaps/
            <synonymmap-name>.json
```

---

## Pre-requisites

| Requirement | Details |
|---|---|
| **Azure CLI** | Installed and logged in (`az login`) |
| **Source AI Search** | Running service with admin key access |
| **Backup Storage Account** | Blob container created; user has **Storage Blob Data Contributor** role |
| **Target AI Search** (restore only) | Deployed in DR region with admin key access |
| **Target Data Sources** (restore only) | Storage accounts / databases replicated to DR region |

---

## Part 1: Backup

### Command

```powershell
.\backup-aisearch-to-blob.ps1 `
    -SourceServiceName  <source-search-service-name> `
    -SourceResourceGroup <source-resource-group> `
    -BackupStorageAccount <backup-storage-account-name> `
    -BackupContainer <backup-container-name>
```

### Example

```powershell
.\backup-aisearch-to-blob.ps1 `
    -SourceServiceName  aisearchuaen `
    -SourceResourceGroup uaenorthrg `
    -BackupStorageAccount stgswissnorth `
    -BackupContainer backup
```

### Optional Parameters

| Parameter | Default | Description |
|---|---|---|
| `-SkipDocuments` | `$false` | Skip exporting documents (export schema only) |
| `-ApiVersion` | `2024-07-01` | Azure AI Search REST API version |
| `-DocumentBatchSize` | `1000` | Number of documents per page during export |

### What Gets Backed Up

| Component | Description |
|---|---|
| **Index Definitions** | Full schema including fields, analyzers, scoring profiles |
| **Documents** | All documents from each index (paginated) |
| **Data Sources** | Connection type, connection string, container references |
| **Skillsets** | AI enrichment pipeline definitions |
| **Indexers** | Data ingestion pipeline definitions |
| **Synonym Maps** | Synonym mapping definitions |

---

## Part 2: Restore

### Step 1 – Prepare the Data Source Config File

Create a `datasource-config.json` file that maps each data source name to its **DR-region connection string**:

```json
{
    "blob-datasource": "DefaultEndpointsProtocol=https;AccountName=<dr-storage-account>;AccountKey=<key>;EndpointSuffix=core.windows.net",
    "sql-datasource": "Server=tcp:<dr-sql-server>.database.windows.net,1433;Database=<db>;User ID=<user>;Password=<password>;Encrypt=True;",
    "cosmos-datasource": "AccountEndpoint=https://<dr-cosmos>.documents.azure.com;AccountKey=<key>;Database=<db>;"
}
```

> **Note**: Only include data sources that exist in your AI Search service. The data source **names must match exactly** as they appear in the source service.

### Step 2 – Run the Restore

```powershell
.\restore-aisearch-from-blob.ps1 `
    -TargetServiceName  <target-search-service-name> `
    -TargetResourceGroup <target-resource-group> `
    -BackupStorageAccount <backup-storage-account-name> `
    -BackupContainer <backup-container-name> `
    -SourceServiceName <source-search-service-name> `
    -SourceResourceGroup <source-resource-group> `
    -DataSourceConfigFile ".\datasource-config.json"
```

### Example

```powershell
.\restore-aisearch-from-blob.ps1 `
    -TargetServiceName  aisearchswissnorth `
    -TargetResourceGroup swissnorthrg `
    -BackupStorageAccount stgswissnorth `
    -BackupContainer backup `
    -SourceServiceName aisearchuaen `
    -SourceResourceGroup uaenorthrg `
    -DataSourceConfigFile ".\datasource-config.json"
```

### Optional Parameters

| Parameter | Default | Description |
|---|---|---|
| `-DataSourceConnectionStrings` | `@{}` | Inline hashtable alternative to config file |
| `-DataSourceConfigFile` | (none) | Path to JSON file with connection string mappings |
| `-RunIndexersAfterRestore` | `$false` | Automatically trigger indexers after creation |
| `-SkipDocuments` | `$false` | Skip document upload (use when indexers will repopulate) |
| `-SkipDataSources` | `$false` | Skip data source creation (configure manually) |
| `-SkipSkillsets` | `$false` | Skip skillset creation |
| `-SkipIndexers` | `$false` | Skip indexer creation |
| `-BlobPrefix` | (auto) | Override the blob prefix path directly |
| `-ApiVersion` | `2024-07-01` | Azure AI Search REST API version |
| `-DocumentBatchSize` | `1000` | Documents per batch during upload |

---

## Restore Order

The restore script creates components in dependency order:

```
1. Synonym Maps     (referenced by indexes)
2. Indexes          (required by indexers)
   └─ Documents     (pushed into indexes)
3. Data Sources     (connection strings remapped)
4. Skillsets        (referenced by indexers)
5. Indexers         (depends on all above)
```

---

## DR Workflow Summary

### Initial Setup (One-Time)

1. Deploy a target AI Search service in the DR region (same SKU as source)
2. Replicate underlying data sources (storage accounts, databases) to the DR region
3. Create a `datasource-config.json` with DR-region connection strings
4. Ensure the backup storage account and container exist

### Ongoing DR Sync

```
┌─────────────────┐     Backup Script      ┌──────────────────┐
│  Source          │ ─────────────────────►  │  Blob Storage    │
│  AI Search      │  (indexes, docs,        │  (stgswissnorth/ │
│  (aisearchuaen) │   datasources,          │   backup)        │
│                 │   skillsets, etc.)       │                  │
└─────────────────┘                         └────────┬─────────┘
                                                     │
                                               Restore Script
                                            (remap conn strings)
                                                     │
                                                     ▼
                                            ┌──────────────────┐
                                            │  Target          │
                                            │  AI Search       │
                                            │  (DR region)     │
                                            └──────────────────┘
```

### Scheduling (Recommended)

- Run the **backup script** on a schedule (e.g., daily via Azure Automation, Azure DevOps pipeline, or cron job)
- Keep the **restore script** and `datasource-config.json` ready for on-demand DR failover
- Test the restore periodically to validate the DR process

---

## Important Notes

- **Index Overwrite**: The restore script deletes and recreates indexes on the target. Any existing data in identically-named indexes will be replaced.
- **Connection Strings**: Always use the `-DataSourceConfigFile` parameter to remap data sources to DR-region endpoints. Without it, the original (source) connection strings are used and a warning is shown.
- **Skillset Dependencies**: If skillsets reference Azure AI Services keys or custom skill endpoints, ensure those are available in the DR region.
- **Large Indexes**: For indexes with millions of documents, consider using `-SkipDocuments` and letting indexers rebuild from replicated data sources instead.
- **API Keys**: The scripts retrieve admin keys via Azure CLI. Ensure the executing identity has `Search Service Contributor` or `Contributor` role on both source and target AI Search services.
