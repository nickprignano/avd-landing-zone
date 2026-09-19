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

Or skip `az account set` and pass `-s <subscription-id>` to the deploy and
stop-lab scripts instead — they print the target subscription before doing
anything, which is worth having if you have more than one.

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

This creates: spoke VNet + subnets + NSG (plus route table + hub peering only in
hub-peered mode) → storage account + file share → private endpoint + DNS zone →
host pool + app group + workspace + session host VMs → scaling plan → role
assignments.

## 4. Post-deploy config

```bash
# Point FSLogix at the profile share
pwsh ./scripts/config/Configure-FSLogix.ps1 -ResourceGroup rg-avd-lz-dev

# Install the AVD agent and register hosts to the pool
pwsh ./scripts/config/Register-SessionHosts.ps1 -ResourceGroup rg-avd-lz-dev
```

## 5. Grant admin consent for Entra Kerberos (manual, once)

Session hosts are Entra-ID joined, so the profile share authenticates with Entra
Kerberos. Enabling it creates an app registration for the storage account, and
that registration needs admin consent from a **Global Administrator** before any
host can get a ticket. Neither Bicep nor the config scripts can do this for you.

```bash
STG=$(az storage account list -g rg-avd-lz-dev --query "[0].name" -o tsv)
APP_ID=$(az ad app list --display-name "[Storage Account] $STG" --query "[0].appId" -o tsv)
az ad app permission admin-consent --id "$APP_ID"
```

Session hosts also need a reboot after `Configure-FSLogix.ps1`, because
`CloudKerberosTicketRetrievalEnabled` only takes effect on restart.

```bash
az vm restart -g rg-avd-lz-dev --ids $(az vm list -g rg-avd-lz-dev --query "[].id" -o tsv)
```

## 6. Verify

- Host pool blade → session hosts show **Available** within a few minutes.
- Assign yourself to the desktop application group (or be in `desktopUserObjectIds`).
- Connect via the AVD client. Profile should load from FSLogix.

If the desktop appears but sign-in fails, that's RBAC, not credentials — see
[gotchas.md](gotchas.md). If sign-in works but the profile doesn't roam, the
admin consent in step 5 or the NTFS permissions on the share are the usual
cause.

If a host doesn't register or a profile doesn't load, start with [gotchas.md](gotchas.md).

## Teardown

```bash
az group delete -n rg-avd-lz-dev --yes --no-wait
```
