#Requires -Version 7.0
<#
.SYNOPSIS
    Applies NTFS owner SIDs to every file from file-manifest.jsonl (Phase 2f).

.DESCRIPTION
    P/Invoke SetNamedSecurityInfo with OWNER_SECURITY_INFORMATION so we
    touch only the owner section and avoid the managed ACL round-trip.
    Build-AcmeAD stores every SID in ad-manifest.json; the planner writes
    ownerSid per file record directly, so we just push them to disk.

    Terminated-user SIDs are set as-is here. They become orphans after
    Phase 2h deletes those accounts from AD.

.PARAMETER ConfigPath
    Path to config/main-config(.dev).json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ManifestDir = Join-Path $RepoRoot 'manifests'
$LogDir      = Join-Path $ManifestDir 'logs'
$FileManifest= Join-Path $ManifestDir 'file-manifest.jsonl'
if (-not (Test-Path $FileManifest)) { throw "file-manifest.jsonl missing at $FileManifest" }
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory | Out-Null }

$RunStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$LogPath = Join-Path $LogDir ("owners-$RunStamp.log")

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $LogPath -Value "[$stamp] [$Level] $Message"
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host "[$stamp] [$Level] $Message" -ForegroundColor $color
}

function Import-JsonFile {
    param([string]$Path)
    return Get-Content -Path $Path -Raw | ConvertFrom-Json
}

Write-Log "Set-AcmeOwners starting"
$cfg = Import-JsonFile $ConfigPath
$throttle  = [int]$cfg.scale.parallelThreads
$batchSize = [int]$cfg.scale.batchSize
Write-Log "parallelThreads=$throttle  batchSize=$batchSize"

# ---------------------------------------------------------------------------
# P/Invoke for SetNamedSecurityInfo + ConvertStringSidToSid
# ---------------------------------------------------------------------------
if (-not ('Acme.NativeOwner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Acme {
    public static class NativeOwner {
        private const uint SE_FILE_OBJECT = 1;
        private const uint OWNER_SECURITY_INFORMATION = 0x00000001;

        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern uint SetNamedSecurityInfo(
            string pObjectName, uint objectType, uint securityInfo,
            IntPtr psidOwner, IntPtr psidGroup, IntPtr pDacl, IntPtr pSacl);

        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern bool ConvertStringSidToSid(string stringSid, out IntPtr psid);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr hMem);

        public static void SetOwner(string path, string sid) {
            IntPtr psid;
            if (!ConvertStringSidToSid(sid, out psid))
                throw new System.ComponentModel.Win32Exception(
                    Marshal.GetLastWin32Error(), "ConvertStringSidToSid failed for " + sid);
            try {
                uint rc = SetNamedSecurityInfo(path, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
                    psid, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                if (rc != 0)
                    throw new System.ComponentModel.Win32Exception((int)rc,
                        "SetNamedSecurityInfo failed rc=" + rc + " for " + path);
            } finally {
                LocalFree(psid);
            }
        }
    }
}
'@
}

# Enable SeRestorePrivilege so we can set owner to foreign SIDs (terminated/svc accounts).
if (-not ('Acme.PrivilegeHelper' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Acme {
    public static class PrivilegeHelper {
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool OpenProcessToken(IntPtr h, uint desired, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        private static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
        [DllImport("advapi32.dll", SetLastError=true)]
        private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll,
            ref TOKEN_PRIVILEGES newState, uint bufLen, IntPtr prevState, IntPtr returnLen);
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES {
            public uint PrivilegeCount; public LUID Luid; public uint Attributes;
        }
        public static void Enable(string privilege) {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            LUID luid;
            if (!LookupPrivilegeValue(null, privilege, out luid))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            TOKEN_PRIVILEGES tp;
            tp.PrivilegeCount = 1; tp.Luid = luid; tp.Attributes = 0x00000002; // ENABLED
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
}
try { [Acme.PrivilegeHelper]::Enable('SeRestorePrivilege') } catch { Write-Log "SeRestorePrivilege enable failed: $($_.Exception.Message)" 'WARN' }
try { [Acme.PrivilegeHelper]::Enable('SeTakeOwnershipPrivilege') } catch { }

$lines = [System.IO.File]::ReadAllLines($FileManifest)
$total = $lines.Length
Write-Log "Records: $total"
if ($total -eq 0) { return }

$batches = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $total; $i += $batchSize) {
    $end = [Math]::Min($i + $batchSize - 1, $total - 1)
    $batches.Add([pscustomobject]@{ Id = $batches.Count + 1; Lines = $lines[$i..$end] })
}
Write-Log "Batches: $($batches.Count)"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$results = $batches | ForEach-Object -ThrottleLimit $throttle -Parallel {
    $batch = $_
    try { [Acme.PrivilegeHelper]::Enable('SeRestorePrivilege') } catch { }
    try { [Acme.PrivilegeHelper]::Enable('SeTakeOwnershipPrivilege') } catch { }
    $applied = 0; $failed = 0
    $swBatch = [System.Diagnostics.Stopwatch]::StartNew()
    $fails = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $batch.Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $path = $null; $sid = $null
        try {
            $rec = $line | ConvertFrom-Json
            $path = $rec.path
            $sid = $rec.ownerSid
            if (-not $sid) { continue }
            [Acme.NativeOwner]::SetOwner($path, $sid)
            $applied++
        } catch {
            $failed++
            $fails.Add("$path ($sid) :: $($_.Exception.Message)")
        }
    }
    $swBatch.Stop()
    [pscustomobject]@{ Id=$batch.Id; Applied=$applied; Failed=$failed; ElapsedMs=$swBatch.ElapsedMilliseconds; Failures=$fails }
}
$sw.Stop()

$applied = ($results | Measure-Object Applied -Sum).Sum
$failed  = ($results | Measure-Object Failed -Sum).Sum
$rate = if ($sw.Elapsed.TotalSeconds -gt 0) { $applied / $sw.Elapsed.TotalSeconds } else { 0 }
Write-Log ("applied={0} failed={1} elapsed={2:N1}s ({3:N0} files/sec)" -f $applied, $failed, $sw.Elapsed.TotalSeconds, $rate) 'OK'
if ($failed -gt 0) {
    foreach ($r in $results) { foreach ($m in $r.Failures | Select-Object -First 5) { Write-Log $m 'ERROR' } }
}
$summary = [ordered]@{
    records=$total; applied=$applied; failed=$failed
    elapsedSeconds=[Math]::Round($sw.Elapsed.TotalSeconds, 2)
    filesPerSecond=[Math]::Round($rate, 1)
    logPath=$LogPath
}
$summary | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $LogDir 'owners-summary.json') -Encoding utf8
$summary | Format-List
if ($failed / [Math]::Max(1,$total) -gt 0.001) { exit 1 }
