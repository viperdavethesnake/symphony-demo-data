# symphony-demo-data

A generator for a realistic, messy, enterprise-scale NAS dataset used to demo **Panzura Symphony**.

Builds a fake company (**Acme Corp**, `acme.local`) on a single Windows Server VM that acts as Domain Controller, DNS server, and SMB file server. Populates Active Directory with users, groups, service accounts, disabled accounts, and terminated-but-orphaned accounts. Generates ~10 million files under `S:\Share` with realistic folder structure, file types, sizes, timestamps, duplicates, and broken ACLs.

## What this demo is designed to show

Symphony's three highest-value stories, tuned into the dataset on purpose:

1. **Cold data discovery** — 80% of files are older than 2 years, with a long tail out to 15 years. Easy to demo tiering and archive recommendations.
2. **Broken ACLs and oversharing** — deliberate mess: `Everyone:Read` on Payroll, orphaned SIDs from deleted users, broken inheritance, direct-user ACEs, owner mismatches.
3. **Space-by-owner, group, and file type** — Pareto-distributed ownership (10% of users own 60% of bytes), a handful of fat file types (ISO/VHDX/video) dwarf the file count of Office docs.

## Scale

- **10 million files**
- **~1 PB logical** (what Symphony reports)
- **~70–90 GB physical** inside the VHDX (NTFS sparse files)
- **~30–50 GB** on the ZFS backing store after lz4/zstd compression

## Stack

- Windows Server 2022 VM (single box: AD DS + DNS + File Services)
- PowerShell 7+ for all generation (AD setup, file creation, ACL application, timestamps)
- JSON config files drive every knob — no code changes needed to re-tune

## Layout

```
symphony-demo-data/
├── README.md
├── docs/
│   ├── 00-overview.md         ← project scope, architecture, value props
│   ├── 01-ad-design.md        ← Active Directory spec
│   ├── 02-file-generation.md  ← (TBD) file gen architecture
│   ├── 03-acl-design.md       ← (TBD) ACL patterns
│   ├── 04-vm-provisioning.md  ← (TBD) VM build steps
│   └── decisions.md           ← running log of decisions
├── config/
│   ├── main-config.json       ← primary knobs
│   └── filetypes.json         ← (TBD) extension → header/size table
├── scripts/                   ← PowerShell generators (TBD)
└── manifests/                 ← runtime artifacts (gitignored)
```

## Getting started (on the Windows VM)

Not yet — scripts are still being designed. See `docs/` for the current spec.

## Roles

- **Architects / PMs**: author specs and configs in `docs/` and `config/`
- **Builders**: Claude Code on the Windows VM implements against the spec in `scripts/`
