# 02 — Architecture

Single-VM, single-language (PowerShell 7), config-driven. One master orchestrator runs a short chain of specialized scripts.

## Block diagram

```
                ┌────────────────────────────────────────────────────┐
                │              config/ (all knobs)                   │
                │ main-config.json  filetypes.json  folder-templates  │
                │ token-pool.json                                     │
                └───────┬─────────────────────────────────┬──────────┘
                        │                                 │
              ┌─────────▼───────────┐           ┌─────────▼──────────┐
              │ Build-AcmeAD.ps1    │           │ Initialize-AcmeDisk│
              │  (once per VM)      │           │ Disable-AcmeDefender│
              │                     │           │  (VM bootstrap)    │
              └──────┬──────────────┘           └────────┬───────────┘
                     │                                    │
                     ▼                                    ▼
          manifests/ad-manifest.json            S:\ (NTFS, sparse-ready)
                     │                                    │
                     │                                    │
                     │    ┌───────────────────────────────┘
                     │    │
                     ▼    ▼
              ┌─────────────────────────────────────────────┐
              │          Build-AcmeData.ps1                 │
              │          (master orchestrator)              │
              └─────┬────────────────┬──────────────┬──────┘
                    │                │              │
        ┌───────────▼──────┐ ┌──────▼─────┐ ┌──────▼──────────┐
        │Build-AcmeShare   │ │Set-AcmeACLs│ │Remove-AcmeOrphans│
        │ Phase A: serial  │ │ plan+apply │ │  AD deletes      │
        │ Phase B: 24-way  │ │ + file-ACE │ │                  │
        │ Dup pass: serial │ │ sample     │ │                  │
        └────┬─────────────┘ └─────┬──────┘ └──────┬───────────┘
             │                     │               │
             └─────────────────────┴───────────────┘
                               │
                               ▼
                       Test-AcmeData.ps1
                               │
                               ▼
                 manifests/logs/verification.json
```

## Build-AcmeShare — the heavy lifter

See `docs/06-streaming-rewrite.md` for the full spec and D-029 for the rationale.

### Phase A (single-threaded, ~30 s)

1. Load configs + ad-manifest.
2. Expand folder templates into a flat list (~7,200 folders).
3. Allocate a target file count per folder (largest-remainder math on log-normal weights, biased for archives / rabbit-holes).
4. Precompute **SharedCtx**: extension catalog, owner-pool cache (per `(bias, dept)` key), age-bucket weights, per-affinity ext weight tables.
5. Emit `manifests/folder-manifest.json` (Set-AcmeACLs consumes this).
6. `New-Item` every folder on disk (serial — avoids mkdir races).

### Phase B (parallel, ~60 min at 10 M files, 24 threads)

Folders are sorted by `targetFileCount` descending and **round-robin chunked** across N runspaces. Each runspace owns its chunk end-to-end — no cross-runspace coordination.

Per folder:
- Seed a `System.Random` from `hash(relPath) XOR masterSeed`. Same folder = same files across runs.
- For each file in `targetFileCount`:
    - Sample ext (category weighted by `fileTypeMix`, then ext weighted by per-department affinity).
    - Sample size (log-normal from the ext's `sizeDistribution`).
    - Sample age bucket (per folder's `ageBias`) → `btime, mtime, atime` triplet (`btime ≤ mtime ≤ atime`, with 10 % recent-atime bump).
    - Sample owner SID from the folder's precomputed owner pool.
    - Render filename via template tokens.
    - `[System.IO.File]::Create` → `FSCTL_SET_SPARSE` → write header at 0 → write marker at `markerOffset` → `SetLength(size)` → close.
    - `SetCreationTimeUtc/LastWriteTimeUtc/LastAccessTimeUtc`.
    - P/Invoke `SetNamedSecurityInfo(OWNER | DACL | UNPROTECTED)` — sets owner while preserving inheritance (see [04-why-powershell.md](04-why-powershell.md) for why this specific flag combo).
- With per-folder probability = `versionDriftPercent / 100`, spawn 3–6 siblings with suffixes (`_v2`, `_FINAL`, `_Approved`, …) and staircased mtime.

### Dup pass (single-threaded, ~40 min at 10 M)

1. `Directory.EnumerateFiles` the tree, probabilistic-accept `~8 % × totalFiles` source paths.
2. For each source, copy to 2–5 random destination folders from folder-manifest (rename variants: same, `- Copy`, `(2)`).
3. New owner sampled from **destination** folder's owner pool (so "same file, 5 different people's folders" — the Symphony dedup story).

## Set-AcmeACLs — folder ACLs + mess patterns

Two-pass:

1. **Plan (single-threaded):** categorize each folder (`dept-root`, `dept-sub`, `dept-sensitive`, `dept-archive`, `shared-public`, `shared-scratch`, `shared-archive`, `shared-projects`, `root`, `other`). Build clean ACE list per template in `docs/03-acl-design.md`. Then overlay six mess patterns at config-driven rates:
    - `oversharingPercent` — `Everyone:Read` / `AuthenticatedUsers:Modify` / `DomainUsers:FullControl` thrown onto random (preferably sensitive) folders.
    - `orphanedSidPercent` — ACEs referencing the 12 terminated users' SIDs (unresolvable after Remove-AcmeOrphans runs).
    - `brokenInheritancePercent` — deep folders with PROTECTED DACL + stricter / looser / unrelated-dept ACE.
    - `directUserAcePercent` — direct-user (non-group) ACEs, sometimes sprawling, sometimes wrong-dept.
    - `ownerMismatchPercent` — folder owner set to a random user / service account / terminated SID.
    - `conflictingAcePercent` — explicit `Deny Write` alongside the Allow.

2. **Apply (parallel, ~24-thread batches):** build `DirectorySecurity`, `AddAccessRule` per ACE, `SetAccessControl`.

Then the **file-level ACE pass** (single-threaded, ~30 s): reservoir-sample ~0.5 % of files on disk, add a direct-user `Modify` ACE to each (~60 k at 10 M scale).

## Remove-AcmeOrphans

Single-threaded. Reads `ad-manifest.json`, filters `status == 'terminated'`, `Remove-ADUser` for each. Archives the pre-delete manifest with a timestamp suffix. Those 12 SIDs are now unresolvable on disk — any file owned by them, or any folder ACE referencing them, becomes the "orphaned SID" demo story.

## Test-AcmeData

Disk-driven (no file-manifest since D-029). Streams `Directory.EnumerateFiles` over the whole tree once to:
- Count exact per-extension totals → category distribution check.
- Reservoir-sample 500 files for per-file validation (magic-byte header, `btime ≤ mtime ≤ atime`, non-null owner SID, age-bucket tally).

Plus 200 random folder-manifest entries for ACL sanity. Output: `manifests/logs/verification.json` with `pass: true/false`.

## What happens in what order

See [03-workflow.md](03-workflow.md).

## What got scrapped

The original design had a 5-script planning pipeline (`Plan-AcmeData` → `Build-AcmeFolders` → `Build-AcmeFiles` → `Set-AcmeTimestamps` → `Set-AcmeOwners`) that emitted a 5 GB `file-manifest.jsonl` between passes. It broke at 10 M scale on PowerShell's list-handling quirks — the planner built a 13 M-record `List[object]` in RAM and the second phase crashed with array-index errors. D-029 / `docs/06-streaming-rewrite.md` documents the rip-out.
