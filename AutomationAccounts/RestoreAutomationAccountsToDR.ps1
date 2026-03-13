<#
.SYNOPSIS
  Restores Azure Automation Account resources from a blob storage backup
  to a DR target Automation Account.

.DESCRIPTION
  Reads all components previously backed up by Backup-AutomationAccountToBlob.ps1
  from blob storage and re-creates them in the target (DR) Automation Account:

  1. Runbooks – downloads content files and definition JSON, imports and publishes.
  2. Schedules – recreates schedule definitions (frequency, interval, start time, expiry, time zone).
  3. Variables – copies name/value/description (encrypted values will be empty placeholders).
  4. Modules – installs custom (non-default) modules from PowerShell Gallery.
  5. Python packages – installs Python 3/2 packages via ARM REST.
  6. Job Schedules – re-links runbooks to schedules with the original parameters.

  Credentials, certificates, and connections backup JSONs are listed at the end
  so the operator can re-create them manually (secrets NOT stored in backup).

.PARAMETER SourceStorageAccount
  Storage account name where the backup blobs are stored.

.PARAMETER SourceContainer
  Container name in the storage account. Default: "config-docs".

.PARAMETER SourceBlobPrefix
  Blob prefix path to the backup. This is the path produced by the backup script,
  typically: <subscriptionName>/<subscriptionId>/<resourceGroup>/Microsoft.Automation/<accountName>

.PARAMETER TargetSubscriptionId
  Subscription hosting the DR Automation Account.

.PARAMETER TargetResourceGroup
  Resource group of the DR Automation Account.

.PARAMETER TargetAutomationAccount
  Name of the DR Automation Account.

.PARAMETER SkipRunbooks
  Skip runbook restore.

.PARAMETER SkipSchedules
  Skip schedule restore.

.PARAMETER SkipVariables
  Skip variable restore.

.PARAMETER SkipModules
  Skip module installation.

.PARAMETER SkipPythonPackages
  Skip Python package installation.

.PARAMETER SkipJobSchedules
  Skip re-linking runbooks to schedules.

.EXAMPLE
  .\RestoreAutomationAccountsToDR.ps1 `
    -SourceStorageAccount  "stagentlab20260105" `
    -SourceContainer       "config-docs" `
    -SourceBlobPrefix      "ME-MngEnvMCAP304533-utkugulen-1/30459864-17d2-4001-ad88-1472f3dd1ba5/rg-agent-lab-01/Microsoft.Automation/automationaccountdr" `
    -TargetSubscriptionId  "30459864-17d2-4001-ad88-1472f3dd1ba5" `
    -TargetResourceGroup   "rg-lab" `
    -TargetAutomationAccount "automationaccountdrbackup"

.NOTES
  Prerequisites:
    - Azure CLI logged in (az login) with Blob Data Reader on the source storage account.
    - Az PowerShell modules: Az.Accounts, Az.Automation
    - Contributor on the target Automation Account.
    - Encrypted variables are stored as empty values; update manually after restore.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]  [string]$SourceStorageAccount,
  [string]$SourceContainer = "config-docs",
  [Parameter(Mandatory=$true)]  [string]$SourceBlobPrefix,
  [Parameter(Mandatory=$true)]  [string]$TargetSubscriptionId,
  [Parameter(Mandatory=$true)]  [string]$TargetResourceGroup,
  [Parameter(Mandatory=$true)]  [string]$TargetAutomationAccount,
  [switch]$SkipRunbooks,
  [switch]$SkipSchedules,
  [switch]$SkipVariables,
  [switch]$SkipModules,
  [switch]$SkipPythonPackages,
  [switch]$SkipJobSchedules
)

$ErrorActionPreference = 'Stop'

#region Helpers

function Invoke-Arm {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$Method  = 'GET',
    [string]$Payload = $null
  )
  $params = @{ Method = $Method; Path = $Path; ErrorAction = 'Stop' }
  if ($Payload) { $params['Payload'] = $Payload }
  $resp = Invoke-AzRestMethod @params
  if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
    if ($resp.Content) { return $resp.Content | ConvertFrom-Json }
    return $null
  }
  if ($resp.StatusCode -ge 400) {
    Write-Warning "ARM $Method $Path returned $($resp.StatusCode): $($resp.Content)"
  }
  return $null
}

