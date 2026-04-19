# 05 — Orchestration

How the pieces fit together at runtime. What scripts exist, what they produce, what depends on what.

> **2026-04-18:** The multi-phase planning pipeline was replaced by a single streaming script (`Build-AcmeShare.ps1`). See D-029 and `docs/06-streaming-rewrite.md`. Inventory and graph below reflect the live design.

## Script inventory

All PowerShell 7+. All live in `scripts/`. All take `-ConfigPath` pointing to `config/main-config.json` (or `.dev.json`).

| Script | Phase | Depends on | Produces |
|---|---|---|---|
| `Build-AcmeAD.ps1` | `ad` | config | `manifests/ad-manifest.json` (Populate) or archived manifest (Remove) |
| `Build-AcmeShare.ps1` | `share` | config, ad-manifest, filetypes, folder-templates, token-pool | `manifests/folder-manifest.json`, files on disk under `S:\Share` (sparse + header + size + timestamps + owner — one streaming pass; version drift inlined; final single-threaded dup pass) |
| `Set-AcmeACLs.ps1` | `2g` | folder-manifest, ad-manifest | folders (and ~0.5% files) with ACLs; `manifests/logs/acl-summary.json` |
| `Remove-AcmeOrphans.ps1` | `2h` | ad-manifest | terminated users deleted from AD, leaving orphaned SIDs on disk |
| `Test-AcmeData.ps1` | `verify` | folder-manifest + disk | `manifests/logs/verification.json` (file sample is disk-driven — there is no file-manifest) |
| `Build-AcmeData.ps1` | **Master** | all of the above | runs all phases in order |
| `Initialize-AcmeDisk.ps1` | VM bootstrap | — | formats `S:` with the locked parameter matrix, creates `S:\Share` |
| `Disable-AcmeDefender.ps1` | VM bootstrap | — | fully disables Defender on the lab VM (D-047) |

## Master orchestration script

`Build-AcmeData.ps1` is the entry point humans call. It:
1. Reads the passed config
2. Checks `manifests/ad-manifest.json` exists (runs `Build-AcmeAD.ps1` if missing)
3. Runs each phase in order: `ad` → `share` → `2g` → `2h` (opt-in) → `verify`
4. Times each phase, writes to `manifests/logs/run-summary.json`
5. Stops on any phase failure (`$ErrorActionPreference = 'Stop'`)
6. Supports `-SkipPhase` for partial re-runs (e.g. `-SkipPhase @('ad','share')` to rerun only the ACL/verify tail)
7. Supports `-RunOrphans` to opt in to deleting terminated AD users (destructive)
8. Supports `-DryRun` to run only the `ad` phase

```powershell
$phases = @(
    @{ id='ad';     script='Build-AcmeAD.ps1';       skipIf={ Test-Path manifests/ad-manifest.json } }
    @{ id='share';  script='Build-AcmeShare.ps1' }
    @{ id='2g';     script='Set-AcmeACLs.ps1' }
    @{ id='2h';     script='Remove-AcmeOrphans.ps1'; optIn=$true }
    @{ id='verify'; script='Test-AcmeData.ps1' }
)
```

## Dependency graph

```
config/main-config.json
        │
        ├─► Build-AcmeAD.ps1 ──► ad-manifest.json
        │                              │
        │   filetypes.json             │
        │   folder-templates.json      │
        │   token-pool.json            │
        │         │                    │
        │         ▼                    ▼
        └──► Build-AcmeShare.ps1 ──► folder-manifest.json
                │  (Phase A: expand + allocate + mkdir; Phase B: parallel
                │   runspaces write sparse+header+size+timestamps+owner inline;
                │   version drift inlined; dup pass single-threaded from disk)
                │
                ▼  files on S:\Share
                │
        Set-AcmeACLs.ps1 (parallel; folder-manifest-driven)
                │
                ▼
        Remove-AcmeOrphans.ps1 (opt-in — destructive to AD)
                │
                ▼
        Test-AcmeData.ps1 (disk-driven sample + folder-manifest ACL check)
                │
                ▼
        verification.json + run-summary.json
```

## Logs and artifacts

All generated artifacts land in `manifests/` (gitignored). Structure:

```
manifests/
├── ad-manifest.json                     ← 400+ users, 40 groups, SIDs
├── folder-manifest.json                 ← 7k–50k folders with metadata
└── logs/
    ├── ad-populate-<stamp>.log
    ├── share-<stamp>.log                ← top-level share progress
    ├── share-chunks-<stamp>/            ← per-runspace worker logs
    │   ├── chunk-00001.log
    │   └── chunk-00001-failures.jsonl   ← per-chunk failure shards
    ├── share-summary.json
    ├── acls-<stamp>.log
    ├── acl-summary.json                 ← ACL mess counts vs targets
    ├── orphans-<stamp>.log (if run)
    ├── ad-teardown-summary.json (if run)
    ├── failures.jsonl                   ← merged per-file errors
    ├── verify-<stamp>.log
    ├── verification.json                ← final truth report
    ├── run-<stamp>.log                  ← orchestrator log
    └── run-summary.json                 ← per-phase timings, top-level result
```

## Re-runs and idempotency

| Phase | Idempotent? | Re-run behavior |
|---|---|---|
| `ad` (Build-AcmeAD) | Yes | Check-before-create; safe to re-run |
| `share` (Build-AcmeShare) | No | Assumes empty target. Wipe `S:\Share` before re-running |
| `2g` (ACLs) | Yes | Replaces folder ACLs, not merges |
| `2h` (Orphans) | Partially | If terminated users already deleted, skip silently |
| `verify` | Yes | Read-only |

Full reset (nuke and pave):
```powershell
Get-ChildItem -Path 'S:\Share' -Force | Remove-Item -Recurse -Force
Remove-Item -Path '.\manifests\folder-manifest.json' -Force
# Keep ad-manifest.json; AD state is stable.
# Re-run: pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json -SkipPhase @('ad')
```

## Resume strategy

No intra-`share` resume — the streaming generator is all-or-nothing per run. If it fails:
1. Inspect `manifests/logs/share-<stamp>.log` and the per-chunk `chunk-NNNNN.log` shards
2. Check `manifests/logs/failures.jsonl` for per-file errors
3. Wipe `S:\Share` and re-run

For partial re-runs past `share` (ACLs only, verify only, etc.):
```powershell
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json -SkipPhase @('ad','share')
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success, verification clean |
| 1 | A phase script threw, or the share phase exceeded the 0.1% failure threshold |
| 2 | Verification found at least one non-zero mismatch (folder missing, magic byte mismatch, timestamp inconsistent, owner null, folder with no ACL) |

## Expected runtimes

| Phase | Dev (2000 files) | Prod (10M files) |
|---|---|---|
| `ad` | 30–60 s (one-shot; skipped on re-runs) | same |
| `share` | < 30 s | under 30 min (target from D-029/docs/06) |
| `2g` | < 10 s | 10–20 min |
| `2h` | < 5 s (if run) | < 10 s |
| `verify` | < 5 s | 2–10 min (disk enumeration dominates) |
