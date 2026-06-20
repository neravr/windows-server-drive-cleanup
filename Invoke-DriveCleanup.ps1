#Requires -Version 5.1
<#
.SYNOPSIS
    Automated disk space reclamation for Windows Server environments.

.DESCRIPTION
    Clears log files, temp files, and orphaned VM snapshots older than a
    configurable retention threshold. Generates a CSV report showing space
    reclaimed per drive. Designed to run as a scheduled task.

.PARAMETER TargetPaths
    Array of paths to clean. Defaults to common log/temp directories.

.PARAMETER RetentionDays
    Files older than this many days will be deleted. Default: 30.

.PARAMETER ReportPath
    Output path for the CSV report. Default: C:\Logs\DriveCleanup.

.PARAMETER WhatIf
    Simulates cleanup without deleting anything. Recommended for first run.

.EXAMPLE
    .\Invoke-DriveCleanup.ps1 -RetentionDays 14 -WhatIf
    .\Invoke-DriveCleanup.ps1 -RetentionDays 30 -ReportPath "D:\Reports\Cleanup"

.NOTES
    Author: Nerav Rangari
    Schedule via Task Scheduler: weekly, SYSTEM account, elevated.
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string[]]$TargetPaths = @(
        "$env:SystemRoot\Temp",
        "$env:SystemRoot\Logs",
        "$env:TEMP",
        "C:\Windows\SoftwareDistribution\Download",
        "C:\inetpub\logs\LogFiles"
    ),

    [ValidateRange(1, 365)]
    [int]$RetentionDays = 30,

    [string]$ReportPath = "C:\Logs\DriveCleanup",

    [switch]$IncludeSnapshots
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ──────────────────────────────────────────────
# SETUP
# ──────────────────────────────────────────────

$Timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm"
$LogFile     = Join-Path $ReportPath "cleanup_log_$Timestamp.txt"
$ReportFile  = Join-Path $ReportPath "cleanup_report_$Timestamp.csv"
$Cutoff      = (Get-Date).AddDays(-$RetentionDays)

if (-not (Test-Path $ReportPath)) {
    New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $Entry | Tee-Object -FilePath $LogFile -Append | Write-Verbose
}

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

# ──────────────────────────────────────────────
# SNAPSHOT BASELINE (before cleanup)
# ──────────────────────────────────────────────

function Get-DriveFreeSpace {
    Get-PSDrive -PSProvider FileSystem |
        Where-Object { $_.Used -ne $null } |
        Select-Object Name,
            @{ N = "FreeGB"; E = { [math]::Round($_.Free / 1GB, 2) } }
}

$Before = Get-DriveFreeSpace

# ──────────────────────────────────────────────
# FILE CLEANUP
# ──────────────────────────────────────────────

Write-Log "Starting cleanup. Retention: $RetentionDays days. Cutoff: $Cutoff"

foreach ($Path in $TargetPaths) {
    if (-not (Test-Path $Path)) {
        Write-Log "Path not found, skipping: $Path" -Level WARN
        continue
    }

    Write-Log "Scanning: $Path"

    $Files = Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $Cutoff }

    $PathBytes  = 0
    $PathCount  = 0
    $PathErrors = 0

    foreach ($File in $Files) {
        $Size = $File.Length

        if ($PSCmdlet.ShouldProcess($File.FullName, "Delete file")) {
            try {
                Remove-Item -Path $File.FullName -Force -ErrorAction Stop
                $PathBytes += $Size
                $PathCount++
            } catch {
                Write-Log "Failed to delete: $($File.FullName) — $_" -Level ERROR
                $PathErrors++
            }
        } else {
            # WhatIf mode: count but don't delete
            $PathBytes += $Size
            $PathCount++
        }
    }

    $MB = [math]::Round($PathBytes / 1MB, 2)
    Write-Log "Path complete: $Path | Files: $PathCount | Reclaimed: ${MB} MB | Errors: $PathErrors"

    $Results.Add([PSCustomObject]@{
        Path          = $Path
        FilesRemoved  = $PathCount
        ReclaimedMB   = $MB
        Errors        = $PathErrors
        Timestamp     = $Timestamp
    })
}

