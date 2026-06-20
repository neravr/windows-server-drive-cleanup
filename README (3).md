# windows-server-drive-cleanup

Scheduled PowerShell script for automated disk space reclamation on Windows Server environments. Cleans log files, temp directories, Windows Update cache, IIS logs, and orphaned VM snapshots — then outputs a per-path CSV report and drive space delta.

Built to run unattended via Task Scheduler across enterprise server fleets.

---

## What it cleans

- `C:\Windows\Temp` and user `%TEMP%`
- `C:\Windows\Logs`
- `C:\Windows\SoftwareDistribution\Download` (Windows Update cache)
- `C:\inetpub\logs\LogFiles` (IIS logs)
- Recycle Bin (all drives)
- Orphaned `.vhd` / `.avhd` / `.vhdx` snapshots *(optional, see flags)*

Target paths are fully configurable via `-TargetPaths`.

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-TargetPaths` | `string[]` | Common log/temp dirs | Paths to scan and clean |
| `-RetentionDays` | `int` | `30` | Delete files older than N days |
| `-ReportPath` | `string` | `C:\Logs\DriveCleanup` | Output folder for CSV report and log |
| `-IncludeSnapshots` | `switch` | Off | Also clean orphaned VHD/AVHD snapshots |
| `-WhatIf` | `switch` | Off | Dry run — shows what would be deleted without deleting |

---

## Usage

**Dry run first (always recommended):**
```powershell
.\Invoke-DriveCleanup.ps1 -RetentionDays 30 -WhatIf
```

**Standard cleanup:**
```powershell
.\Invoke-DriveCleanup.ps1 -RetentionDays 30
```

**Aggressive cleanup with snapshot removal:**
```powershell
.\Invoke-DriveCleanup.ps1 -RetentionDays 14 -IncludeSnapshots
```

**Custom paths and report location:**
```powershell
.\Invoke-DriveCleanup.ps1 `
    -TargetPaths "D:\AppLogs", "E:\Temp" `
    -RetentionDays 7 `
    -ReportPath "D:\Reports\Cleanup"
```

---

## Output

The script writes two files to `-ReportPath` on each run:

**`cleanup_report_<timestamp>.csv`** — per-path summary:
```
Path,FilesRemoved,ReclaimedMB,Errors,Timestamp
C:\Windows\Temp,312,1840.5,0,2025-03-01_02-00
C:\Windows\Logs,87,420.2,0,2025-03-01_02-00
C:\inetpub\logs\LogFiles,54,2100.8,1,2025-03-01_02-00
Orphaned Snapshots,3,8192.0,0,2025-03-01_02-00
```

**`cleanup_log_<timestamp>.txt`** — timestamped audit trail with per-file errors, drive space before/after, and totals.

**Console summary** (drive space delta):
```
Drive  BeforeFreeGB  AfterFreeGB  GainGB
-----  ------------  -----------  ------
C      18.42         30.15        11.73
D      44.10         56.80        12.70
```

---

## Task Scheduler setup

1. Open **Task Scheduler** → Create Task
2. **General** tab: Run as `SYSTEM`, check *Run with highest privileges*
3. **Triggers** tab: Weekly, day of your choice, off-hours (e.g. 2:00 AM)
4. **Actions** tab → New:
   - Program: `powershell.exe`
   - Arguments:
     ```
     -ExecutionPolicy Bypass -NonInteractive -File "C:\Scripts\Invoke-DriveCleanup.ps1" -RetentionDays 30
     ```
5. **Settings** tab: Check *Run task as soon as possible after a scheduled start is missed*

---

## Requirements

- PowerShell 5.1 or later
- Run as Administrator (or SYSTEM via Task Scheduler)
- For snapshot cleanup: access to Hyper-V storage paths

---

## Notes

- Always run with `-WhatIf` on a new environment before scheduling
- Snapshot cleanup targets `C:\ClusterStorage` and `C:\Hyper-V` by default — adjust paths to match your environment
- The script uses `$ErrorActionPreference = "Continue"` so a single locked file won't abort the whole run
- Errors are logged per-file and surfaced in the CSV `Errors` column
