# symphony-demo-data — launch pack

Everything you need to stand up, run, and troubleshoot the Panzura Symphony demo dataset.

## What this is

A generator that produces a realistic, messy, **enterprise-scale NAS dataset** on a single Windows Server 2025 VM:

- **12.24 M files** across **7,217 folders**
- **1.58 PB logical** / **~746 GB physical** (NTFS sparse)
- Real AD domain (`acme.local`), 411 users, 38 groups, 12 intentionally-orphaned SIDs
- File-level + folder-level ACL mess patterns
- 15-year age distribution (80 % older than 2 years)

Built to demo three Symphony value props:

1. **Cold-data discovery** — 80/20 age split, tail to 15 years.
2. **Broken ACLs / oversharing** — orphaned SIDs, direct-user ACEs, broken inheritance, conflicting Allow/Deny, cross-department oversharing.
3. **Space-by-user / group / type** — Pareto ownership (hoarders), service accounts, heavy-hitter file types.

## Where to start

| You want to… | Read this |
|---|---|
| See the big picture | [02-architecture.md](02-architecture.md) |
| Stand up a VM from scratch | [01-requirements.md](01-requirements.md) → [03-workflow.md](03-workflow.md) |
| Rebuild on an already-provisioned VM | [03-workflow.md](03-workflow.md) § "Rebuild from scratch" |
| Run a single phase | [05-usage.md](05-usage.md) |
| Tune counts / mess rates | [06-configuration.md](06-configuration.md) |
| Know why this is PowerShell, not Python | [04-why-powershell.md](04-why-powershell.md) |
| Debug a failed run | [07-troubleshooting.md](07-troubleshooting.md) |
| Know what's *not* perfect | [08-known-limitations.md](08-known-limitations.md) |

## Repo map

```
symphony-demo-data/
├── config/            knobs (main-config.json + sub-configs)
├── docs/              design docs (00–06) + decisions.md log
├── launch/            you are here
├── scripts/           the PowerShell pipeline
└── manifests/         runtime artifacts (gitignored)
    ├── ad-manifest.json         users/groups/SIDs (post AD build)
    ├── folder-manifest.json     7.2k folders (post share build)
    ├── logs/                    timestamped per-phase logs
    └── RESUME.md                session-handoff notes
```

## Current state

Live VM has a finished 12.24 M-file dataset. See `manifests/RESUME.md` for the last-known-good state and exact rebuild commands.