function Download-BlobJson {
  param(
    [string]$BlobName,
    [string]$StorageAccount,
    [string]$Container
  )
  $tmpFile = [System.IO.Path]::GetTempFileName()
  try {
    $out = az storage blob download `
        --account-name $StorageAccount --container-name $Container `
        --name $BlobName --file $tmpFile `
        --auth-mode login --no-progress -o none 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    Get-Content $tmpFile -Raw | ConvertFrom-Json
  } finally {
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
  }
}

function Download-BlobToFile {
  param(
    [string]$BlobName,
    [string]$LocalPath,
    [string]$StorageAccount,
    [string]$Container
  )
  $out = az storage blob download `
      --account-name $StorageAccount --container-name $Container `
      --name $BlobName --file $LocalPath `
      --auth-mode login --no-progress -o none 2>&1
  return ($LASTEXITCODE -eq 0)
}

function List-Blobs {
  param(
    [string]$Prefix,
    [string]$StorageAccount,
    [string]$Container
  )
  $raw = az storage blob list `
      --account-name $StorageAccount --container-name $Container `
      --prefix $Prefix --auth-mode login -o json 2>$null | ConvertFrom-Json
  if ($raw) { return @($raw) } else { return @() }
}

#endregion Helpers

# -- Summary counters ----------------------------------------------------------

$script:summary = [ordered]@{
  RunbooksCopied     = 0; RunbooksFailed     = 0
  SchedulesCopied    = 0; SchedulesFailed    = 0; SchedulesSkipped = 0
  VariablesCopied    = 0; VariablesFailed    = 0; VariablesEncrypted = 0
  ModulesInstalled   = 0; ModulesFailed      = 0
  Py3PkgsInstalled   = 0; Py3PkgsFailed      = 0
  Py2PkgsInstalled   = 0; Py2PkgsFailed      = 0
  JobLinksCopied     = 0; JobLinksFailed     = 0
}

# ============================================================
#  Step 0: Validate backup & target
# ============================================================

Write-Host "`n╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  AUTOMATION ACCOUNT RESTORE FROM BLOB BACKUP                     ║" -ForegroundColor Cyan
Write-Host "║  Source : $SourceStorageAccount / $SourceContainer"               -ForegroundColor Cyan
Write-Host "║  Prefix : $SourceBlobPrefix"                                      -ForegroundColor Cyan
Write-Host "║  Target : $TargetAutomationAccount (RG: $TargetResourceGroup)"    -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Read backup metadata from blob
Write-Host "[0/7] Reading backup metadata ..." -ForegroundColor Yellow
$metadata = Download-BlobJson -BlobName "$SourceBlobPrefix/backup-metadata.json" `
    -StorageAccount $SourceStorageAccount -Container $SourceContainer
if (-not $metadata) {
  throw "Could not read backup-metadata.json from $SourceStorageAccount/$SourceContainer/$SourceBlobPrefix. Verify the blob prefix and storage permissions."
}
Write-Host "  Backup source : $($metadata.sourceAutomationAccount) ($($metadata.sourceLocation))" -ForegroundColor Green
Write-Host "  Backup time   : $($metadata.backupTimestamp)" -ForegroundColor Green
Write-Host "  Subscription  : $($metadata.subscriptionName) ($($metadata.subscriptionId))" -ForegroundColor Green

# ============================================================
#  Step 1: Validate target Automation Account
# ============================================================

Write-Host "`n[1/7] Validating target Automation Account..." -ForegroundColor Cyan

# Ensure Az context is set
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
  Write-Host "  No Az session found – running Connect-AzAccount ..." -ForegroundColor Yellow
  Connect-AzAccount -ErrorAction Stop | Out-Null
  $ctx = Get-AzContext
}

