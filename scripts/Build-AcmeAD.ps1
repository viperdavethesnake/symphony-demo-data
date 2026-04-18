#Requires -Version 7.0
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Builds or tears down the Acme Corp AD population used by the symphony-demo-data generator.

.DESCRIPTION
    Populate mode (default): creates OUs, users (active/disabled/terminated),
    service accounts, groups (department/role/resource), group memberships, and
    emits manifests/ad-manifest.json.

    Remove mode: deletes everything this script created, using the manifest as
    the authoritative list (falls back to pattern-based scan if manifest is
    missing). Archives the manifest on success. Never touches built-in AD
    objects. Does not demote the DC.

    Idempotent — Populate is safe to re-run, it checks-before-creates.

.PARAMETER ConfigPath
    Path to config/main-config.json.

.PARAMETER Mode
    Populate (default) or Remove.

.PARAMETER Force
    Skip interactive confirmation in Remove mode.

.EXAMPLE
    pwsh -File .\scripts\Build-AcmeAD.ps1 -ConfigPath .\config\main-config.json
    pwsh -File .\scripts\Build-AcmeAD.ps1 -ConfigPath .\config\main-config.json -Mode Remove -Force
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('Populate','Remove')][string]$Mode = 'Populate',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$RepoRoot     = Split-Path -Parent $PSScriptRoot
$ManifestDir  = Join-Path $RepoRoot 'manifests'
$LogDir       = Join-Path $ManifestDir 'logs'
$ManifestPath = Join-Path $ManifestDir 'ad-manifest.json'
$NamePoolPath = Join-Path (Split-Path -Parent $ConfigPath) 'name-pool.json'

if (-not (Test-Path $ManifestDir)) { New-Item -Path $ManifestDir -ItemType Directory | Out-Null }
if (-not (Test-Path $LogDir))      { New-Item -Path $LogDir      -ItemType Directory | Out-Null }

$LogPath = Join-Path $LogDir ("ad-{0}-{1:yyyyMMdd-HHmmss}.log" -f $Mode.ToLower(), (Get-Date))

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "[$stamp] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line
    $color = switch ($Level) { 'ERROR' {'Red'} 'WARN' {'Yellow'} 'OK' {'Green'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------
function Import-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "File not found: $Path" }
    return Get-Content -Path $Path -Raw | ConvertFrom-Json
}

Write-Log "Loading config from $ConfigPath"
$Config   = Import-JsonFile -Path $ConfigPath
$NamePool = Import-JsonFile -Path $NamePoolPath

# ---------------------------------------------------------------------------
# AD connectivity
# ---------------------------------------------------------------------------
try {
    $Domain    = Get-ADDomain
    $DomainDN  = $Domain.DistinguishedName
    $DomainDns = $Domain.DNSRoot
} catch {
    throw "Unable to reach AD: $($_.Exception.Message)"
}

if ($DomainDns -ne $Config.ad.domain) {
    throw "Domain mismatch — AD says '$DomainDns', config says '$($Config.ad.domain)'"
}
Write-Log "Connected to $DomainDns ($DomainDN)" 'OK'

$RootOuName = $Config.ad.rootOU
$RootOuDN   = "OU=$RootOuName,$DomainDN"

# ---------------------------------------------------------------------------
# Seeded PRNG
# ---------------------------------------------------------------------------
$script:Rng = [System.Random]::new([int]$Config.meta.seed)
function Get-RandInt { param([int]$Max) return $script:Rng.Next($Max) }
function Get-Shuffled {
    param([object[]]$Items)
    $a = @($Items)
    for ($i = $a.Length - 1; $i -gt 0; $i--) {
        $j = $script:Rng.Next($i + 1)
        $tmp = $a[$i]; $a[$i] = $a[$j]; $a[$j] = $tmp
    }
    return ,$a
}
function Get-RandomPick { param([object[]]$Items) return $Items[$script:Rng.Next($Items.Length)] }

# ---------------------------------------------------------------------------
# Idempotent AD helpers
# ---------------------------------------------------------------------------
function Test-ADOuExists {
    param([string]$DN)
    try { return [bool](Get-ADOrganizationalUnit -Identity $DN -ErrorAction Stop) }
    catch { return $false }
}

function New-ADOuIfMissing {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    if (Test-ADOuExists -DN $dn) { return $dn }
    New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false | Out-Null
    Write-Log "Created OU: $dn"
    return $dn
}