# ──────────────────────────────────────────────
# ORPHANED SNAPSHOT CLEANUP (optional)
# ──────────────────────────────────────────────

if ($IncludeSnapshots) {
    Write-Log "Scanning for orphaned .vhd/.avhd snapshots..."

    $SnapshotExtensions = @("*.vhd", "*.avhd", "*.vhdx", "*.avhdx")
    $SnapshotPaths      = @("C:\ClusterStorage", "C:\Hyper-V")
    $SnapBytes          = 0
    $SnapCount          = 0

    foreach ($SnapPath in $SnapshotPaths) {
        if (-not (Test-Path $SnapPath)) { continue }

        foreach ($Ext in $SnapshotExtensions) {
            $Snapshots = Get-ChildItem -Path $SnapPath -Recurse -Filter $Ext -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $Cutoff }

            foreach ($Snap in $Snapshots) {
                if ($PSCmdlet.ShouldProcess($Snap.FullName, "Delete orphaned snapshot")) {
                    try {
                        $SnapBytes += $Snap.Length
                        Remove-Item -Path $Snap.FullName -Force -ErrorAction Stop
                        $SnapCount++
                    } catch {
                        Write-Log "Snapshot delete failed: $($Snap.FullName) — $_" -Level ERROR
                    }
                }
            }
        }
    }

    $SnapMB = [math]::Round($SnapBytes / 1MB, 2)
    Write-Log "Snapshots: removed $SnapCount files | Reclaimed: ${SnapMB} MB"

    $Results.Add([PSCustomObject]@{
        Path          = "Orphaned Snapshots"
        FilesRemoved  = $SnapCount
        ReclaimedMB   = $SnapMB
        Errors        = 0
        Timestamp     = $Timestamp
    })
}

# ──────────────────────────────────────────────
# RECYCLE BIN
# ──────────────────────────────────────────────

Write-Log "Clearing Recycle Bin..."
try {
    if ($PSCmdlet.ShouldProcess("All drives", "Clear Recycle Bin")) {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Log "Recycle Bin cleared."
    }
} catch {
    Write-Log "Recycle Bin clear failed: $_" -Level WARN
}

# ──────────────────────────────────────────────
# DELTA REPORT
# ──────────────────────────────────────────────

$After = Get-DriveFreeSpace

$Summary = foreach ($Drive in $Before) {
    $AfterDrive = $After | Where-Object { $_.Name -eq $Drive.Name }
    if ($AfterDrive) {
        [PSCustomObject]@{
            Drive        = $Drive.Name
            BeforeFreeGB = $Drive.FreeGB
            AfterFreeGB  = $AfterDrive.FreeGB
            GainGB       = [math]::Round($AfterDrive.FreeGB - $Drive.FreeGB, 2)
        }
    }
}

Write-Log "──── Drive Space Delta ────"
$Summary | ForEach-Object {
    Write-Log "Drive $($_.Drive): Before=$($_.BeforeFreeGB) GB | After=$($_.AfterFreeGB) GB | Gain=$($_.GainGB) GB"
}

$TotalReclaimedMB = ($Results | Measure-Object -Property ReclaimedMB -Sum).Sum
Write-Log "Total reclaimed: $([math]::Round($TotalReclaimedMB, 2)) MB across $($Results.Count) path(s)."

# ──────────────────────────────────────────────
# EXPORT CSV
# ──────────────────────────────────────────────

$Results | Export-Csv -Path $ReportFile -NoTypeInformation -Force
Write-Log "Report saved: $ReportFile"
Write-Log "Log saved:    $LogFile"

# ──────────────────────────────────────────────
# CONSOLE SUMMARY
# ──────────────────────────────────────────────

Write-Host "`nCleanup complete." -ForegroundColor Cyan
$Results | Format-Table -AutoSize
$Summary | Format-Table -AutoSize
