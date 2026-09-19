# AVD Landing Zone — the baseline

A deployable **Azure Virtual Desktop landing zone baseline** — the must-haves, not the magic.

This repo stands up the non-negotiable 80% of an AVD deployment that's the same in every environment: networking, identity wiring, storage, a host pool, and a scaling plan. It's the floor. What you build on top of it — workload sizing, identity edge cases, cost tuning, compliance overlays — is the real engineering, and that's deliberately **out of scope** (see [`docs/out-of-scope.md`](docs/out-of-scope.md)).

---

## What this deploys

| Layer | What you get | AVM module |
|-------|--------------|------------|
| **Networking** | Spoke VNet, session-host + private-endpoint subnets, NSGs, route table forcing egress through a hub | `avm/res/network/virtual-network` |
| **Private endpoints + DNS** | Private endpoints for storage; private DNS zone linked to the VNet | `avm/res/network/private-endpoint`, `avm/res/network/private-dns-zone` |
| **Storage** | Premium Azure Files share behind a private endpoint, with Entra Kerberos for SMB auth, for FSLogix profiles | `avm/res/storage/storage-account` |
| **Host pool** | AVD host pool, application group, workspace | `avm/res/desktop-virtualization/host-pool` (+ app group, workspace) |
| **Session hosts** | VMs joined to Entra ID, AVD agents registered | `avm/res/compute/virtual-machine` |
| **Scaling** | A scaling plan attached to the host pool | `avm/res/desktop-virtualization/scaling-plan` |
| **Access** | The role assignments that make the above usable: desktop access, VM sign-in, SMB share access, and power on/off for the scaling plan | native `Microsoft.Authorization/roleAssignments` |
| **Cost guard** | Daily auto-shutdown, a resource-group budget with alerts, and a kill switch that disables the scaling plan and deallocates the hosts | `avm/res/insights/action-group` + native budget / Logic App |