function Test-ADGroupExists {
    param([string]$Sam)
    try { return [bool](Get-ADGroup -Identity $Sam -ErrorAction Stop) }
    catch { return $false }
}

function New-ADGroupIfMissing {
    param(
        [string]$Name,
        [string]$Path,
        [ValidateSet('Global','DomainLocal','Universal')][string]$Scope = 'Global',
        [string]$Description
    )
    if (Test-ADGroupExists -Sam $Name) {
        return Get-ADGroup -Identity $Name
    }
    $p = @{
        Name          = $Name
        SamAccountName = $Name
        GroupScope    = $Scope
        GroupCategory = 'Security'
        Path          = $Path
    }
    if ($Description) { $p.Description = $Description }
    $g = New-ADGroup @p -PassThru
    Write-Log "Created group: $Name ($Scope)"
    return $g
}

function Test-ADUserExists {
    param([string]$Sam)
    try { return [bool](Get-ADUser -Identity $Sam -ErrorAction Stop) }
    catch { return $false }
}

function New-ADUserIfMissing {
    param(
        [Parameter(Mandatory)][hashtable]$U,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][securestring]$Password,
        [bool]$Enabled = $true
    )
    if (Test-ADUserExists -Sam $U.samAccountName) {
        return Get-ADUser -Identity $U.samAccountName -Properties SID, DistinguishedName
    }
    $params = @{
        Name                  = $U.displayName
        SamAccountName        = $U.samAccountName
        UserPrincipalName     = $U.userPrincipalName
        GivenName             = $U.givenName
        Surname               = $U.surname
        DisplayName           = $U.displayName
        AccountPassword       = $Password
        Enabled               = $Enabled
        PasswordNeverExpires  = $true
        CannotChangePassword  = $true
        Path                  = $Path
        ChangePasswordAtLogon = $false
    }
    if ($U.ContainsKey('department') -and $U.department) { $params.Department = $U.department }
    if ($U.ContainsKey('title') -and $U.title)           { $params.Title      = $U.title }
    if ($U.ContainsKey('employeeId') -and $U.employeeId) { $params.EmployeeID = $U.employeeId }

    New-ADUser @params | Out-Null
    Write-Log "Created user: $($U.samAccountName) ($($U.status))"
    return Get-ADUser -Identity $U.samAccountName -Properties SID, DistinguishedName
}

function Add-ADGroupMemberIfMissing {
    param([string]$GroupName, [string]$MemberSam)
    $members = @(Get-ADGroupMember -Identity $GroupName -Recursive:$false -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty SamAccountName)
    if ($members -notcontains $MemberSam) {
        Add-ADGroupMember -Identity $GroupName -Members $MemberSam
    }
}

# ---------------------------------------------------------------------------
# Static per-department title pool
# ---------------------------------------------------------------------------
$TitlePool = @{
    Engineering     = @('Software Engineer','Senior Software Engineer','Staff Engineer','Engineering Manager','Director of Engineering','VP Engineering')
    Sales           = @('SDR','Account Executive','Senior Account Executive','Sales Manager','Director of Sales','VP Sales')
    Marketing       = @('Marketing Specialist','Senior Marketing Manager','Marketing Manager','Director of Marketing','VP Marketing')
    Finance         = @('Accountant','Senior Accountant','Finance Manager','Controller','Director of Finance','VP Finance','CFO')
    Legal           = @('Paralegal','Counsel','Senior Counsel','General Counsel')
    HR              = @('HR Generalist','HR Manager','Director of HR','VP People')
    IT              = @('IT Support','Systems Administrator','Senior Sysadmin','IT Manager','Director of IT')
    Executive       = @('CEO','COO','Chief of Staff')
    Operations      = @('Operations Analyst','Operations Manager','Senior Ops Manager','Director of Operations','VP Operations')
    CustomerSuccess = @('Customer Success Associate','CSM','Senior CSM','CS Manager','Director of Customer Success','VP Customer Success')
    Product         = @('Product Manager','Senior PM','Group PM','Director of Product','VP Product','CPO')
    Facilities      = @('Facilities Coordinator','Facilities Manager','Director of Facilities')
}

# Senior tier per department — these people are managers; everyone else reports up to them.
function Get-SeniorTitles {
    param([string]$Dept)
    $titles = $TitlePool[$Dept]
    # The last ~half of the list is the senior tier.
    $split = [Math]::Max(1, [Math]::Floor($titles.Count / 2))
    return ,@($titles[$split..($titles.Count - 1)])
}

