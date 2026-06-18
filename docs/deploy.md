# Deploy walkthrough

End-to-end, cold start to a working desktop. The infra is `az` + Bicep; the post-deploy config is PowerShell.

## 0. Prereqs

- Azure subscription you can deploy to (a personal pay-as-you-go sub is fine)
- Azure CLI ≥ 2.60 with bicep (`az bicep upgrade`)
- PowerShell 7+ with `Az` modules (`Install-Module Az`)
- vCPU quota in your target region — [check first](gotchas.md#2-vcpu-quota-in-your-target-region)

No hub and no domain are required for the standalone path.

```bash
az login
az account set --subscription "<your-subscription-id>"
```

## 1. Parameters

```bash
cp parameters/dev.example.bicepparam parameters/dev.bicepparam
```

The example defaults already run **standalone** (no hub). You only need to touch:
- `namePrefix` — short prefix; everything derives from it
- `location`
- `sessionHostVmSize` — confirm quota for this size
- leave `adminPassword = ''` — you'll be prompted at deploy time
- leave `desktopUserObjectIds = []` — the deploy script grants the desktop to you
- leave `hubVnetResourceId = ''` — empty = standalone. Set it only to peer to a real hub.

## 2. Dry run (recommended)

```bash
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -g rg-avd-lz-dev -l eastus2 --what-if
```

Review the what-if output. Nothing is created.

## 3. Deploy the infrastructure

```bash
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -g rg-avd-lz-dev -l eastus2
```

This creates: spoke VNet + subnets + NSG + route table + hub peering → storage account + file share → private endpoint + DNS zone → host pool + app group + workspace + session host VMs → scaling plan.

## 4. Post-deploy config

```bash
# Point FSLogix at the profile share
pwsh ./scripts/config/Configure-FSLogix.ps1 -ResourceGroup rg-avd-lz-dev

# Install the AVD agent and register hosts to the pool
pwsh ./scripts/config/Register-SessionHosts.ps1 -ResourceGroup rg-avd-lz-dev
```

## 5. Verify

- Host pool blade → session hosts show **Available** within a few minutes.
- Assign yourself to the desktop application group (or be in `desktopUserObjectIds`).
- Connect via the AVD client. Profile should load from FSLogix.

If a host doesn't register or a profile doesn't load, start with [gotchas.md](gotchas.md).

## Teardown

```bash
az group delete -n rg-avd-lz-dev --yes --no-wait
```
