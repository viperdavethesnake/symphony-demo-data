# Decision Log

Running log of decisions made during design. Newest at top.

---

## 2026-04-17 (round 8) — remaining pipeline scripts implemented

### D-043: Master orchestrator shells out to `pwsh -File` per phase (not dot-sourcing)
`Build-AcmeData.ps1` invokes each phase script as `& pwsh -NoProfile -File <script>`. Each phase gets its own PowerShell process, isolating `$ErrorActionPreference`, loaded Add-Type assemblies, and module imports. Phase crashes surface as non-zero `$LASTEXITCODE` without polluting the orchestrator's session. Cost is ~0.5s per phase for process spawn — negligible against any real phase (plan: minutes; files: 10s of minutes).

### D-042: "Ex-admin" owner variant is approximated by random active user
Spec (`docs/03-acl-design.md` pattern 5) calls for an "ex-admin" owner variant — "someone who used to be an admin but is now a regular user." The AD manifest has no `wasAdmin` flag and adding one would require re-running `Build-AcmeAD.ps1`. For v1 we approximate by picking a random active user for that variant — Symphony's ACL analysis sees the mismatched-owner pattern either way. Open question 2 in the ACL spec is flagged as deferred; revisit if demo storytelling needs it.

### D-041: File owner-setting uses P/Invoke `SetNamedSecurityInfo`, not managed ACL round-trip
`Set-AcmeOwners.ps1` sets NTFS owner via P/Invoke with `OWNER_SECURITY_INFORMATION` only, bypassing the managed DACL read/modify/write cycle. Measured 9,975 files/sec in dev vs. expected ~3–5k for the managed round-trip. Also enables `SeRestorePrivilege` + `SeTakeOwnershipPrivilege` so setting owner to a foreign SID (terminated users, service accounts) succeeds. Managed fallback was considered and rejected on performance grounds.

### D-040: `Remove-AcmeOrphans.ps1` is opt-in via `-RunOrphans` in the orchestrator
The master script skips phase 2h (orphan pass) by default. `Build-AcmeData.ps1 -RunOrphans` is required to actually delete terminated users from AD. Reason: the orphan pass is irreversible without an AD snapshot and should not run in a rehearsal or partial-resume scenario unless explicitly requested. When opted in, the switch also passes `-Force` to suppress the interactive prompt.

### D-039: ACL APIs use `[System.IO.FileSystemAclExtensions]`, not `[System.IO.Directory]::SetAccessControl`
In PowerShell 7 / .NET 6+, the static `[System.IO.Directory]::SetAccessControl(path, security)` method was removed; same for `FileInfo.SetAccessControl` and `GetAccessControl`. The working equivalents are the extension methods on `FileSystemAclExtensions` that take a `DirectoryInfo` / `FileInfo` argument. Set-AcmeACLs.ps1 uses these throughout, which is a real incompatibility with older PS 5.1-era snippets in docs and product forums.

---

## 2026-04-17 (round 7) — `Plan-AcmeData.ps1` implemented

### D-038: Dev overrides live in a full-copy `main-config.dev.json`, not a merge overlay
A separate `config/main-config.dev.json` duplicates the full shape of `main-config.json`, overriding only `scale.rootPath` (repo-relative `test-data\Share`), `scale.totalFiles` (2000), `scale.parallelThreads`, and `scale.batchSize`. Scripts still take a single `-ConfigPath` param — no merge helper. Tradeoff: structural drift between main and dev is possible, but a merge/overlay loader was judged more complex than the benefit for a dev-only convenience. Flagged in the file's `$comment` field so the human keeps the two in sync.

### D-037: Relative `scale.rootPath` resolves against repo root
If `scale.rootPath` is not absolute, scripts resolve it via `Join-Path $RepoRoot $rootPath`. This lets the dev config reference `test-data\Share` portably across machines without hardcoding a developer home directory. Prod config keeps `S:\Share` absolute, matching the lab's mapped data volume.

