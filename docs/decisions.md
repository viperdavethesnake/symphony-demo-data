# Decision Log

Running log of decisions made during design. Newest at top.

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
