# 04 — VM Provisioning

End-to-end checklist for building the Windows Server VM that hosts AD, DNS, and the SMB share. Written so someone (or Claude Code) can run it start to finish without improvising.

## Target VM specs

| Resource | Value |
|---|---|
| Hypervisor | Whatever hosts the ZFS-backed storage (Hyper-V, Proxmox, ESXi, etc.) |
| OS | Windows Server 2025 Standard (Desktop Experience) |
| vCPU | 8 |
| RAM | 16 GB |
| System disk (C:) | 80 GB, dynamic |
| Data disk (S:) | 200 GB VHDX, dynamic-expanding, on the 4 TB NVMe |
| Network | Single NIC, static IP, internal/isolated network preferred |
| Firmware | UEFI, Secure Boot optional |

System disk holds Windows + PowerShell + git. Data disk is dedicated to `S:\Share`. Separation makes snapshots cleaner and lets you throw away just the data disk if a regen is needed.

## Pre-install checklist

- [ ] 4 TB NVMe installed, ZFS dataset created with compression (lz4 or zstd)
- [ ] Hypervisor configured to place the data VHDX on the ZFS dataset
- [ ] Network isolated or firewalled — this VM will have a domain, don't accidentally collide with production AD

## Phase 0 — OS install and initial config

1. Install Windows Server 2025 Standard (Desktop Experience)
2. Set hostname: `panzura-sym01`
3. Set timezone correctly (UTC is fine, or match your demo venue)
4. Install all pending Windows Updates (reboot as needed)
5. Set a static IP on the NIC (e.g. `10.10.10.10/24`)
6. Set DNS server to `127.0.0.1` (will be self-resolved once AD is up)
7. Disable IE Enhanced Security Configuration (for admins, for sanity)
8. Fully disable Microsoft Defender — run `pwsh -File .\scripts\Disable-AcmeDefender.ps1` (elevated). AV scanning 10M file creates is catastrophic for throughput; Defender is disabled for everything via `Set-MpPreference` + Server-SKU policy registry keys. Tamper Protection must be OFF beforehand (Windows Security UI). See D-047.
9. Disable sleep / hibernation
10. Enable Remote Desktop if you want to RDP in

## Phase 1 — Install AD DS, DNS, File Services

```powershell
Install-WindowsFeature -Name AD-Domain-Services, DNS, FS-FileServer -IncludeManagementTools
```

Do **not** promote yet. Reboot if prompted.

## Phase 2 — Promote to Domain Controller

```powershell
Install-ADDSForest `
    -DomainName 'acme.local' `
    -DomainNetbiosName 'ACME' `
    -DomainMode 'WinThreshold' `
    -ForestMode 'WinThreshold' `
    # Note: on Windows Server 2025, the installer may raise these to 'Windows2025' —
    # that is fine, the live domain runs at Windows2025Domain/Windows2025Forest.
    -InstallDns `
    -SafeModeAdministratorPassword (ConvertTo-SecureString 'DemoPass!2026' -AsPlainText -Force) `
    -Force `
    -NoRebootOnCompletion:$false
```

VM reboots automatically and comes up as a DC. Log back in as `ACME\Administrator`.

Verify:
```powershell
Get-ADDomain
Get-ADForest
Resolve-DnsName acme.local
```

## Phase 3 — Prepare the data disk

In the hypervisor, attach the 200 GB VHDX (or raw-backed disk) as the VM's second disk. Everything from here is scripted — run `scripts/Initialize-AcmeDisk.ps1` and it handles online/init/format/flags/share-root.

### Format parameters (authoritative — see D-044)

| Parameter | Value | Why |
|---|---|---|
| Drive letter | `S` | Per spec |
| File system | NTFS | Required for sparse + ACLs |
| Partition style | GPT | 2 TB is under MBR's limit but GPT is modern default |
| Allocation unit size | 4096 (4 KB) | Required for sparse efficiency. 64 KB would waste ~60 KB per file × 10M = ~600 GB |
| Large FRS | Enabled | 1 KB MFT records vs 4 KB default. Holds more attributes inline, less fragmentation at 10M files |
| Volume label | `AcmeShare` | |
| Quick format | Yes | Full format would take hours for no benefit on a 2 TB disk |
| Compression | Disabled | NTFS compression conflicts with sparse flag semantics |
| Short (8.3) names | Disabled | Pure perf drag at 10M files |
| Last access updates | Disabled | We set atime deliberately; don't let the OS bump it |
| Indexing | Disabled | Windows Search would try to crawl 10M files |
| Sparse flag | Set on `S:\Share` | Documentation/insurance — the generator still sets sparse per-file via P/Invoke |

### Run it

```powershell
cd C:\Projects\symphony-demo-data
git pull
# Must be elevated
pwsh -File .\scripts\Initialize-AcmeDisk.ps1
```

If there's more than one RAW disk or you want to be explicit:

```powershell
pwsh -File .\scripts\Initialize-AcmeDisk.ps1 -DiskNumber 1
```

If a bad format needs to be redone (destructive — wipes the disk):

```powershell
pwsh -File .\scripts\Initialize-AcmeDisk.ps1 -DiskNumber 1 -Force
```

