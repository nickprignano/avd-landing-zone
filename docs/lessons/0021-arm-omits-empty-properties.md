# 0021. ARM leaves out empty properties, and `@($null).Count` is 1

- **Area:** Preflight (Well-Architected review)
- **Found in / fixed by:** first live `-WellArchitected` run, northcentralus; fixed in the PR after #19

## What happened
The review passed the zone check in a region without availability zones, with an empty list:
```
  [PASS ] Session hosts spread across availability zones
          Zones: 
```
The storage finding also lost its "ZRS needs a region with availability zones" note. The offline scenario had passed.

## Why
ARM omits a property that has no value. A regional VM has no `zones` property, and a region without zones has no `availabilityZoneMappings`. The code counted them with `@($vm.zones).Count` and `@($loc.availabilityZoneMappings).Count`, and in PowerShell `@($null)` is a one-element array, so both counts were 1. The mock returned empty arrays (`zones = @()`) instead of omitting the property, so it was more permissive than Azure and hid the bug.

The same run also found two PSRule for Azure rules that can't read this design: `Azure.PublicIP.IsAttached` only looks at `ipConfiguration`, not `natGateway`, and `Azure.VM.ADE` doesn't recognise encryption at host. PSRule's export also printed raw warnings for optional lookups (classic administrators, a preview Defender for Storage API).

## Fix
- Count only real entries: `@($x | Where-Object { $_ }).Count`.
- The mock now omits `zones` and `availabilityZoneMappings` when there are none.
- The two rules are suppressed with reasons in `.ps-rule/Suppressions.Rule.yaml`, narrowly: NAT Gateway IPs (`pip-ng-*`) and managed disks.
- Export warnings become one summary line (details with `-Verbose`).
- Each PSRule finding now shows the rule's first reason.

## Guard
The WellArchitected offline scenario asserts that a region without zones is reported as having none, and that no raw PSRule warnings are printed. Restoring `@($vm.zones).Count` makes it fail. `tests/portal/fixtures/real-postdeploy-waf.txt` keeps the real output.

## Rule
Never count an ARM property with `@($x).Count` alone; filter out nulls. The mock must omit empty properties the way ARM does.