### D-036: Time anchor for planner is `ad-manifest.meta.generatedAtUtc`, not wall-clock
The planner freezes "now" to the `generatedAtUtc` field emitted by `Build-AcmeAD.ps1` so that running the planner twice against the same inputs produces bit-for-bit identical `file-manifest.jsonl`. Using wall-clock `Get-Date` broke determinism even within the same day due to sub-second drift propagating through age-bucket sampling. Wall-clock is used only as a fallback (with a WARN log) if the ad-manifest predates this field. Verified: two back-to-back dev runs produce byte-identical file-manifests.

### D-035: Planning is single-threaded by design; execution phases parallelize
`Plan-AcmeData.ps1` does all sampling in a single-threaded pass per `docs/02-file-generation.md`'s "plan everything, then execute dumbly in parallel" philosophy. Decisions (ext, size, owner, timestamps, dup/drift groups) require a coherent global view — partitioning across runspaces would complicate seeding and the dup pass (which picks sources globally). Trade-off accepted: planner at 10M scale is projected 5–12 min (extrapolated from dev run at ~200 files/sec); that's a fraction of the execution phases it feeds.

---

## 2026-04-17 (round 6) — `Build-AcmeAD.ps1` implemented

### D-034: Shared demo password is `Acme!Pass2026` (not `Acme!Demo2026`)
First iteration used `Acme!Demo2026` which failed AD complexity rules for the `demo.admin` account: Windows rejects passwords containing substrings of the account's display name longer than 2 consecutive chars, and "Demo Admin" intersects "Demo" in the password. Changed to `Acme!Pass2026` — no overlap with any generated user name or sAMAccountName. Stored in `ad.password` in `main-config.json`. All generated accounts are enabled, `PasswordNeverExpires`, `CannotChangePassword`. They never log in.

### D-033: Name pool lives in `config/name-pool.json`
Separate JSON file with `firstNames` (~200) and `lastNames` (~200) arrays. Keeps the roster config-driven and lets anyone swap in a different pool without touching the script. Not checked against real people.

### D-032: Role-group sizing is the sole source of truth for role-group memberships; no random sprinkle
First draft layered an "1–3 additional role groups per user" random sprinkle on top of the seeded `roleGroupSizing` block. The sprinkle blew up project-group sizes (e.g. `GRP_ProjectApollo` sized to 25 got ~118 members). Removed the sprinkle — `ad.roleGroupSizing` is authoritative. Rule-based groups (`GRP_AllStaff`, `GRP_Managers`, `GRP_Executives`) are populated from user attributes, not sizing.

### D-031: Title assignment uses pyramid (exponential) weighting, not uniform random
First draft picked titles uniformly from each department's title pool, producing ~33% senior-title users and 142 "executives" for 356 active. Changed to exponential weighting: weight(i) = 2^(N-1-i) where i is the index in the pool (junior first). For a 6-title pool, the junior title is 32× more common than the most senior. Produces realistic pyramid — ~31 executives on a 356-user active pool.

### D-030: Title pool lives in the script, not config
Per-department title pools are baked into `Build-AcmeAD.ps1` as `$TitlePool` (a hashtable keyed by department). Not config-driven — titles are demo-flavor, not a tuning knob. Adjust only in the script.

---

## 2026-04-17 (round 5)

### D-029: Live VM is Windows Server 2025, hostname `panzura-sym01`
The actual lab VM is running Windows Server 2025 Standard (not 2022) and its hostname is `panzura-sym01` (not `ACME-DC01`). Domain/forest functional level is `Windows2025Domain`/`Windows2025Forest` (raised above the originally-specified `WinThreshold`/2016). All docs updated to match what's deployed. This has no functional impact on the dataset — `acme.local`, NetBIOS `ACME`, and the single-DC-all-roles topology are unchanged.

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
- Windows Server 2025 VM hosts AD DS + DNS + File Services
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
