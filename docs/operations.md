# Operations scripts (Cloud Shell)

Three PowerShell scripts in [`scripts/ops/`](../scripts/ops) that run against a **deployed** landing zone from Azure Cloud Shell:

| Script | What it does |
|---|---|
| `Test-AvdLandingZoneReadiness.ps1` | Preflight. Confirms the landing zone is ready for session hosts and users, **including the three post-deployment tenant steps**. Check mode by default; `-Fix` remediates. |
| `Deploy-AvdDemo.ps1` | Deploys a demo host pool and session host into the landing zone, then validates that a user can sign in. |
| `Remove-AvdDemo.ps1` | Removes the demo. `-IncludeLandingZone` tears down the whole landing zone. |

They share `AvdLandingZone.psm1`. The landing zone's resources, Entra groups and AVD service principal are discovered from its naming convention and the role assignments it created, so the only required inputs are `-NamePrefix` and `-Environment`.

## Running them

```powershell
# Cloud Shell (PowerShell), in the landing zone subscription
git clone https://github.com/nickprignano/avd-landing-zone.git
cd avd-landing-zone
Set-AzContext -Subscription '<landing zone subscription>'

./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev          # check
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix     # fix
./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -TestUserUpn alex@contoso.com
./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment dev
```

Microsoft Graph sign-in uses a device code in Cloud Shell. Required roles:

| For | Azure | Entra ID |
|---|---|---|
| Preflight (check) | Reader on the subscription, plus Role Based Access Control Administrator on the storage account for the NTFS step (it grants a temporary role) | Global Reader (or Security Reader + Directory Readers) |
| Preflight `-Fix` | Owner, or Contributor + Role Based Access Control Administrator | Cloud Application Administrator **and** Conditional Access Administrator |
| Demo deploy | Owner, or Contributor + Role Based Access Control Administrator | Global Reader (Cloud Application Administrator with `-FixNtfs`) |
| Cleanup | Owner | Intune Administrator + Cloud Device Administrator (to remove device objects) |

## Preflight: what it checks and fixes

| Area | Check | `-Fix` |
|---|---|---|
| Tooling | PowerShell 7, Bicep CLI, Microsoft.Graph.Authentication | — |
| Subscription | Your RBAC; resource providers; `EncryptionAtHost` feature; VM size offered in the region and zones; family and regional vCPU quota | Registers providers and the feature |
| Landing zone | The five resource groups; VNet, storage, Key Vault, Log Analytics, AVD Insights DCR, host pool; Entra Kerberos on the storage; storage and AVD private endpoints with DNS zone groups | — |
| RBAC | AVD Users/Admins groups and AVD service principal assignments; SMB Share Contributor for AVD Users | — |
| Entra ID | Both groups have members; the tenant has Intune licensing | — |
| **Step 1** | Admin consent for `[Storage Account] <account>.file.core.windows.net`; the `kdc_enable_cloud_group_sids` tag, so Kerberos tickets carry cloud-only group SIDs | Grants tenant-wide consent for the scopes the app requests; adds the tag |
| **Step 2** | Every enabled Conditional Access policy that requires MFA (or an authentication strength) for **all** apps and covers AVD users excludes the storage app. Policies scoped to other users or roles are reported for review | Adds the storage app to the policy's excluded applications. **You confirm each policy** unless `-Force` |
| **Step 3** | The profile share root ACL matches FSLogix guidance: inheritance cut; SYSTEM, Administrators and AVD Admins full control; CREATOR OWNER modify on subfolders; AVD Users modify on this folder only; no write for Authenticated Users, Users or Everyone | Replaces the root ACL |

### How the NTFS step works

The profile share is private and SMB-only, so Cloud Shell can't reach it. The check runs **on a session host** through Run Command:

1. The host's managed identity gets a temporary *Storage File Data Privileged Reader* role on the storage account, or *Privileged Contributor* with `-Fix`.
2. On the host, the script reads the share root's security descriptor through the Azure Files REST API with backup intent, and sets it when fixing. No SMB mount or user ticket is involved.
3. The role is removed again, even if the check fails.

Role assignments can take a few minutes to reach the storage data plane, so the script retries for up to about six minutes. By default it uses a running host in `rg-<prefix>-<env>-hosts`. Use `-NtfsHostName` to pick one, or `-AllowHostStart` to start a stopped host and deallocate it afterwards. `Deploy-AvdDemo.ps1` runs the same check from the demo host.

Group SIDs are the synced group's on-premises SID when it has one, otherwise the Entra `S-1-12-1-…` SID.

## Demo deployment

`Deploy-AvdDemo.ps1` deploys [`bicep/demo/main.bicep`](../bicep/demo/main.bicep) into `rg-<prefix>-<env>-demo`:
- Pooled host pool (validation ring), desktop app group, workspace.
- `-SessionHostCount` hosts (default 1), built by the landing zone's own `controlPlane` and `sessionHosts` modules.
- The existing spoke, profile share, Log Analytics, DCR, private DNS, groups and AVD service principal.
- No scaling plan, so the host stays up while you test. The host pool private endpoint lives in the demo RG, so cleanup removes it.

It then validates sign-in readiness:

| Area | Validation |
|---|---|
| Host pool | Every host **Available**, accepting new sessions, all AVD health checks passing (waits up to `-TimeoutMinutes`) |
| Host configuration | `Configure-FSLogix` and `Register-AvdAgent` run commands succeeded; on the host: Entra joined, Intune enrolled, agent registered, FSLogix and Entra Kerberos configured, profile share resolves to a private IP and answers on TCP 445 |
| Access | AVD Users hold Desktop Virtualization User on the demo app group, VM User Login on the demo RG, and SMB Share Contributor on the storage |
| Tenant | Steps 1–3 as above (check only; `-FixNtfs` applies the ACL) |
| Test user | With `-TestUserUpn`: enabled, a member of AVD Users (including nested groups), licensed |

The demo host's break-glass password is random and isn't stored anywhere. Use **VM > Reset password** if you need it.

## Cleanup

`Remove-AvdDemo.ps1` removes:
- the demo resource group;
- its deployment record;
- the demo hosts' Entra ID and Intune device objects (`-KeepDevices` keeps them).

It supports `-WhatIf`.

With `-IncludeLandingZone`, you must type the landing zone name to confirm (`-Force` skips this). It then removes:
1. **Profile backup.** It disables vault immutability and soft delete, which would otherwise block the delete. It stops protection, deletes the recovery points, and unregisters the storage account, which releases the backup delete lock.
2. **The five landing zone resource groups**, in dependency order.
3. **Subscription-level resources:** `avdlz-*` policy assignments with their role assignments, the budget, the activity-log diagnostic setting, and deployment records.
4. **The landing zone hosts' device objects.**
5. **Defender plans**, set back to Free, only with `-ResetDefender`.

The Key Vault stays soft-deleted under purge protection for 90 days.

## Exit codes

Preflight and demo return **0** when nothing failed and **1** otherwise, so you can use them in pipelines. Warnings don't fail the run. `-PassThru` on the preflight returns the result objects instead.
