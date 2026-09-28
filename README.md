# Cloud-native AVD Landing Zone

An **enterprise-ready Azure Virtual Desktop landing zone for greenfield, cloud-native organisations** — Entra ID-joined, Intune-managed, private by default, and deployed end to end from one Bicep template.

It is deliberately *not* a general-purpose accelerator. Microsoft's [AVD Landing Zone Accelerator](https://github.com/Azure/avdaccelerator) (LZA) covers every identity model and brownfield scenario through a wide option surface. This repo makes the opposite trade: **one opinionated path — no domain controllers, no line of sight to on-premises, no post-deployment scripts** — and hardens that path fully. See [`docs/design-decisions.md`](docs/design-decisions.md) for the side-by-side.

## What you get

| Area | What's deployed | Why it matters |
|------|-----------------|----------------|
| **Identity** | Session hosts Entra ID-joined and Intune-enrolled; Entra SSO; VM User/Admin Login RBAC; break-glass local admin stored in Key Vault | No AD DS or Entra Domain Services to run; devices managed like every other endpoint |
| **Profiles** | Premium Azure Files (ZRS) with **Entra Kerberos**, shared-key access disabled, SMB 3.1.1 + AES-256, private endpoint, share RBAC, soft delete, **Azure Backup** | FSLogix without storage keys, domain joins or a management VM |
| **Session hosts** | Trusted Launch (Secure Boot + vTPM), encryption at host, zone-spread, Windows 11 24H2 multi-session + M365, AMA + AVD Insights, Guest Configuration | Secure by default; registered and FSLogix-configured **declaratively** by managed Run Commands |
| **Control plane** | Pooled host pool with **AVD Private Link** for session hosts, Start VM on Connect, scheduled agent updates, hardened RDP properties, weekday/weekend autoscale | Hosts reach AVD privately; idle cost is scaled away |
| **Network** | Spoke with **no default outbound access**: NAT Gateway (standalone) or hub firewall (hub-peered, peering created both ways); NSG on the private endpoint subnet; private DNS | Egress is always explicit, which suits the retirement of Azure's default outbound access |
| **Operations** | Log Analytics, AVD Insights DCR, diagnostics on every resource, alerts (unhealthy hosts, FSLogix errors, connection errors, Service Health), activity log export | Day-2 visibility from day 1 |
| **Governance** | Azure Policy guardrails (allowed locations, tag inheritance), Defender for Cloud (Servers P2, Storage, Key Vault), subscription budget | The subscription arrives governed |
| **Delivery** | Strict Bicep linting, PSScriptAnalyzer, shellcheck, PSRule for Azure, subscription what-if on PRs, environment-gated deploy workflow (OIDC) | Changes are reviewed as code and promoted with approvals |

Everything is built from pinned [Azure Verified Modules](https://aka.ms/avm).

## Quick start

Prerequisites (details in [`docs/deploy.md`](docs/deploy.md)):
- A **dedicated subscription** where you are Owner, plus Azure CLI ≥ 2.65.
- Two Entra ID security groups: AVD users and AVD admins.
- Intune licensing in the tenant (or set `enrollInIntune = false`).
- vCPU quota for the session host size in your region.

```bash
az login && az account set --subscription "<subscription-id>"

# What-if first
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l eastus2 \
  --users-group "AVD Users" --admins-group "AVD Admins" --what-if

# Deploy (≈30-45 min the first time)
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l eastus2 \
  --users-group "AVD Users" --admins-group "AVD Admins"
```

Then finish the three one-time tenant steps (admin consent for the storage account's Entra app, a Conditional Access exclusion, and NTFS hardening) from Azure Cloud Shell. The preflight checks them and `-Fix` applies them:

```powershell
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix
./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -TestUserUpn you@contoso.com   # optional demo + sign-in validation
```

See [`docs/operations.md`](docs/operations.md). Users in the AVD Users group can then sign in through the Windows App.

## Repo layout

```
avd-landing-zone/
├── bicep/
│   ├── main.bicep                 # subscription-scope orchestration
│   ├── demo/main.bicep            # demo host pool inside a deployed landing zone
│   └── modules/
│       ├── governance.bicep       # policy, Defender, budget, activity log
│       ├── monitoring.bicep       # Log Analytics, AVD Insights DCR, alerts
│       ├── network.bicep          # spoke, NSGs, NAT Gateway / hub routing, peering
│       ├── privateDns.bicep       # privatelink zones (standalone)
│       ├── keyVault.bicep         # break-glass credential
│       ├── storage.bicep          # Azure Files + Entra Kerberos for FSLogix
│       ├── backup.bicep           # Azure Backup for the profile share
│       ├── controlPlane.bicep     # host pool, app group, workspace, autoscale
│       └── sessionHosts.bicep     # VMs, run commands, host RBAC
├── bicepconfig.json               # linter: security rules are errors
├── parameters/
│   ├── dev.bicepparam             # tenant values read from environment variables
│   └── prod.bicepparam
├── scripts/
│   ├── deploy/deploy.sh           # providers, features, lookups, deploy
│   ├── ops/                       # Cloud Shell: preflight (-Fix), demo deploy + validation, cleanup
│   └── sessionhost/               # embedded into Run Commands at compile time
│       ├── Set-FSLogixConfiguration.ps1
│       └── Register-AvdAgent.ps1
├── tests/                         # Pester unit tests for scripts/ops
├── ps-rule.yaml                   # PSRule for Azure configuration
├── docs/
└── .github/workflows/
    ├── validate.yml               # lint, analysis, PSRule, what-if
    └── deploy.yml                 # manual, environment-gated deployment
```

## Documentation

- [`docs/design-decisions.md`](docs/design-decisions.md): the opinions this repo takes and how it compares with the LZA
- [`docs/architecture.md`](docs/architecture.md): resource layout, traffic flows, identity and RBAC model
- [`docs/deploy.md`](docs/deploy.md): prerequisites, deployment, post-deployment steps, scaling out, teardown
- [`docs/operations.md`](docs/operations.md): preflight with fix mode, demo host pool with sign-in validation, cleanup
- [`docs/ci.md`](docs/ci.md): validation and deployment pipelines, OIDC setup
- [`docs/gotchas.md`](docs/gotchas.md): the things that bite
- [`docs/out-of-scope.md`](docs/out-of-scope.md): what this repo does not do
- [`docs/setup-azure-account.md`](docs/setup-azure-account.md): starting from zero on a personal card (lab use)

## License

MIT — see [`LICENSE`](LICENSE).
