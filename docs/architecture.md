# Architecture

The shape of what this deploys.

```
            HUB VNet (you provide)              SPOKE VNet (this template)
        ┌───────────────────────────┐      ┌────────────────────────────────────┐
        │  Azure Firewall / NVA      │◄─────┤  NETWORKING (#1)                    │
        │  Private DNS Zones         │ peer │   snet-session-hosts (no public IP) │
        │  VPN / ExpressRoute GW     │      │   snet-private-endpoints            │
        │                            │      │   NSG + route table → egress to hub │
        │  IDENTITY (#2)             │      │                                     │
        │   Entra ID (tenant, CA)    │◄─────┤  HOST POOL                          │
        │   [Domain services = OUT   │ join │   session hosts (Entra ID joined)   │
        │    OF SCOPE — Entra only]  │      │   app group + workspace             │
        └───────────────────────────┘      │   Scaling Plan                      │
                                           │                                     │
                                           │  STORAGE (#3)                       │
                                           │   Azure Files (private endpoint)    │
                                           │   FSLogix profile containers        │
                                           └────────────────────────────────────┘
```

## The three non-negotiables, in order

1. **Networking** — the boundary everything else sits inside. Spoke VNet, isolated subnets, NSGs, forced egress through the hub. Built first because nothing can be deployed correctly until it exists.
2. **Identity** — Entra ID join. Who can sign in and what they can reach. Built before the host pool because hosts need somewhere to join. **Entra-only by default**; domain services are out of scope.
3. **Storage** — FSLogix profile storage behind a private endpoint. Where the user's desktop persists. Without it, a non-persistent pool is useless.

## Why AVM

`main.bicep` is a thin orchestration layer. The actual resources come from [Azure Verified Modules](https://aka.ms/avm) — Microsoft-maintained, tested module wrappers. You compose them; you don't maintain them. That's the whole "don't rebuild the boring 80%" idea expressed in the code.

## What's deliberately missing

See [out-of-scope.md](out-of-scope.md). The short version: the hub, golden imaging, domain services, sizing, cost tuning, monitoring, and compliance are all yours. This is the floor.
