# 06 — Streaming Rewrite (replaces the planning pipeline)

The manifest-first pipeline is **dead**. We burned a day fighting PowerShell array quirks at 10M scale with nothing on disk. This doc supersedes the relevant parts of `02-file-generation.md`.

## What's changing

**Out:** `Plan-AcmeData.ps1`, `Build-AcmeFolders.ps1`, `Build-AcmeFiles.ps1`, `Set-AcmeTimestamps.ps1`, `Set-AcmeOwners.ps1`, `file-manifest.jsonl`.

**In:** one new script, `Build-AcmeShare.ps1`. Streams folder creation + file creation + sparse + header + size + timestamps + owner all in one pass, per folder, per runspace. No intermediate manifest. No 5 GB JSONL. No "plan everything in RAM first."

**Unchanged:** `Build-AcmeAD.ps1`, `Set-AcmeACLs.ps1`, `Remove-AcmeOrphans.ps1`, `Test-AcmeData.ps1` (with minor tweaks listed below). Configs (`main-config.json`, `filetypes.json`, `folder-templates.json`, `token-pool.json`, `name-pool.json`) unchanged.

**Orchestrator update:** `Build-AcmeData.ps1` calls the new single script instead of the old four.

## Why this is fine

- We don't need bit-for-bit determinism. Distributions match config, individual filenames don't matter.
- We don't need resumability. Crash = `rm -rf S:\Share`, restart. Snapshots, not manifests, are the safety net.
- Streaming never hits the PowerShell-holds-13M-objects-in-RAM wall.
- The only thing we lose is the "inspect the plan before execution" story, and we never used it.

## Architecture

```
Build-AcmeShare.ps1
├── Phase A (single-threaded, ~seconds)
│   ├── Load config, filetypes, folder-templates, token-pool, ad-manifest
│   ├── Expand folder templates → flat folder list (~50k entries)
│   ├── Assign target file count per folder (same largest-remainder math as before)
│   ├── Emit folder-manifest.json  (needed by Set-AcmeACLs.ps1 later)
│   └── Split folder list into N chunks (N = parallelThreads)
└── Phase B (parallel, the hot path)
    └── ForEach-Object -Parallel over chunks. Each runspace:
         for each folder in chunk:
             create folder on disk
             for k = 1..targetFileCount:
                 sample ext, size, timestamps, owner  (local RNG seeded from folder path + file index)
                 create file via P/Invoke sparse + header + SetLength
                 set btime/mtime/atime
                 set owner SID
         write per-chunk stats to log
```

## Key design decisions

### No global file manifest
Files are created, timestamped, owner-set in one pass. Nothing writes to disk about them after. `Test-AcmeData.ps1` validates against disk + config distributions, not against a record.

### Duplicates and version drift happen inline, per folder
A folder flagged for dup activity picks N source files it creates, and within the same chunk copies them to 2–5 other folders **in its own chunk**. Cross-chunk copies are fine too — the target folder already exists because all folders are created in Phase A before Phase B starts writing files (we do the mkdir walk once up front in serial for safety, then go parallel on file writes).

**Simpler variant:** skip cross-folder dups in the hot path. Do one final `Copy-Dups` pass at the end that picks source files from random folders on disk and copies them. Cheap, single-threaded, one `Get-ChildItem` per source. Same effect on Symphony's duplicate detection.

Pick the simpler variant. Cross-folder coordination in runspaces is not worth it.

### Version drift also inline
Same folder, same base name, N suffixed siblings (`_v2`, `_FINAL`, etc.). Trivial — a folder picks a file it just created, generates 2–5 sibling names, writes each with staircased mtime. No coordination needed.

### Folder creation is Phase A, before parallel writes
Workers never create folders. Avoids mkdir races. 50k folders in serial = 30 seconds.

### RNG is seeded per-folder, not per-process
Each runspace computes a folder-local seed: `hash(folderRelPath) XOR masterSeed`. Identical folder = identical files, even across re-runs. Good enough determinism, no cross-runspace state.

### P/Invoke types loaded once per runspace
`Acme.NativeFsctl` (sparse) and `Acme.NativeOwner` (owner) get `Add-Type`'d inside the parallel block, first iteration. Cached in `$using:` is hard; re-adding is cheap.

### No in-memory accumulation beyond one folder
Each iteration builds ~150–800 files, writes them, moves on. Memory ceiling is one folder's worth of file state, not 10M records.

## Script: `scripts/Build-AcmeShare.ps1`

### Parameters
- `-ConfigPath` (required)
- `-SkipFolderCreation` (switch) — skip Phase A mkdir pass if folders already exist
- `-MaxFiles` (int, optional) — cap total files for a quick smoke test without editing config

### Phase A pseudocode
```
load configs + ad-manifest
expand templates → $allFolders (same logic as current Plan-AcmeData.ps1 Phase 2a)
allocate file counts → $allFolders[i].targetFileCount (same largest-remainder math)
emit folder-manifest.json
create root path and sparse-flag it
for each folder: New-Item -ItemType Directory -Force
chunk folders into parallelThreads lists
```

