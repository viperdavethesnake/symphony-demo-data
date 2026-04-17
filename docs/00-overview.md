# 00 — Project Overview

## Purpose

Generate a realistic, messy, enterprise-scale NAS dataset for demonstrating **Panzura Symphony**. Symphony connects to the dataset over SMB and performs file assessment — metadata, timestamps, sizes, file type distribution, ACLs, group/user ownership, duplicate detection, and cold-data identification.

The generator's job is **preparation**, not the demo itself. It runs once (overnight), the VM is snapshotted, and every future demo starts from a clean snapshot restore.

## Demo value props the dataset is tuned for

Everything in the generator is designed to make one of these three stories pop on Symphony's dashboard:

### 1. Cold data discovery (tiering / archive)
- **80% of files are older than 2 years**
- Long tail: 20% are 10+ years old
- `atime`, `mtime`, `btime` (creation) all consistent — `btime ≤ mtime ≤ atime`
- A small % of files with ancient `mtime` but recent `atime` (backup/scanner touched them) — demonstrates the nuance of using atime vs mtime for tiering decisions

### 2. Broken ACLs and oversharing
- Deliberate ACL mess across ~15–20% of folders
- Patterns: `Everyone:Read` on sensitive folders, orphaned SIDs from deleted users, broken inheritance, direct-user ACEs instead of groups, owner mismatches, conflicting allow/deny ACEs

### 3. Space-by-user, group, and file type
- Pareto ownership: 10% of users own ~60% of bytes
- A few "hoarders" with hundreds of GB of personal media / old backups
- File-type skew: ~60% of files are Office docs but consume <10% of space; 5 extensions (ISO, VHDX, MP4, PSD, ZIP) eat ~70% of capacity

## Scale

| Metric | Value |
|---|---|
| Total files | 10,000,000 |
| Total folders | ~50,000–100,000 |
| AD users | 400 (356 active, 32 disabled, 12 terminated/orphaned) |
| AD groups | ~40 |
| Logical size (reported by Symphony) | ~1 PB |
| Physical size in VHDX | ~70–90 GB |
| Compressed on ZFS | ~30–50 GB |

## Architecture

### Single VM, multiple roles
One Windows Server 2022 VM. Role consolidation is intentional — this is a demo lab, not production.

- **AD DS** — domain controller for `acme.local`
- **DNS** — integrated, authoritative for the domain
- **File Services** — hosts `S:\Share` exposed over SMB

### Storage
- VHDX on 4 TB NVMe, dynamic-expanding, 200 GB provisioned for `S:` to leave MFT headroom
- Backing store is ZFS with lz4 or zstd compression
- NTFS sparse flag enabled on `S:\Share` before generation
- `S:` formatted with 4 KB clusters and large file records (`format S: /FS:NTFS /A:4096 /L /Q`)

### Generation pipeline
All phases run on the Windows VM in PowerShell 7+.

1. **AD setup** — install roles, promote to DC, build OU tree, create users/groups (see `01-ad-design.md`)
2. **File manifest build** — plan every file's path, size, type, timestamps, owner, ACL from config + seed (reproducible)
3. **File creation** — parallel workers write magic-byte headers + sparse bodies
4. **Timestamp application** — set `btime` / `mtime` / `atime` in logically consistent order
5. **ACL application** — apply group/user ACEs per folder, inject deliberate ACL mess
6. **Orphan pass** — delete the ~12 "terminated" users, leaving their SIDs baked into file ownership and ACLs

### Config-driven
Every knob lives in JSON. No code changes to re-tune scale, age distribution, file-type mix, ACL mess rates, user counts, etc.

## Reproducibility

The generator is seeded. Given the same config and seed, it produces the same dataset. Makes the snapshot regenerable if the VM is lost.

## What's explicitly out of scope

- Fake PII content inside files (headers only; no fake SSNs, CC numbers, etc.)
- Openable Office documents (valid magic bytes, but not valid documents)
- Full-text content for deep content scanning
- Multi-site, multi-DC, replication
- NFS export (SMB only)
- Any trust or federation scenarios
