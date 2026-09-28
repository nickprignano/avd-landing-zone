# Operations scripts (Cloud Shell)

Three PowerShell scripts in [`scripts/ops/`](../scripts/ops) that run against a **deployed** landing zone from Azure Cloud Shell:

| Script | What it does |
|---|---|
| `Test-AvdLandingZoneReadiness.ps1 -PreDeployment` | Preflight **before** deploying: is this subscription and tenant ready for the landing zone your parameter file describes? Check mode by default; `-Fix` remediates. |
| `Test-AvdLandingZoneReadiness.ps1` | Preflight **after** deploying: is the landing zone ready for session hosts and users, **including the three post-deployment tenant steps**? Check mode by default; `-Fix` remediates. |
| `Deploy-AvdDemo.ps1` | Deploys a demo host pool and session host into the landing zone, then validates that a user can sign in. |
| `Remove-AvdDemo.ps1` | Removes the demo. `-IncludeLandingZone` tears down the whole landing zone. |

They share `AvdLandingZone.psm1`. The landing zone's resources, Entra groups and AVD service principal are discovered from its naming convention and the role assignments it created, so the only required inputs are `-NamePrefix` and `-Environment`.

## Running them

```powershell
# Cloud Shell (PowerShell), in the landing zone subscription
git clone https://github.com/nickprignano/avd-landing-zone.git
cd avd-landing-zone
Set-AzContext -Subscription '<landing zone subscription>'

# 1. Before deploying: repeat until it comes back clean (-Fix remediates what it can).
#    -Location picks the region; omit it for the file's default (northcentralus).
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/dev.bicepparam -Location northcentralus -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins'
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/dev.bicepparam -Location northcentralus -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins' -Fix

# 2. Deploy, as a separate run (the clean preflight prints this command)
bash ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus --users-group 'AVD Users' --admins-group 'AVD Admins'

# 3. After deploying
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev          # check
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix     # fix
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -WellArchitected -SkipTenant -SkipNtfs   # Well-Architected review
./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -TestUserUpn alex@contoso.com
./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment dev
```

Microsoft Graph sign-in uses a device code in Cloud Shell: the script prints a code and waits until you enter it at https://microsoft.com/devicelogin. To sign in up front instead (the scripts reuse an existing sign-in that has the scopes they need):

```powershell
Connect-MgGraph -TenantId (Get-AzContext).Tenant.Id -UseDeviceCode -NoWelcome -Scopes 'Application.Read.All','Policy.Read.All','Group.Read.All','Directory.Read.All','Group.ReadWrite.All','Application.ReadWrite.All','DelegatedPermissionGrant.ReadWrite.All','Policy.ReadWrite.ConditionalAccess'
``` Required roles:

| For | Azure | Entra ID |
|---|---|---|
| Pre-deployment preflight | Reader (check); Owner or Contributor to register providers with `-Fix` | Directory Readers (check); Groups Administrator + Application Administrator with `-Fix` (creates groups and the AVD service principal) |
| Preflight (check) | Reader on the subscription, plus Role Based Access Control Administrator on the storage account for the NTFS step (it grants a temporary role) | Global Reader (or Security Reader + Directory Readers) |
| Well-Architected review (`-WellArchitected`) | Reader on the subscription | — (with `-SkipTenant`) |
| Preflight `-Fix` | Owner, or Contributor + Role Based Access Control Administrator | Cloud Application Administrator **and** Conditional Access Administrator |
| Demo deploy | Owner, or Contributor + Role Based Access Control Administrator | Global Reader (Cloud Application Administrator with `-FixNtfs`) |
| Cleanup | Owner | Intune Administrator + Cloud Device Administrator (to remove device objects) |

## Pre-deployment preflight

`-PreDeployment` works before the landing zone exists. To choose the region, use the [deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/): it builds this command with `-Location` set to the region you pick, and reads the output to tell you the next step. It compiles your `.bicepparam` file with the real group and service principal IDs and checks the subscription and tenant against the **effective** values (file values, else template defaults). Once it comes back clean, it prints the `deploy.sh` command to run as a separate step.