### Phase B pseudocode (per runspace)
```
Add-Type Acme.NativeFsctl, Acme.NativeOwner, Acme.PrivilegeHelper
enable SeRestorePrivilege, SeTakeOwnershipPrivilege
build local lookup tables: extension catalog, age-weight cache, owner-pool cache
for each folder in this chunk:
    if folder.targetFileCount == 0: continue
    folderRng = seeded System.Random(hash(folder.relPath) XOR masterSeed)
    for k = 1..folder.targetFileCount:
        ext      = sample ext weighted by fileTypeMix * folder.affinity
        extMeta  = extension catalog lookup
        size     = log-normal sample from extMeta.sizeDistribution
        ageBucket= weighted pick from folder's ageBias weights
        btime,mtime,atime = sample in bucket (same logic as current Get-TimestampTriplet)
        ownerSid = weighted pick from folder's owner pool
        fname    = render pattern with tokens
        path     = Join-Path folder.path fname
        fh       = [System.IO.File]::Create(path)
        [Acme.NativeFsctl]::SetSparse(fh.SafeFileHandle)
        write header bytes
        write marker at markerOffset if defined
        fh.SetLength(size)
        fh.Dispose()
        [System.IO.File]::SetCreationTimeUtc(path, btime)
        [System.IO.File]::SetLastWriteTimeUtc(path, mtime)
        [System.IO.File]::SetLastAccessTimeUtc(path, atime)
        [Acme.NativeOwner]::SetOwner(path, ownerSid)
        if folderRng.NextDouble() < versionDriftTrigger:
            create 2-5 sibling files with suffixes, staircased mtime, same owner
    per-chunk stats: filesCreated, bytesLogical, failures
return stats
```

### After Phase B — the global dup pass
Single-threaded. Pick `~8% * totalFiles` files at random from the filesystem via `Get-ChildItem S:\Share -Recurse -File` (streaming, don't materialize the list). For each, copy to 2–5 random destination folders in the folder manifest, with a rename variant (`- Copy`, `(2)`, same name). Set copy's btime/mtime/atime close to source. Owner = owner of destination folder (sampled fresh, not source's owner — this gives the demo "same file in 5 different people's folders" pattern).

Don't try to be smart about picking sources. Random is fine.

### Failures
Per-file failures logged to `manifests/logs/failures.jsonl`, merged from per-chunk shards same as the old `Build-AcmeFiles.ps1` did. 0.1% threshold still enforced.

### Logging
- `manifests/logs/share-<runstamp>.log` — top-level progress
- `manifests/logs/share-chunks-<runstamp>/chunk-XXXXX.log` — per-runspace
- `manifests/logs/share-summary.json` — final result

## Minor tweaks to other scripts

**`Set-AcmeACLs.ps1`** — no change. Reads `folder-manifest.json`, which the new script still emits.

**`Test-AcmeData.ps1`** — rewrite Check 2–4. Instead of sampling from file-manifest.jsonl, do this:
- `Get-ChildItem S:\Share -Recurse -File` with a random skip factor to sample ~500 files
- Verify each file has: valid magic bytes for its extension, consistent btime ≤ mtime ≤ atime, a non-null owner SID
- Aggregate: file type histogram vs `fileTypeMix`, age bucket histogram vs `ageDistribution`, mean ACL count vs expected

**`Build-AcmeData.ps1` (orchestrator)** — replace the 4 phases (`plan`, `2c`, `2d`, `2e`, `2f`) with one phase entry:
```powershell
@{ id='share';  script='Build-AcmeShare.ps1' }
```
Everything else (ad, acls, orphans, verify) unchanged.

## What to delete

Delete these files — do not leave them in the repo as dead code:
- `scripts/Plan-AcmeData.ps1`
- `scripts/Build-AcmeFolders.ps1`
- `scripts/Build-AcmeFiles.ps1`
- `scripts/Set-AcmeTimestamps.ps1`
- `scripts/Set-AcmeOwners.ps1`

Update `docs/02-file-generation.md` to a one-paragraph note: "Superseded by `06-streaming-rewrite.md`" and leave it.

Update `docs/05-orchestration.md` to reflect the new phase list.

Update `docs/decisions.md` with D-029 noting the planning pipeline was scrapped and why.

Update `CLAUDE.md` Phase order section.

## Non-negotiables (unchanged)

- PowerShell 7+, `#Requires -Version 7.0`
- `$ErrorActionPreference = 'Stop'`, `Set-StrictMode -Version Latest`
- P/Invoke for sparse + owner
- Magic-byte headers real, sparse bodies
- a/m/btime consistent, btime ≤ mtime ≤ atime
- ACL pass still operates on folder-manifest.json after file creation
- Parallel via `ForEach-Object -Parallel` with throttle from config

## Expected performance

- Phase A: folder expansion + allocation + mkdir = 30–60 seconds
- Phase B: ~10–15k files/sec aggregate at throttle=24 → 10M files in 10–20 minutes
- Global dup pass: 5–10 minutes
- Version drift pass: inlined in Phase B, adds maybe 10% to its time
- Total: **under 30 minutes** for 10M files end-to-end before ACL pass.

If it takes longer than that, something is wrong.

## Implementation order for Claude Code

1. Write `Build-AcmeShare.ps1` with Phase A + Phase B + dup pass.
2. Delete the five dead scripts listed above.
3. Update `Build-AcmeData.ps1` orchestrator phase list.
4. Update `Test-AcmeData.ps1` checks to read from disk not manifest.
5. Smoke test: `pwsh -File .\scripts\Build-AcmeShare.ps1 -ConfigPath .\config\main-config.dev.json` (2000 files).
6. Inspect `S:\Share` manually. Does it look right? Timestamps vary? Owners set? Headers valid?
7. If yes, run full 10M against `main-config.json`.
8. Then `Set-AcmeACLs.ps1`, then `Remove-AcmeOrphans.ps1`, then `Test-AcmeData.ps1`.

## What NOT to do

- Do not keep the planning scripts "just in case." Delete them.
- Do not write a manifest mid-run. The whole point is no manifest.
- Do not try to preserve cross-run determinism for individual filenames. Per-folder seeding is enough.
- Do not coordinate between runspaces. Folders are disjoint. Dup pass is single-threaded.
- Do not read `file-manifest.jsonl` anywhere. It no longer exists.
