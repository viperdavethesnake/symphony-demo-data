# 07 — Troubleshooting

## Run failed — where do I start?

1. Read the orchestrator log: `manifests/logs/run-<stamp>.log`. It'll show `[phase] FAILED: <message>` for the offending phase.
2. Read the per-phase log: `<phase>-<stamp>.log`. Usually has the actual stack trace.
3. For `share` phase failures: also check `manifests/logs/share-chunks-<stamp>/chunk-NNNNN.log` for per-runspace output and `chunk-NNNNN-failures.jsonl` for per-file errors.
4. Aggregated errors merge into `manifests/logs/failures.jsonl`.

## Phase-specific errors

### `share` phase

**`Cannot find type [Acme.NativeFsctl]`**
P/Invoke `Add-Type` didn't run in the runspace. Usually means the parent script's `Add-Type` block didn't complete before the parallel block. Re-run from a clean pwsh session.

**`The process cannot access the file because it is being used by another process`**
Antivirus is scanning file creates. Run `Disable-AcmeDefender.ps1` and verify `Get-MpComputerStatus.AntivirusEnabled` is `False`. Tamper Protection must be off first.

**`Failure rate X exceeds 0.1% threshold`**
Something systematic is wrong. Read the first 20 lines of `failures.jsonl` — they'll cluster on one root cause (missing folder, privilege issue, AV holding handles).

**Phase B finishes but disk usage is tiny**
Sparse isn't taking effect. Check `Get-Volume S` — `AllocationUnitSize` should be 4096. If the disk was formatted with a larger cluster or without the sparse flag on `S:\Share`, re-run `Initialize-AcmeDisk.ps1 -Force`.

### `2g` (Set-AcmeACLs)

**`The property 'meta' cannot be found on this object`**
`folder-manifest.json` is stale or truncated. Re-run the `share` phase (or run Build-AcmeShare standalone with `-MaxFiles 2000` to regenerate cheaply, then re-run ACLs).

**21 `group not found` WARNs**
Before v0.2.1, these were loud for `GRP_*BuildsRW` / `GRP_*ReadWrite` / `GRP_Projects` etc. — expected-missing probes with fallback. v0.2.1 silenced them. If you see them on v0.2.1+, some AD group is genuinely missing; cross-check `ad-manifest.json` `.groups[]` against the expected names.

**All files end up `protected=True` with only 4 ACEs**
This was the v0.2.0 bug — fixed in v0.2.1. If you see it on v0.2.1+, you're running outdated code or `SetOwner` isn't calling `GetNamedSecurityInfo` first. Run:

```powershell
$f = Get-ChildItem S:\Share -Recurse -File | Get-Random
$s = [System.IO.FileSystemAclExtensions]::GetAccessControl($f)
$s.AreAccessRulesProtected    # should be False on v0.2.1+
```

If `True`, remediate without a full rebuild:
```powershell
icacls S:\Share /inheritance:e /t /c /q
```
~15 min at 12 M files, native.

### `2h` (Remove-AcmeOrphans)

**`Exception calling "ShouldProcess" ... Object reference not set`**
v0.2.0 bug with strict mode + `-Force`. Fixed in v0.2.0→0.2.1 bridge. Pull latest.

**`deleted=0 alreadyGone=12`**
The orphan pass already ran in a previous session. Safe — no action needed. Files already have unresolvable SIDs.

**`failed=12` (all users)**
Likely privilege issue. You need `Domain Admins` or explicit Remove-ADUser permissions. Run as `ACME\demo.admin` or `ACME\Administrator`.

### `verify` phase

**`pass: false` with `checks.fileSample.magicMismatch > 0`**
A file's magic-byte header doesn't match its extension. Usually means the ext catalog (`filetypes.json`) has a typo in the `header` hex — or `Path.GetExtension` returned something unexpected for an odd filename (see the `db` / `.DS_Store` notes in [08-known-limitations.md](08-known-limitations.md)).

**`checks.aclSample.withoutAcl > 0`**
Some folder has zero ACEs. Something went wrong in Set-AcmeACLs. Re-run `-SkipPhase @('ad','share','2h','verify')` to reapply.

**`checks.distribution.fileTypePct.<cat>.actual` way off target**
Category miscount. Usually the `unclassifiedFiles` field is non-zero — filename patterns producing exts the catalog doesn't know (`Thumbs-17.db`, `.DS_Store-NN`). Cosmetic at < 2 % of total. See limits doc.

## Disk full

`S:` is 2 TB. A full 10 M-file build lands at ~746 GB. If you see ENOSPC mid-Phase-B, check:

```powershell
Get-Volume S | Select FileSystemLabel, Size, SizeRemaining
fsutil sparse queryflag S:\Share
```

If the share root doesn't have the sparse flag, headers and marker writes balloon. Re-format (`Initialize-AcmeDisk.ps1 -Force`) is the fix — faster than trying to retrofit sparse on 12 M existing files.

## "VM feels slow / paused"

Windows VMs under KVM/Proxmox can get paused during snapshot operations or clock-skew corrections. Symptoms: wall-clock elapsed on a command is hours longer than `[Stopwatch].Elapsed`. If you notice a huge gap between the two, the VM was suspended — not a bug in the scripts.

## "A phase hangs and won't produce output"

PS7 stdout buffering through `ForEach-Object -Parallel` can stall if a runspace is blocked. Check CPU via `Get-Process pwsh`. If CPU is pegged, it's grinding. If CPU is near 0 and mem is 10+ GB, the process may be stuck (check the Plan phase's historical 100-min grind on 10 M — that was real work, not a hang).

## Starting over cleanly

Nuclear option when something's subtly wrong and you don't want to debug it:

```powershell
# Kill any pwsh left from a botched run
Get-Process pwsh | Where-Object { $_.StartTime -lt (Get-Date).AddMinutes(-10) } | Stop-Process -Force

# Reformat S: — way faster than Remove-Item on 12M files
pwsh -File .\scripts\Initialize-AcmeDisk.ps1 -DiskNumber 1 -Force

# Clean manifests (keep ad-manifest if AD is still good)
Remove-Item manifests\folder-manifest.json -Force -ErrorAction SilentlyContinue
Get-ChildItem manifests\logs -Directory -Filter 'share-chunks-*' | Remove-Item -Recurse -Force
Remove-Item manifests\logs\failures.jsonl, manifests\logs\share-summary.json -Force -ErrorAction SilentlyContinue

# Re-run
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json -SkipPhase @('ad','2h')
```

## When in doubt

`docs/decisions.md` has the running decision log (D-001 through D-048+D-029). Many troubleshooting situations map to a decision entry that explains *why* something looks the way it does.
