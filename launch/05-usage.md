# 05 — Usage

## The scripts

All under `scripts/`. All PowerShell 7. All take `-ConfigPath` pointing at a main-config JSON.

### `Build-AcmeData.ps1` — master orchestrator

The one you usually call. Runs every phase in order.

```powershell
# Full pipeline, first run (AD + share + ACLs + verify, no orphan pass by default)
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json

# Include the destructive orphan pass
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json -RunOrphans

# Skip phases (common)
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json -SkipPhase @('ad','2h')

# Just the AD phase (dry-run-ish)
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json -DryRun
```

| Flag | Effect |
|---|---|
| `-ConfigPath <path>` | **Required.** Path to main-config(.dev).json. |
| `-SkipPhase @('ad','share','2g','2h','verify')` | Skip listed phases. Useful for partial re-runs. |
| `-RunOrphans` | Opt-in: run `Remove-AcmeOrphans.ps1` (2h). Off by default — it mutates live AD. |
| `-DryRun` | Run the `ad` phase only. |

Exit codes: `0` = all phases OK; `1` = a phase threw or share exceeded 0.1 % failure threshold; `2` = verification detected mismatches.

### `Build-AcmeShare.ps1` — the streaming generator

Runs alone if you want just the file-creation step.

```powershell
# Standalone prod run
pwsh -File .\scripts\Build-AcmeShare.ps1 -ConfigPath .\config\main-config.json

# Smoke test: 100k files without editing config
pwsh -File .\scripts\Build-AcmeShare.ps1 -ConfigPath .\config\main-config.json -MaxFiles 100000

# Re-run into an existing folder tree (skip the mkdir pass)
pwsh -File .\scripts\Build-AcmeShare.ps1 -ConfigPath .\config\main-config.json -SkipFolderCreation
```

| Flag | Effect |
|---|---|
| `-ConfigPath` | Required. |
| `-MaxFiles <n>` | Override `scale.totalFiles` without editing config. `0` (default) = use config. |
| `-SkipFolderCreation` | Skip Phase A.5 mkdir loop. |

### `Set-AcmeACLs.ps1`

Reads `manifests/folder-manifest.json` and `ad-manifest.json`. No flags beyond `-ConfigPath`.

### `Remove-AcmeOrphans.ps1`

```powershell
# Preview only
pwsh -File .\scripts\Remove-AcmeOrphans.ps1 -ConfigPath .\config\main-config.json -WhatIf

# Destructive
pwsh -File .\scripts\Remove-AcmeOrphans.ps1 -ConfigPath .\config\main-config.json -Force
```

`-Force` skips the interactive "delete 12 users? (y/N)" prompt. `-WhatIf` lists what would be deleted without touching AD.

### `Test-AcmeData.ps1`

```powershell
pwsh -File .\scripts\Test-AcmeData.ps1 -ConfigPath .\config\main-config.json

# Bigger sample for a more confident distribution readout
pwsh -File .\scripts\Test-AcmeData.ps1 -ConfigPath .\config\main-config.json -SampleSize 5000
```

Reads only folder-manifest + disk. Produces `manifests/logs/verification.json`. Exit `2` if any check shows non-zero mismatch.

### `Initialize-AcmeDisk.ps1`

```powershell
# Auto-detect the RAW data disk
pwsh -File .\scripts\Initialize-AcmeDisk.ps1

# Target a specific disk, destroy existing data
pwsh -File .\scripts\Initialize-AcmeDisk.ps1 -DiskNumber 1 -Force
```

### `Disable-AcmeDefender.ps1`

No parameters. One-shot. Requires Tamper Protection off beforehand.

### `Build-AcmeAD.ps1`

```powershell
# Populate
pwsh -File .\scripts\Build-AcmeAD.ps1 -ConfigPath .\config\main-config.json

# Tear down (removes every AD object the script created)
pwsh -File .\scripts\Build-AcmeAD.ps1 -ConfigPath .\config\main-config.json -Mode Remove
```

## Reading the output

### `manifests/logs/run-summary.json`

Top-level result of the last orchestrator run:

```json
{
  "runStamp": "20260418-204710",
  "configPath": ".../main-config.json",
  "totalElapsedSec": 8179.5,
  "phases": [
    { "id": "share",  "status": "ok", "elapsedSec": 6149.80 },
    { "id": "2g",     "status": "ok", "elapsedSec": 1972.51 },
    { "id": "verify", "status": "ok", "elapsedSec":   46.51 }
  ],
  "success": true
}
```

### `manifests/logs/verification.json`

The "does it look right" report. Key fields:

- `pass` — top-level bool.
- `checks.folderExistence.missing` — should be 0.
- `checks.fileSample.magicMismatch` — magic-byte mismatches in the 500-file sample. Should be 0.
- `checks.fileSample.timestampInconsistent` — files where `btime > mtime` or `mtime > atime` violated. Should be 0.
- `checks.fileSample.ownerNull` — files with no resolvable owner. Should be 0.
- `checks.aclSample.withoutAcl` — folders with no ACEs. Should be 0.
- `checks.aclSample.avgAces` — expect 11–13 on a healthy run.
- `checks.distribution.fileTypePct[<cat>].actual` vs `.target` — within 1 pp of config.
- `checks.distribution.ageBucketsPctSample[<bucket>].actual` vs `.target` — within a few pp on a 500 sample.
- `checks.distribution.terminatedOwnerEstimate` — projected count of files owned by deleted users (the orphaned-SID demo population).

### `manifests/logs/share-summary.json`

```json
{
  "phaseB": {
    "filesCreated": 11351919,
    "bytesLogical": 1569513162585646,
    "failed": 0,
    "elapsedSeconds": 3663.0,
    "filesPerSecond": 3099
  },
  "dup": { "added": 892697, "failed": 0 },
  "grandTotals": { "filesCreated": 12244616, "failPct": 0.0 }
}
```

### `manifests/logs/acl-summary.json`

Shows `messCounters` — how many folders got each mess pattern. Should roughly match the percentages in `config.acl.*`.

## Typical operator flow

1. `Build-AcmeData.ps1 -ConfigPath main-config.json` → watch logs stream.
2. When done, read `verification.json` — `pass: true` is the green light.
3. If any mismatch → read the matching phase log under `manifests/logs/<phase>-<stamp>.log`.
4. Spot-check a few random files manually (see the one-liner in `03-workflow.md` § 7).
5. Point Symphony at `S:\Share`.
