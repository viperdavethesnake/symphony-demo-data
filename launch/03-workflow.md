# 03 — Workflow

End-to-end sequence. First-time setup runs every step; re-runs skip the one-shot VM bootstrap bits.

## From-zero bootstrap (new VM)

All commands run from `C:\Users\Administrator\Downloads\symphony-demo-data` in an elevated `pwsh` shell.

### 1. Format the data disk (one-shot)

```powershell
pwsh -File .\scripts\Initialize-AcmeDisk.ps1 -DiskNumber 1 -Force
```
Brings disk online, GPT, 4 KB NTFS + LargeFRS, `AcmeShare` label, disables 8.3 / last-access / indexing, creates `S:\Share` with sparse flag. ~5 seconds. See `docs/04-vm-provisioning.md` Phase 3 for the locked parameter matrix.

### 2. Disable Defender (one-shot)

Tamper Protection must already be off (check Windows Security UI). Then:
```powershell
pwsh -File .\scripts\Disable-AcmeDefender.ps1
```
Three-layer disable: `Set-MpPreference` + policy regkeys + exclusions (D-047). Within ~5 seconds `Get-MpComputerStatus` should show `AntivirusEnabled: False`.

### 3. Install AD DS role + promote to DC

Not scripted — do this manually via Server Manager or `Install-WindowsFeature`. Reboot. Promote to DC of a fresh forest `acme.local`. Log back in as `ACME\Administrator`.

### 4. Build AD

```powershell
pwsh -File .\scripts\Build-AcmeAD.ps1 -ConfigPath .\config\main-config.json
```
Creates OUs, 411 users, 38 groups, nesting, role memberships. Emits `manifests/ad-manifest.json`. ~1–2 minutes. Idempotent (check-before-create).

### 5. Snapshot the VM

Recommended label: `01-ad-populated`. This is the fallback point if you want to re-run data generation with different config.

### 6. Build the data

```powershell
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json -RunOrphans
```
Runs phases in order: `share` → `2g` (ACLs) → `2h` (orphans, because of `-RunOrphans`) → `verify`. **~2 h 20 min at 10 M files.** Exit 0 = verification PASS.

### 7. Verify manually

Skim `manifests/logs/verification.json`. Spot-check a few files on disk:

```powershell
Get-ChildItem S:\Share -Recurse -File | Get-Random -Count 5 | ForEach-Object {
    $a = Get-Acl -LiteralPath $_.FullName
    "{0}  owner={1}  ACEs={2}" -f $_.Name, $a.Owner, @($a.Access).Count
}
```

You should see varied owners (different users, not all `Administrator`), ACE counts in the 10–16 range (4 baked + 6+ inherited from folder).

### 8. Point Symphony at `S:\Share` and demo.

## Rebuild from scratch (keep the DC)

You've changed config (different file count, different mess rates, different AD layout) and want a fresh dataset. AD itself is fine.

```powershell
# Wipe (reformat is faster than Remove-Item at 10M scale — D-029)
pwsh -File .\scripts\Initialize-AcmeDisk.ps1 -DiskNumber 1 -Force

# Clean stale artifacts
Remove-Item manifests\folder-manifest.json -Force -ErrorAction SilentlyContinue
Get-ChildItem manifests\logs -Directory -Filter 'share-chunks-*' | Remove-Item -Recurse -Force
Remove-Item manifests\logs\failures.jsonl, manifests\logs\share-summary.json -Force -ErrorAction SilentlyContinue

# Rebuild — skip AD since already populated, skip orphans if already deleted
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json -SkipPhase @('ad','2h')
```

If the AD teardown already deleted the 12 terminated users in a prior run, skip `2h` (running it again is harmless but logs "already gone" warnings). If you've rebuilt AD from scratch, drop `-SkipPhase` on `2h` or pass `-RunOrphans` instead.

## Partial re-runs

The orchestrator's `-SkipPhase` is the escape hatch for every partial path.

| Want to… | Command |
|---|---|
| Re-apply ACLs only | `Build-AcmeData.ps1 -SkipPhase @('ad','share','2h')` |
| Re-verify only | `Build-AcmeData.ps1 -SkipPhase @('ad','share','2g','2h')` |
| Rebuild data, keep ACLs-on-demand | `Build-AcmeData.ps1 -SkipPhase @('ad','2g','2h','verify')` then separately run ACLs |
| Run share in isolation with a smaller count | `pwsh -File .\scripts\Build-AcmeShare.ps1 -ConfigPath …\main-config.json -MaxFiles 100000` |

## Dev iteration

`config/main-config.dev.json` overrides `scale.totalFiles = 2000` and throttle = 4. Same `S:\Share` target. A full dev run (`share + 2g + verify`) takes ~15 seconds. Use this to validate script changes before blowing an hour on prod scale.

```powershell
# Wipe + dev rebuild loop
pwsh -File .\scripts\Initialize-AcmeDisk.ps1 -DiskNumber 1 -Force
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.dev.json -SkipPhase @('ad','2h')
```

## Where things live during/after a run

```
manifests/
├── ad-manifest.json                          stable once AD is built
├── folder-manifest.json                      regenerated each share run
├── ad-manifest.json.orphan-pass-<stamp>      snapshot when 2h runs
└── logs/
    ├── run-<stamp>.log                       orchestrator top-level
    ├── share-<stamp>.log                     Build-AcmeShare log
    ├── share-chunks-<stamp>/chunk-NNNNN.log  per-runspace (one per thread)
    ├── share-summary.json                    counts + bytes + rate
    ├── acls-<stamp>.log
    ├── acl-summary.json                      mess-pattern counts
    ├── orphans-<stamp>.log
    ├── orphans-summary.json
    ├── verify-<stamp>.log
    ├── verification.json                     PASS/FAIL report
    ├── failures.jsonl                        merged per-file errors
    └── run-summary.json                      per-phase timings
```

## Expected timings (10 M files, 24 threads)

| Phase | Elapsed | Notes |
|---|---|---|
| `ad` | 1–2 min | Skipped on re-runs |
| `share` Phase A | < 5 s | Folder tree + mkdir |
| `share` Phase B | ~60 min | Parallel file create |
| `share` dup pass | ~42 min | Single-threaded by spec |
| `2g` | ~33 min | Folder apply + file-level ACE apply |
| `2h` | < 1 s | 12 ADUser deletes |
| `verify` | ~45 s | Streams 12 M files in ~40 s |
| **Total** | **~2 h 20 min** | |

Dev scale (`main-config.dev.json`, 2 k files): whole pipeline in < 15 s.
