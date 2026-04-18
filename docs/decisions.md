# Decision Log

Running log of decisions made during design. Newest at top.

---

## 2026-04-17 (round 4)

### D-028: `Build-AcmeAD.ps1` supports Populate and Remove modes
Single script, `-Mode Populate` (default) or `-Mode Remove`. Remove uses `ad-manifest.json` as the authoritative delete list (surgical), with a pattern-based fallback if the manifest is lost. Requires `-Confirm` or `-Force`. Never touches built-in AD objects. Does not demote the DC. Manifest is archived (renamed with timestamp), not deleted, for audit.

---

## 2026-04-17 (round 3)

### D-027: Token pool is synthetic, not real
`config/token-pool.json` uses fictional codewords and parody vendor names (Globex, Initech, etc.) rather than real-looking companies. Avoids any accidental impression that this data is real or references real entities.

### D-026: Folder templates parameterized via token expansions
`config/folder-templates.json` uses a small templating syntax (`{yearRange}`, `{codewordList:N}`, `{q}`, `{month}`, etc.) so templates are compact and readable. The planner implements the expansion rules listed in the same file.

### D-025: Per-department file-type affinity multipliers
Each department has an `affinityMultipliers` map that biases the global fileTypeMix for that department's folders (Marketing heavy on PSD/AI/MP4, Finance heavy on XLSX/PDF, IT heavy on ISO/MSI/LOG). The planner multiplies the global mix weights by these multipliers per folder.

### D-024: Owner bias is per-folder, not per-file
Folders have an `ownerBias` that determines the weighted owner pool for all files in that folder. Files still sample individually, but from a biased pool. Produces realistic "this folder is mostly Sarah's stuff" patterns.

### D-023: Five named age-bias profiles
`mixed`, `recent-leaning`, `old-leaning`, `old`, `very-old`. Each is a set of weight multipliers applied to the global ageDistribution. Archive folders get `very-old`, Product/Marketing get `recent-leaning`, most get `mixed`.

### D-022: Resume strategy via `-SkipPhase`
Master orchestrator `Build-AcmeData.ps1` supports `-SkipPhase @('ad','plan','2c','2d')` to resume after failures. The file-manifest is the source of truth — later phases can re-apply from it idempotently.

### D-021: Three snapshot points
VM snapshots at `00-clean-dc`, `01-ad-populated`, `02-full-dataset`. Demo restore always uses `02`. `01` is the restore point for regen with tweaked knobs.

### D-020: Defender exclusion on S:
Windows Defender real-time scanning of 10M file creates is catastrophic. Exclude `S:\` before running file gen. Same for any other AV the lab hypervisor runs.

### D-019: ACL mess patterns are per-folder percentages
All ACL mess percentages (oversharing, orphaned SIDs, broken inheritance, etc.) apply per folder, not per file. File-level ACEs are the exception at ~0.5% of files for the "direct user" pattern.

### D-018: Six deliberate ACL mess patterns
1. Oversharing (Everyone/Authenticated Users/Domain Users on sensitive folders)
2. Orphaned SIDs (from terminated users, post-deletion)
3. Broken inheritance (stricter/looser/unrelated)
4. Direct-user ACEs (individuals instead of groups)
5. Owner mismatches (random user, ex-admin, service account, terminated)
6. Conflicting allow/deny ACEs
Each has specified target folders so the demo story lands.

---

## 2026-04-17 (continued)

### D-017: Filename token pool, not realistic sentences
Filenames generated from templates with placeholder tokens (`{n5}`, `{codeword}`, `{date}`, `{year}`, `{q}`, `{month}`, `{rev}`) filled from a content-neutral token pool. Enough to look realistic, no need to generate "real" document titles.

### D-016: Magic-byte headers as hex strings in filetypes.json
`config/filetypes.json` holds header bytes as uppercase hex strings. Some formats (ISO, TAR, WAV, AVI) need markers at non-zero offsets — expressed as `marker` + `markerOffset` fields.

### D-015: Duplicate and drift planned in manifest, not generated during execution
Both exact duplicates (8%) and version drift clusters (3%) are decided during the manifest planning pass. Execution workers are oblivious — they just see N manifest entries and create N files. Keeps workers dumb and parallel-safe.

### D-014: Orphan pass happens AFTER file creation
Terminated users exist in AD during file gen so their SIDs can be applied as owners and ACEs. Only after all files are written and ACLs applied do we delete the terminated users. Their SIDs become unresolvable on disk — the orphan demo.

### D-013: Timestamps and owners are separate passes from file creation
File creation sets times to "now". Phase 2e overwrites with the planned btime/mtime/atime. Phase 2f applies the planned owner. Separating these phases keeps each pass's hot path minimal and parallelizable.

### D-012: NTFS sparse flag via P/Invoke, not fsutil
`fsutil sparse setflag` shells out per call — at 10M files that's 10M process spawns. Unworkable. Use P/Invoke to `DeviceIoControl(FSCTL_SET_SPARSE)` instead. PowerShell `Add-Type` wraps the Win32 call.

### D-011: Manifest-first architecture
File generation is split into a single-threaded planning pass (emits `manifests/file-manifest.jsonl`) and a parallel execution pass (dumb workers read manifest, write files). Deterministic, debuggable, replayable, trivially parallel.

---

## 2026-04-17

### D-010: Repo and collaboration setup
- GitHub repo: `viperdavethesnake/symphony-demo-data`
- Architects/PMs author specs on Mac via Claude Desktop filesystem connector
- Builders use Claude Code on the Windows VM against this repo

### D-009: 10 million files
- Target scale is 10M, not 1M
- Enterprise-feeling scale, Pareto distributions look real, cold-data numbers land in the millions
- Generator architected for parallel from day one (no "ship then optimize")

### D-008: Generation is not the demo
- Generator runs once, VM gets snapshotted, every demo starts from snapshot restore
- Gen time is irrelevant to demo UX — optimize for correctness and realism, not speed
- Re-gen only if spec changes

### D-007: Age distribution 80/20
- 80% of files older than 2 years, 20% newer
- Long tail out to 15 years to make cold-data tiering demos punch
- Explicitly matches common enterprise NAS reality — supports Symphony's tiering value prop

### D-006: Three demo value props drive everything
- Cold data tiering
- Broken ACLs / oversharing
- Space by user, group, file type
- Every knob in the generator should land one of these three stories

### D-005: File headers are real magic bytes, not junk
- Every file has a valid magic-byte header for its extension
- Body is sparse (zeros)
- Cost is small, ensures Symphony's file-type classification shows clean breakdown

### D-004: Single VM, all roles
- Windows Server 2022 VM hosts AD DS + DNS + File Services
- Domain: `acme.local`, NetBIOS `ACME`
- Single DC, no replication, no trusts

### D-003: Sparse files on NTFS
- NTFS sparse flag on `S:\Share`
- Logical ~1 PB, physical ~70–90 GB in VHDX, ~30–50 GB on ZFS after compression
- ~20,000:1 logical-to-physical ratio

### D-002: Windows + PowerShell for generation
- Only Windows NTFS + PowerShell can set creation/mtime/atime cleanly
- Linux/ZFS can't set `btime` (crtime) through normal APIs
- PowerShell 7+ for parallel runspaces
- JSON config files drive all knobs

### D-001: SMB-only demo surface
- Symphony scans via SMB
- Needs real NTFS ACLs resolving against real AD users/groups
- No NFS, no multi-protocol exposure for this demo

---

## Template for new entries

```
## YYYY-MM-DD

### D-NNN: One-line decision title
- Context / why
- What was decided
- Alternatives rejected and why (if relevant)
```
