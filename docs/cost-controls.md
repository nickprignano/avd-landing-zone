# Cost controls — how not to get a surprise bill

This template runs real VMs and premium storage. If you are paying out of your
own pocket, read this before you deploy.

## The thing you need to know first

**Azure has no hard spending cap on a pay-as-you-go subscription.** There is no
setting that stops the meter. The spending limit you may have read about applies
only to credit-based subscriptions (free trial, Visual Studio, MSDN) — when the
credit runs out those get disabled. A pay-as-you-go subscription on a card has no
equivalent, by design.

So nothing in this repo *prevents* spend. Everything here bounds it, and the
bounds have different reaction times. Use the fast ones.

## The second thing: budget alerts are slow

Azure Cost Management budgets are evaluated against cost data that lags real
usage by roughly **8–24 hours**. A budget-triggered kill switch can fire most of
a day after you blew past the number. It is a backstop for when you forget, not
a guard.

This is why the **forecast** alert matters more than the actual-spend one: it
warns you on trajectory rather than waiting for the spend to land.

## What's wired up, fastest first

| Layer | Reaction time | Stops | Where |
|---|---|---|---|
| **Auto-shutdown** on session hosts | Deterministic, daily | Session host compute | `hostPool.bicep`, on by default, 19:00 local |
| **Scaling plan** ramp-down | Within the hour, out of hours | Most session host compute | `scalingPlan.bicep` |
| **`stop-lab.sh`** | Immediate | Session host compute | `scripts/ops/stop-lab.sh` |
| **Budget kill switch** | 8–24h late | Session host compute | `costGuard.bicep` |
| **`stop-lab.sh --delete`** | Immediate | Everything | `scripts/ops/stop-lab.sh` |

Note what's missing from most of those rows: only `--delete` takes the bill to
zero. Deallocating the hosts stops the large, hourly part of the bill. Managed
disks, the premium file share and the private endpoint keep charging whether
anything is running or not.

## Where the money actually goes

The session host VMs dominate, by a wide margin. Two `Standard_D4as_v5` left
running 24/7 are the overwhelming majority of this deployment's cost — on the
order of a few hundred dollars a month in common US regions, against roughly
tens of dollars a month for everything else combined.

Those are order-of-magnitude figures to set your expectations, not a quote.
Prices vary by region and change; check the
[pricing calculator](https://azure.microsoft.com/pricing/calculator/) for your
region before you deploy, and set `monthlyBudgetAmount` from that.

The practical consequence: **deallocating the VMs removes most of the bill**,
which is exactly what both kill switches do.

If you want the demo to cost less, the highest-leverage knob is
`sessionHostCount = 1`, followed by a smaller `sessionHostVmSize`. Check quota
for whatever you pick — see [gotchas.md](gotchas.md).

## The manual kill switch

The one to actually reach for.

```bash
./scripts/ops/stop-lab.sh -g rg-avd-lz-dev --status   # what's running
./scripts/ops/stop-lab.sh -g rg-avd-lz-dev           # stop it (reversible)
./scripts/ops/stop-lab.sh -g rg-avd-lz-dev --start   # bring it back
./scripts/ops/stop-lab.sh -g rg-avd-lz-dev --delete  # remove everything
```

Add `-s <subscription-id>` to target a specific subscription instead of
whatever your `az` context happens to be set to. It does not change your global
az context — the flag is passed per-command. Either way the script prints the
subscription name and ID before it touches anything, and `--delete` names them
in the confirmation prompt. Acting on the wrong subscription is the mistake that
actually happens, and with `--delete` there is no undo.

`stop` disables the scaling plan **before** deallocating the hosts. That order
matters: deallocate without disabling the plan and it ramps everything back up
at the next ramp-up window, which on a weekday is 07:00.

`--start` reverses both.

## The automated kill switch

`bicep/modules/costGuard.bicep` deploys:

- A **budget** scoped to the lab's resource group, at `monthlyBudgetAmount`.
- Alerts at 50% and 80% of actual spend (email), at 100% **forecast** (email —
  your early warning), and at 100% actual (email + kill switch).
- An **action group** wired to a **Logic App** which disables the scaling plan
  and then deallocates every VM in the resource group.

The Logic App runs on consumption billing, so while it sits idle it costs
nothing.

### Permissions

The Logic App uses a system-assigned managed identity holding exactly two roles
at resource group scope:

- **Virtual Machine Contributor** — to deallocate the hosts.
- **Desktop Virtualization Contributor** — to switch the scaling plan off.

It deliberately does **not** hold Contributor, and it deliberately does **not**
delete anything. The action group triggers it via a callback URL, and that URL
is a bearer credential: anyone who has it can fire it. A URL that can stop your
lab is an acceptable risk. A URL that can delete it is not. Deleting stays
manual, behind a typed confirmation, in `stop-lab.sh --delete`.

### Testing it

Do this once, before you trust it. From the portal: Logic App →
**Run trigger** → `manual`. The hosts should deallocate and the scaling plan
should show `scalingPlanEnabled: false`. Confirm with:

```bash
./scripts/ops/stop-lab.sh -g rg-avd-lz-dev --status
```

Then `--start` to undo. An untested kill switch is not a kill switch.

## Configuration

In your `.bicepparam`:

```bicep
param enableAutoShutdown = true
param autoShutdownTime = '1900'                  // HHmm, 24-hour
param autoShutdownTimeZone = 'Eastern Standard Time'

param enableCostGuard = true
param monthlyBudgetAmount = 50
param costAlertEmails = [ 'you@example.com' ]
```

**Set `costAlertEmails` explicitly.** If you leave it empty the deploy script
falls back to your signed-in address — but on a personal subscription created
with a Microsoft account, that identity is often a guest whose UPN looks like
`you_gmail.com#EXT#@yourtenant.onmicrosoft.com` and **does not receive mail**.
The script detects that shape and refuses to use it rather than sending your
budget alerts into a void, but then the cost guard is skipped entirely. Set a
real inbox.

## Known limits

- The budget's `startDate` must be the first of a month. If you redeploy in a
  later month and Azure rejects the start-date change, pass the original value
  as `budgetStartDate`.
- The budget is scoped to the **resource group**. It does not see spend
  elsewhere in the subscription.
- Deallocated VMs still incur disk charges. Only `--delete` reaches zero.
- None of this has been exercised against a live subscription. See the caveat in
  the repo history.
- No subscription or tenant ID is committed anywhere. Bicep resolves the
  subscription with `subscription().subscriptionId`; the scripts use your `az`
  context or `-s`. A CI job (`no-hardcoded-ids` in `validate.yml`) fails the
  build if either regresses, or if a real `.bicepparam` is force-added.