# Helper to switch subscription while keeping tenant context (avoids multi-tenant token errors)
$script:currentTenant = $ctx.Tenant.Id
function Set-Sub ([string]$SubId) {
  Set-AzContext -Subscription $SubId -Tenant $script:currentTenant -ErrorAction Stop | Out-Null
}

Set-Sub $TargetSubscriptionId

$api = "api-version=2023-11-01"
$tgtBase = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroup/providers/Microsoft.Automation/automationAccounts/$TargetAutomationAccount"
$targetAA = Invoke-Arm -Path "${tgtBase}?${api}"
if (-not $targetAA) {
  throw "Target Automation Account not found: $TargetAutomationAccount in $TargetResourceGroup ($TargetSubscriptionId)"
}
Write-Host "  Target : $($targetAA.name) ($($targetAA.location))" -ForegroundColor Green

# ============================================================
#  Step 2: Restore runbooks
# ============================================================

if (-not $SkipRunbooks) {
  Write-Host "`n[2/7] Restoring runbooks from backup ..." -ForegroundColor Cyan

  $rbBlobs = List-Blobs -Prefix "$SourceBlobPrefix/runbooks/" `
      -StorageAccount $SourceStorageAccount -Container $SourceContainer

  # Find definition JSON blobs
  $defBlobs = @($rbBlobs | Where-Object { $_.name -like '*-definition.json' })

  if ($defBlobs.Count -eq 0) {
    Write-Host "  No runbook backups found." -ForegroundColor DarkGray
  }
  else {
    Write-Host "  Found $($defBlobs.Count) runbook backup(s)." -ForegroundColor DarkGray

    $tempDir = Join-Path $env:TEMP ("aa-restore-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    Set-Sub $TargetSubscriptionId

    foreach ($defBlob in $defBlobs) {
      $def = Download-BlobJson -BlobName $defBlob.name `
          -StorageAccount $SourceStorageAccount -Container $SourceContainer
      if (-not $def) {
        Write-Warning "  Could not download definition: $($defBlob.name)"
        $script:summary.RunbooksFailed++
        continue
      }

      $rbName = $def.name
      $rbType = $def.runbookType

      # Determine file extension
      $ext = switch ($rbType) {
        'PowerShell'                    { '.ps1' }
        'PowerShell72'                  { '.ps1' }
        'PowerShellWorkflow'            { '.ps1' }
        'Python2'                       { '.py' }
        'Python3'                       { '.py' }
        'GraphicalPowerShell'           { '.graphrunbook' }
        'GraphicalPowerShellWorkflow'   { '.graphrunbook' }
        default                         { '.ps1' }
      }

      # Download content file
      $contentBlobName = "$SourceBlobPrefix/runbooks/$rbName$ext"
      $localFile = Join-Path $tempDir ($rbName + $ext)

      $downloaded = Download-BlobToFile -BlobName $contentBlobName -LocalPath $localFile `
          -StorageAccount $SourceStorageAccount -Container $SourceContainer

      if (-not $downloaded -or -not (Test-Path $localFile)) {
        Write-Warning "  No content file for runbook '$rbName' – skipping."
        $script:summary.RunbooksFailed++
        continue
      }

      try {
        Write-Host "  Importing: $rbName ($rbType)..." -ForegroundColor Yellow
        $importParams = @{
          Path                  = $localFile
          Type                  = $rbType
          Name                  = $rbName
          ResourceGroupName     = $TargetResourceGroup
          AutomationAccountName = $TargetAutomationAccount
          Force                 = $true
        }
        if ($def.description) { $importParams['Description'] = $def.description }

        Import-AzAutomationRunbook @importParams | Out-Null
        Publish-AzAutomationRunbook -Name $rbName `
          -ResourceGroupName $TargetResourceGroup `
          -AutomationAccountName $TargetAutomationAccount | Out-Null

        Write-Host "    ✓ $rbName" -ForegroundColor Green
        $script:summary.RunbooksCopied++
      }
      catch {
        Write-Warning "    Failed to import runbook '$rbName': $($_.Exception.Message)"
        $script:summary.RunbooksFailed++
      }
    }

    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
else {
  Write-Host "`n[2/7] Skipping runbooks (-SkipRunbooks)." -ForegroundColor DarkGray
}

