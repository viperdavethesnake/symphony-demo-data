# 06 — Configuration reference

All knobs live under `config/`. Changing a value, re-running, producing a different-but-still-valid dataset is the whole point of this project being config-driven (constraint 8 in CLAUDE.md).

## `main-config.json` — the primary file

```json
{
  "meta": {
    "version": "0.1.0",
    "seed": 42,                      ← change for a different dataset
    "tenantName": "Acme Corp"
  },
  ...
}
```

### `meta`

| Field | Purpose |
|---|---|
| `seed` | Master RNG seed. Same seed + same config = bit-for-bit same dataset (modulo inevitable OS-level noise). Bump to reshuffle. |
| `tenantName` | Display name only; appears in some filenames / docs. |

### `ad` — AD build parameters

| Field | Default | Purpose |
|---|---|---|
| `domain` / `netbios` | `acme.local` / `ACME` | FQDN + NETBIOS. Baked into SIDs — change before first `Build-AcmeAD` run. |
| `password` | `Acme!Pass2026` | Every user's password. Must satisfy Windows complexity policy. |
| `adminAccount.samAccountName` | `demo.admin` | Dedicated domain admin for demos. |
| `users.activeCount` / `disabledCount` / `terminatedCount` / `serviceAccountCount` | 356 / 32 / 12 / 10 | 411 total. Terminated users become the orphan-SID source. |
| `departmentDistribution` | 12 depts, 3–90 each | How the 356 active users split across departments. Percentage-free; raw counts. |
| `groups.createDepartmentGroups` / `createRoleGroups` / `createResourceGroups` | true | Gate the three group tiers. Leave on. |
| `groups.rolesPerUserMin` / `rolesPerUserMax` | 1 / 3 | How many role groups each active user joins. |
| `roleGroupSizing` | hash of group → count/percent | Per-group membership counts for special groups (`GRP_Contractors`, project teams, `GRP_LegalHold`, etc). |
| `groupNesting` | hash of parent → children[] | AGDLP nesting. Most depts nest their top group into per-resource groups. |

### `scale`

| Field | Dev | Prod | Purpose |
|---|---|---|---|
| `totalFiles` | 2000 | 10000000 | Target base file count. Drift siblings + dup copies land on top. |
| `rootPath` | `S:\Share` | `S:\Share` | Absolute path to the share root. Both dev and prod point at the real `S:` (D-048). |
| `parallelThreads` | 4 | 24 | `ForEach-Object -ThrottleLimit` in Phase B. Match vCPU count. |
| `batchSize` | 250 | 5000 | Folders per runspace chunk — affects load balance, not correctness. |

### `folders`

