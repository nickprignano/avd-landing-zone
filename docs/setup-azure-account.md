# Setup — Azure tenant & subscription on a personal card (lab use)

This guide is for trying the landing zone in a personal lab. Production deployments go into a dedicated subscription from your platform team; start at [deploy.md](deploy.md).

You need an Azure subscription (and the Entra tenant that comes with it) before you can deploy anything. Signing up creates **both at once** — there's no separate "create a tenant" step. This takes about 10 minutes.

> **Why pay-as-you-go and not the free trial?** AVD runs real VMs and premium storage, which are **not** free-tier services. The $200 free-credit path works, but it adds 30-day expiry and free-tier-eligibility friction you don't want mid-demo. Signing up directly as pay-as-you-go (or upgrading immediately) makes the deployment "just work." You still only pay for what you use — a short AVD demo is a few dollars — but **tear it down when done** (step 7).

## What you need

- A credit or debit card — **not prepaid or virtual** (those are rejected). In Hong Kong and Brazil, credit cards only.
- A phone number (SMS verification).
- A Microsoft account or GitHub account (you can create one during signup).

A ~$1 temporary authorization hold may appear on the card during verification; it's removed automatically, not a charge.

## Steps

### 1. Sign up

1. Go to **https://azure.microsoft.com** and click **Start free** (or **Buy now** / **Pay as you go** if you want to skip the free-credit phase entirely).
2. Sign in with a Microsoft or GitHub account, or create one.
3. Enter your profile + phone number; complete the SMS code.
4. Enter your card details. Make sure the billing address matches your bank records and the selected country/region. (If verification hangs, allow third-party cookies in the browser.)
5. Accept the agreement and finish. You now have a tenant **and** a subscription.

### 2. (If you used the free trial) Upgrade to pay-as-you-go

If you took the $200-credit path, remove the spending limit so AVD resources can deploy:

- Portal → **Subscriptions** → your subscription → **Settings → Spending limit** → remove it / upgrade to pay-as-you-go.

You keep any remaining credit for the rest of the 30 days; usage beyond free amounts bills to your card.

### 3. Confirm what you've got

```bash
az login
az account show -o table          # shows your subscription name + id
az account show --query id -o tsv  # the subscription id you'll deploy into
```

If `az` isn't installed: https://learn.microsoft.com/cli/azure/install-azure-cli

### 4. Check your region quota (do this BEFORE deploying)

Brand-new subscriptions often start with **very low vCPU quota** — this is the most common thing that blocks an AVD demo.

```bash
az vm list-usage --location northcentralus -o table | grep -i "standard d"
```

The dev parameters deploy one `Standard_D4as_v5` (4 vCPUs). If you're below that, request an increase: Portal → **Subscriptions → Usage + quotas**.

### 5. Create the two Entra groups

```bash
az ad group create --display-name "AVD Users" --mail-nickname avd-users
az ad group create --display-name "AVD Admins" --mail-nickname avd-admins
az ad group member add --group "AVD Users" --member-id $(az ad signed-in-user show --query id -o tsv)
```

### 6. Lab-specific parameter changes

A personal tenant has no Intune licence, so edit `parameters/dev.bicepparam` and add:

```bicep
param enrollInIntune = false
```

### 7. Deploy

```bash
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus \
  --users-group "AVD Users" --admins-group "AVD Admins"
```

Then do the [post-deployment steps](deploy.md#4-post-deployment). In a personal tenant you're the Global Administrator, so you can grant the admin consent yourself.

### 8. Verify

Open the [Windows App](https://windows.cloud.microsoft), sign in with the same account, and connect to the desktop. See [deploy.md](deploy.md#5-verify).

### 9. Tear it down (important — it's your card)

Follow [deploy.md → Teardown](deploy.md#7-teardown). The dev parameters don't enable backup, so in practice:

```bash
for rg in hosts avd storage management network; do
  az group delete -n rg-avdlz-dev-$rg --yes
done
```

Deleting the resource groups stops the VM and storage charges. The subscription itself costs nothing when idle.

---

## Notes & limits

- **One free account per person.** If you've used the Azure free account before, you won't get the $200 credit again — sign up pay-as-you-go instead.
- **Entra tenant is included and free.** Entra ID Free comes with the billing account; you can't (and don't need to) cancel it.
- **AVD access requires an eligible licence** for each user (e.g. Microsoft 365 E3/E5/Business Premium or Windows Enterprise E3/E5). For a short personal lab you're paying for the VMs and storage; check licensing before letting anyone else use it.
- **Entra Kerberos for cloud-only identities**: a personal tenant only has cloud-only users. Check [Microsoft's current guidance](https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable) for cloud-only support. If Entra Kerberos isn't working, FSLogix blocks sign-in on purpose (`PreventLoginWithFailure`); work through [gotchas](gotchas.md#fslogix-profiles-dont-attach).
- These steps reflect Azure's signup flow as of mid-2026; Microsoft changes the portal and offer terms periodically, so if a screen differs, follow the on-screen prompts — the substance (card + phone + Microsoft account → tenant + subscription) is stable.
