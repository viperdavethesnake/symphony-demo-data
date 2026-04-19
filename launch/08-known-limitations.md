# 08 — Known limitations

Things that are *not* broken but worth knowing.

## Sparse ratio: ~2,000:1, not 20,000:1

CLAUDE.md's original target was 20,000:1 (1 PB logical / 50 GB physical). Reality at 12 M files: 1.58 PB logical / 746 GB physical = **2,113:1**.

Why lower:
- 4 KB cluster minimum × 12 M files ≈ 48 GB just for headers.
- Some ext headers are >1 KB (PSD, various archives), forcing multiple clusters at offset 0.
- Markers at high offsets (ISO `markerOffset: 32769`, WAV/AVI at 8, TAR at 257) allocate extra clusters where the marker lands.
- NTFS MFT records grow with file count (LargeFRS keeps this bounded but still ~30 GB).

Not a bug, just physics of NTFS at this scale. Fits comfortably in a 2 TB drive.

## Dup pass is single-threaded

Per D-029 / `docs/06-streaming-rewrite.md`, the duplicate pass is intentionally sequential. At 10 M files it's ~40 min, which dominates the second half of the `share` phase. Parallelizing would require cross-runspace coordination (the target folder is in another chunk's territory) and the spec explicitly said "not worth it."

Live with the 40 min unless someone rewrites the dup pass into an independent phase with its own folder ownership.

## No mid-`share` resume

If Build-AcmeShare crashes at Phase B file 7,000,000, you wipe and restart. There's no checkpoint file, no per-folder "done" marker. The failure model is: succeed, or rm -rf S:\Share. Snapshots, not manifests, are the safety net.

## The 4 baked-explicit ACEs on every file

Every generated file has 4 **explicit** ACEs that can't easily be removed:

```
NT AUTHORITY\SYSTEM                    FullControl
BUILTIN\Administrators                 FullControl
BUILTIN\Users                          ReadAndExecute, Synchronize
ACME\Administrator                     FullControl
```

These are the NTFS process-default DACL that `File.Create` materializes. Any call to `SetNamedSecurityInfo` with `OWNER | DACL | UNPROTECTED` preserves them as explicit (the v0.2.1 fix uses this flag combo). Removing them would require an additional `SetAccessControl` per file with a custom DACL — adds 2× the syscalls in the hot path.

These are cosmetically on top of the real ACEs that matter (the inherited ones from the folder, which carry the mess patterns). They don't affect the demo stories.

## `unclassifiedFiles` count ~1 %

`verification.json` reports `unclassifiedFiles: ~160,000` out of 12 M. These are files whose `Path.GetExtension(filename)` returns something the `filetypes.json` catalog doesn't know.

Root causes:
- **`Thumbs.db` collision renames.** The pattern is literal `Thumbs.db`; when multiple land in the same folder, `Thumbs-17.db` is generated. Ext = `.db`; the catalog keys it as `thumbs_db` (not `db`) → unclassified.
- **`.DS_Store` collision renames.** Becomes `.DS_Store-17` → `Path.GetExtension` returns `.Store-17`, entirely unexpected.
- **Version-drift siblings with weird suffix interactions.** `Report.docx_FINAL_v2` → ext = `.docx_FINAL_v2`.

Doesn't break generation or verification `pass`; just shows up as a non-zero `unclassifiedFiles` in the report. Fix would be a smarter classifier in Test-AcmeData (filename-pattern fallback when ext lookup misses).

## Junk category undercount (3.58 % vs 5 % target)

Same root cause as above — collision-renamed `Thumbs.db` / `.DS_Store` files get classified as `unclassified` instead of `junk`. Real junk-file count is roughly on target; the distribution report just slices them wrong.

## `group not found` silence pattern

Set-AcmeACLs' dept-root template probes `GRP_${dept}BuildsRW` and `GRP_${dept}ReadWrite` before falling back to `GRP_${dept}`. Most departments have only the third. v0.2.1 passes `-Silent` on the first two probes so only a genuinely-broken AD shows WARNs. If you add a new dept that has one of the RW/ReadOnly groups, the fallback will find it automatically.

## Terminated-user ACL references: probabilistic

`acl.orphanedSidPercent: 3` means 3 % of folders (~215 at 7,217) get an ACE referencing *one of the 12 terminated users*. Some users will show up in many folders, others in none. This is demo-real (employees leave, their explicit ACEs outlive them) but it's not deterministic per-user.

## Determinism caveat

"Same seed + same config = same dataset" is true in principle but not bit-exact. Sources of non-determinism:
- OS scheduling of parallel runspaces → file creation order within a folder varies.
- Collision-rename suffixes depend on insertion order.
- AD user/group SIDs depend on what the DC assigns.

What's deterministic: folder tree shape, per-folder file counts, ext/size/age/owner distributions, ACL mess patterns, and which 12 users are terminated.

## What this dataset is NOT

- **Not for performance testing.** Files are mostly zeros; read throughput is meaningless.
- **Not for security / DLP scanning that needs real content.** Magic bytes only.
- **Not SMB-exposed.** `S:\Share` is local-only. Symphony reads the filesystem directly.
- **Not domain-joined to anything real.** `acme.local` is self-contained.
- **Not password-strong.** `Acme!Pass2026` is in plain text in `main-config.json`. Lab only.

## Script re-runs in place

- `Build-AcmeAD.ps1` is idempotent. Re-running doesn't duplicate users.
- `Build-AcmeShare.ps1` is NOT idempotent. Re-running into a populated tree will fail mid-Phase-B on file-exists collisions. Wipe first.
- `Set-AcmeACLs.ps1` replaces folder DACLs (plus inheritance). Re-running is safe but re-randomizes mess patterns (different seed-derived folders get messed up).
- `Remove-AcmeOrphans.ps1` is safe to re-run (already-gone users skip silently).
- `Test-AcmeData.ps1` is always safe.

## Committed password

Yes, `config/main-config.json` has `"password": "Acme!Pass2026"` in plaintext. This is a **lab-only tool**. If you're tempted to use it in a non-lab environment, don't — but also, rotate the password and encrypt the config first.
