# 02 — File Generation

This phase turns the AD manifest + JSON config into 10M files under `S:\Share`. It's the heaviest phase by a wide margin. Getting this right is most of the project.

## Philosophy: plan everything, then execute dumbly in parallel

Do **not** make decisions while writing files. All randomness, sampling, pathing, and attribute choices happen **up front** in a single-threaded **planning pass** that emits a manifest. The **execution pass** is embarrassingly parallel workers that do no thinking — they just read a manifest line, create a file, write a header, extend it sparse, move on.

Benefits:
- Deterministic given a seed
- Replayable (lose a VM? run execution against the manifest again)
- Debuggable (read the manifest; it tells you exactly what was supposed to happen)
- Parallel is trivial when work units are independent

## Sub-phases

| # | Phase | Parallel? | Notes |
|---|---|---|---|
| 2a | Folder tree plan | No | In-memory tree from templates + config |
| 2b | File manifest plan | No | Single pass, writes `manifests/file-manifest.jsonl` (~3–5 GB) |
| 2c | Folder creation | No | `New-Item -ItemType Directory` loop; serial avoids mkdir races |
| 2d | File creation | **Yes** | Parallel workers, batches of 5000. Magic-byte header + sparse extend |
| 2e | Timestamp application | **Yes** | Separate pass — creation sets times to "now", must overwrite |
| 2f | Owner application | **Yes** | `icacls /setowner` or Win32 API |
| 2g | ACL application | **Yes** | See `03-acl-design.md` |
| 2h | Orphan pass | No | Delete terminated users from AD — their SIDs are now unresolvable on disk |

## Phase 2a — Folder tree plan

Folder structure is built from templates in `config/folder-templates.json` (one template per department). Templates define the characteristic sub-structure of each department's share plus some parameterized variability.

**Example (Finance):**
```
Finance/
├── AP/{FY2015..FY2026}/
├── AR/{FY2015..FY2026}/
├── GL/{Q1,Q2,Q3,Q4}/{FY2015..FY2026}/
├── Budgets/{FY2015..FY2026}/
├── Audit/{external,internal}/{FY2015..FY2026}/
├── Tax/{federal,state,international}/{FY2015..FY2026}/
├── Policies/
├── Reports/{monthly,quarterly,annual}/
├── Vendors/{A..Z distributed}/
└── Archive/{FY2010..FY2018}/
```

**Common traits:**
- Every department has an `Archive/` subtree biased toward old ages
- Every department has a `Projects/` or equivalent with randomly-named project folders (pulled from a project-name dictionary)
- `Shared/Public`, `Shared/Scratch`, `Shared/Projects`, `Shared/Archive` at root
- A small % of folders (~2%) go 9+ levels deep (the "someone's personal rabbit hole" pattern)
- Target: ~50k–100k folders total

**Output:** in-memory folder list with attributes: `path`, `department`, `themeTags`, `targetFileCount`, `ageBias`, `ownerBias`.

## Phase 2b — File manifest plan

Walk every folder, decide its file count from a log-normal (median ~150, long tail), then for each file sample:

1. **Extension** — from global `fileTypeMix` × folder `affinityMultipliers`
2. **Size** — from that extension's distribution in `config/filetypes.json`
3. **Age bucket** — from global `ageDistribution`, biased by folder (`Archive/` skews old, recent-named folders skew new)
4. **Timestamps** — `btime` within the age bucket; `mtime ≥ btime` (usually same day, sometimes weeks/months later); `atime ≥ mtime` (usually close to mtime, occasionally bumped recent per `atimeRecentlyTouchedPercent`)
5. **Owner SID** — weighted sample from folder's owner pool (department users, hoarders, service accounts). 10% of users get heavy-hitter weighting. Small % referencing terminated users (become orphans after phase 2h)
6. **Filename** — realistic per-extension templates (e.g. `Q3_Invoice_{n}.pdf`, `Screenshot_{date}.png`, `build-{tag}.zip`)
7. **Duplicate group** — null for most. For files selected into a dup cluster: `dupGroup: "d0042"` shared across copies. For version drift: `dupGroup: "v0017"` with sibling suffixes (`_v1`, `_v2`, `_FINAL`, `_FINAL_v2`, `_USE_THIS`)

**Manifest format (`manifests/file-manifest.jsonl`, one record per line):**

```jsonc
{"path":"S:\\Share\\Departments\\Finance\\AP\\FY2019\\Invoice_00042.pdf","ext":"pdf","size":2457600,"btime":"2019-03-14T09:22:11Z","mtime":"2019-03-14T14:10:00Z","atime":"2019-03-14T14:10:00Z","ownerSid":"S-1-5-21-...-1234","dupGroup":null}
```

JSONL streams cleanly. Workers can read-ahead/chunk without parsing the whole thing.

## Phase 2c — Folder creation

Serial is fine. Even 100k folders takes under a minute with `New-Item -ItemType Directory -Force`. Serial avoids races on nested paths.

## Phase 2d — File creation (the hot path)

**Per-file work:**
1. Open file with `[System.IO.File]::Create(path)`
2. Set NTFS sparse flag via `DeviceIoControl(FSCTL_SET_SPARSE)` — P/Invoke, see below
3. Write magic-byte header (bytes from `config/filetypes.json`)
4. `SetLength(targetSize)` — extends the file logically; sparse flag means the extension consumes zero physical blocks
5. Close

**Do NOT** shell out to `fsutil sparse setflag` per file. At 10M files that's 10M process spawns, catastrophically slow. Use P/Invoke from PowerShell:

```powershell
$signature = @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool DeviceIoControl(
    IntPtr hDevice, uint dwIoControlCode, IntPtr lpInBuffer, uint nInBufferSize,
    IntPtr lpOutBuffer, uint nOutBufferSize, out uint lpBytesReturned, IntPtr lpOverlapped);
'@
Add-Type -MemberDefinition $signature -Name NativeMethods -Namespace Win32
# FSCTL_SET_SPARSE = 0x900C4
```

