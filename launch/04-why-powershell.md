# 04 — Why PowerShell

Short version: **only PowerShell on NTFS can cleanly set creation time (`btime`) and set a file owner to an arbitrary SID**, and we need both. Python and bash-over-WSL either can't or are markedly slower.

## btime (CreationTime)

NTFS has four timestamps: creation, last-write, last-access, change. POSIX has three (mtime / atime / ctime, where `ctime` = inode-change, not creation). On Linux / WSL, `touch` and friends can set mtime and atime but **not** NTFS's creation time — you'd have to go through the Windows API (`SetFileTime`) anyway.

From PowerShell 7 we get a one-liner per file:

```powershell
[System.IO.File]::SetCreationTimeUtc($path,  $btime)
[System.IO.File]::SetLastWriteTimeUtc($path, $mtime)
[System.IO.File]::SetLastAccessTimeUtc($path, $atime)
```

Three managed calls, each a single `SetFileTime` kernel call. `btime ≤ mtime ≤ atime` is enforced by the planner (see `docs/02-file-generation.md` → superseded `docs/06-streaming-rewrite.md`). Demo realism cares about creation-time — "this file was created in 2013, last touched in 2019" is the cold-data story.

## Arbitrary SID as owner

File ownership for the mess patterns needs to reference SIDs that don't belong to the current process — terminated users' SIDs, service accounts, users in other departments. That's privileged: the caller needs either `SeRestorePrivilege` (write any owner) or `SeTakeOwnershipPrivilege` (take ownership, then transfer). PowerShell + P/Invoke `SetNamedSecurityInfo` + `AdjustTokenPrivileges` is the shortest path.

```csharp
// scripts/Build-AcmeShare.ps1 — Acme.NativeOwner.SetOwner
SetNamedSecurityInfo(path, SE_FILE_OBJECT,
    OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION | UNPROTECTED_DACL_SECURITY_INFO,
    psid, IntPtr.Zero, pDacl, IntPtr.Zero);
```

`SeRestorePrivilege` is enabled at script start via `Acme.PrivilegeHelper.Enable('SeRestorePrivilege')`.

### The flag-combo subtlety (v0.2.1)

We initially called `SetNamedSecurityInfo` with only `OWNER_SECURITY_INFORMATION`. Windows silently bakes the current effective DACL into *explicit* ACEs and flips the `PROTECTED` bit — so files never inherited from their parent folder. The correct combo is `OWNER | DACL | UNPROTECTED`, and you have to supply a real `pDacl` (not `NULL` — that wipes to "Everyone:FullControl") so you `GetNamedSecurityInfo` first to retrieve the current DACL, then `Set` with the retrieved pointer. Two kernel calls per file, same semantics as `icacls /inheritance:e`. See the v0.2.1 commit for the full post-mortem.

## FSCTL_SET_SPARSE

`[System.IO.File]::Create` gives us a `FileStream`. `FileStream.SafeFileHandle` is what `DeviceIoControl(FSCTL_SET_SPARSE)` wants. Any language with P/Invoke could do this; PowerShell just happens to be the native shell on the target OS.

```csharp
// Acme.NativeFsctl.SetSparse
DeviceIoControl(handle.DangerousGetHandle(), 0x900C4,
    IntPtr.Zero, 0, IntPtr.Zero, 0, out bytesReturned, IntPtr.Zero);
```

## ACLs (managed API)

For folder ACL writes (Set-AcmeACLs) we use `System.Security.AccessControl.DirectorySecurity` / `FileSecurity` via `[System.IO.FileSystemAclExtensions]`. Clean managed API, handles inheritance flags correctly, supports `ContainerInherit` / `ObjectInherit` / `InheritOnly` / `NoPropagateInherit` without hand-rolling ACL binary format.

## RSAT-AD-PowerShell

`Build-AcmeAD.ps1` is 100 % `ActiveDirectory` module (`New-ADUser`, `New-ADGroup`, `Add-ADGroupMember`). Python alternatives exist (`ldap3`) but would add a runtime dependency, re-implement AGDLP nesting logic, and not integrate with the built-in AD DS provisioning flow.

## ForEach-Object -Parallel

PS7-only. Runspaces share the AppDomain, so `Add-Type` loads P/Invoke classes once and every worker sees them. No subprocess startup cost. 24 threads at ~130 files/sec/thread = ~3,100 files/sec aggregate end-to-end with all the syscalls. Python's `concurrent.futures` + `ctypes` could match it, but spawning 24 Python processes per batch would swamp the startup cost.

## Things we don't need any other language for

- Reading / writing JSON configs → `ConvertFrom-Json` / `ConvertTo-Json`.
- Streaming disk enumeration → `[System.IO.Directory]::EnumerateFiles` (lazy, fast).
- Reservoir sampling → 10 lines of PowerShell.
- Log-normal and weighted sampling → `System.Random.NextDouble()` + math.

## What we couldn't do in PowerShell cleanly

None of the above are pure-PS; they all P/Invoke. PowerShell is the glue that makes the P/Invoke calls cheap to chain and parallelize. The alternative would be a single C# executable, which we'd then have to ship, version, and sign — for a demo-data tool, the cost isn't worth it.

## Non-negotiables from CLAUDE.md

- `#Requires -Version 7.0` at the top of every script
- `$ErrorActionPreference = 'Stop'` — fail fast
- `Set-StrictMode -Version Latest` — undefined vars / out-of-range indexes throw
- No aliases in committed code (`ForEach-Object` not `%`, `Where-Object` not `?`)
- Comment-based help on every exported function
