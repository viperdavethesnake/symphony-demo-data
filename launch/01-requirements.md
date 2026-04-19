# 01 — Requirements

## Host hypervisor

- KVM / Proxmox / Hyper-V / VMware — anything that can run a Windows Server 2025 guest with a 2 TB virtio disk.
- At least **8 vCPUs, 32 GB RAM** on the host allocated to this VM. The build uses 24 parallel runspaces during Phase B.

## Guest VM

| Spec | Minimum | What we used |
|---|---|---|
| OS | Windows Server 2025 | Windows Server 2025 Standard 10.0.26100 |
| vCPUs | 8 | 24 (matches `scale.parallelThreads` = 24) |
| RAM | 16 GB | 32 GB |
| System disk | 60 GB | 100 GB |
| Data disk | 1 TB | 2 TB (`S:` drive, virtio) |

Disk sizing math:
- 12 M files × 4 KB cluster minimum ≈ 48 GB headers
- Markers at high offsets (ISO at 32769) allocate extra clusters
- Sparse tails ≈ 0 bytes
- **Total: ~750 GB physical for a full 10 M-file build** — leave margin for ACL metadata growth.

## Required Windows roles / features

All installed via `Install-WindowsFeature` on the VM during Phase 0:

- **AD DS** (Active Directory Domain Services) — hosts `acme.local`
- **DNS Server** — paired with AD DS
- **File Server** + **File and Storage Services**
- **RSAT-AD-PowerShell** — Build-AcmeAD uses this module

Plus:
- **PowerShell 7** (`pwsh`) from winget or the MSI. Windows PowerShell 5.1 is **not** sufficient (ForEach-Object -Parallel, PS7-only APIs).
- **.NET Core** ships with PS7.

## Windows Defender

Must be **fully disabled** on the lab VM (see D-047). Live-scanning 12 M file creations tanks throughput and, in prolonged runs, can throw transient AV holds on File.Create. `scripts/Disable-AcmeDefender.ps1` does the three-layer disable (prefs + policy regkeys + exclusions). Tamper Protection must be off first or preference writes silently revert.

## Disk format

`S:` must be formatted with:

- NTFS, GPT partition style
- **4 KB allocation unit** (not 64 KB — saves ~600 GB at scale)
- **UseLargeFRS** enabled (bigger MFT records, less fragmentation at 12 M files)
- **8.3 name creation disabled**
- **Last-access updates disabled**
- **Indexing disabled** (Windows Search on 12 M files is fatal)
- **Compression disabled** (conflicts with sparse flag semantics)
- `S:\Share` sparse flag set

`scripts/Initialize-AcmeDisk.ps1 -DiskNumber <N> -Force` does all of this in one shot.

## Repo prerequisites

- `git` on the VM
- Clone into `C:\Users\Administrator\Downloads\symphony-demo-data` (or adjust paths accordingly — configs use absolute `S:\Share`)
- Run PowerShell scripts as the **domain admin** you created during AD setup (`demo.admin` by default). The scripts need Remove-ADUser rights, WRITE_OWNER privilege, and SeRestorePrivilege to write arbitrary owner SIDs.

## Network / domain

- VM is a stand-alone DC hosting its own domain (`acme.local`, NETBIOS `ACME`).
- No cross-domain trusts, no internet required after setup.
- RDP is enough to operate it. No other inbound services needed.

## Not required

- SQL Server
- IIS
- Any non-PowerShell runtime (no Python, no Node, no WSL)
- A real file-server role beyond the File Services feature. We don't expose SMB shares — Symphony scans the local filesystem directly.