Claude Code: wrap this in a helper function, call it on the `SafeFileHandle` of each new file before writing the header.

**Parallelism:**
- `ForEach-Object -Parallel` with `-ThrottleLimit` from `config.scale.parallelThreads` (default 24)
- Each runspace gets a batch of 5000 manifest lines (`config.scale.batchSize`)
- Amortizes runspace startup across thousands of files
- Runspaces share nothing — no locks needed, paths are unique

**Expected throughput:** 8–15k files/sec aggregate on the i7-14700K. 10M files in ~15–25 minutes for this phase.

**Logging:**
- One log file per runspace under `manifests/logs/create-{runspaceId}.log`
- Failures written to `manifests/logs/failures.jsonl` (shared via `[System.Threading.Mutex]` or per-runspace then merged)

## Phase 2e — Timestamp application

Creating a file sets `btime`, `mtime`, `atime` all to "now". We need to overwrite. Separate pass.

**Per-file:**
```powershell
[System.IO.File]::SetCreationTimeUtc($path, $btime)
[System.IO.File]::SetLastWriteTimeUtc($path, $mtime)
[System.IO.File]::SetLastAccessTimeUtc($path, $atime)
```

Parallel same pattern as 2d. Faster than creation — pure metadata ops, no body writes. Expect 20–30k files/sec.

**Order matters:** set `btime` first, `mtime` next, `atime` last. Setting `mtime` also bumps `ctime` (NTFS change time), but we don't care about NTFS `ctime` — Symphony uses Windows semantics where "creation time" = `btime`.

## Phase 2f — Owner application

`icacls` can set owner but shelling per file is too slow. Options:

1. **`icacls /setowner` in batches with a file list** — acceptable
2. **P/Invoke `SetNamedSecurityInfo`** — fastest, what a production tool would do

Claude Code's call — start with batched icacls, switch to P/Invoke if throughput is insufficient. Target 15–25k files/sec.

Applied per-file from the manifest's `ownerSid`. Terminated-user SIDs go in as-is; they're still valid AD users at this phase. Phase 2h deletes them.

## Phase 2g — ACL application

See `docs/03-acl-design.md` (TBD). Folder-level ACLs primarily, with a small % of file-level ACLs for the "direct user ACE" mess pattern.

## Phase 2h — Orphan pass

Delete the ~12 terminated users from AD. Their SIDs remain in ACLs and as file owners. Symphony reports these as unresolvable during scan — that's the orphan demo.

```powershell
$terminated = $adManifest.users | Where-Object { $_.status -eq 'terminated' }
$terminated | ForEach-Object { Remove-ADUser -Identity $_.samAccountName -Confirm:$false }
```

## Magic-byte catalog

Lives in `config/filetypes.json`. Per extension it specifies:
- `category` (office/images/archives/media/installers/cadCode/textLogs/junk)
- `header` — hex-string of bytes to write at offset 0 (some formats like ISO need a byte written at a non-zero offset; handled as `{offset: 0x8001, bytes: "4344303031"}`)
- `sizeDistribution` — lognormal with `p50Bytes`, `p95Bytes`, `minBytes`, `maxBytes`
- `filenamePatterns` — array of templates like `"Invoice_{n:05d}.pdf"`, `"Q{quarter}_{year}_Report.pdf"`

The generator samples a filename pattern and fills placeholders from a content-neutral token pool (numbers, years, quarter names, project codewords, employee IDs).

## Duplicate and version-drift pass (inside Phase 2b)

**Exact duplicates (`exactDuplicatePercent` = 8%):**
- Pick source files uniformly at random
- For each, create 2–5 copies in other folders
- Copies share `dupGroup` ID, same size, same header, same (or near-same) mtime
- Filename can match exactly or be copy-renamed (`- Copy.pdf`, `(2).pdf`)

**Version drift (`versionDriftPercent` = 3%):**
- Pick base files, generate 3–6 sibling filenames in the same folder:
  - `Report.docx`, `Report_v2.docx`, `Report_FINAL.docx`, `Report_FINAL_v2.docx`, `Report_FINAL_USE_THIS.docx`
- Sizes vary ±30% between versions (edited drafts)
- mtimes staircase: each version mtime later than the previous
- All share a `dupGroup` ID

Both are planned in the manifest. Execution is oblivious.

## Seeding and reproducibility

One master seed in `config/main-config.json`. Derived seeds per phase (hash of master + phase name). Same config → same manifest → same dataset. Enables regeneration if the VM is lost.

## Error handling

- Any file that fails creation is logged and skipped. Generator does not abort.
- Final report: `manifests/logs/summary.json` with counts of planned / created / failed / skipped per phase
- If failure rate exceeds 0.1% of planned files, flag a warning at end

## Performance budget (for reference)

On the target hardware (i7-14700K, 96 GB RAM, NVMe ZFS-backed VHDX):

| Phase | Expected time |
|---|---|
| 2a folder plan | < 1 min |
| 2b manifest plan | 3–8 min |
| 2c folder creation | 1–2 min |
| 2d file creation | 15–25 min |
| 2e timestamps | 8–12 min |
| 2f owners | 10–20 min |
| 2g ACLs | 15–30 min (depends on ACL complexity) |
| 2h orphan pass | < 1 min |
| **Total** | **~60–100 min** |

Run overnight with buffer. Snapshot the VM as soon as it completes.

## Open questions before implementation

None. All dependencies (AD manifest, config schemas, folder templates, file-type catalog) are specified or will be by the time scripts start. Claude Code should flag any ambiguities encountered during implementation.