The script is idempotent when `S:` already exists — it reports state and ensures `S:\Share` + sparse flag are present, but will not wipe without `-Force`.

**Virtio gotcha:** on KVM/Proxmox, a freshly-attached raw-backed disk comes up offline and sometimes read-only. The script handles this by running `Set-Disk -IsOffline $false` / `Set-Disk -IsReadOnly $false` against any offline/read-only disk before initialization.

### SMB share

Deferred until AD build runs — `GRP_AllStaff` is created by `Build-AcmeAD.ps1`. After AD is populated:

```powershell
New-SmbShare -Name 'Share' -Path 'S:\Share' -FullAccess 'ACME\Domain Admins' -ChangeAccess 'ACME\GRP_AllStaff'
```

## Phase 4 — Tooling install

```powershell
# PowerShell 7 (via winget or direct MSI)
winget install --id Microsoft.PowerShell --source winget

# Git
winget install --id Git.Git --source winget

# RSAT is already present on Server 2022 as part of AD DS role tools
```

Open a fresh `pwsh` (not `powershell`) window from here on.

## Phase 5 — Clone the repo

```powershell
New-Item -Path 'C:\Projects' -ItemType Directory
Set-Location 'C:\Projects'
git clone https://github.com/viperdavethesnake/symphony-demo-data.git
Set-Location symphony-demo-data
```

## Phase 6 — Snapshot: "clean DC, empty share"

Take a hypervisor-level snapshot here. Named `00-clean-dc`. This is your fallback if anything downstream goes wrong — you can always revert here, not back to before AD was built.

## Phase 7 — Run the AD build

```powershell
pwsh -File .\scripts\Build-AcmeAD.ps1 -ConfigPath .\config\main-config.json
```

Expected duration: 2–3 minutes. Produces `manifests/ad-manifest.json`.

Verify:
```powershell
Get-ADUser -Filter * | Measure-Object  # should be ~422 (400 users + 10 service + system accounts)
Get-ADGroup -Filter * | Measure-Object  # should be ~40+ (plus built-in)
```

## Phase 8 — Snapshot: "AD populated"

Second snapshot, `01-ad-populated`. This is the state to revert to if you want to re-run file gen with different config knobs.

## Phase 9 — Run file generation

```powershell
pwsh -File .\scripts\Build-AcmeData.ps1 -ConfigPath .\config\main-config.json
```

Expected duration: 60–100 minutes. Runs all sub-phases 2a–2h end to end (folder plan → manifest → folders → files → timestamps → owners → ACLs → orphan pass). Progress written to console and to `manifests/logs/`.

## Phase 10 — Verification

```powershell
pwsh -File .\scripts\Test-AcmeData.ps1 -ConfigPath .\config\main-config.json
```

Reports actual file counts, folder counts, age distribution, file-type distribution, ACL mess counts, orphaned SID counts. Compares against config targets. Writes `manifests/logs/verification.json`.

## Phase 11 — Snapshot: "full dataset"

Final snapshot, `02-full-dataset`. **This is the demo snapshot.** Every demo starts here.

## Snapshots summary

| # | Name | When | Purpose |
|---|---|---|---|
| 0 | `00-clean-dc` | After Phase 6 | DC up, S: mounted, share empty. Fallback for "I broke something" |
| 1 | `01-ad-populated` | After Phase 8 | AD users/groups in place. Restore to re-run file gen with new knobs |
| 2 | `02-full-dataset` | After Phase 11 | **The demo starting state.** Restore before every demo. |

## Firewall

Inbound:
- 445/tcp (SMB) — required, this is what Symphony connects on
- 3389/tcp (RDP) — optional, for you
- 53/tcp/udp (DNS) — required if anything else queries the DC
- 88/tcp/udp (Kerberos), 389/tcp (LDAP), 464/tcp (Kerberos password change), 636/tcp (LDAPS) — required for any AD-joined client

If Symphony runs from another VM on the same isolated network, those ports need to be reachable from it to `panzura-sym01`.

## Gotchas

- **Defender must be off, not just excluded.** Exclusions alone are unreliable at 10M-file scale — some paths leak through real-time scanning regardless. Phase 0 step 8 runs `Disable-AcmeDefender.ps1` which turns the service off entirely via policy keys. `Get-MpComputerStatus` should report `AntivirusEnabled: False` and `AMRunningMode: Not running`.
- **Don't install backup agents** — they'll try to index the share and produce absurd results.
- **Clock drift** — if the VM hibernates and resumes, clock can drift enough to confuse AD. Disable sleep/hibernate.
- **VHDX dynamic expansion** — dynamic-expanding VHDX grows as physical allocation grows, not as logical size grows. Sparse files are logical-only, so the VHDX stays small. Expected final VHDX size: under 100 GB.
- **Antimalware snapshotting** — if your hypervisor runs its own AV against VM disks, exclude the data VHDX.

## Cost to rebuild from scratch

If both the VM and the VHDX are lost:
- Windows install + AD: ~30 min manual
- Repo clone + AD build: ~5 min
- File gen: ~90 min unattended
- **Total: under 2.5 hours** from bare metal to demo-ready

Seeded generation means the rebuilt dataset is **identical** to the previous one (same config, same seed). Snapshots are convenience, not necessity.
