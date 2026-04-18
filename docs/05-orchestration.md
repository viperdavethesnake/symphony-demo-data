# 05 — Orchestration

How the pieces fit together at runtime. What scripts exist, what they produce, what depends on what.

## Script inventory

All PowerShell 7+. All live in `scripts/`. All take `-ConfigPath` pointing to `config/main-config.json`.

| Script | Phase | Depends on | Produces |
|---|---|---|---|
| `Build-AcmeAD.ps1` | AD setup | config | `manifests/ad-manifest.json` |
| `Plan-AcmeData.ps1` | 2a + 2b | config, ad-manifest, filetypes, folder-templates, token-pool | `manifests/folder-manifest.json`, `manifests/file-manifest.jsonl` |
| `Build-AcmeFolders.ps1` | 2c | folder-manifest | folders on disk under `S:\Share` |
| `Build-AcmeFiles.ps1` | 2d | file-manifest | files on disk (empty-at-planned-size) |
| `Set-AcmeTimestamps.ps1` | 2e | file-manifest | files with correct btime/mtime/atime |
| `Set-AcmeOwners.ps1` | 2f | file-manifest, ad-manifest | files with owner SIDs |
| `Set-AcmeACLs.ps1` | 2g | folder-manifest, ad-manifest | folders (and ~0.5% files) with ACLs |
| `Remove-AcmeOrphans.ps1` | 2h | ad-manifest | terminated users deleted from AD, leaving orphaned SIDs on disk |
| `Test-AcmeData.ps1` | Verification | all manifests | `manifests/logs/verification.json` |
| `Build-AcmeData.ps1` | **Master** | all of the above | runs all phases in order |

## Master orchestration script

`Build-AcmeData.ps1` is the entry point humans call. It:
1. Reads `config/main-config.json`
2. Validates all sub-configs are present (`filetypes.json`, `folder-templates.json`, `token-pool.json`)
3. Checks `manifests/ad-manifest.json` exists (runs `Build-AcmeAD.ps1` if missing)
4. Runs each phase in order
5. Times each phase, writes to `manifests/logs/run-summary.json`
6. Stops on any phase failure (honors `$ErrorActionPreference = 'Stop'`)
7. Supports `-SkipPhase` parameter for resuming partial runs (`-SkipPhase @('2a','2b','2c','2d')` to skip to timestamps)
8. Supports `-DryRun` for the planning phases only (produces manifests without touching disk)

Rough skeleton (not a spec, just shape — Claude Code designs the actual flow):

```powershell
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string[]]$SkipPhase = @(),
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

$phases = @(
    @{ id='ad';   script='Build-AcmeAD.ps1';       skipIf={ Test-Path manifests/ad-manifest.json } }
    @{ id='plan'; script='Plan-AcmeData.ps1' }
    @{ id='2c';   script='Build-AcmeFolders.ps1' }
    @{ id='2d';   script='Build-AcmeFiles.ps1' }
    @{ id='2e';   script='Set-AcmeTimestamps.ps1' }
    @{ id='2f';   script='Set-AcmeOwners.ps1' }
    @{ id='2g';   script='Set-AcmeACLs.ps1' }
    @{ id='2h';   script='Remove-AcmeOrphans.ps1' }
    @{ id='verify'; script='Test-AcmeData.ps1' }
)
# iterate, log, write run-summary.json
```

## Dependency graph

```
config/main-config.json
        │
        ├─► Build-AcmeAD.ps1 ──► ad-manifest.json
        │                             │
        │   filetypes.json            │
        │   folder-templates.json     │
        │   token-pool.json           │
        │         │                   │
        │         ▼                   ▼
        └──► Plan-AcmeData.ps1 ──► folder-manifest.json
                                     file-manifest.jsonl
                                       │
                                       ▼
                               Build-AcmeFolders.ps1
                                       │
                                       ▼
                               Build-AcmeFiles.ps1  (parallel)
                                       │
                                       ▼
                            Set-AcmeTimestamps.ps1  (parallel)
                                       │
                                       ▼
                              Set-AcmeOwners.ps1    (parallel)
                                       │
                                       ▼
                               Set-AcmeACLs.ps1    (parallel)
                                       │
                                       ▼
                            Remove-AcmeOrphans.ps1
                                       │
                                       ▼
                               Test-AcmeData.ps1
                                       │
                                       ▼
                           verification.json + summary
```

## Logs and artifacts

All generated artifacts land in `manifests/` (gitignored). Structure:

```
manifests/
├── ad-manifest.json              ← 400 users, 40 groups, SIDs
├── folder-manifest.json          ← 50k–100k folders with metadata
├── file-manifest.jsonl           ← 10M file records (3–5 GB)
└── logs/
    ├── ad-build.log
    ├── plan.log
    ├── folders.log
    ├── files-runspace-{id}.log   ← one per parallel worker
    ├── timestamps-runspace-{id}.log
    ├── owners-runspace-{id}.log
    ├── acls-runspace-{id}.log
    ├── orphans.log
    ├── failures.jsonl            ← any per-file errors across any phase
    ├── acl-summary.json          ← ACL mess counts vs targets
    ├── verification.json         ← final truth report
    └── run-summary.json          ← per-phase timings, top-level result
```

## Re-runs and idempotency

| Phase | Idempotent? | Re-run behavior |
|---|---|---|
| AD build | Yes | Check-before-create; safe to re-run |
| Planning | Yes | Deterministic given seed; regenerates manifests |
| Folders | Yes | `New-Item -Force` |
| Files | No | Assumes empty target. Wipe `S:\Share` before re-running |
| Timestamps | Yes | Just overwrites |
| Owners | Yes | Just overwrites |
| ACLs | Yes | Replaces ACL, not merges |
| Orphan pass | Partially | If terminated users are already deleted, skip silently |

Full reset (nuke and pave):
```powershell
Remove-Item -Path 'S:\Share\*' -Recurse -Force
Remove-Item -Path '.\manifests' -Recurse -Force
# Remove AD users/groups is more work — revert to snapshot 00-clean-dc instead
```

## Resume strategy

If something fails mid-run:
1. Inspect `manifests/logs/failures.jsonl` and the phase's own log
2. Fix the root cause
3. Re-run `Build-AcmeData.ps1 -SkipPhase @('ad','plan','2c','2d')` to skip completed phases
4. The file-manifest is the source of truth — timestamps/owners/ACLs passes just re-apply from it

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, verification clean |
| 1 | A phase script threw |
| 2 | Verification pass found > 0.1% drift from targets |
| 3 | Pre-flight check failed (missing config, missing ad-manifest, disk too small, etc.) |

## Time-to-rebuild from snapshot 01

If you revert to `01-ad-populated` and want a regen with tweaked config:
- Wipe `S:\Share`, wipe `manifests/`, re-run `Build-AcmeData.ps1 -SkipPhase ad`
- Expected: 60–95 min unattended