The Bicep is a thin orchestration layer (`bicep/main.bicep`) that composes [Azure Verified Modules](https://aka.ms/avm) — you're not maintaining the network or storage modules, you're wiring Microsoft-maintained ones together.

---

## Scope boundary (read this before you fork)

**In scope — the floor:**
- A working spoke network with the guardrails in place before anything else
- Private endpoints + DNS so traffic stays off the public internet
- FSLogix-ready storage
- A non-persistent host pool with a scaling plan
- **Entra ID join** for session hosts, with **Entra Kerberos** so profiles can mount without domain services
- The **RBAC** that an Entra-only deployment actually needs — desktop access, VM sign-in, SMB share access, and the scaling plan's power on/off rights
- **Cost controls you can actually rely on** — auto-shutdown, a budget, and a kill switch, with honest documentation of what each one can and cannot stop
- **Standalone by default** — runs on a fresh personal subscription with no hub; optionally peers to an existing hub

**Out of scope — the real engagement** (see [`docs/out-of-scope.md`](docs/out-of-scope.md)):
- **Entra Domain Services and hybrid / AD DS join** — Entra-only by default
- Golden image / imaging pipeline (uses a marketplace image)
- Workload sizing, IOPS/backup strategy for profile storage
- Hub deployment (standalone needs none; hub-peered mode assumes a hub exists and you supply its resource ID)
- Creating the tenant / subscription itself (signing up at portal.azure.com gives you both)
- Cost optimization tuning, compliance/policy overlays, monitoring

If a thing isn't in the table above, assume it's intentionally left for you.

---

## Quick start — standalone demo on a personal subscription

This is the **minimum viable path**: a brand-new pay-as-you-go subscription, clone, run, connect to a desktop. No hub, no domain, no pre-existing infrastructure. Defaults are set for exactly this.

> **No Azure account yet?** [`docs/setup-azure-account.md`](docs/setup-azure-account.md) walks through creating the tenant + subscription on a personal card (≈10 min) — including why to use pay-as-you-go rather than the free trial for an AVD demo.

```bash
# 0. One-time: log in and point at your subscription
az login
az account set --subscription "<your-subscription-id>"

# 1. Clone
git clone https://github.com/nickprignano/avd-landing-zone.git
cd avd-landing-zone

# 2. Copy the example parameters. The defaults already work standalone —
#    you only HAVE to set namePrefix and location if you want to change them.
cp parameters/dev.example.bicepparam parameters/dev.bicepparam

# 3. Deploy the infrastructure (az). The script registers resource providers,
#    creates the resource group, grants the desktop to YOU, and prompts for an
#    admin password. First run registers providers — that can take a few minutes.
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -g rg-avd-lz-dev -l eastus2

# 4. Post-deploy configuration (PowerShell)
pwsh ./scripts/config/Configure-FSLogix.ps1 -ResourceGroup rg-avd-lz-dev
pwsh ./scripts/config/Register-SessionHosts.ps1 -ResourceGroup rg-avd-lz-dev

# 5. ONE manual step: grant admin consent for Entra Kerberos on the storage
#    account, as a Global Administrator. Profiles will not mount without it.
#    See docs/gotchas.md#4 for the exact commands.

# 6. Connect: open the AVD client, sign in with the same account, open the desktop.
```

That's it — cloning and following these steps produces a working AVD desktop. Full walkthrough and verification in [`docs/deploy.md`](docs/deploy.md).

> **Cost note — read [`docs/cost-controls.md`](docs/cost-controls.md) before you deploy.** This runs real VMs and premium storage on your card, and **Azure has no hard spending cap on pay-as-you-go**. The template ships four layers of protection — daily auto-shutdown on the session hosts, the scaling plan, a manual kill switch, and a budget-triggered automated one — but only the manual one is instant. Budget alerts lag real usage by 8–24 hours, so they are a backstop, not a cap.
>
> ```bash
> ./scripts/ops/stop-lab.sh -g rg-avd-lz-dev            # stop now, reversible
> ./scripts/ops/stop-lab.sh -g rg-avd-lz-dev --delete   # remove everything
> ```

### Peering to a real hub instead (enterprise path)

The standalone mode skips hub peering and forced egress. To run the "real" posture — peer to an existing hub and force egress through its firewall — set `hubVnetResourceId` in your `.bicepparam` to the hub VNet's resource ID (and `hubFirewallPrivateIp` if it differs from the default). Everything else is identical.

---

## Prerequisites

For the standalone personal-subscription demo, all you need is:

- An Azure subscription you can create resources in (a personal pay-as-you-go sub is fine)
- Azure CLI ≥ 2.60 (`az bicep upgrade` to get the Bicep extension)
- PowerShell 7+ with the `Az` modules (`Install-Module Az`) — for the two config scripts
- vCPU quota in your region for the session-host VM size — **check this first** (see [`docs/gotchas.md`](docs/gotchas.md)); brand-new subs sometimes start with low quota

The deploy script handles the rest that a fresh subscription needs: **resource provider registration** and **granting the desktop to the signed-in user**. You do **not** need a hub, a domain, or a pre-made Entra group for the standalone path.

What's still assumed (and intentionally upstream — see [`docs/out-of-scope.md`](docs/out-of-scope.md)): creating the **tenant and subscription** themselves. If you're swiping a personal card, signing up at portal.azure.com gives you both automatically before you start.

---

## Repo layout

```
avd-landing-zone/
├── bicep/
│   ├── main.bicep              # orchestration: composes the modules below
│   └── modules/                # thin wrappers around AVM, one per concern
│       ├── network.bicep
│       ├── privateEndpoints.bicep
│       ├── storage.bicep
│       ├── hostPool.bicep
│       ├── scalingPlan.bicep
│       ├── rbac.bicep          # cross-cutting role assignments
│       └── costGuard.bicep     # budget + alerts + automated kill switch
├── parameters/
│   └── dev.example.bicepparam  # copy -> dev.bicepparam and edit
├── scripts/
│   ├── deploy/deploy.sh        # az deployment of the Bicep
│   ├── ops/stop-lab.sh         # kill switch: stop / start / delete the lab
│   └── config/                 # PowerShell post-deploy config
│       ├── Configure-FSLogix.ps1
│       └── Register-SessionHosts.ps1
├── docs/
│   ├── deploy.md
│   ├── setup-azure-account.md
│   ├── architecture.md
│   ├── cost-controls.md
│   ├── ci.md
│   ├── out-of-scope.md
│   └── gotchas.md
└── .github/workflows/
    └── validate.yml            # lint (auto) + what-if (opt-in) on PR — see docs/ci.md
```

---

## CI / validation

The repo ships a GitHub Actions workflow (`.github/workflows/validate.yml`):

- **Lint** runs on every PR touching `bicep/`, `parameters/`, or the workflow — it builds the Bicep (including resolving the pinned AVM modules) and fails the PR if it doesn't transpile. **No setup required.**
- **What-if** is opt-in: set the repo variable `AZURE_WHATIF_ENABLED=true` and it runs `az deployment group what-if` against a test resource group on each PR. It authenticates with **OIDC** (no stored secret).

To enable the what-if you'll need secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `SH_ADMIN_PW`, variables `AZURE_WHATIF_ENABLED` + `AZURE_WHATIF_RG`, and a federated credential on the app registration. Full step-by-step (including the exact `az` commands) is in [`docs/ci.md`](docs/ci.md).

## A note on what this is *not*

This is a teaching baseline, not a hardened production module set. It's deliberately readable over clever, and it stops at the floor on purpose. Fork it, change the parameters, and make it yours — then do the actual engineering on top.

## License

MIT — see [`LICENSE`](LICENSE). Use it, fork it, ship it.