# ============================================================
#  Step 3: Restore schedules
# ============================================================

if (-not $SkipSchedules) {
  Write-Host "`n[3/7] Restoring schedules from backup ..." -ForegroundColor Cyan

  $schBlobs = List-Blobs -Prefix "$SourceBlobPrefix/schedules/" `
      -StorageAccount $SourceStorageAccount -Container $SourceContainer
  $schBlobs = @($schBlobs | Where-Object { $_.name -like '*.json' })

  if ($schBlobs.Count -eq 0) {
    Write-Host "  No schedule backups found." -ForegroundColor DarkGray
  }
  else {
    Write-Host "  Found $($schBlobs.Count) schedule backup(s)." -ForegroundColor DarkGray

    Set-Sub $TargetSubscriptionId

    foreach ($schBlob in $schBlobs) {
      $sch = Download-BlobJson -BlobName $schBlob.name `
          -StorageAccount $SourceStorageAccount -Container $SourceContainer
      if (-not $sch) {
        Write-Warning "  Could not download: $($schBlob.name)"
        $script:summary.SchedulesFailed++
        continue
      }

      # Skip expired one-time schedules
      if ($sch.frequency -eq 'OneTime' -and -not $sch.nextRun) {
        Write-Host "  Skipping expired one-time schedule: $($sch.name)" -ForegroundColor DarkGray
        $script:summary.SchedulesSkipped++
        continue
      }

      try {
        # Ensure start time is in the future
        $startTime = [datetime]$sch.startTime
        $minStart  = (Get-Date).AddMinutes(6)
        if ($startTime -lt $minStart) {
          $startTime = $minStart
          Write-Host "    Start time adjusted (original was in the past)" -ForegroundColor DarkGray
        }

        $schedParams = @{
          Name                  = $sch.name
          ResourceGroupName     = $TargetResourceGroup
          AutomationAccountName = $TargetAutomationAccount
          StartTime             = $startTime
        }
        if ($sch.description)  { $schedParams['Description'] = $sch.description }
        if ($sch.timeZone)     { $schedParams['TimeZone']    = $sch.timeZone }

        # Set expiry time only if it is a real date (not max-value sentinel)
        if ($sch.expiryTime) {
          $expiry = [datetime]$sch.expiryTime
          if ($expiry.Year -lt 9999) {
            $schedParams['ExpiryTime'] = $expiry
          }
        }

        # Map frequency to the correct parameter set
        switch ($sch.frequency) {
          'OneTime' {
            $schedParams['OneTime'] = $true
          }
          'Hour' {
            $schedParams['HourInterval'] = [int]$sch.interval
          }
          'Day' {
            $schedParams['DayInterval'] = [int]$sch.interval
          }
          'Week' {
            $schedParams['WeekInterval'] = [int]$sch.interval
            if ($sch.advancedSchedule -and $sch.advancedSchedule.weekDays) {
              $schedParams['DaysOfWeek'] = @($sch.advancedSchedule.weekDays)
            }
          }
          'Month' {
            $schedParams['MonthInterval'] = [int]$sch.interval
            if ($sch.advancedSchedule -and $sch.advancedSchedule.monthDays) {
              $schedParams['DaysOfMonth'] = @($sch.advancedSchedule.monthDays)
            }
            elseif ($sch.advancedSchedule -and $sch.advancedSchedule.monthlyOccurrences) {
              $occ = $sch.advancedSchedule.monthlyOccurrences[0]
              $schedParams['DayOfWeek'] = $occ.day
              $schedParams['DayOfWeekOccurrence'] = $occ.occurrence
            }
          }
        }

        Write-Host "  Creating: $($sch.name) ($($sch.frequency))..." -ForegroundColor Yellow
        New-AzAutomationSchedule @schedParams | Out-Null
        Write-Host "    ✓ $($sch.name)" -ForegroundColor Green
        $script:summary.SchedulesCopied++
      }
      catch {
        Write-Warning "    Failed to create schedule '$($sch.name)': $($_.Exception.Message)"
        $script:summary.SchedulesFailed++
      }
    }
  }
}
else {
  Write-Host "`n[3/7] Skipping schedules (-SkipSchedules)." -ForegroundColor DarkGray
}

