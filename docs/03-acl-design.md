# 03 — ACL Design

ACLs are the second-biggest value prop Symphony has. The dataset must contain a specific, deliberately-crafted mess that makes Symphony's ACL analysis discover real problems. Random ACL assignment won't do it — the patterns have to be recognizable as the things enterprise storage admins actually wring their hands over.

## What Symphony is looking for

Based on the product materials, Symphony's ACL analysis surfaces:
1. Sensitive folders exposed to too-broad groups (oversharing)
2. Access controlled by ACEs that no longer resolve (orphaned SIDs)
3. ACL inheritance broken in unexpected places
4. Individual user ACEs where group ACEs should exist (sprawl)
5. Owners who don't make sense (random user owning a shared folder)
6. Allow + Deny collisions creating unclear effective permissions

We plant all six, at configurable rates, on folders that make each pattern tell a story.

## Baseline: the "correct" ACL model (AGDLP)

Most folders follow Microsoft's recommended AGDLP pattern:

- **A**ccount → member of **G**lobal group
- **G**lobal group → member of **D**omain **L**ocal group
- **D**omain local group → granted **P**ermission on resource

In this dataset:
- Users → Department global groups (`GRP_Engineering`) → Resource domain local groups (`GRP_EngineeringBuildsRW`) → ACE on folder

"Clean" folders get only resource groups on their ACLs. Mess patterns deliberately violate this.

## The six mess patterns

All percentages apply **per folder** (not per file). With ~50k–100k folders, 5% oversharing = 2,500–5,000 oversharing violations. That's enough for Symphony's dashboard to show meaningful counts.

### 1. Oversharing (`oversharePercent`: 5%)

Broad groups granted access to sensitive folders. Variants:

| Variant | ACE | Target folders |
|---|---|---|
| Everyone can read | `Everyone:Read` | Finance/Payroll, HR/Employees, Legal/Contracts, Executive, IT/Credentials |
| Authenticated Users can modify | `Authenticated Users:Modify` | Finance (broadly), HR (broadly) |
| Domain Users full control | `Domain Users:FullControl` | A few random folders — the "someone fat-fingered it" pattern |
| `GRP_AllStaff` on exec content | `GRP_AllStaff:Read` | Executive subfolders |

Target mix:
- 40% Everyone:Read on obviously-sensitive folders (the headline slide)
- 25% Authenticated Users:Modify
- 15% Domain Users:FullControl (rare but dramatic)
- 20% AllStaff on exec content

### 2. Orphaned SIDs (`orphanedSidPercent`: 3%)

Generated as a consequence of the orphan pass (phase 2h) — the ~12 terminated users were referenced as ACL entries and/or file owners before deletion. After deletion, those SIDs remain on disk as unresolvable.

Implementation:
- During ACL planning, a percentage of ACL entries reference terminated users directly (as individual ACEs)
- Some folders have terminated users as **owner** (compounds with pattern 5 below)
- After phase 2h deletes the terminated users from AD, all those ACEs become orphaned

Distribution: spread widely, not clustered. A handful in every department.

### 3. Broken inheritance (`brokenInheritancePercent`: 4%)

Child folders with inheritance disabled and a divergent ACL. Three sub-variants:

| Variant | Pattern |
|---|---|
| Stricter than parent | Child blocks inheritance, has narrower ACL (legit-looking but creates confusion — parent says anyone in dept, child says only managers) |
| Looser than parent | Child blocks inheritance, adds wider access (Everyone:Read where parent was just the dept group) |
| Completely unrelated | Child blocks inheritance, ACL has totally different groups than parent (the "we used this folder for a project and never cleaned it up" pattern) |

Target mix: 40% stricter, 35% looser (dangerous), 25% unrelated.

Apply preferentially in nested structures 3+ levels deep.

### 4. Direct-user ACEs (`directUserAcePercent`: 6%)

Individual users granted explicit permissions on folders instead of going through a group. The "I just added Bob because he asked" pattern.

Variants:
- Single user ACE with Modify or FullControl on a shared folder
- Multiple user ACEs accumulated over time on the same folder (sprawl)
- User ACE for someone **not in that department** — the cross-dept favor pattern
- User ACE still present after the user transferred to another department

Distribution: 60% single user, 25% multi-user sprawl (3–5 users on same folder), 15% wrong-department.

### 5. Owner mismatches (`ownerMismatchPercent`: 10%)

NTFS file/folder owners that don't match expected administrative patterns. Variants:

| Variant | Pattern |
|---|---|
| Random user as owner | Some random rank-and-file employee owns a shared folder instead of the dept group or an admin |
| Ex-admin owner | Someone who used to be an admin (but is now a regular user) owns an important folder |
| Service account as owner of user content | `svc_backup` or `svc_scanner` owns folders it should not "own" |
| Terminated user as owner | User was deleted — owner now shows as unresolvable SID (overlaps with pattern 2) |

Target mix: 40% random user, 20% ex-admin, 25% service account, 15% terminated.

Owner mismatches apply at both folder and file level. Most at folder level.

