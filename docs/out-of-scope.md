# Out of scope — where the template stops and the engineering starts

This repo is the **floor**: the non-negotiable baseline that's the same in every AVD deployment. The list below is everything it deliberately does *not* do. None of these are oversights — they're the parts that depend on your org, and they're where the real engagement lives.

If you fork this for a real deployment, this is your backlog.

## Identity

- **Entra Domain Services and hybrid / AD DS join.** This template is **Entra-ID-only by default**. Session hosts are Entra joined with `enablerdsaadauth`. If you need traditional domain join — for legacy apps, GPO, on-prem resource access — that's a different identity model and a different host configuration. Out of scope on purpose.
- **Conditional Access policies.** Who can connect, from where, under what conditions — your security team owns this.
- **Trust to existing forests, legacy auth, app-level identity dependencies.** The edge cases that make identity the hardest of the three non-negotiables.

## Networking

- **The hub.** The **standalone default needs no hub** — it runs on a fresh subscription with default internet egress, which is what makes the demo clone-and-run. The optional hub-peered mode assumes a hub VNet already exists and peers to it; firewall, gateway, and shared services are yours.
- **Address space / IPAM planning.** The defaults are lab ranges. Real ranges, peering to on-prem, and avoiding overlap is a planning conversation, not a parameter.

## Tenant & subscription

- **Creating the tenant and the subscription themselves** is upstream of this template. Signing up at portal.azure.com with a card creates both for you automatically. Enterprise tenant/subscription vending (management groups, EA/MCA billing scopes, landing-zone governance) is a whole discipline of its own and deliberately out of scope.

## Imaging

- **Golden image / image pipeline.** Session hosts use a marketplace Windows 11 multi-session image. What goes in your image, how you patch and version it, custom image templates or a build pipeline — a whole separate topic.

## Storage

- **Sizing.** Premium file share at a fixed quota is a sane default, not a sized solution. IOPS, capacity, tiering, and backup strategy are a sizing exercise that depends on your user count and profile behavior.
- **Backup / DR for profiles.** Not configured here.

## Operations

- **Cost optimization.** The scaling plan schedule is a reasonable default. Tuning it to real usage — time zones, shift patterns, how aggressively you can scale down — is where the savings actually are. Basic *cost safety* (auto-shutdown, a budget, a kill switch) is in scope and documented in [cost-controls.md](cost-controls.md); cost *optimization* is not.
- **Monitoring / Log Analytics / alerts.** Not wired up.
- **Policy / compliance overlays.** Azure Policy, regulatory baselines, tagging enforcement — org-specific.

---

**The point:** the floor is built once and reused. Everything above is the building, and the building is the job. That's not a gap in the template — it's the line between a starting point and a delivered solution.