# ============================================================
#  Step 4: Restore variables
# ============================================================

if (-not $SkipVariables) {
  Write-Host "`n[4/7] Restoring variables from backup ..." -ForegroundColor Cyan

  $varBlobs = List-Blobs -Prefix "$SourceBlobPrefix/variables/" `
      -StorageAccount $SourceStorageAccount -Container $SourceContainer
  $varBlobs = @($varBlobs | Where-Object { $_.name -like '*.json' })

  if ($varBlobs.Count -eq 0) {
    Write-Host "  No variable backups found." -ForegroundColor DarkGray
  }
  else {
    Write-Host "  Found $($varBlobs.Count) variable backup(s)." -ForegroundColor DarkGray

    Set-Sub $TargetSubscriptionId

    foreach ($varBlob in $varBlobs) {
      $var = Download-BlobJson -BlobName $varBlob.name `
          -StorageAccount $SourceStorageAccount -Container $SourceContainer
      if (-not $var) {
        Write-Warning "  Could not download: $($varBlob.name)"
        $script:summary.VariablesFailed++
        continue
      }

      try {
        $value     = $var.value
        $encrypted = [bool]$var.isEncrypted

        if ($encrypted) {
          $value = ""
          $script:summary.VariablesEncrypted++
          Write-Host "  Creating (encrypted placeholder): $($var.name)" -ForegroundColor Yellow
        }
        else {
          if ($null -eq $value) { $value = "" }
          Write-Host "  Creating: $($var.name)" -ForegroundColor Yellow
        }

        $varParams = @{
          Name                  = $var.name
          ResourceGroupName     = $TargetResourceGroup
          AutomationAccountName = $TargetAutomationAccount
          Value                 = $value
          Encrypted             = $encrypted
        }
        if ($var.description) { $varParams['Description'] = $var.description }

        try {
          New-AzAutomationVariable @varParams | Out-Null
        }
        catch {
          Set-AzAutomationVariable -Name $var.name `
            -ResourceGroupName $TargetResourceGroup `
            -AutomationAccountName $TargetAutomationAccount `
            -Value $value -Encrypted $encrypted | Out-Null
        }

        Write-Host "    ✓ $($var.name)" -ForegroundColor Green
        $script:summary.VariablesCopied++
      }
      catch {
        Write-Warning "    Failed to restore variable '$($var.name)': $($_.Exception.Message)"
        $script:summary.VariablesFailed++
      }
    }
  }
}
else {
  Write-Host "`n[4/7] Skipping variables (-SkipVariables)." -ForegroundColor DarkGray
}

# ============================================================
#  Step 5: Install custom modules
# ============================================================

if (-not $SkipModules) {
  Write-Host "`n[5/7] Installing custom modules from backup ..." -ForegroundColor Cyan

  $modBlobs = List-Blobs -Prefix "$SourceBlobPrefix/modules/" `
      -StorageAccount $SourceStorageAccount -Container $SourceContainer
  $modBlobs = @($modBlobs | Where-Object { $_.name -like '*.json' })

  if ($modBlobs.Count -eq 0) {
    Write-Host "  No custom module backups found." -ForegroundColor DarkGray
  }
  else {
    Write-Host "  Found $($modBlobs.Count) module backup(s)." -ForegroundColor DarkGray

    Set-Sub $TargetSubscriptionId

    foreach ($modBlob in $modBlobs) {
      $mod = Download-BlobJson -BlobName $modBlob.name `
          -StorageAccount $SourceStorageAccount -Container $SourceContainer
      if (-not $mod) {
        Write-Warning "  Could not download: $($modBlob.name)"
        $script:summary.ModulesFailed++
        continue
      }

      $modName    = $mod.name
      $modVersion = $mod.version
      $contentUri = "https://www.powershellgallery.com/api/v2/package/$modName/$modVersion"

      try {
        Write-Host "  Installing: $modName ($modVersion)..." -ForegroundColor Yellow
        New-AzAutomationModule -Name $modName `
          -ResourceGroupName $TargetResourceGroup `
          -AutomationAccountName $TargetAutomationAccount `
          -ContentLinkUri $contentUri | Out-Null

        Write-Host "    ✓ $modName ($modVersion)" -ForegroundColor Green
        $script:summary.ModulesInstalled++
      }
      catch {
        Write-Warning "    Failed to install module '$modName': $($_.Exception.Message)"
        Write-Warning "    If the module is not from PSGallery, install it manually on the target."
        $script:summary.ModulesFailed++
      }
    }
  }
}
else {
  Write-Host "`n[5/7] Skipping modules (-SkipModules)." -ForegroundColor DarkGray
}

# ============================================================
#  Step 6: Install Python packages
# ============================================================

if (-not $SkipPythonPackages) {
  Write-Host "`n[6/7] Installing Python packages from backup ..." -ForegroundColor Cyan

  Set-Sub $TargetSubscriptionId

  # Python 3 packages
  $py3Blobs = List-Blobs -Prefix "$SourceBlobPrefix/python3packages/" `
      -StorageAccount $SourceStorageAccount -Container $SourceContainer
  $py3Blobs = @($py3Blobs | Where-Object { $_.name -like '*.json' })

  if ($py3Blobs.Count -gt 0) {
    Write-Host "  Found $($py3Blobs.Count) Python 3 package backup(s)." -ForegroundColor DarkGray

    foreach ($pkgBlob in $py3Blobs) {
      $pkg = Download-BlobJson -BlobName $pkgBlob.name `
          -StorageAccount $SourceStorageAccount -Container $SourceContainer
      if (-not $pkg) {
        $script:summary.Py3PkgsFailed++
        continue
      }

      $pkgName    = $pkg.name
      $pkgVersion = $pkg.version
      $contentUri = if ($pkg.contentLink -and $pkg.contentLink.uri) {
        $pkg.contentLink.uri
      } else {
        "https://pypi.org/packages/source/$($pkgName[0])/$pkgName/$pkgName-$pkgVersion.tar.gz"
      }

      try {
        Write-Host "  Installing Python 3: $pkgName ($pkgVersion)..." -ForegroundColor Yellow
        $body = @{
          properties = @{
            contentLink = @{ uri = $contentUri }
          }
        } | ConvertTo-Json -Depth 5

        Invoke-Arm -Path "${tgtBase}/python3Packages/${pkgName}?${api}" -Method PUT -Payload $body | Out-Null
        Write-Host "    ✓ $pkgName ($pkgVersion)" -ForegroundColor Green
        $script:summary.Py3PkgsInstalled++
      }
      catch {
        Write-Warning "    Failed to install Python 3 package '$pkgName': $($_.Exception.Message)"
        $script:summary.Py3PkgsFailed++
      }
    }
  }
  else {
    Write-Host "  No Python 3 package backups found." -ForegroundColor DarkGray
  }

  # Python 2 packages
  $py2Blobs = List-Blobs -Prefix "$SourceBlobPrefix/python2packages/" `
      -StorageAccount $SourceStorageAccount -Container $SourceContainer
  $py2Blobs = @($py2Blobs | Where-Object { $_.name -like '*.json' })

  if ($py2Blobs.Count -gt 0) {
    Write-Host "  Found $($py2Blobs.Count) Python 2 package backup(s)." -ForegroundColor DarkGray

    foreach ($pkgBlob in $py2Blobs) {
      $pkg = Download-BlobJson -BlobName $pkgBlob.name `
          -StorageAccount $SourceStorageAccount -Container $SourceContainer
      if (-not $pkg) {
        $script:summary.Py2PkgsFailed++
        continue
      }

      $pkgName    = $pkg.name
      $pkgVersion = $pkg.version
      $contentUri = if ($pkg.contentLink -and $pkg.contentLink.uri) {
        $pkg.contentLink.uri
      } else {
        "https://pypi.org/packages/source/$($pkgName[0])/$pkgName/$pkgName-$pkgVersion.tar.gz"
      }

      try {
        Write-Host "  Installing Python 2: $pkgName ($pkgVersion)..." -ForegroundColor Yellow
        $body = @{
          properties = @{
            contentLink = @{ uri = $contentUri }
          }
        } | ConvertTo-Json -Depth 5

        Invoke-Arm -Path "${tgtBase}/python2Packages/${pkgName}?${api}" -Method PUT -Payload $body | Out-Null
        Write-Host "    ✓ $pkgName ($pkgVersion)" -ForegroundColor Green
        $script:summary.Py2PkgsInstalled++
      }
      catch {
        Write-Warning "    Failed to install Python 2 package '$pkgName': $($_.Exception.Message)"
        $script:summary.Py2PkgsFailed++
      }
    }
  }
  else {
    Write-Host "  No Python 2 package backups found." -ForegroundColor DarkGray
  }
}
else {
  Write-Host "`n[6/7] Skipping Python packages (-SkipPythonPackages)." -ForegroundColor DarkGray
}