### 6. Conflicting allow/deny (`conflictingAcePercent`: 1%)

Rare but dramatic. Explicit Deny ACEs that contradict inherited Allow ACEs, or vice versa.

Example: parent folder grants `GRP_Engineering:Modify`. Child folder adds `GRP_Engineering:Deny Write`. Effective: most engineering can read but not write. The "someone got locked out and nobody knows why" pattern.

Keep rare (1%) but always place them in folders where they'd actually cause user pain — Engineering build folders, Finance reporting, etc.

## Standard folder ACL templates

For the ~80% of folders without mess patterns, apply a clean template based on folder type.

### Department root (e.g. `S:\Share\Departments\Engineering`)
```
CREATOR OWNER        : FullControl (container inherit only)
SYSTEM               : FullControl
Domain Admins        : FullControl
GRP_EngineeringBuildsRW : Modify
GRP_Engineering      : ReadAndExecute
```

### Department subfolder (standard)
Inherits from department root. No explicit ACEs.

### Cross-department shared project
```
CREATOR OWNER        : FullControl
SYSTEM               : FullControl
Domain Admins        : FullControl
GRP_ProjectApollo    : Modify
```

### Sensitive subfolder (Finance/Payroll, HR/Employees, Legal/Contracts)
```
SYSTEM               : FullControl
Domain Admins        : FullControl
GRP_HRPayroll        : FullControl   (for Payroll)
GRP_HREmployeeRecords: Modify        (for EmployeeRecords)
(Inheritance blocked — these folders do NOT inherit from parent)
```

Note: the "correct" sensitive folders block inheritance legitimately. The **broken inheritance** mess pattern applies elsewhere — normal folders that oddly block inheritance.

### Public (`S:\Share\Shared\Public`)
```
SYSTEM               : FullControl
Domain Admins        : FullControl
GRP_AllStaff         : Modify
```

### Scratch (`S:\Share\Shared\Scratch`)
```
SYSTEM               : FullControl
Domain Admins        : FullControl
GRP_AllStaff         : FullControl (creator-owner scoped)
Everyone             : Read
```
(This one gets the "Everyone can read scratch" ACE legitimately — it's a scratch share.)

### Archive (`S:\Share\Shared\Archive`)
```
SYSTEM               : FullControl
Domain Admins        : FullControl
GRP_AllStaff         : Read
GRP_ITAdmins         : Modify
```

## File-level ACLs

Most files inherit from their folder. A small % (~0.5% of files) have **explicit** file-level ACEs — usually as part of the direct-user pattern or conflicting ACE pattern. File-level ACEs are expensive to set at scale, so we keep this rate deliberately low.

## Application strategy

### Order
1. Apply clean ACL templates to all folders (walk folder tree, stamp template by folder type)
2. Apply mess patterns on top of the clean baseline — pick target folders per pattern's target list
3. Set file-level ACEs for the ~0.5% of files that need them
4. Set owners (phase 2f from file-generation spec) — may overlap with owner mismatch pattern here

### Mechanics

**Clean ACL application:**
- Use `[System.IO.Directory]::GetAccessControl()` + `SetAccessControl()` from PowerShell — faster than `icacls` for folder-level work
- For maximum speed, P/Invoke `SetNamedSecurityInfo` and build ACLs from raw SID byte arrays (skips name resolution entirely)

**Mess pattern application:**
- Pre-compute the SID for every well-known principal (Everyone = `S-1-1-0`, Authenticated Users = `S-1-5-11`, Domain Users = `<domain-sid>-513`, etc.)
- Load all group SIDs from `manifests/ad-manifest.json` once at startup
- Apply patterns by folder category, not per-folder-iteration — select N random target folders for pattern X, stamp them in parallel

### Parallelism
- Folder ACL application is parallel-safe (each folder independent)
- Use `ForEach-Object -Parallel` with same throttle as file creation
- File ACLs: same, but batched

### Performance budget
50k–100k folders at 1–3ms per ACL write = 1–5 minutes for clean pass. Mess patterns add ~500–1500 ACL writes = seconds. File-level ACLs at ~50k files × 1ms = under a minute. Total ACL phase: **~10–15 minutes** including Get-Acl reads.

## Verification pass

After all ACLs are applied, run a verification that:
- Counts ACEs by type (group/user/well-known/orphaned)
- Reports distribution vs target percentages from config
- Writes `manifests/logs/acl-summary.json`
- Flags any folder with no ACL at all (shouldn't happen)

This summary becomes the "ground truth" that you can compare Symphony's findings against during the demo — handy for SEs to explain what they're looking at.

## Open questions

1. Do we want a small % of ACLs that reference **legacy well-known SIDs** like `BUILTIN\Users` or `BUILTIN\Power Users`? Some old enterprise shares have these. Flag if you want me to add this as pattern 7.
2. For the "ex-admin" owner variant in pattern 5: do you want specific ex-admin users modeled in the AD manifest (e.g. one or two users who have `wasAdmin: true`)? Easy to add but needs to be designed into the AD generation phase.

Answer inline or skip and let Claude Code flag if it matters.
