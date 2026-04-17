# 01 — Active Directory Design

Active Directory is the identity layer for the entire demo. Every file's owner and every ACL entry resolves against it. Symphony's "space by user" and "space by group" reports, and its broken-ACL discovery, are only as good as the AD behind them.

## Role of the VM

**Single Windows Server 2022 Standard VM** hosts:
- AD Domain Services (domain controller)
- DNS (integrated, authoritative)
- File Services (SMB share `S:\Share`)

Role consolidation is deliberate. This is a demo lab, not production.

## Domain

| Property | Value |
|---|---|
| Forest / domain | `acme.local` |
| NetBIOS name | `ACME` |
| Functional level | Windows Server 2016 |
| DNS | Integrated, VM points to itself (127.0.0.1) for resolution |
| Trusts | None |
| Sites | Default only |

## OU Structure

```
acme.local
└── Acme/
    ├── Users/
    │   ├── Sales/
    │   ├── Marketing/
    │   ├── Engineering/
    │   ├── Finance/
    │   ├── Legal/
    │   ├── HR/
    │   ├── IT/
    │   ├── Executive/
    │   ├── Operations/
    │   ├── CustomerSuccess/
    │   ├── Product/
    │   └── Facilities/
    ├── DisabledUsers/
    ├── ServiceAccounts/
    └── Groups/
        ├── Departments/
        ├── Roles/
        └── Shares/
```

- **Active users** live in their department OU
- **Disabled users** are moved to `DisabledUsers` (account disabled flag set, still resolvable by SID)
- **Terminated users** are *deleted entirely* after the file gen phase — their SIDs remain baked into ACLs and file ownership on disk as unresolvable entries. This is the orphaned-SID demo.
- **Service accounts** live in `ServiceAccounts`

## User Population (400 total)

| Category | Count | % | Notes |
|---|---|---|---|
| Active | 356 | 89% | Distributed across departments |
| Disabled | 32 | 8% | Account disabled, still in AD |
| Terminated (deleted) | 12 | 3% | Deleted after file gen — produces orphaned SIDs |
| Service accounts | 10 | — | Not counted in 400 |

### Department distribution of active users

| Department | Active users |
|---|---|
| Engineering | 90 |
| Sales | 60 |
| Operations | 45 |
| Marketing | 35 |
| CustomerSuccess | 35 |
| Product | 25 |
| Finance | 20 |
| IT | 18 |
| HR | 12 |
| Legal | 8 |
| Facilities | 5 |
| Executive | 3 |
| **Total** | **356** |

### User attributes

- `sAMAccountName` — `firstname.lastname`, numeric suffix on collisions (e.g. `john.smith2`)
- `userPrincipalName` — `firstname.lastname@acme.local`
- `displayName` — `Firstname Lastname`
- `givenName`, `sn` — set
- `department` — set to department name
- `title` — per-department title pool (Engineering → Software Engineer / Senior Software Engineer / Staff Engineer / Engineering Manager / Director of Engineering / VP Engineering; Sales → SDR / AE / Senior AE / Sales Manager / Director of Sales / VP Sales; etc.)
- `manager` — users report up within their own department (org chart generated, managers are senior titles)
- `employeeID` — zero-padded 6-digit number
- Names pulled from realistic first/last name pool (seeded, reproducible)

### Service accounts

| sAMAccountName | Purpose |
|---|---|
| `svc_backup` | Backup agent |
| `svc_sql` | SQL Server |
| `svc_sharepoint` | SharePoint |
| `svc_scanner` | Document scanner / MFP |
| `svc_veeam` | Veeam backup |
| `svc_monitoring` | Monitoring (Nagios / SCOM) |
| `svc_build` | CI/CD build agent |
| `svc_deploy` | Deployment automation |
| `svc_archive` | Archive mover |
| `svc_iis` | IIS app pool |

Service accounts are the hidden space hogs in most enterprises — `svc_backup` and `svc_veeam` end up owning huge swaths of files. That's the demo.

## Groups (~40 total)

Groups follow a loose AGDLP pattern (Accounts → Global → Domain Local → Permissions), with deliberate violations sprinkled in so Symphony finds ACL sprawl.

### Department groups (12, one per department)

Global security groups. Every active user in a department is a member of that department's group.