# ============================================================
#  Step 7: Link job schedules
# ============================================================

if (-not $SkipJobSchedules) {
  Write-Host "`n[7/7] Linking job schedules from backup ..." -ForegroundColor Cyan

  $jsBlobs = List-Blobs -Prefix "$SourceBlobPrefix/jobschedules/" `
      -StorageAccount $SourceStorageAccount -Container $SourceContainer
  $jsBlobs = @($jsBlobs | Where-Object { $_.name -like '*.json' })

  if ($jsBlobs.Count -eq 0) {
    Write-Host "  No job schedule backups found." -ForegroundColor DarkGray
  }
  else {
    Write-Host "  Found $($jsBlobs.Count) job schedule backup(s)." -ForegroundColor DarkGray

    Set-Sub $TargetSubscriptionId

    foreach ($jsBlob in $jsBlobs) {
      $js = Download-BlobJson -BlobName $jsBlob.name `
          -StorageAccount $SourceStorageAccount -Container $SourceContainer
      if (-not $js) {
        $script:summary.JobLinksFailed++
        continue
      }

      try {
        $regParams = @{
          RunbookName           = $js.runbookName
          ScheduleName          = $js.scheduleName
          ResourceGroupName     = $TargetResourceGroup
          AutomationAccountName = $TargetAutomationAccount
        }
        if ($js.parameters -and ($js.parameters | Get-Member -MemberType NoteProperty).Count -gt 0) {
          $paramHash = @{}
          $js.parameters.PSObject.Properties | ForEach-Object { $paramHash[$_.Name] = $_.Value }
          $regParams['Parameters'] = $paramHash
        }

        Write-Host "  Linking: $($js.runbookName) -> $($js.scheduleName)..." -ForegroundColor Yellow
        Register-AzAutomationScheduledRunbook @regParams | Out-Null
        Write-Host "    ✓ $($js.runbookName) -> $($js.scheduleName)" -ForegroundColor Green
        $script:summary.JobLinksCopied++
      }
      catch {
        Write-Warning "    Failed to link '$($js.runbookName)' -> '$($js.scheduleName)': $($_.Exception.Message)"
        $script:summary.JobLinksFailed++
      }
    }
  }
}
else {
  Write-Host "`n[7/7] Skipping job schedules (-SkipJobSchedules)." -ForegroundColor DarkGray
}