| Field | Purpose |
|---|---|
| `departmentShares` | List of top-level department names under `S:\Share\Departments\`. Drives `folder-templates.json` lookups. |
| `commonShares` | `Public` / `Scratch` / `Archive` / `Projects` — the `S:\Share\Shared\*` siblings. |
| `minDepth` / `maxDepth` | Target tree depth range. Soft targets — folder-templates dominate. |
| `deepFolderPercent` | % of leaf folders that get "rabbit hole" extra depth. |
| `deepFolderMaxDepth` | Hard cap on how deep those rabbit holes go. |

### `ageDistribution`

Must sum to 100. Per-bucket file share (base files; drift siblings skew these). Default biases 80 % older than 2 years — the cold-data demo story.

### `timeConsistency.atimeRecentlyTouchedPercent`

% of files whose atime gets bumped to within the last 30 days (the "a backup touched it" realism pattern). Default 10.

### `fileTypeMix`

Must sum to 100. Per-category file share. Category → ext mapping lives in `filetypes.json`.

### `duplicates`

| Field | Default | Purpose |
|---|---|---|
| `exactDuplicatePercent` | 8 | Fraction of files that are exact-content copies of an earlier file (across folders). Avg copies per source ≈ 3.5. |
| `versionDriftPercent` | 3 | Fraction of base files that spawn 3–6 sibling "version drift" files (`_v2`, `_FINAL`, …). |
| `versionDriftClusterSizeMin` / `Max` | 3 / 6 | Drift cluster size bounds. |

### `acl` — mess-pattern rates

| Field | Default | Mess pattern |
|---|---|---|
| `oversharePercent` | 5 | Folders with `Everyone` / `AuthenticatedUsers` / `DomainUsers` ACEs. |
| `orphanedSidPercent` | 3 | Folders with an ACE referencing a terminated user (becomes `<unresolvable>` after orphan pass). |
| `brokenInheritancePercent` | 4 | Deep folders with PROTECTED DACL + stricter/looser/unrelated overlay. |
| `directUserAcePercent` | 6 | Folders with one or more direct-user (non-group) ACEs. |
| `ownerMismatchPercent` | 10 | Folders whose owner is set to a random / service / terminated user instead of Administrator. |
| `conflictingAcePercent` | 1 | Folders with a `Deny Write` alongside `Allow Modify`. |

Every percentage is a fraction of the total folder count, independently drawn — they can overlap. File-level ACEs are at a fixed ~0.5 % of files (not in config).

### `spaceSkew`

| Field | Default | Purpose |
|---|---|---|
| `hoarderUserPercent` | 10 | Top X % of active users become "hoarders". |
| `hoarderBytesShare` | 60 | Hoarders own ~60 % of logical bytes. Drives the Pareto demo story. |
| `serviceAccountDominantBytesShare` | 25 | Service accounts own ~25 % of bytes (backup/scanner/etc). |

## `filetypes.json`

Per-extension metadata. Structure:

```json
"<category>": {
  "<ext>": {
    "category": "<category>",        ← redundant with outer, used as shortcut
    "header": "<hex bytes>",         ← magic bytes written at offset 0
    "headerOffset": 0,               ← almost always 0
    "marker": "<hex>",               ← optional; only for tar/iso/wav/avi
    "markerOffset": <offset>,        ← where the marker lands
    "sizeDistribution": {
      "p50Bytes": 350000,
      "p95Bytes": 2500000,
      "minBytes": 20480,
      "maxBytes": 15000000
    },
    "filenamePatterns": ["Report_{n5}.docx", ...]
  }
}
```

Size sampling: log-normal fit to `p50Bytes` / `p95Bytes`, clamped to `[min, max]`.

Filename tokens: `{n3}` / `{n5}` (digits), `{date}` / `{year}` / `{q}` / `{month}`, `{codeword}` / `{rev}`. Tokens pull from `token-pool.json`.

## `folder-templates.json`

Per-department template:

```json
"<DeptName>": {
  "structure": [
    "Briefs/{yearRange}",
    "Quotes/{yearRange}/{month}",
    ...
  ],
  "affinityMultipliers": { "xlsx": 3.0, "iso": 0.1, ... },
  "ageBias": "mixed",                ← mixed | recent-leaning | old-leaning | old | very-old
  "archiveFolderAgeBias": "old",     ← optional override for Archive/ subtrees
  "ownerBias": "department",         ← department | executives-only | it-admins-and-service-accounts | all-staff | mixed | mixed-including-terminated | cross-department
  "sensitiveFolders": ["Payroll", "Contracts"]   ← optional; top-level names
}
```

Structure entries use template tokens expanded at plan time:

| Token | Produces |
|---|---|
| `{yearRange}` | `FY2012`…`FY2026` (range from `defaults.yearRangeStart`/`End`) |
| `{yearRangeStart:X,yearRangeEnd:Y}` | explicit range (Archive subtrees use this for 2012–2019) |
| `{q}` | `Q1`–`Q4` |
| `{month}` | `01-Jan`…`12-Dec` |
| `{rev}` | `rev1`/`rev2`/`rev3`/`final`/`archive` |
| `{version}` | `v1.0`…`v2.1` |
| `{codewordList:N}` | pick `N` random codewords |
| `{vendorList:N}` | pick `N` random vendors |
| `{userList:N}` | pick `N` random active-user samAccountNames |
| `a,b,c` | literal brace alternation |

## `token-pool.json`

Lists of strings. `codewords` (96), `vendors` (50), `revisions` (33), `monthsShort` (12), `quartersVerbose` (4). Edit to reskin the dataset's "flavor".

## `main-config.dev.json`

Minimal overlay for dev runs. Only changes:
- `scale.totalFiles: 2000`
- `scale.parallelThreads: 4`
- `scale.batchSize: 250`

Everything else (AD, fileTypeMix, ACL rates, etc.) is identical to prod so dev exercises the same code paths.
