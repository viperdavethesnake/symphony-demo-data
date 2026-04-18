# CLAUDE.md

Standing instructions for Claude Code working in this repo.

## Your role

You are the **builder**. Architecture and design decisions live in `docs/` and `config/`. Do not redesign — implement against the spec. If the spec is ambiguous or you believe it's wrong, flag it and ask before diverging.

## What this project is

A generator that produces a realistic, messy, enterprise-scale NAS dataset for demoing **Panzura Symphony**. Target: **10 million files** on a Windows Server 2025 VM (single box running AD DS + DNS + File Services for the fake `acme.local` domain), exposed via SMB from `S:\Share`.

Read `README.md` and `docs/00-overview.md` first. Always.

## Non-negotiable constraints

1. **Windows + PowerShell 7+ only** for all generation work. Not Python. Not Bash. The only way to set `btime` (creation time) cleanly is PowerShell on NTFS.
2. **Every file must have a valid magic-byte header** for its extension. The body can be (and should be) sparse zeros, but the header must make the file type correctly identifiable.
3. **NTFS sparse flag** on `S:\Share` — logical size is huge, physical footprint must stay small.
4. **a/m/btime must be logically consistent**: `btime ≤ mtime ≤ atime`. A small deliberate % of files have a recently-bumped atime for demo realism — that's specified in the config.
5. **AD identities must resolve** — ACLs and file ownership reference real SIDs from the `acme.local` domain. The file generator reads `manifests/ad-manifest.json`, never queries AD during the hot path.
6. **Parallel from day one**. 10M files means PowerShell 7 runspaces (`ForEach-Object -Parallel` or equivalent). No "ship single-threaded first."
7. **Seeded / reproducible**. Same config + same seed = same dataset. Seed lives in `config/main-config.json`.
8. **Config-driven**. Every knob lives in JSON under `config/`. Do not hardcode counts, percentages, paths, or names.
9. **Idempotent where it makes sense**. AD build script should check-before-create so re-runs don't error. File gen does not need to be idempotent (re-run wipes `S:\Share` and starts over).

## Repo layout

```
symphony-demo-data/
├── README.md                    ← project summary
├── CLAUDE.md                    ← this file
├── docs/
│   ├── 00-overview.md           ← scope, architecture, value props, scale
│   ├── 01-ad-design.md          ← AD spec
│   ├── 02-file-generation.md    ← file gen architecture
│   ├── 03-acl-design.md         ← ACL patterns and mess injection
│   ├── 04-vm-provisioning.md    ← VM build steps end-to-end
│   ├── 05-orchestration.md      ← how the scripts fit together
│   └── decisions.md             ← running decision log (read this)
├── config/
│   ├── main-config.json         ← primary knobs
│   ├── filetypes.json           ← extension → header/size table
│   ├── folder-templates.json    ← per-department folder structure templates
│   └── token-pool.json          ← codewords, vendors, revisions for filename generation
├── scripts/                     ← PowerShell goes here (your job)
└── manifests/                   ← gitignored runtime artifacts
```

## Demo value props the data is tuned for

Everything must land one of these three stories. Don't add features that don't.

1. **Cold data discovery** — 80/20 age split, long tail to 15 years.
2. **Broken ACLs / oversharing** — oversharing, orphaned SIDs, broken inheritance, direct-user ACEs, owner mismatches, conflicting ACEs.
3. **Space by user, group, file type** — Pareto ownership, heavy-hitter file types.

## Scale and sparse math (for context)

- 10M files
- ~1 PB logical (Symphony reports this)
- ~70–90 GB physical in the VHDX
- ~30–50 GB on ZFS after compression
- ~20,000:1 logical-to-physical ratio

## Phase order for the full build

1. **VM provisioning** — install Windows features, format S:, enable sparse. See `docs/04-vm-provisioning.md`
2. **AD setup** — `Build-AcmeAD.ps1` creates OUs, users, groups. Emits `manifests/ad-manifest.json`. See `docs/01-ad-design.md`
3. **Plan** — `Plan-AcmeData.ps1` emits `folder-manifest.json` and `file-manifest.jsonl`. See `docs/02-file-generation.md`
4. **Folder creation** — walk folder-manifest, create directories
5. **File creation** — parallel workers: magic-byte header + sparse body
6. **Timestamp application** — set btime/mtime/atime consistently
7. **Owner application** — apply ownerSid per file
8. **ACL application** — folder-level ACLs + mess patterns. See `docs/03-acl-design.md`
9. **Orphan pass** — delete the ~12 terminated users so their SIDs become unresolvable
10. **Verification** — `Test-AcmeData.ps1` produces `verification.json`

Orchestration details and the master script shape in `docs/05-orchestration.md`.

## Coding standards

- PowerShell 7+ (`pwsh`), not Windows PowerShell 5.1
- Functions use approved verbs (`Get-`, `Set-`, `New-`, `Build-`)
- Script-level `[CmdletBinding()]` + `param()` blocks
- `#Requires -Version 7.0` at top of every script
- `$ErrorActionPreference = 'Stop'` at top of every script
- Explicit parameter types, explicit return types where non-obvious
- Progress via `Write-Progress` for long-running phases
- Logs go to `manifests/logs/` (gitignored), timestamped, one per phase
- All paths handled with `Join-Path`, never string concatenation
- No aliases in committed code (`ForEach-Object` not `%`, `Where-Object` not `?`)
- Comment-based help on every exported function

## Working with the decision log

`docs/decisions.md` is the source of truth for why things are the way they are. Read it before making choices. If you make a new decision during implementation that wasn't covered by the spec, append to it (new entry at top, D-NNN incrementing).

## What to do when in doubt

Ask. In this repo, the humans are architects and PMs — they'd rather answer a quick question than unwind a wrong implementation.

## What NOT to do

- Don't add fake PII content to files (headers only)
- Don't generate fully-valid openable Office documents (magic bytes are enough)
- Don't try to run generation on Linux/Mac
- Don't pull in Python or any non-PowerShell runtime for generation
- Don't query AD during the file-creation hot path — use the manifest
- Don't hardcode config values
- Don't optimize prematurely; but also don't ship single-threaded "for now"