# ============================================================
#  Summary
# ============================================================

# Check for credentials/certificates/connections in backup that need manual setup
$credBlobs = List-Blobs -Prefix "$SourceBlobPrefix/credentials/" `
    -StorageAccount $SourceStorageAccount -Container $SourceContainer
$certBlobs = List-Blobs -Prefix "$SourceBlobPrefix/certificates/" `
    -StorageAccount $SourceStorageAccount -Container $SourceContainer
$connBlobs = List-Blobs -Prefix "$SourceBlobPrefix/connections/" `
    -StorageAccount $SourceStorageAccount -Container $SourceContainer

Write-Host "`n=============================="              -ForegroundColor Cyan
Write-Host "  DR Restore Summary"                          -ForegroundColor Cyan
Write-Host "=============================="                -ForegroundColor Cyan
Write-Host "  Backup   : $($metadata.sourceAutomationAccount) ($($metadata.sourceLocation)) @ $($metadata.backupTimestamp)" -ForegroundColor DarkCyan
Write-Host "  Target   : $($targetAA.name) ($($targetAA.location))" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Runbooks   : $($script:summary.RunbooksCopied) copied, $($script:summary.RunbooksFailed) failed" `
  -ForegroundColor $(if ($script:summary.RunbooksFailed -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Schedules  : $($script:summary.SchedulesCopied) copied, $($script:summary.SchedulesFailed) failed, $($script:summary.SchedulesSkipped) skipped" `
  -ForegroundColor $(if ($script:summary.SchedulesFailed -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Variables  : $($script:summary.VariablesCopied) copied, $($script:summary.VariablesFailed) failed" `
  -ForegroundColor $(if ($script:summary.VariablesFailed -gt 0) { 'Yellow' } else { 'Green' })
if ($script:summary.VariablesEncrypted -gt 0) {
  Write-Host "               ($($script:summary.VariablesEncrypted) encrypted – placeholder values, update manually)" -ForegroundColor Yellow
}
Write-Host "  Modules    : $($script:summary.ModulesInstalled) installed, $($script:summary.ModulesFailed) failed" `
  -ForegroundColor $(if ($script:summary.ModulesFailed -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Py3 Pkgs   : $($script:summary.Py3PkgsInstalled) installed, $($script:summary.Py3PkgsFailed) failed" `
  -ForegroundColor $(if ($script:summary.Py3PkgsFailed -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Py2 Pkgs   : $($script:summary.Py2PkgsInstalled) installed, $($script:summary.Py2PkgsFailed) failed" `
  -ForegroundColor $(if ($script:summary.Py2PkgsFailed -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Job Links  : $($script:summary.JobLinksCopied) linked, $($script:summary.JobLinksFailed) failed" `
  -ForegroundColor $(if ($script:summary.JobLinksFailed -gt 0) { 'Yellow' } else { 'Green' })

# Warn about resources that require manual setup
$credBlobs = @($credBlobs | Where-Object { $_.name -like '*.json' })
$certBlobs = @($certBlobs | Where-Object { $_.name -like '*.json' })
$connBlobs = @($connBlobs | Where-Object { $_.name -like '*.json' })
if ($credBlobs.Count -gt 0 -or $certBlobs.Count -gt 0 -or $connBlobs.Count -gt 0) {
  Write-Host "`n  Manual setup required (secrets not in backup):" -ForegroundColor Yellow
  if ($credBlobs.Count -gt 0) {
    Write-Host "    Credentials ($($credBlobs.Count)):" -ForegroundColor Yellow
    foreach ($b in $credBlobs) {
      $n = [System.IO.Path]::GetFileNameWithoutExtension($b.name)
      Write-Host "      - $n" -ForegroundColor DarkGray
    }
  }
  if ($certBlobs.Count -gt 0) {
    Write-Host "    Certificates ($($certBlobs.Count)):" -ForegroundColor Yellow
    foreach ($b in $certBlobs) {
      $n = [System.IO.Path]::GetFileNameWithoutExtension($b.name)
      Write-Host "      - $n" -ForegroundColor DarkGray
    }
  }
  if ($connBlobs.Count -gt 0) {
    Write-Host "    Connections ($($connBlobs.Count)):" -ForegroundColor Yellow
    foreach ($b in $connBlobs) {
      $n = [System.IO.Path]::GetFileNameWithoutExtension($b.name)
      Write-Host "      - $n" -ForegroundColor DarkGray
    }
  }
}

Write-Host "==============================" -ForegroundColor Cyan
Write-Host "  Done." -ForegroundColor Green