function Test-IsManagerTitle {
    param([string]$Title)
    return $Title -match '(Manager\b|Director\b|^VP |CEO|COO|CFO|CPO|Chief\b|General Counsel|Controller|CSM|Group PM|Senior PM)'
}

function Test-IsExecutiveTitle {
    param([string]$Title)
    return $Title -match '^(VP |Director of|CEO|COO|CFO|CPO|Chief|General Counsel)'
}

# Pyramid-weighted title picker — earlier titles (junior) are exponentially more common than later ones (senior).
function Get-WeightedTitle {
    param([Parameter(Mandatory)][string[]]$Titles)
    $n = $Titles.Count
    $weights = 0..($n - 1) | ForEach-Object { [Math]::Pow(2, $n - 1 - $_) }
    $total = ($weights | Measure-Object -Sum).Sum
    $r = $script:Rng.NextDouble() * $total
    $cum = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $cum += $weights[$i]
        if ($r -le $cum) { return $Titles[$i] }
    }
    return $Titles[$n - 1]
}

# ---------------------------------------------------------------------------
# Roster planning
# ---------------------------------------------------------------------------
function New-UserRoster {
    Write-Log 'Planning user roster...'
    $roster = [System.Collections.Generic.List[hashtable]]::new()
    $usedSams = [System.Collections.Generic.HashSet[string]]::new()

    # Assemble pool: active + disabled + terminated distributed proportional to department weights.
    $activeCount     = [int]$Config.ad.users.activeCount
    $disabledCount   = [int]$Config.ad.users.disabledCount
    $terminatedCount = [int]$Config.ad.users.terminatedCount

    $deptDist = @{}
    $Config.ad.departmentDistribution.PSObject.Properties | ForEach-Object {
        $deptDist[$_.Name] = [int]$_.Value
    }

    # Build a list of department slots proportional to active distribution
    $deptSlotList = @()
    foreach ($k in $deptDist.Keys) {
        for ($i = 0; $i -lt $deptDist[$k]; $i++) { $deptSlotList += $k }
    }
    $deptSlotList = Get-Shuffled -Items $deptSlotList

    # Extra slots for disabled + terminated (distributed by same weights)
    $extraSlotList = @()
    $extraNeeded = $disabledCount + $terminatedCount
    for ($i = 0; $i -lt $extraNeeded; $i++) {
        $extraSlotList += Get-RandomPick -Items $deptSlotList
    }

    $allSlots = @()
    $allSlots += ,@($deptSlotList  | ForEach-Object { @{ dept = $_; status = 'active' } })
    $allSlots += ,@($extraSlotList[0..($disabledCount - 1)]   | ForEach-Object { @{ dept = $_; status = 'disabled' } })
    if ($terminatedCount -gt 0) {
        $allSlots += ,@($extraSlotList[$disabledCount..($extraNeeded - 1)] | ForEach-Object { @{ dept = $_; status = 'terminated' } })
    }
    $flatSlots = @()
    foreach ($group in $allSlots) { foreach ($s in $group) { $flatSlots += $s } }

    $empIdCounter = 100000

    foreach ($slot in $flatSlots) {
        $first = Get-RandomPick -Items $NamePool.firstNames
        $last  = Get-RandomPick -Items $NamePool.lastNames
        $baseSam = ("{0}.{1}" -f $first, $last).ToLower()
        $baseSam = $baseSam -replace '[^a-z.]', ''
        $sam = $baseSam
        $suffix = 2
        while ($usedSams.Contains($sam)) {
            $sam = "$baseSam$suffix"
            $suffix++
        }
        [void]$usedSams.Add($sam)

        $dept    = $slot.dept
        $titles  = $TitlePool[$dept]
        $title   = Get-WeightedTitle -Titles $titles
        $empId   = ("{0:D6}" -f $empIdCounter); $empIdCounter++

        $u = @{
            samAccountName    = $sam
            userPrincipalName = "$sam@$DomainDns"
            givenName         = $first
            surname           = $last
            displayName       = "$first $last"
            department        = $dept
            title             = $title
            employeeId        = $empId
            status            = $slot.status
            groups            = @()
            managerSam        = $null
            sid               = $null
            dn                = $null
        }
        [void]$roster.Add($u)
    }

    # Manager assignment — per department, senior-tier titles have no manager; everyone else
    # reports up to a random senior-tier user in the same department.
    $byDept = @{}
    foreach ($u in $roster) {
        if (-not $byDept.ContainsKey($u.department)) { $byDept[$u.department] = @() }
        $byDept[$u.department] += $u
    }
    foreach ($dept in $byDept.Keys) {
        $seniorTitles = Get-SeniorTitles -Dept $dept
        $deptUsers    = $byDept[$dept]
        $seniors      = @($deptUsers | Where-Object { $seniorTitles -contains $_.title })
        $juniors      = @($deptUsers | Where-Object { $seniorTitles -notcontains $_.title })
        if ($seniors.Count -eq 0 -and $deptUsers.Count -gt 0) {
            # Fallback: first user becomes the manager
            $seniors = @($deptUsers[0])
            $juniors = @($deptUsers | Select-Object -Skip 1)
        }
        foreach ($jr in $juniors) {
            $mgr = Get-RandomPick -Items $seniors
            $jr.managerSam = $mgr.samAccountName
        }
    }

    Write-Log ("Roster planned: {0} total ({1} active, {2} disabled, {3} terminated)" -f `
        $roster.Count, $activeCount, $disabledCount, $terminatedCount)
    return $roster
}

# ---------------------------------------------------------------------------
# Populate mode
# ---------------------------------------------------------------------------
function Invoke-Populate {
    Write-Log '=== BEGIN Populate ==='

    # --- OU tree ---
    Write-Log 'Building OU tree...'
    New-ADOuIfMissing -Name $RootOuName -Path $DomainDN | Out-Null

    $usersOuDN         = New-ADOuIfMissing -Name 'Users'           -Path $RootOuDN
    $disabledOuDN      = New-ADOuIfMissing -Name 'DisabledUsers'   -Path $RootOuDN
    $svcOuDN           = New-ADOuIfMissing -Name 'ServiceAccounts' -Path $RootOuDN
    $groupsOuDN        = New-ADOuIfMissing -Name 'Groups'          -Path $RootOuDN
    $groupsDeptOuDN    = New-ADOuIfMissing -Name 'Departments'     -Path $groupsOuDN
    $groupsRoleOuDN    = New-ADOuIfMissing -Name 'Roles'           -Path $groupsOuDN
    $groupsShareOuDN   = New-ADOuIfMissing -Name 'Shares'          -Path $groupsOuDN

    $deptOuDNs = @{}
    foreach ($dept in $Config.ad.departmentDistribution.PSObject.Properties.Name) {
        $deptOuDNs[$dept] = New-ADOuIfMissing -Name $dept -Path $usersOuDN
    }

    # --- Department groups ---
    Write-Log 'Creating department groups...'
    $deptGroupNames = @()
    foreach ($dept in $Config.ad.departmentDistribution.PSObject.Properties.Name) {
        $g = "GRP_$dept"
        New-ADGroupIfMissing -Name $g -Path $groupsDeptOuDN -Scope Global -Description "Department: $dept" | Out-Null
        $deptGroupNames += $g
    }

    # --- Role groups ---
    Write-Log 'Creating role/cross-functional groups...'
    $roleGroupNames = @(
        'GRP_Managers','GRP_Executives','GRP_AllStaff','GRP_Contractors',
        'GRP_ProjectApollo','GRP_ProjectPhoenix','GRP_ProjectAtlas',
        'GRP_AuditCommittee','GRP_SecurityClearance','GRP_RemoteWorkers',
        'GRP_Interns','GRP_NewHires','GRP_BoardAccess','GRP_LegalHold'
    )
    foreach ($g in $roleGroupNames) {
        New-ADGroupIfMissing -Name $g -Path $groupsRoleOuDN -Scope Global -Description 'Role / cross-functional group' | Out-Null
    }

    # --- Resource groups ---
    Write-Log 'Creating resource groups...'
    $resourceGroupNames = @(
        'GRP_FinanceReadOnly','GRP_FinanceReadWrite',
        'GRP_LegalContractsRO','GRP_LegalContractsRW',
        'GRP_EngineeringBuildsRW','GRP_MarketingAssetsRW',
        'GRP_ExecutiveConfidential','GRP_HRPayroll','GRP_HREmployeeRecords',
        'GRP_ITAdmins','GRP_PublicRead','GRP_AuditReadOnly'
    )
    foreach ($g in $resourceGroupNames) {
        New-ADGroupIfMissing -Name $g -Path $groupsShareOuDN -Scope DomainLocal -Description 'Resource group' | Out-Null
    }

    # --- Roster plan ---
    $roster = New-UserRoster

    # --- Users ---
    $securePw = ConvertTo-SecureString $Config.ad.password -AsPlainText -Force
    Write-Log 'Creating active users...'
    foreach ($u in @($roster | Where-Object { $_.status -eq 'active' })) {
        $path = $deptOuDNs[$u.department]
        $ad = New-ADUserIfMissing -U $u -Path $path -Password $securePw -Enabled $true
        $u.sid = $ad.SID.Value
        $u.dn  = $ad.DistinguishedName
    }
    Write-Log 'Creating disabled users...'
    foreach ($u in @($roster | Where-Object { $_.status -eq 'disabled' })) {
        $ad = New-ADUserIfMissing -U $u -Path $disabledOuDN -Password $securePw -Enabled $false
        $u.sid = $ad.SID.Value
        $u.dn  = $ad.DistinguishedName
    }
    Write-Log 'Creating terminated users (to be deleted post-filegen)...'
    foreach ($u in @($roster | Where-Object { $_.status -eq 'terminated' })) {
        $path = $deptOuDNs[$u.department]
        $ad = New-ADUserIfMissing -U $u -Path $path -Password $securePw -Enabled $true
        $u.sid = $ad.SID.Value
        $u.dn  = $ad.DistinguishedName
    }

    # --- Service accounts ---
    Write-Log 'Creating service accounts...'
    $svcAccounts = @(
        @{ sam='svc_backup';     display='Backup Service' }
        @{ sam='svc_sql';        display='SQL Server Service' }
        @{ sam='svc_sharepoint'; display='SharePoint Service' }
        @{ sam='svc_scanner';    display='Scanner / MFP Service' }
        @{ sam='svc_veeam';      display='Veeam Backup Service' }
        @{ sam='svc_monitoring'; display='Monitoring Service' }
        @{ sam='svc_build';      display='Build Agent Service' }
        @{ sam='svc_deploy';     display='Deploy Automation Service' }
        @{ sam='svc_archive';    display='Archive Mover Service' }
        @{ sam='svc_iis';        display='IIS App Pool Service' }
    )
    $svcRoster = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $svcAccounts) {
        $u = @{
            samAccountName    = $s.sam
            userPrincipalName = "$($s.sam)@$DomainDns"
            givenName         = $s.sam
            surname           = 'Service'
            displayName       = $s.display
            department        = $null
            title             = 'Service Account'
            employeeId        = $null
            status            = 'service'
            groups            = @()
            managerSam        = $null
            sid               = $null
            dn                = $null
        }
        $ad = New-ADUserIfMissing -U $u -Path $svcOuDN -Password $securePw -Enabled $true
        $u.sid = $ad.SID.Value
        $u.dn  = $ad.DistinguishedName
        [void]$svcRoster.Add($u)
    }

    # --- demo.admin ---
    Write-Log 'Creating demo.admin...'
    $adminCfg = $Config.ad.adminAccount
    $adminU = @{
        samAccountName    = $adminCfg.samAccountName
        userPrincipalName = "$($adminCfg.samAccountName)@$DomainDns"
        givenName         = 'Demo'
        surname           = 'Admin'
        displayName       = $adminCfg.displayName
        department        = $null
        title             = 'Demo Administrator'
        employeeId        = $null
        status            = 'admin'
        groups            = @()
        managerSam        = $null
        sid               = $null
        dn                = $null
    }
    $adminAd = New-ADUserIfMissing -U $adminU -Path $svcOuDN -Password $securePw -Enabled $true
    $adminU.sid = $adminAd.SID.Value
    $adminU.dn  = $adminAd.DistinguishedName
    if ($adminCfg.domainAdmin) {
        Add-ADGroupMemberIfMissing -GroupName 'Domain Admins' -MemberSam $adminU.samAccountName
        Write-Log "Added $($adminU.samAccountName) to Domain Admins"
    }

    # --- Manager attributes (second pass) ---
    Write-Log 'Setting manager attributes...'
    foreach ($u in $roster) {
        if ($u.managerSam) {
            $mgr = Get-ADUser -Identity $u.managerSam
            Set-ADUser -Identity $u.samAccountName -Manager $mgr.DistinguishedName
        }
    }

    # --- Department group memberships ---
    Write-Log 'Populating department group memberships...'
    foreach ($u in $roster) {
        $g = "GRP_$($u.department)"
        Add-ADGroupMemberIfMissing -GroupName $g -MemberSam $u.samAccountName
        $u.groups += $g
    }

    # --- Role group memberships ---
    Write-Log 'Populating role group memberships...'
    $activeUsers = @($roster | Where-Object { $_.status -eq 'active' })

    # AllStaff = every active + disabled + terminated user
    foreach ($u in $roster) {
        Add-ADGroupMemberIfMissing -GroupName 'GRP_AllStaff' -MemberSam $u.samAccountName
        $u.groups += 'GRP_AllStaff'
    }
    # Managers
    foreach ($u in $roster) {
        if (Test-IsManagerTitle -Title $u.title) {
            Add-ADGroupMemberIfMissing -GroupName 'GRP_Managers' -MemberSam $u.samAccountName
            $u.groups += 'GRP_Managers'
        }
    }
    # Executives
    foreach ($u in $roster) {
        if (Test-IsExecutiveTitle -Title $u.title) {
            Add-ADGroupMemberIfMissing -GroupName 'GRP_Executives' -MemberSam $u.samAccountName
            $u.groups += 'GRP_Executives'
        }
    }

    # Seeded subset-style role groups
    function Add-SeededRoleMembers {
        param(
            [string]$GroupName,
            [object[]]$Candidates,
            [int]$Count
        )
        if ($Count -le 0 -or $Candidates.Count -eq 0) { return }
        $shuffled = Get-Shuffled -Items $Candidates
        $take = [Math]::Min($Count, $shuffled.Count)
        foreach ($u in $shuffled[0..($take - 1)]) {
            Add-ADGroupMemberIfMissing -GroupName $GroupName -MemberSam $u.samAccountName
            $u.groups += $GroupName
        }
    }

    $sizing = $Config.ad.roleGroupSizing
    foreach ($prop in $sizing.PSObject.Properties) {
        if ($prop.Name -eq '$comment') { continue }
        $gname = $prop.Name
        $cfg   = $prop.Value

        # Candidates default to active users
        $candidates = $activeUsers
        if ($cfg.PSObject.Properties.Name -contains 'departments') {
            $deptFilter = @($cfg.departments)
            $candidates = @($activeUsers | Where-Object { $deptFilter -contains $_.department })
        }

        $count = 0
        if ($cfg.PSObject.Properties.Name -contains 'count') {
            $count = [int]$cfg.count
        } elseif ($cfg.PSObject.Properties.Name -contains 'percent') {
            $count = [int][Math]::Round(($activeUsers.Count * [double]$cfg.percent) / 100.0)
        }
        Add-SeededRoleMembers -GroupName $gname -Candidates $candidates -Count $count
    }

    # Role-group sizing above is the sole source of truth for role-group memberships;
    # no additional random sprinkle. Matrix membership comes from Managers/Executives/AllStaff
    # rules + the seeded sizing block.

    # --- Resource group nesting ---
    Write-Log 'Nesting department groups into resource groups...'
    $nesting = $Config.ad.groupNesting
    foreach ($prop in $nesting.PSObject.Properties) {
        if ($prop.Name -eq '$comment') { continue }
        $parent = $prop.Name
        foreach ($child in @($prop.Value)) {
            Add-ADGroupMemberIfMissing -GroupName $child -MemberSam $parent
        }
    }

    # --- Emit manifest ---
    Write-Log 'Emitting ad-manifest.json...'
    $manifest = [ordered]@{
        meta = [ordered]@{
            domain         = $DomainDns
            netbios        = $Config.ad.netbios
            rootOU         = $RootOuName
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            seed           = [int]$Config.meta.seed
            script         = 'Build-AcmeAD.ps1'
            version        = $Config.meta.version
        }
        users  = @()
        groups = @()
    }

    # Normal users
    foreach ($u in $roster) {
        $manifest.users += [ordered]@{
            samAccountName = $u.samAccountName
            sid            = $u.sid
            dn             = $u.dn
            displayName    = $u.displayName
            department     = $u.department
            title          = $u.title
            employeeId     = $u.employeeId
            managerSam     = $u.managerSam
            status         = $u.status
            groups         = @($u.groups | Sort-Object -Unique)
        }
    }
    # Service accounts
    foreach ($u in $svcRoster) {
        $manifest.users += [ordered]@{
            samAccountName = $u.samAccountName
            sid            = $u.sid
            dn             = $u.dn
            displayName    = $u.displayName
            department     = $null
            title          = 'Service Account'
            employeeId     = $null
            managerSam     = $null
            status         = 'service'
            groups         = @()
        }
    }
    # demo.admin
    $manifest.users += [ordered]@{
        samAccountName = $adminU.samAccountName
        sid            = $adminU.sid
        dn             = $adminU.dn
        displayName    = $adminU.displayName
        department     = $null
        title          = 'Demo Administrator'
        employeeId     = $null
        managerSam     = $null
        status         = 'admin'
        groups         = @('Domain Admins')
    }

    # Groups with SIDs
    $allGroupRecords = @()
    foreach ($g in $deptGroupNames)      { $allGroupRecords += @{ name=$g; type='department' } }
    foreach ($g in $roleGroupNames)      { $allGroupRecords += @{ name=$g; type='role' } }
    foreach ($g in $resourceGroupNames)  { $allGroupRecords += @{ name=$g; type='resource' } }

    foreach ($gr in $allGroupRecords) {
        $adg = Get-ADGroup -Identity $gr.name -Properties Members
        $manifest.groups += [ordered]@{
            name        = $gr.name
            sid         = $adg.SID.Value
            dn          = $adg.DistinguishedName
            type        = $gr.type
            memberCount = @($adg.Members).Count
        }
    }

    $json = $manifest | ConvertTo-Json -Depth 6
    Set-Content -Path $ManifestPath -Value $json -Encoding UTF8
    Write-Log "Manifest written: $ManifestPath" 'OK'

    # --- Summary ---
    $summary = [ordered]@{
        mode           = 'Populate'
        usersCreated   = $manifest.users.Count
        groupsCreated  = $manifest.groups.Count
        activeUsers    = @($roster | Where-Object { $_.status -eq 'active' }).Count
        disabledUsers  = @($roster | Where-Object { $_.status -eq 'disabled' }).Count
        terminatedUsers= @($roster | Where-Object { $_.status -eq 'terminated' }).Count
        serviceAccounts= $svcRoster.Count
        adminAccounts  = 1
        manifestPath   = $ManifestPath
        logPath        = $LogPath
    }
    Write-Log ('=== END Populate === ' + ($summary | ConvertTo-Json -Compress)) 'OK'
    return $summary
}

# ---------------------------------------------------------------------------
# Remove mode
# ---------------------------------------------------------------------------
function Invoke-Remove {
    Write-Log '=== BEGIN Remove ==='

    $deleteUsers  = [System.Collections.Generic.List[string]]::new()
    $deleteGroups = [System.Collections.Generic.List[hashtable]]::new()
    $deleteOUs    = [System.Collections.Generic.List[string]]::new()

    if (Test-Path $ManifestPath) {
        Write-Log "Using manifest as authoritative delete list: $ManifestPath"
        $m = Import-JsonFile -Path $ManifestPath
        foreach ($u in $m.users) { [void]$deleteUsers.Add($u.samAccountName) }
        foreach ($g in $m.groups) { [void]$deleteGroups.Add(@{ name=$g.name; type=$g.type }) }
    } else {
        Write-Log 'No manifest found — falling back to pattern-based scan.' 'WARN'
        if (Test-ADOuExists -DN $RootOuDN) {
            $scanUsers = Get-ADUser -Filter * -SearchBase $RootOuDN -SearchScope Subtree
            foreach ($u in $scanUsers) { [void]$deleteUsers.Add($u.SamAccountName) }
            $scanGroups = Get-ADGroup -Filter * -SearchBase $RootOuDN -SearchScope Subtree
            foreach ($g in $scanGroups) {
                $type = if     ($g.Name -like 'GRP_Project*')     { 'role' }
                        elseif ($g.Name -in @('GRP_Managers','GRP_Executives','GRP_AllStaff','GRP_Contractors','GRP_AuditCommittee','GRP_SecurityClearance','GRP_RemoteWorkers','GRP_Interns','GRP_NewHires','GRP_BoardAccess','GRP_LegalHold')) { 'role' }
                        elseif ($g.Name -match '^GRP_[A-Z][a-z]+$') { 'department' }
                        else { 'resource' }
                [void]$deleteGroups.Add(@{ name=$g.Name; type=$type })
            }
        } else {
            Write-Log 'Root OU does not exist. Nothing to do.' 'WARN'
        }
    }

    # Summary
    $summary = [ordered]@{
        usersToDelete  = $deleteUsers.Count
        groupsToDelete = $deleteGroups.Count
        rootOU         = $RootOuDN
    }
    Write-Host ''
    Write-Host 'Will delete:' -ForegroundColor Yellow
    Write-Host "  Users (includes service + admin): $($summary.usersToDelete)"
    Write-Host "  Groups:                            $($summary.groupsToDelete)"
    Write-Host "  Plus the OU tree under:            $RootOuDN"
    Write-Host ''

    if (-not $Force) {
        if (-not $PSCmdlet.ShouldProcess("$RootOuDN and contents", 'DELETE from AD')) {
            Write-Log 'Cancelled by user — no changes.' 'WARN'
            return
        }
    }

    # --- Delete users ---
    Write-Log 'Deleting users...'
    $userFails = 0
    foreach ($sam in $deleteUsers) {
        try {
            if (Test-ADUserExists -Sam $sam) {
                Remove-ADUser -Identity $sam -Confirm:$false
                Write-Log "Deleted user: $sam"
            }
        } catch {
            Write-Log "Failed to delete user '$sam': $($_.Exception.Message)" 'ERROR'
            $userFails++
        }
    }

    # --- Delete groups (resource -> role -> department) ---
    Write-Log 'Deleting groups (resource -> role -> department)...'
    $orderedGroups = @()
    $orderedGroups += @($deleteGroups | Where-Object { $_.type -eq 'resource' })
    $orderedGroups += @($deleteGroups | Where-Object { $_.type -eq 'role' })
    $orderedGroups += @($deleteGroups | Where-Object { $_.type -eq 'department' })
    $orderedGroups += @($deleteGroups | Where-Object { $_.type -notin @('resource','role','department') })

    $groupFails = 0
    foreach ($g in $orderedGroups) {
        try {
            if (Test-ADGroupExists -Sam $g.name) {
                Remove-ADGroup -Identity $g.name -Confirm:$false
                Write-Log "Deleted group: $($g.name)"
            }
        } catch {
            Write-Log "Failed to delete group '$($g.name)': $($_.Exception.Message)" 'ERROR'
            $groupFails++
        }
    }

    # --- Delete OUs deepest-first ---
    Write-Log 'Deleting OUs (deepest first)...'
    if (Test-ADOuExists -DN $RootOuDN) {
        $allOUs = Get-ADOrganizationalUnit -Filter * -SearchBase $RootOuDN -SearchScope Subtree |
            Sort-Object { $_.DistinguishedName.Split(',').Count } -Descending

        foreach ($ou in $allOUs) {
            try {
                # Disable accidental-deletion protection if set
                if ($ou.ProtectedFromAccidentalDeletion) {
                    Set-ADOrganizationalUnit -Identity $ou.DistinguishedName -ProtectedFromAccidentalDeletion $false
                }
                Remove-ADOrganizationalUnit -Identity $ou.DistinguishedName -Recursive -Confirm:$false
                Write-Log "Deleted OU: $($ou.DistinguishedName)"
            } catch {
                Write-Log "Failed to delete OU '$($ou.DistinguishedName)': $($_.Exception.Message)" 'ERROR'
            }
        }
    }

    # --- Archive manifest ---
    if (Test-Path $ManifestPath) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $archive = Join-Path $ManifestDir ("ad-manifest.json.removed-$stamp")
        Move-Item -Path $ManifestPath -Destination $archive
        Write-Log "Manifest archived: $archive" 'OK'
    }

    $teardown = [ordered]@{
        mode          = 'Remove'
        usersDeleted  = $deleteUsers.Count - $userFails
        groupsDeleted = $deleteGroups.Count - $groupFails
        userFails     = $userFails
        groupFails    = $groupFails
        logPath       = $LogPath
    }
    $teardownSummaryPath = Join-Path $LogDir 'ad-teardown-summary.json'
    ($teardown | ConvertTo-Json -Depth 4) | Set-Content -Path $teardownSummaryPath -Encoding UTF8

    Write-Log ('=== END Remove === ' + ($teardown | ConvertTo-Json -Compress)) 'OK'
    return $teardown
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
try {
    switch ($Mode) {
        'Populate' { $result = Invoke-Populate }
        'Remove'   { $result = Invoke-Remove }
    }
    if ($result) {
        Write-Host ''
        Write-Host 'RESULT:' -ForegroundColor Green
        $result | Format-List
    }
    exit 0
} catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    exit 1
}