| Area | Check | `-Fix` |
|---|---|---|
| Tooling | PowerShell 7, Bicep CLI, `az` and `bash` (used by `deploy.sh`), Microsoft.Graph.Authentication | — |
| Entra ID | `-UsersGroup` / `-AdminsGroup` (name or object ID) resolve to exactly one security group each, with members; the Azure Virtual Desktop service principal exists | Creates missing groups (by name) and the service principal. `-AddMeToGroups` (separate switch) adds you to both groups |
| Parameters | The file compiles, with `-Location` overriding its region; prints prefix, environment, region, host count and size, zones, connectivity mode, Intune enrollment | — |
| Subscription | Owner, or Contributor + RBAC Administrator, plus policy rights when `enablePolicyGuardrails`; every resource provider `deploy.sh` needs; AVD host pools offered in the region; `EncryptionAtHost` (when used); VM size offered in **every requested zone**; family and regional vCPU quota for the host count; the profile storage SKU (Premium ZRS/LRS file shares) in the region; no soft-deleted, purge-protected Key Vault holding the vault name; budget parameters complete | Registers providers and the feature and **waits** for them (up to 15 minutes; the feature takes about that long), then re-registers `Microsoft.Compute` so the feature takes effect |
| Network | HubPeered only: hub VNet readable; firewall IP set for egress; central DNS zone IDs present | — |
| Landing zone | Whether `rg-<prefix>-<env>-*` already exists (deploying then updates in place), and fails if it exists in another region (resource groups can't move) | — |
| Tenant | Intune licensing when `enrollInIntune = true` (the join fails without it); whether you hold active roles for the post-deployment steps; which Conditional Access policies will need the storage app excluded | — |

## Post-deployment preflight: what it checks and fixes

| Area | Check | `-Fix` |
|---|---|---|
| Tooling | PowerShell 7, Bicep CLI, Microsoft.Graph.Authentication | — |
| Subscription | Your RBAC; resource providers; `EncryptionAtHost` feature; VM size offered in the region and zones; family and regional vCPU quota | Registers providers and the feature, waits for them, then re-registers `Microsoft.Compute` |
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

## Well-Architected review

`-WellArchitected` adds a review of the **deployed** landing zone against the [Azure Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/), grouped by pillar and ending with a scorecard. It needs only Reader; add `-SkipTenant -SkipNtfs` to leave out the tenant steps (no Graph sign-in). Findings are **warnings, never failures**: they are trade-offs to review, not deployment blockers. Why it is built this way: [decision 0009](decisions/0009-well-architected-review.md).

| Pillar | Checks |
|---|---|
| Reliability | At least two session hosts; hosts in availability zones (and whether the region has any); zone-redundant profile storage; share soft delete; profile share backup; Azure Advisor reliability recommendations |
| Security | Defender for Cloud plans for servers, storage and Key Vault; Trusted Launch and encryption at host; storage TLS 1.2, HTTPS only and no shared keys; Key Vault purge protection, RBAC and private access; open Defender for Cloud recommendations on landing zone resources |
| Cost Optimization | A budget; a scaling plan enabled on the host pool; Advisor cost recommendations |
| Operational Excellence | Host pool diagnostics to Log Analytics; log retention of 90 days or more; Azure Policy compliance of the landing zone resource groups; Advisor recommendations |
| Performance Efficiency | Accelerated networking on the session hosts; Advisor recommendations |
| All | **PSRule for Azure** on the live resources, with the same rules and suppressions CI applies to the templates, so drift since deployment shows up. It installs `PSRule.Rules.Azure` on first use and takes a minute or two; `-SkipPSRule` leaves it out |

**Expected in dev.** `parameters/dev.bicepparam` keeps costs down on purpose: one host, locally redundant storage, no backup, Defender off, 30-day logs, no budget, and a region without zones by default. In dev and test those findings say *Expected in dev* and the scorecard counts them separately; in prod the same findings are plain warnings. `parameters/prod.bicepparam` fixes most of them; availability zones also need a region that has them.

**PSRule on live resources** also evaluates the subscription itself, so it can report settings the landing zone doesn't manage: Defender for Cloud security contacts and provisioning, PIM for privileged roles, a Service Health alert (the landing zone deploys one only when `AVD_ALERT_EMAIL` is set). These are real findings for a review; fix them in the subscription. Rules that can't read this design are suppressed with the reason in `.ps-rule/Suppressions.Rule.yaml` (NAT Gateway public IPs, encryption at host instead of Azure Disk Encryption). Each finding shows the rule's reason.

**Limits.** Advisor and Policy evaluate on their own schedule (about once a day), so a landing zone deployed today can look cleaner than it is; run the review again the next day. Microsoft's [Well-Architected assessment](https://learn.microsoft.com/assessments/) for Azure Virtual Desktop is a questionnaire about your requirements (recovery targets, operations, support) that no script can answer; this review gives you the evidence for most of its questions.

## Deployment portal

Every script ends with a machine-readable line (`<<<AVDLZ-STATE {...} AVDLZ-STATE>>>`): the stage, whether it passed, the context for the next command, and each failure with a stable id. Paste the output into the [deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/) and it tells you what to run next. The format is described in [`docs/portal/README.md`](portal/README.md).

If the portal gives the wrong advice or you are stuck, use **Report a problem** in the portal. It builds a GitHub issue from the output you pasted. Before anything leaves your browser, it removes email addresses, IDs, subscription and resource names, your name prefix and group names, and secrets. You review the report, tick that it contains nothing private, and submit it on GitHub. Issues are public.

## Exit codes

Preflight and demo return **0** when nothing failed and **1** otherwise, so you can use them in pipelines. Warnings don't fail the run. `-PassThru` on the preflight returns the result objects instead.
