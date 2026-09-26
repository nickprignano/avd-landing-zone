# Design decisions

This landing zone is **opinionated on purpose**. Each opinion removes a class of options, and with it a class of failure modes. This page records those choices and compares them with Microsoft's [AVD Landing Zone Accelerator](https://github.com/Azure/avdaccelerator) (LZA).

## Who this is for

Organisations that are **cloud-native or going cloud-native with AVD**:
- identities in Entra ID (cloud-only or synced);
- devices managed by Intune;
- no requirement for AD DS-joined session hosts, Group Policy, or line of sight to domain controllers;
- a new (greenfield) AVD subscription.

If you need AD DS or Entra Domain Services-joined hosts, brownfield integration into existing resource groups, or a portal wizard, use the LZA. It is built for that breadth.

## How it differs from the LZA

| Concern | AVD LZA | This repo |
|---|---|---|
| **Identity model** | Choose between AD DS, Entra Domain Services, Entra ID, and Entra ID + Kerberos (the Bicep default is AD DS) | **Entra ID only.** Entra join + Intune enrollment, Entra Kerberos for profiles. No domain credentials anywhere in the deployment |
| **Scenarios** | Greenfield and brownfield, many toggles, portal UI + Bicep + Terraform | **Greenfield only**, one path, ~40 parameters, Bicep only |
| **Session host configuration** | Custom Script Extension that downloads configuration scripts from GitHub at deploy time | **Managed Run Commands** whose scripts are embedded at compile time (`loadTextContent`). Session hosts need no route to GitHub, and a deployment can't be changed by an upstream edit |
| **Host registration** | Scripted during deployment | Declarative, idempotent Run Command. The token is passed as a protected parameter and a redeploy never re-registers a healthy host |
| **FSLogix storage auth** | Storage keys, or domain-joining the storage account through a DSC package and management VM | **Entra Kerberos** with shared-key access disabled. No management VM, no keys, no DSC |
| **Egress** | Depends on the chosen networking option | Always explicit: subnets are created with **default outbound access off**, and egress goes through a NAT Gateway (standalone) or the hub firewall |
| **AVD Private Link** | Optional | **On by default** for the host pool connection (session hosts go private; clients still connect from anywhere) |
| **Session host security** | Configurable | Trusted Launch, encryption at host, no public IPs, IaaS antimalware off (Defender is built into Windows 11), Guest Configuration on |
| **Governance** | Optional custom policy definitions | Subscription guardrails built in: allowed locations, tag inheritance, Defender for Cloud plans, budget, activity log export |
| **Operations** | AVD Insights optional | AVD Insights DCR, diagnostics on every resource and **actionable alerts** on by default |
| **Delivery** | Deploy from the portal or CLI | CI/CD included: strict lint, script analysis, PSRule for Azure, what-if on PRs, environment-gated deploy with OIDC |
| **Codebase** | Large, broad | Small enough to read in an afternoon: `main.bicep` plus nine modules |

## Decisions

### 1. Entra ID only
Supporting several identity models is where most of the complexity in AVD deployments comes from: domain-join credentials, OU paths, DNS line of sight to domain controllers, and storage-account domain joins. Choosing Entra ID removes all of it. Hosts are Entra-joined by the `AADLoginForWindows` extension and optionally enrolled in Intune (`mdmId`). Admin access is through Entra RBAC (VM Administrator Login), not a shared credential.

### 2. Entra Kerberos for FSLogix, shared keys off
Session hosts retrieve Kerberos tickets for the share from Entra ID (`CloudKerberosTicketRetrievalEnabled`). The storage account allows **only Kerberos over SMB 3.1.1 with AES-256**, has **shared-key access disabled**, and is reachable only through its private endpoint. Share-level access is RBAC on Entra groups.
Trade-off: one tenant step (admin consent for the storage account's app registration) can't be done in Bicep. See [deploy.md](deploy.md#4-post-deployment).

### 3. Everything declarative, nothing downloaded from GitHub
Run Commands (`Microsoft.Compute/virtualMachines/runCommands`) are ARM resources, so host configuration is part of the deployment graph and its success or failure is the deployment's (`treatFailureAsDeploymentFailure`). The PowerShell lives in `scripts/sessionhost/` and is compiled into the template, so the same commit always configures hosts the same way. The only runtime downloads are the AVD agent and boot loader, fetched from Microsoft's official links.

### 4. Explicit egress
Azure is retiring default outbound access for new VNets. Subnets are created with `defaultOutboundAccess: false` (this can only be set at creation), so every packet leaves through something you chose: a NAT Gateway in standalone mode, or the hub firewall in hub-peered mode (UDR 0.0.0.0/0, peering created in both directions).

### 5. Private by default, public where users need it
Storage, Key Vault, and the host pool connection path use Private Link. The workspace feed stays public so users can subscribe from any network, which is the typical cloud-native pattern of internet-first access gated by Conditional Access.

### 6. One resource group per lifecycle
`network`, `management`, `storage`, `avd` (control plane), `hosts`. Hosts can be rebuilt without touching profiles; RBAC is scoped per group (for example, VM login roles only on `hosts`).

### 7. Subscription-scope deployment
The landing zone owns its subscription, following the subscription-vending model. That's what makes subscription guardrails, Defender plans and the budget possible. If your platform team already assigns these from a management group, turn them off with `enablePolicyGuardrails` / `enableDefenderForCloud`.

### 8. Compile-time safety
`bicepconfig.json` promotes the security-relevant linter rules to errors (secure parameters, secrets in outputs, hardcoded cloud URLs). Parameter files read tenant values from environment variables and fail to compile if a required one is missing.
