# Decision Log

Running log of decisions made during design. Newest at top.

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