- `GRP_Sales`, `GRP_Marketing`, `GRP_Engineering`, `GRP_Finance`, `GRP_Legal`, `GRP_HR`, `GRP_IT`, `GRP_Executive`, `GRP_Operations`, `GRP_CustomerSuccess`, `GRP_Product`, `GRP_Facilities`

### Role / cross-functional groups (~15)

Users get 1–3 of these in addition to their department group. Creates matrix membership — makes ACL analysis interesting.

- `GRP_Managers` — all users with manager-level titles
- `GRP_Executives` — VP and above
- `GRP_AllStaff` — everyone
- `GRP_Contractors` — small subset flagged as contractors
- `GRP_ProjectApollo`, `GRP_ProjectPhoenix`, `GRP_ProjectAtlas` — cross-functional project teams
- `GRP_AuditCommittee` — small group with Finance + Legal + Executive overlap
- `GRP_SecurityClearance` — small group
- `GRP_RemoteWorkers` — ~30% of users
- `GRP_Interns` — small group
- `GRP_NewHires` — users with recent start dates
- `GRP_BoardAccess` — exec-only
- `GRP_LegalHold` — users under litigation hold (small, crosses departments)

### Share / resource groups (~12)

These are what *should* appear on folder ACLs. Department groups get nested into these.

- `GRP_FinanceReadOnly`, `GRP_FinanceReadWrite`
- `GRP_LegalContractsRO`, `GRP_LegalContractsRW`
- `GRP_EngineeringBuildsRW`
- `GRP_MarketingAssetsRW`
- `GRP_ExecutiveConfidential`
- `GRP_HRPayroll`, `GRP_HREmployeeRecords`
- `GRP_ITAdmins`
- `GRP_PublicRead`
- `GRP_AuditReadOnly`

Some folder ACLs **violate** this AGDLP pattern on purpose — referencing department groups directly, or individual users, or well-known SIDs like `Everyone`. That's the ACL-sprawl demo.

## Admin Accounts

- Built-in `Administrator` (for VM access)
- `demo.admin` — used to run the generator scripts
- Default `Domain Admins`, `Enterprise Admins`, `Schema Admins` — as AD creates them

## Generation Order

The AD build script is a single pass, idempotent (check-before-create so re-runs don't error).

1. Install AD DS + DNS + File Services Windows features
2. Promote VM to domain controller (`Install-ADDSForest`)
3. Reboot
4. Run `Build-AcmeAD.ps1`:
   - Create OU tree
   - Create all groups (empty)
   - Create all active users, assign to dept OUs
   - Create all disabled users, assign to `DisabledUsers` OU, set disabled flag
   - Create all terminated users (will be deleted later, during file gen phase)
   - Create service accounts
   - Populate group memberships (department → role → resource)
   - Nest department groups into resource groups
   - Set user attributes (title, manager, department, employeeID)
5. Emit `manifests/ad-manifest.json`

### ad-manifest.json

The file generator consumes this — never queries AD during the hot path of creating 10M files.

```jsonc
{
  "domain": "acme.local",
  "users": [
    {
      "samAccountName": "sarah.chen",
      "sid": "S-1-5-21-...-1234",
      "dn": "CN=Sarah Chen,OU=Engineering,OU=Users,OU=Acme,DC=acme,DC=local",
      "department": "Engineering",
      "title": "Senior Software Engineer",
      "status": "active",        // active | disabled | terminated
      "groups": ["GRP_Engineering", "GRP_ProjectApollo", "GRP_RemoteWorkers"]
    }
  ],
  "groups": [
    {
      "name": "GRP_Engineering",
      "sid": "S-1-5-21-...-5678",
      "dn": "CN=GRP_Engineering,OU=Departments,OU=Groups,OU=Acme,DC=acme,DC=local",
      "type": "department",
      "memberCount": 90
    }
  ]
}
```

## Terminated user handling (the orphan pattern)

This is how Symphony finds "broken" ACLs with unresolvable SIDs:

1. AD build phase creates all 12 terminated users as normal
2. They're included in the `ad-manifest.json` with `status: "terminated"`
3. File gen phase assigns ownership and/or ACLs referencing these users for some % of files
4. **After** file gen completes and ACLs are applied, a cleanup pass deletes the 12 terminated users from AD
5. Result: those files now have owner SIDs and ACL entries that don't resolve to any account — Symphony flags them as orphaned

## Open questions for this phase

None currently. Sign off or redline and move to file generation.
